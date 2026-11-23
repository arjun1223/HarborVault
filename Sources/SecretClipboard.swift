import AppKit
import CryptoKit

@MainActor enum SecretClipboard {
    private static var changeCount: Int?
    private static var expiry: DispatchWorkItem?
    private static var ownedBoard: NSPasteboard?
    static func copy(_ secret: String, to board: NSPasteboard = .general, expiresAfter: TimeInterval = 60) {
        clearIfOwned()
        let item = NSPasteboardItem()
        item.setString(secret, forType: .string)
        item.setData(Data(), forType: .init("org.nspasteboard.ConcealedType"))
        item.setData(Data(), forType: .init("org.nspasteboard.TransientType"))
        board.clearContents()
        board.writeObjects([item])
        changeCount = board.changeCount
        ownedBoard = board
        let task = DispatchWorkItem { clearIfOwned() }
        expiry = task
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, expiresAfter), execute: task)
    }
    static func clearIfOwned() {
        expiry?.cancel(); expiry = nil
        if let changeCount, let ownedBoard, ownedBoard.changeCount == changeCount { ownedBoard.clearContents() }
        changeCount = nil
        ownedBoard = nil
    }
}

enum ProtectedSharingKey {
    private struct Envelope: Codable {
        let version: Int
        let salt: Data
        let rounds: Int
        let sealed: Data
    }
    static func save(_ sharingKey: String, password: String, to url: URL) throws {
        guard password.count >= 10 else { throw VaultError.message("Protect the saved key with at least 10 characters.") }
        _ = try PortableVault.parseKey(sharingKey)
        let salt = try VaultCrypto.random(32)
        let key = try VaultCrypto.derive(password, salt: salt)
        let sealed = try VaultCrypto.seal(Data(sharingKey.utf8), key: key, context: "Harbor protected sharing key v1")
        let envelope = Envelope(version: 1, salt: salt, rounds: VaultCrypto.rounds, sealed: sealed)
        try VaultStorage.atomic(JSONEncoder().encode(envelope), to: url)
    }
    static func load(from url: URL, password: String) throws -> String {
        let envelope = try JSONDecoder().decode(Envelope.self, from: SecurityIO.read(url, maximum: 4096))
        guard envelope.version == 1, envelope.rounds == VaultCrypto.rounds else { throw VaultError.message("Unsupported saved-key format.") }
        let key = try VaultCrypto.derive(password, salt: envelope.salt, rounds: envelope.rounds)
        let bytes: Data
        do { bytes = try VaultCrypto.open(envelope.sealed, key: key, context: "Harbor protected sharing key v1") }
        catch { throw VaultError.message("That password didn’t unlock the saved key.") }
        guard let sharingKey = String(data: bytes, encoding: .utf8) else { throw VaultError.message("Invalid saved key.") }
        _ = try PortableVault.parseKey(sharingKey)
        return sharingKey
    }
}
