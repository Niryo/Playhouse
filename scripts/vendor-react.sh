#!/usr/bin/env bash
# One-time vendoring of the prebuilt React runtime the plugin renderer loads.
# Copies the production CommonJS builds of react, react-reconciler and
# scheduler into Playhouse/Resources/PluginRuntime/vendor. The app build never
# runs this; rerun it by hand only to change the pinned versions below.
set -euo pipefail

react_version="18.3.1"
reconciler_version="0.29.2"
scheduler_version="0.23.2"

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
destination="${repository_root}/Playhouse/Resources/PluginRuntime/vendor"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

cd "${work}"
npm pack --silent "react@${react_version}" "react-reconciler@${reconciler_version}" "scheduler@${scheduler_version}" >/dev/null
for package in react react-reconciler scheduler; do
  mkdir -p "${package}"
  tar -xzf "${package}"-[0-9]*.tgz -C "${package}" --strip-components 1
done

mkdir -p "${destination}"
cp react/cjs/react.production.min.js "${destination}/react.js"
cp scheduler/cjs/scheduler.production.min.js "${destination}/scheduler.js"
cp react-reconciler/cjs/react-reconciler.production.min.js "${destination}/react-reconciler.js"
cp react/LICENSE "${destination}/LICENSE"
printf 'react %s\nreact-reconciler %s\nscheduler %s\n' "${react_version}" "${reconciler_version}" "${scheduler_version}" > "${destination}/VERSIONS"
printf 'Vendored React runtime into %s\n' "${destination}"
