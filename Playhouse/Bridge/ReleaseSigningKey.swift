/// The Ed25519 public key that release manifests are signed with, base64 of its
/// raw 32 bytes. `scripts/release-setup.sh` writes it once, keeping the private
/// half in the maintainer's login keychain. Empty means this build has no
/// release key yet, and it never offers an update.
enum ReleaseSigningKey {
    static let publicKey = ""
}
