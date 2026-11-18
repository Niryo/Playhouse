#!/usr/bin/env bash
# Builds, signs and publishes a Playhouse release from this Mac to GitHub
# (Niryo/Playhouse). See docs/release-system.md.
#
#   scripts/release.sh <version> [--notes-file <path>] [--skip-tests] [--dry-run]
#   scripts/release.sh --bump patch|minor|major [...]
#
# Run it from the primary checkout, on master, with a clean tree, after
# scripts/release-setup.sh. --dry-run builds, signs, verifies and packages
# into /tmp/playhouse-release/<version> without tagging or publishing.
# Without --notes-file the notes are the commit subjects since the last release,
# opened in $EDITOR first when run from a terminal.
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "${repository_root}/scripts/app-profile.sh"
playhouse_load_app_profile "${repository_root}"

repository="Niryo/Playhouse"
certificate_name="Playhouse Release Signing"
manifest_key_service="Playhouse Release Manifest Key"
manifest_key_account="playhouse-release"
feed_url="https://github.com/${repository}/releases/latest/download/playhouse-release.json"

die() { printf 'release: %s\n' "$*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }

version=""
bump=""
notes_file=""
skip_tests=false
dry_run=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --bump) bump="${2:?--bump needs patch, minor or major}"; shift 2 ;;
    --notes-file) notes_file="${2:?--notes-file needs a path}"; shift 2 ;;
    --skip-tests) skip_tests=true; shift ;;
    --dry-run) dry_run=true; shift ;;
    -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) die "unknown option $1" ;;
    *) [[ -z "${version}" ]] || die "only one version"; version="${1#v}"; shift ;;
  esac
done

semver() { [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; }
newer() { # newer A B: A > B
  python3 -c 'import sys; a, b = (tuple(map(int, v.split("."))) for v in sys.argv[1:]); sys.exit(0 if a > b else 1)' "$1" "$2"
}

step "Preflight"
[[ "${PLAYHOUSE_PROFILE_KIND}" == "primary" ]] || die "run this from the primary checkout, not a linked worktree; releases use the com.playhouse.app bundle identifier."
[[ "$(uname -m)" == "arm64" ]] || die "releases are Apple Silicon builds; run this on an arm64 Mac."
command -v gh >/dev/null || die "the GitHub CLI (gh) is required."
gh auth status >/dev/null 2>&1 || die "gh is not signed in; run gh auth login."
branch="$(git -C "${repository_root}" branch --show-current)"
[[ "${branch}" == "master" ]] || die "release from master (on ${branch})."
[[ -z "$(git -C "${repository_root}" status --porcelain)" ]] || die "the working tree has changes; commit or remove them first."
git -C "${repository_root}" fetch --quiet origin master --tags
[[ "$(git -C "${repository_root}" rev-parse HEAD)" == "$(git -C "${repository_root}" rev-parse origin/master)" ]] \
  || die "master is not at origin/master; push or pull first."

latest="$(gh release view --repo "${repository}" --json tagName --jq .tagName 2>/dev/null || true)"
latest="${latest#v}"
if [[ -n "${bump}" ]]; then
  [[ -z "${version}" ]] || die "pass a version or --bump, not both."
  base="${latest:-0.0.0}"
  semver "${base}" || die "the latest release ${base} isn't a semantic version."
  IFS=. read -r major minor patch <<< "${base}"
  case "${bump}" in
    major) version="$((major + 1)).0.0" ;;
    minor) version="${major}.$((minor + 1)).0" ;;
    patch) version="${major}.${minor}.$((patch + 1))" ;;
    *) die "--bump takes patch, minor or major." ;;
  esac
fi
[[ -n "${version}" ]] || die "pass a version (for example 0.1.0) or --bump."
semver "${version}" || die "${version} isn't a semantic version (x.y.z)."
if [[ -n "${latest}" ]]; then
  newer "${version}" "${latest}" || die "${version} isn't newer than the latest release ${latest}."
elif newer 0.1.0 "${version}"; then
  die "the first release is 0.1.0 or later (got ${version})."
fi
tag="v${version}"
git -C "${repository_root}" rev-parse -q --verify "refs/tags/${tag}" >/dev/null && die "tag ${tag} already exists."

