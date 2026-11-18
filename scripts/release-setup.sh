#!/usr/bin/env bash
# One-time setup of the maintainer's Mac for scripts/release.sh. Creates, in the
# login keychain:
#   - "Playhouse Release Signing", a self-signed code signing certificate. Every
#     release is signed with it, and an installed Playhouse accepts an update
#     only when it carries the same certificate.
#   - "Playhouse Release Manifest Key", the Ed25519 private key that signs each
#     release's playhouse-release.json.
# and writes the manifest key's public half into
# Playhouse/Bridge/ReleaseSigningKey.swift, which you then commit.
#
# Running it again reuses whatever already exists. Back up both items (Keychain
# Access → Export): losing either means installed copies can't verify updates
# and have to be reinstalled by hand.
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
certificate_name="Playhouse Release Signing"
manifest_key_service="Playhouse Release Manifest Key"
manifest_key_account="playhouse-release"
key_file="${repository_root}/Playhouse/Bridge/ReleaseSigningKey.swift"
keychain="$(security default-keychain -d user | tr -d ' "')"

if security find-identity -v -p codesigning | grep -q "\"${certificate_name}\""; then
  printf 'Code signing certificate "%s" already exists.\n' "${certificate_name}"
else
  printf 'Creating the self-signed code signing certificate "%s"...\n' "${certificate_name}"
  work="$(mktemp -d)"
  trap 'rm -rf "${work}"' EXIT
  cat > "${work}/certificate.cnf" <<EOF
[req]
distinguished_name = subject
x509_extensions = extensions
prompt = no
[subject]
CN = ${certificate_name}
[extensions]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF
  /usr/bin/openssl req -x509 -newkey rsa:3072 -nodes -days 7300 -sha256 \
    -config "${work}/certificate.cnf" \
    -keyout "${work}/key.pem" -out "${work}/certificate.pem" 2>/dev/null
  password="$(uuidgen)"
  /usr/bin/openssl pkcs12 -export -inkey "${work}/key.pem" -in "${work}/certificate.pem" \
    -name "${certificate_name}" -passout "pass:${password}" -out "${work}/identity.p12"
  security import "${work}/identity.p12" -k "${keychain}" -P "${password}" -T /usr/bin/codesign
  printf 'Trusting it for code signing (macOS asks for your password)...\n'
  security add-trusted-cert -p codeSign -k "${keychain}" "${work}/certificate.pem"
  security find-identity -v -p codesigning | grep -q "\"${certificate_name}\"" || {
    printf 'The certificate was imported but codesign does not list it as valid.\n' >&2
    exit 1
  }
fi

if private_key="$(security find-generic-password -s "${manifest_key_service}" -a "${manifest_key_account}" -w 2>/dev/null)"; then
  printf 'Manifest signing key "%s" already exists.\n' "${manifest_key_service}"
else
  printf 'Creating the manifest signing key "%s"...\n' "${manifest_key_service}"
  keys="$("${repository_root}/scripts/release-tool.sh" keygen)"
  private_key="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["privateKey"])' "${keys}")"
  security add-generic-password -s "${manifest_key_service}" -a "${manifest_key_account}" \
    -T "" -w "${private_key}" "${keychain}"
fi

public_key="$(PLAYHOUSE_RELEASE_PRIVATE_KEY="${private_key}" "${repository_root}/scripts/release-tool.sh" public-key)"
python3 - "${key_file}" "${public_key}" <<'PY'
import re, sys
path, key = sys.argv[1], sys.argv[2]
text = open(path, encoding="utf-8").read()
updated = re.sub(r'static let publicKey = "[^"]*"', f'static let publicKey = "{key}"', text)
if updated == text and f'"{key}"' not in text:
    sys.exit(f"Couldn't find publicKey in {path}")
open(path, "w", encoding="utf-8").write(updated)
PY
printf 'Release public key: %s\n' "${public_key}"
if ! git -C "${repository_root}" diff --quiet -- "${key_file}"; then
  printf 'Updated %s. Commit it; releases built before it cannot verify manifests.\n' "${key_file#"${repository_root}/"}"
fi
printf 'Back up both keychain items now (Keychain Access → Export).\n'
