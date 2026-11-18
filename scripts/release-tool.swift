// Signs Playhouse release manifests with Ed25519, the same way the app checks
// them (`ReleaseManifestVerifier`). Used by scripts/release.sh and the update
// test fixtures; scripts/release-tool.sh compiles and caches it.
//
//   release-tool keygen
//       Prints {"privateKey": "<base64>", "publicKey": "<base64>"}.
//   release-tool public-key
//       Prints the public key of the private key in PLAYHOUSE_RELEASE_PRIVATE_KEY.
//   release-tool sign <release-info.json>
//       Prints the signed manifest of the file's exact bytes, with the private
//       key in PLAYHOUSE_RELEASE_PRIVATE_KEY.

import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("release-tool: \(message)\n".utf8))
    exit(1)
}

func json(_ object: [String: String]) -> String {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
}

func privateKey() -> Curve25519.Signing.PrivateKey {
    guard let encoded = ProcessInfo.processInfo.environment["PLAYHOUSE_RELEASE_PRIVATE_KEY"], !encoded.isEmpty else {
        fail("PLAYHOUSE_RELEASE_PRIVATE_KEY is not set.")
    }
    guard let data = Data(base64Encoded: encoded.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) else {
        fail("PLAYHOUSE_RELEASE_PRIVATE_KEY is not a base64 Ed25519 private key.")
    }
    return key
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "keygen":
    let key = Curve25519.Signing.PrivateKey()
    print(json([
        "privateKey": key.rawRepresentation.base64EncodedString(),
        "publicKey": key.publicKey.rawRepresentation.base64EncodedString(),
    ]))
case "public-key":
    print(privateKey().publicKey.rawRepresentation.base64EncodedString())
case "sign":
    guard arguments.count == 2 else { fail("Use: release-tool sign <release-info.json>") }
    guard let payload = FileManager.default.contents(atPath: arguments[1]) else { fail("Can't read \(arguments[1]).") }
    guard (try? JSONSerialization.jsonObject(with: payload)) is [String: Any] else { fail("\(arguments[1]) isn't a JSON object.") }
    let signature = try privateKey().signature(for: payload)
    print(json([
        "payload": payload.base64EncodedString(),
        "signature": signature.base64EncodedString(),
    ]))
default:
    fail("Use: release-tool keygen | public-key | sign <release-info.json>")
}
