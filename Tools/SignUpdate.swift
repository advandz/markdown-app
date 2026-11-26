//
//  SignUpdate.swift
//  Markdown
//
//  Copyright © 2026 Advandz Technologies, LLC.
//

// Signs release disk images so the app's updater can tell genuine updates
// from forged ones (Ed25519, as Sparkle does). The private key stays in your
// login Keychain; the app carries the public key as MarkdownUpdatePublicKey
// in Support/App-Info.plist.
//
//   swift Tools/SignUpdate.swift generate                 create the key (once), print its public key
//   swift Tools/SignUpdate.swift public-key               print the public key
//   swift Tools/SignUpdate.swift sign <dmg> [--expect <public key>]
//                                                         write <dmg>.sig, optionally checking the key first
//   swift Tools/SignUpdate.swift verify <dmg> <public key>
//   swift Tools/SignUpdate.swift export                   print the private key, for a password manager
//   swift Tools/SignUpdate.swift import                   store a private key read from standard input
//
// Add --key-file <path> to use a raw 32-byte key file instead of the Keychain
// (for tests). Back the key up somewhere safe: without it, installed copies
// can't verify later releases and won't update automatically.
import CryptoKit
import Foundation
import Security

let service = "Markdown update signing key"
let account = "advandz/markdown-app"

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data(("✗ " + message + "\n").utf8))
    exit(code)
}

var arguments = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    let value = arguments[index + 1]
    arguments.removeSubrange(index...index + 1)
    return value
}
let keyFile = option("--key-file")
let expected = option("--expect")

func keychainQuery() -> [String: Any] {
    [kSecClass as String: kSecClassGenericPassword,
     kSecAttrService as String: service,
     kSecAttrAccount as String: account]
}

func loadKey() -> Curve25519.Signing.PrivateKey? {
    if let keyFile {
        return FileManager.default.contents(atPath: keyFile).flatMap { try? .init(rawRepresentation: $0) }
    }
    var query = keychainQuery()
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
    return try? .init(rawRepresentation: data)
}

func publicKey(of key: Curve25519.Signing.PrivateKey) -> String {
    key.publicKey.rawRepresentation.base64EncodedString()
}

func save(_ key: Curve25519.Signing.PrivateKey) {
    if let keyFile {
        guard FileManager.default.createFile(atPath: keyFile, contents: key.rawRepresentation,
                                             attributes: [.posixPermissions: 0o600]) else { fail("Couldn't write \(keyFile)") }
        return
    }
    var item = keychainQuery()
    item[kSecValueData as String] = key.rawRepresentation
    item[kSecAttrLabel as String] = service
    item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
    let status = SecItemAdd(item as CFDictionary, nil)
    guard status == errSecSuccess else { fail("Couldn't add the key to the Keychain (\(status)).") }
}

switch arguments.first {
case "generate":
    guard loadKey() == nil else { fail("A signing key already exists. Its public key: run `public-key`.") }
    let key = Curve25519.Signing.PrivateKey()
    save(key)
    print(publicKey(of: key))

case "export":
    guard let key = loadKey() else { fail("No signing key on this Mac.", code: 2) }
    FileHandle.standardError.write(Data("This is the private signing key. Keep it secret, somewhere safe.\n".utf8))
    print(key.rawRepresentation.base64EncodedString())

case "import":
    guard loadKey() == nil else { fail("A signing key already exists on this Mac.") }
    let input = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
    guard let data = Data(base64Encoded: input.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) else {
        fail("That isn't a signing key exported with `export`.")
    }
    save(key)
    print(publicKey(of: key))

case "public-key":
    guard let key = loadKey() else { fail("No signing key. Create one with `generate`.", code: 2) }
    print(publicKey(of: key))

case "sign":
    guard arguments.count == 2 else { fail("usage: sign <dmg> [--expect <public key>]") }
    guard let key = loadKey() else { fail("No signing key on this Mac.", code: 2) }
    if let expected, expected != publicKey(of: key) {
        fail("This Mac's signing key doesn't match MarkdownUpdatePublicKey in Support/App-Info.plist.", code: 3)
    }
    let file = URL(fileURLWithPath: arguments[1])
    guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { fail("Couldn't read \(file.path)") }
    let signature = try key.signature(for: data)
    guard key.publicKey.isValidSignature(signature, for: data) else { fail("The new signature doesn't verify.") }
    try (signature.base64EncodedString() + "\n").write(to: file.appendingPathExtension("sig"), atomically: true, encoding: .utf8)
    print(file.appendingPathExtension("sig").path)

case "verify":
    guard arguments.count == 3,
          let keyData = Data(base64Encoded: arguments[2]),
          let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else {
        fail("usage: verify <dmg> <base64 public key>")
    }
    let file = URL(fileURLWithPath: arguments[1])
    guard let data = try? Data(contentsOf: file, options: .mappedIfSafe),
          let text = try? String(contentsOf: file.appendingPathExtension("sig"), encoding: .utf8),
          let signature = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
        fail("Couldn't read \(file.path) or its .sig file.")
    }
    guard key.isValidSignature(signature, for: data) else { fail("The signature doesn't match.") }
    print("✓ Signature verified")

default:
    fail("usage: SignUpdate.swift generate | public-key | sign <dmg> [--expect <key>] | verify <dmg> <key>  [--key-file <path>]")
}
