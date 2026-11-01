import Foundation
import CryptoKit
import CommonCrypto
import LocalAuthentication
import Security

enum VaultError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(s) = self { return s }; return nil }
}

enum VaultCrypto {
    static let rounds = 600_000
    static let chunkSize = 4 * 1024 * 1024
    static func random(_ count: Int) throws -> Data {
        var bytes = Data(count: count)
        let status = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        guard status == errSecSuccess else { throw VaultError.message("Could not generate secure random bytes.") }
        return bytes
    }
    static func derive(_ password: String, salt: Data, rounds: Int = rounds) throws -> SymmetricKey {
        guard salt.count == 32, (600_000...2_000_000).contains(rounds) else { throw VaultError.message("Invalid passcode parameters.") }
        let passwordBytes = Array(password.utf8)
        var output = Data(count: 32)
        let result = output.withUnsafeMutableBytes { out in
            salt.withUnsafeBytes { saltBytes in
                passwordBytes.withUnsafeBytes { pass in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pass.baseAddress!.assumingMemoryBound(to: Int8.self), passwordBytes.count,
                                        saltBytes.baseAddress!.assumingMemoryBound(to: UInt8.self), salt.count,
                                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(rounds), out.baseAddress!.assumingMemoryBound(to: UInt8.self), 32)
                }
            }
        }
        guard result == kCCSuccess else { throw VaultError.message("Passcode derivation failed.") }
        return SymmetricKey(data: output)
    }
    static func seal(_ data: Data, key: SymmetricKey, context: String) throws -> Data {
        try AES.GCM.seal(data, using: key, authenticating: Data(context.utf8)).combined!
    }
    static func open(_ data: Data, key: SymmetricKey, context: String) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key, authenticating: Data(context.utf8))
    }
    static func keyData(_ key: SymmetricKey) -> Data { key.withUnsafeBytes { Data($0) } }

    // The private key is hardware-bound. Its opaque representation is not a raw private key.
    // The Secure Enclave enforces user presence when deriving the unwrap key.
    struct MacUnlock: Codable {
        let privateKeyBlob: Data
        let ephemeralPublicKey: Data
        let wrappedKey: Data
    }
    static func makeMacUnlock(key: SymmetricKey, vaultID: UUID) throws -> MacUnlock {
        guard SecureEnclave.isAvailable else { throw VaultError.message("This Mac does not have an available Secure Enclave. Use a vault passcode instead.") }
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, [.privateKeyUsage, .userPresence], &error) else {
            throw error!.takeRetainedValue() as Error
        }
        let privateKey = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access)
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let secret = try ephemeral.sharedSecretFromKeyAgreement(with: privateKey.publicKey)
        let wrap = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(vaultID.uuidString.utf8), sharedInfo: Data("HarborVault Mac unlock v1".utf8), outputByteCount: 32)
        return MacUnlock(privateKeyBlob: privateKey.dataRepresentation, ephemeralPublicKey: ephemeral.publicKey.x963Representation,
                         wrappedKey: try seal(keyData(key), key: wrap, context: "mac/" + vaultID.uuidString))
    }
    static func macKey(_ unlock: MacUnlock, vaultID: UUID, context: LAContext) throws -> SymmetricKey {
        let privateKey = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: unlock.privateKeyBlob, authenticationContext: context)
        let publicKey = try P256.KeyAgreement.PublicKey(x963Representation: unlock.ephemeralPublicKey)
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: publicKey)
        let wrap = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(vaultID.uuidString.utf8), sharedInfo: Data("HarborVault Mac unlock v1".utf8), outputByteCount: 32)
        let data = try open(unlock.wrappedKey, key: wrap, context: "mac/" + vaultID.uuidString)
        guard data.count == 32 else { throw VaultError.message("Invalid vault key.") }
        return SymmetricKey(data: data)
    }

    private static func u64(_ n: UInt64) -> Data { var big = n.bigEndian; return withUnsafeBytes(of: &big) { Data($0) } }
    private static func read(_ input: FileHandle, _ count: Int) throws -> Data {
        let bytes = try input.read(upToCount: count) ?? Data()
        guard bytes.count == count else { throw VaultError.message("The encrypted file is incomplete.") }
        return bytes
    }
    private static func integer(_ data: Data) -> UInt64 { data.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) } }

    // Bounded-memory file encryption. The complete header and chunk position are authenticated.
    static func encryptFile(source: URL, destination: URL, key: SymmetricKey, vaultID: UUID, fileID: UUID) throws -> (Int64, Data) {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let length = try input.seekToEnd()
        try input.seek(toOffset: 0)
        let chunks = max(1, (length + UInt64(chunkSize) - 1) / UInt64(chunkSize))
        let header = Data("HARBOR01".utf8) + u64(length) + u64(chunks)
        guard FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw VaultError.message("Could not create encrypted file.") }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        try output.write(contentsOf: header)
        var hash = SHA256()
        var bytesRead: UInt64 = 0
        for index in 0..<chunks {
            try Task.checkCancellation()
            let data = try input.read(upToCount: chunkSize) ?? Data()
            let expected = Int(min(UInt64(chunkSize), length - bytesRead))
            guard data.count == expected else { throw VaultError.message("A source file changed during import. Its original was kept.") }
            bytesRead += UInt64(data.count)
            hash.update(data: data)
            let aad = Data((vaultID.uuidString + "/" + fileID.uuidString).utf8) + header + u64(index)
            let sealed = try AES.GCM.seal(data, using: key, authenticating: aad).combined!
            try output.write(contentsOf: u64(UInt64(sealed.count)))
            try output.write(contentsOf: sealed)
        }
        guard (try input.read(upToCount: 1) ?? Data()).isEmpty else { throw VaultError.message("A source file grew during import. Its original was kept.") }
        try output.synchronize()
        return (Int64(length), Data(hash.finalize()))
    }
    @discardableResult static func decryptFile(source: URL, key: SymmetricKey, vaultID: UUID, fileID: UUID, consume: (Data) throws -> Void) throws -> Data {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let header = try read(input, 24)
        guard header.prefix(8) == Data("HARBOR01".utf8) else { throw VaultError.message("Unknown encrypted file format.") }
        let length = integer(header.subdata(in: 8..<16))
        let chunks = integer(header.subdata(in: 16..<24))
        guard length <= UInt64(Int64.max) - UInt64(chunkSize), chunks == max(1, (length + UInt64(chunkSize) - 1) / UInt64(chunkSize)) else { throw VaultError.message("Invalid encrypted file header.") }
        var hash = SHA256()
        var total: UInt64 = 0
        for index in 0..<chunks {
            try Task.checkCancellation()
            let count = integer(try read(input, 8))
            let expected = min(UInt64(chunkSize), length - total)
            guard count == expected + 28 else { throw VaultError.message("Invalid encrypted file chunk.") }
            let sealed = try read(input, Int(count))
            let aad = Data((vaultID.uuidString + "/" + fileID.uuidString).utf8) + header + u64(index)
            let data = try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key, authenticating: aad)
            total += UInt64(data.count)
            hash.update(data: data)
            try consume(data)
        }
        guard total == length, (try input.read(upToCount: 1) ?? Data()).isEmpty else { throw VaultError.message("The encrypted file failed its length check.") }
        return Data(hash.finalize())
    }
    @discardableResult static func reencryptFile(source: URL, destination: URL, sourceKey: SymmetricKey, destinationKey: SymmetricKey, sourceVaultID: UUID, destinationVaultID: UUID, sourceFileID: UUID, destinationFileID: UUID, expectedSize: Int64, expectedDigest: Data) throws -> Data {
        guard expectedSize >= 0, expectedDigest.count == 32 else { throw VaultError.message("Invalid source file metadata.") }
        let length = UInt64(expectedSize)
        let chunks = max(1, (length + UInt64(chunkSize) - 1) / UInt64(chunkSize))
        let header = Data("HARBOR01".utf8) + u64(length) + u64(chunks)
        guard FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw VaultError.message("Could not stage the destination copy.") }
        let output = try FileHandle(forWritingTo: destination); defer { try? output.close() }
        try output.write(contentsOf: header)
        var index: UInt64 = 0
        let digest = try decryptFile(source: source, key: sourceKey, vaultID: sourceVaultID, fileID: sourceFileID) { data in
            let aad = Data((destinationVaultID.uuidString + "/" + destinationFileID.uuidString).utf8) + header + u64(index)
            let sealed = try AES.GCM.seal(data, using: destinationKey, authenticating: aad).combined!
            try output.write(contentsOf: u64(UInt64(sealed.count)))
            try output.write(contentsOf: sealed)
            index += 1
        }
        guard index == chunks, digest == expectedDigest else { throw VaultError.message("The source copy failed verification. Its original was kept.") }
        try output.synchronize()
        let verified = try decryptFile(source: destination, key: destinationKey, vaultID: destinationVaultID, fileID: destinationFileID) { _ in }
        guard verified == digest else { throw VaultError.message("The destination copy failed verification. Its original was kept.") }
        return digest
    }

}
