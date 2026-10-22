#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
common_git_dir="$(git -C "${repository_root}" rev-parse --git-common-dir)"
if [[ "${common_git_dir}" != /* ]]; then
  common_git_dir="${repository_root}/${common_git_dir}"
fi
common_git_dir="$(cd "${common_git_dir}" && pwd -P)"
shared_repository_root="$(cd "${common_git_dir}/.." && pwd -P)"
lock_path="${shared_repository_root}/.e2e.lock"

if (($# == 0)); then
  printf 'Usage: %s -- <command> [args...]\n' "$0" >&2
  exit 2
fi

if [[ "$1" == "--" ]]; then
  shift
fi

if (($# == 0)); then
  printf 'Usage: %s -- <command> [args...]\n' "$0" >&2
  exit 2
fi

exec python3 "${repository_root}/scripts/with-file-lock.py" "$lock_path" "$@"