public_key="$(sed -n 's/.*static let publicKey = "\([^"]*\)".*/\1/p' "${repository_root}/Playhouse/Bridge/ReleaseSigningKey.swift")"
[[ -n "${public_key}" ]] || die "Playhouse/Bridge/ReleaseSigningKey.swift has no key; run scripts/release-setup.sh and commit it."
security find-identity -v -p codesigning | grep -q "\"${certificate_name}\"" \
  || die "no \"${certificate_name}\" certificate; run scripts/release-setup.sh."
printf 'Reading the manifest signing key from the keychain (macOS may ask to allow it)...\n'
PLAYHOUSE_RELEASE_PRIVATE_KEY="$(security find-generic-password -s "${manifest_key_service}" -a "${manifest_key_account}" -w)" \
  || die "no \"${manifest_key_service}\" keychain item; run scripts/release-setup.sh."
export PLAYHOUSE_RELEASE_PRIVATE_KEY
[[ "$("${repository_root}/scripts/release-tool.sh" public-key)" == "${public_key}" ]] \
  || die "the keychain's manifest key doesn't match ReleaseSigningKey.swift."

if [[ -z "${notes_file}" ]]; then
  notes_file="$(mktemp)"
  if [[ -n "${latest}" ]] && git -C "${repository_root}" rev-parse -q --verify "refs/tags/v${latest}" >/dev/null; then
    git -C "${repository_root}" log --no-merges --format='- %s' "v${latest}..HEAD" > "${notes_file}"
  else
    printf -- '- First release of Playhouse.\n' > "${notes_file}"
  fi
  # Edit the generated notes before they are signed into the release.
  if [[ -t 0 && -t 1 ]]; then
    "${VISUAL:-${EDITOR:-vi}}" "${notes_file}" || die "the notes editor exited with an error."
  fi
fi
[[ -s "${notes_file}" ]] || die "the release notes are empty."

# A rollback restores the app, not its data, so the store must stay readable by
# the previous release.
model_files=(Playhouse/App/BoardTask.swift Playhouse/App/ConversationSubject.swift)
if [[ -n "${latest}" ]] && git -C "${repository_root}" rev-parse -q --verify "refs/tags/v${latest}" >/dev/null \
  && ! git -C "${repository_root}" diff --quiet "v${latest}" HEAD -- "${model_files[@]}"; then
  printf 'warning: the SwiftData models changed since %s (%s).\n' "v${latest}" "${model_files[*]}" >&2
  printf 'warning: make sure Playhouse %s can still read data that %s writes, or a rollback loses it.\n' "${latest}" "${version}" >&2
fi
printf 'Releasing Playhouse %s (latest: %s)%s\n' "${version}" "${latest:-none}" "$(${dry_run} && printf ' — dry run')"

if ! ${skip_tests}; then
  step "Running the bridge test suite"
  "${repository_root}/scripts/test-e2e.sh"
fi

commit="$(git -C "${repository_root}" rev-parse HEAD)"
build_number="$(git -C "${repository_root}" rev-list --count HEAD)"
output="/tmp/playhouse-release/${version}"
derived_data="${output}/DerivedData"
rm -rf "${output}"
mkdir -p "${output}"

step "Building Release (arm64), build ${build_number}"
xcodebuild build -quiet \
  -project "${repository_root}/Playhouse.xcodeproj" \
  -scheme Playhouse \
  -configuration Release \
  -destination "platform=macOS,arch=arm64" \
  -derivedDataPath "${derived_data}" \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=YES \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGN_IDENTITY=- \
  MARKETING_VERSION="${version}" \
  CURRENT_PROJECT_VERSION="${build_number}" \
  PLAYHOUSE_APP_BUNDLE_IDENTIFIER=com.playhouse.app
app="${output}/Playhouse.app"
ditto "${derived_data}/Build/Products/Release/Playhouse.app" "${app}"

step "Stamping and signing"
info="${app}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Delete :PlayhouseGitCommit" "${info}" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :PlayhouseGitCommit string ${commit}" "${info}"
/usr/libexec/PlistBuddy -c "Delete :PlayhouseReleaseChannel" "${info}" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :PlayhouseReleaseChannel string stable" "${info}"
for helper in playhouse-cli playhouse-daemon; do
  codesign --force --sign "${certificate_name}" --timestamp=none "${app}/Contents/MacOS/${helper}"
done
codesign --force --sign "${certificate_name}" --timestamp=none "${app}"
codesign --verify --strict --deep --verbose=2 "${app}"

step "Verifying the bundle"
reported="$("${app}/Contents/MacOS/playhouse-cli" version)"
python3 - "${reported}" "${version}" "${build_number}" "${commit}" <<'PY'
import json, sys
result = json.loads(sys.argv[1])["result"]
expected = {"version": sys.argv[2], "build": sys.argv[3], "commit": sys.argv[4], "channel": "stable", "bundleIdentifier": "com.playhouse.app"}
wrong = {key: (result.get(key), value) for key, value in expected.items() if result.get(key) != value}
if wrong:
    sys.exit(f"release: the built CLI reports {wrong}")
PY
verification="$("${app}/Contents/MacOS/playhouse-cli" update verify-bundle --bundle "${app}" --version "${version}")" \
  || die "the app's own update check rejects the build: ${verification}"
python3 -c 'import json,sys; sys.exit(0 if json.loads(sys.argv[1])["result"]["certificateSHA256"] else "release: the build has no signing certificate")' "${verification}"

step "Packaging"
archive_name="Playhouse-${version}.zip"
archive="${output}/${archive_name}"
ditto -c -k --keepParent "${app}" "${archive}"
python3 - "${output}/release-info.json" "${version}" "${build_number}" "${commit}" "${notes_file}" "${archive}" "${repository}" "${tag}" <<'PY'
import datetime, hashlib, json, sys
from pathlib import Path
path, version, build, commit, notes, archive, repository, tag = sys.argv[1:]
data = Path(archive).read_bytes()
info = {
    "version": version,
    "build": build,
    "commit": commit,
    "publishedAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "minimumSystemVersion": "14.0",
    "architecture": "arm64",
    "notes": Path(notes).read_text(encoding="utf-8").strip(),
    "asset": {
        "name": Path(archive).name,
        "url": f"https://github.com/{repository}/releases/download/{tag}/{Path(archive).name}",
        "size": len(data),
        "sha256": hashlib.sha256(data).hexdigest(),
    },
}
Path(path).write_text(json.dumps(info, indent=2, sort_keys=True), encoding="utf-8")
PY
"${repository_root}/scripts/release-tool.sh" sign "${output}/release-info.json" > "${output}/playhouse-release.json"
unset PLAYHOUSE_RELEASE_PRIVATE_KEY
ls -lh "${archive}" "${output}/playhouse-release.json"

if ${dry_run}; then
  printf '\nDry run done; nothing was tagged or published. Artifacts are in %s\n' "${output}"
  exit 0
fi

step "Publishing ${tag}"
git -C "${repository_root}" tag -a "${tag}" -m "Playhouse ${version}"
git -C "${repository_root}" push origin "${tag}"
# A draft first, so the latest-release feed never points at a release whose
# files are still uploading.
gh release create "${tag}" --repo "${repository}" --draft --verify-tag \
  --title "Playhouse ${version}" --notes-file "${notes_file}" \
  "${archive}" "${output}/playhouse-release.json"
gh release edit "${tag}" --repo "${repository}" --draft=false --latest

step "Checking the public feed"
for attempt in 1 2 3 4 5 6; do
  served="$(curl -fsSL "${feed_url}" 2>/dev/null || true)"
  if python3 - "${served}" "${version}" <<'PY' 2>/dev/null
import base64, json, sys
sys.exit(0 if json.loads(base64.b64decode(json.loads(sys.argv[1])["payload"]))["version"] == sys.argv[2] else 1)
PY
  then
    printf 'Published Playhouse %s: https://github.com/%s/releases/tag/%s\n' "${version}" "${repository}" "${tag}"
    exit 0
  fi
  sleep 10
done
die "the release is published, but ${feed_url} doesn't serve ${version} yet; check the release page."
