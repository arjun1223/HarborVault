import Foundation
import CryptoKit

// Version 2 hides the legacy encrypted archive inside padded, independently keyed records.
// Only the padded total size and the format marker are public.
enum PortableEnvelope {
    static let magic = Data("HARBPK02".utf8)
    static let blockSize = 1024 * 1024
    private static let maximumSize: UInt64 = 1 << 40

    private static func number(_ n: UInt64) -> Data {
        var big = n.bigEndian
        return withUnsafeBytes(of: &big) { Data($0) }
    }
    private static func exact(_ input: FileHandle, count: Int) throws -> Data {
        let data = try input.read(upToCount: count) ?? Data()
        guard data.count == count else { throw VaultError.message("The portable vault is truncated.") }
        return data
    }
    private static func subkey(_ key: SymmetricKey, salt: Data, index: UInt64) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: key, salt: salt,
            info: Data("Harbor portable v2 record".utf8) + number(index), outputByteCount: 32)
    }
    static func wrap(_ source: URL, to destination: URL, key: SymmetricKey) throws {
        let input = try SecurityIO.open(source)
        defer { try? input.close() }
        let length = try input.seekToEnd()
        try input.seek(toOffset: 0)
        guard length <= maximumSize - 8 else { throw VaultError.message("This portable vault exceeds the supported size.") }
        var padded = UInt64(blockSize)
        while padded < length + 8 { padded *= 2 }
        let salt = try VaultCrypto.random(32)
        let header = magic + salt + number(padded)
        guard FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw VaultError.message("Could not create the encrypted envelope.")
        }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        try output.write(contentsOf: header)
        var remaining = length
        for index in 0..<(padded / UInt64(blockSize)) {
            try Task.checkCancellation()
            var block = index == 0 ? number(length) : Data()
            let count = Int(min(remaining, UInt64(blockSize - block.count)))
            block.append(try exact(input, count: count))
            remaining -= UInt64(count)
            block.append(Data(repeating: 0, count: blockSize - block.count))
            let sealed = try AES.GCM.seal(block, using: subkey(key, salt: salt, index: index),
                                         authenticating: header + number(index)).combined!
            try output.write(contentsOf: sealed)
            block.resetBytes(in: block.startIndex..<block.endIndex)
        }
        guard remaining == 0, try input.read(upToCount: 1)?.isEmpty != false else { throw VaultError.message("The staged archive changed during export.") }
        try output.synchronize()
    }
    static func unwrap(_ source: URL, to destination: URL, key: SymmetricKey) throws {
        let input = try SecurityIO.open(source)
        defer { try? input.close() }
        let fileSize = try input.seekToEnd()
        try input.seek(toOffset: 0)
        let header = try exact(input, count: 48)
        guard header.prefix(8) == magic else { throw VaultError.message("Unsupported portable vault format.") }
        let salt = header.subdata(in: 8..<40)
        let padded = header.suffix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        guard padded >= UInt64(blockSize), padded <= maximumSize, padded.nonzeroBitCount == 1,
              fileSize == 48 + padded + (padded / UInt64(blockSize)) * 28 else {
            throw VaultError.message("The portable vault has invalid framing.")
        }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw VaultError.message("Could not stage the encrypted archive.")
        }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var remaining: UInt64 = 0
        var innerLength: UInt64 = 0
        for index in 0..<(padded / UInt64(blockSize)) {
            try Task.checkCancellation()
            let sealed = try exact(input, count: blockSize + 28)
            var block: Data
            do {
                block = try AES.GCM.open(AES.GCM.SealedBox(combined: sealed),
                    using: subkey(key, salt: salt, index: index), authenticating: header + number(index))
            } catch { throw VaultError.message("That sharing key didn’t unlock this .harb file, or the file is damaged.") }
            var start = 0
            if index == 0 {
                innerLength = block.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                guard innerLength >= 80, innerLength <= padded - 8,
                      padded == UInt64(blockSize) || innerLength + 8 > padded / 2 else {
                    throw VaultError.message("Invalid encrypted archive length.")
                }
                remaining = innerLength
                start = 8
            }
            let count = Int(min(remaining, UInt64(block.count - start)))
            try output.write(contentsOf: block.subdata(in: start..<start + count))
            remaining -= UInt64(count)
            guard block[(start + count)...].allSatisfy({ $0 == 0 }) else { throw VaultError.message("Invalid encrypted padding.") }
            block.resetBytes(in: block.startIndex..<block.endIndex)
        }
        guard remaining == 0, try input.read(upToCount: 1)?.isEmpty != false else { throw VaultError.message("Invalid portable vault ending.") }
        try output.synchronize()
    }
}
