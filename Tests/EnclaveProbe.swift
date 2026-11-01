import Foundation
import CryptoKit
import Security
import CommonCrypto
print("Secure Enclave available:", SecureEnclave.isAvailable)
var error: Unmanaged<CFError>?
let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, [.privateKeyUsage, .userPresence], &error)!
do {
 let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access)
 print("Protected key created. Opaque representation bytes:", key.dataRepresentation.count)
 print("Public key bytes:", key.publicKey.x963Representation.count)
} catch { print("Protected key creation failed:", error); exit(1) }
