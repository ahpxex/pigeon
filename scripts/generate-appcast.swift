// generate-appcast.swift
// Signs an update zip with Ed25519 (Sparkle's sparkle:edSignature) and
// emits an appcast.xml. Run from CI:
//   swift generate-appcast.swift <zip-path> <version> <build> <download-url> <private-key-base64>
// The private key is the 32-byte seed (base64) stored in the
// SPARKLE_ED_PRIVATE_KEY GitHub secret; the app pins the matching
// public key via SUPublicEDKey.

import CryptoKit
import Foundation

let args = CommandLine.arguments
guard args.count == 6,
      let keyData = Data(base64Encoded: args[5]),
      // Sparkle-format private key is 64 bytes (seed || public); we sign
      // with the 32-byte seed alone (CryptoKit derives the public half).
      keyData.count == 32 || keyData.count == 64,
      let zipData = try? Data(contentsOf: URL(fileURLWithPath: args[1]))
else {
    FileHandle.standardError.write(
        Data("usage: generate-appcast <zip> <version> <build> <url> <ed-key-b64>\n".utf8))
    exit(1)
}
let zipPath = args[1]
let version = args[2]
let build = args[3]
let downloadURL = args[4]

let seed = keyData.prefix(32)  // 32B seed for both formats
let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(seed))
let signature = try privateKey.signature(for: zipData)
let escapedTitle = "Pigeon \(version)"
let escapedNotes = "Pigeon \(version) — see https://github.com/ahpxex/pigeon/releases/tag/v\(version)"

let appcast = """
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>Pigeon</title>
    <link>https://github.com/ahpxex/pigeon</link>
    <description>Most recent changes</description>
    <language>en</language>
    <item>
      <title>\(escapedTitle)</title>
      <sparkle:version>\(build)</sparkle:version>
      <sparkle:shortVersionString>\(version)</sparkle:shortVersionString>
      <description>\(escapedNotes)</description>
      <enclosure
        url="\(downloadURL)"
        sparkle:edSignature="\(signature.base64EncodedString())"
        length="\(zipData.count)"
        type="application/octet-stream" />
    </item>
  </channel>
</rss>
"""

try appcast.write(toFile: "appcast.xml", atomically: true, encoding: .utf8)
print("appcast.xml written: version \(version), \(zipData.count) bytes, sig \(signature.base64EncodedString().prefix(16))…")
