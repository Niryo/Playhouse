#!/usr/bin/env bash
# Runs every Component Catalog showcase through playhouse-plugin-dev with the
# generic smoke driver (scripts/showcase-smoke.py). Uses the same cached e2e
# build as scripts/test-e2e.sh; needs no app window and no UI-test lock.
#   scripts/test-showcases.sh [--only <section>/<showcase>]...
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repository_root}/scripts/app-profile.sh"
playhouse_load_app_profile "${repository_root}"

driver_arguments=()
while (( $# > 0 )); do
  case "$1" in
    --only)
      if (( $# < 2 )); then
        printf 'Expected <section>/<showcase> after --only.\n' >&2
        exit 2
      fi
      driver_arguments+=(--only "$2")
      shift 2
      ;;
    *)
      printf 'Unknown argument: %s\nUsage: %s [--only <section>/<showcase>]...\n' "$1" "$0" >&2
      exit 2
      ;;
  esac
done

build_info="$(python3 "${repository_root}/scripts/prepare-e2e-build.py" \
  --root "${repository_root}" \
  --profile-bundle-id "${PLAYHOUSE_PROFILE_BUNDLE_ID}" \
  --architecture "$(uname -m)")"
derived_data_dir="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["derivedData"])' "${build_info}")"
runner="${derived_data_dir}/Build/Products/Debug/Playhouse.app/Contents/MacOS/playhouse-plugin-dev"
if [[ ! -x "${runner}" ]]; then
  printf 'The app build did not produce playhouse-plugin-dev at %s.\n' "${runner}" >&2
  exit 1
fi

# The runner's api calls reach a daemon only if a showcase makes one; non-live
# showcases don't, so an isolated data directory keeps the run off real data.
data_directory="$(mktemp -d /tmp/playhouse-showcases.XXXXXX)"
trap 'rm -rf "${data_directory}"' EXIT
PLAYHOUSE_DATA_DIRECTORY="${data_directory}" python3 "${repository_root}/scripts/showcase-smoke.py" \
  --runner "${runner}" \
  --showcases "${repository_root}/Playhouse/Resources/Showcase" \
  "${driver_arguments[@]+"${driver_arguments[@]}"}"
