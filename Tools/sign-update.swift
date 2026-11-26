//
//  sign-update.swift
//  Markdown
//
//  Copyright © 2026 Advandz Technologies, LLC.
//

// Signs update disk images so the app's updater can tell a real release from a forged one.
//
//   swift Tools/sign-update.swift keygen            creates the private key (once) and prints the public key
//   swift Tools/sign-update.swift public-key        prints the public key
//   swift Tools/sign-update.swift sign <dmg> <ver>  writes <dmg>.sig
//
// The private key lives outside the repository (MARKDOWN_APP_SIGNING_KEY, default
// ~/.com.advandz.markdown/update-signing.key). Back it up and never commit it. The message that
// is signed must match UpdateSigning.message in Sources/App/UpdateSigning.swift, and the key must
// match UpdateSigning.publicKey there, or installed copies would reject the signature.

import CryptoKit
import Foundation

let keyPath = ProcessInfo.processInfo.environment["MARKDOWN_APP_SIGNING_KEY"]
    ?? NSHomeDirectory() + "/.com.advandz.markdown/update-signing.key"

func fail(_ text: String) -> Never { FileHandle.standardError.write(Data((text + "\n").utf8)); exit(1) }

func loadKey() -> Curve25519.Signing.PrivateKey {
    guard let text = try? String(contentsOfFile: keyPath, encoding: .utf8),
          let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw)
    else { fail("No signing key at \(keyPath). Run: swift Tools/sign-update.swift keygen, or restore it from your backup.") }
    return key
}

/// The public key compiled into the app, read from its source.
func appPublicKey() -> String? {
    let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../Sources/App/UpdateSigning.swift").standardizedFileURL
    guard let text = try? String(contentsOf: source, encoding: .utf8),
          let range = text.range(of: #"static let publicKey = "([^"]*)""#, options: .regularExpression) else { return nil }
    return text[range].split(separator: "\"").dropFirst().first.map(String.init)
}

/// Versions are signed as x.y.z, as the app compares them ("1.1" → "1.1.0").
func normalized(_ version: String) -> String {
    var text = version.trimmingCharacters(in: .whitespaces)
    if text.first == "v" || text.first == "V" { text.removeFirst() }
    var parts = text.split(separator: ".").map(String.init)
    while parts.count < 3 { parts.append("0") }
    return parts.joined(separator: ".")
}

let args = CommandLine.arguments.dropFirst()
switch args.first {
case "keygen":
    if FileManager.default.fileExists(atPath: keyPath) {
        print("Key already exists at \(keyPath)")
    } else {
        let dir = (keyPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let key = Curve25519.Signing.PrivateKey()
        FileManager.default.createFile(atPath: keyPath, contents: Data((key.rawRepresentation.base64EncodedString() + "\n").utf8),
                                       attributes: [.posixPermissions: 0o600])
        print("Created \(keyPath). Back it up and keep it secret.")
    }
    print("Public key: \(loadKey().publicKey.rawRepresentation.base64EncodedString())")
case "public-key":
    print(loadKey().publicKey.rawRepresentation.base64EncodedString())
case "sign":
    let rest = Array(args.dropFirst())
    guard rest.count == 2, let data = try? Data(contentsOf: URL(fileURLWithPath: rest[0]), options: .mappedIfSafe)
    else { fail("usage: sign <dmg> <version>") }
    let key = loadKey()
    let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
    guard appPublicKey() == publicKey else {
        fail("The key at \(keyPath) (public key \(publicKey)) isn't UpdateSigning.publicKey, so the app would reject this signature.")
    }
    let version = normalized(rest[1])
    let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    let message = Data("markdown-app-update\n\(version)\n\(hash)\n".utf8)
    let signature = try key.signature(for: message)
    try Data((signature.base64EncodedString() + "\n").utf8).write(to: URL(fileURLWithPath: rest[0] + ".sig"))
    print("Signed \(rest[0]) (version \(version))")
default:
    fail("usage: sign-update.swift keygen | public-key | sign <dmg> <version>")
}
