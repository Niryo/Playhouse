#!/bin/sh
# Deterministic stand-in for the GitHub CLI used by the bridge and UI suites.
# It answers pull-request list/create calls and `gh pr view <number> --json
# mergedAt[,mergeable,headRefOid]` from a state file (lines of
# `<number>=<merged|unmerged|conflicting|head-mismatch>`) and logs each probe.
# Create calls return sequential fixture PR numbers. Environment:
#   PLAYHOUSE_E2E_GH_STATE_PATH          state file (required)
#   PLAYHOUSE_E2E_GH_CALL_LOG            append-only log of probed PR numbers (required)
#   PLAYHOUSE_E2E_GH_CREATE_LOG          append-only log of list/create calls
#   PLAYHOUSE_E2E_GH_CREATE_FIRST_NUMBER first generated PR number (default 501)
#   PLAYHOUSE_E2E_GH_CREATE_FAILURE_PATH  optional file containing create attempt to fail
#   PLAYHOUSE_E2E_GH_STARTED_DIRECTORY   with EXPECTED_IDS, full probes must all start
#   PLAYHOUSE_E2E_GH_EXPECTED_IDS        before any answers (parallel-probe check)
#   PLAYHOUSE_E2E_GH_REMOTE_REPOSITORY   bare repo whose refs/heads/pr-<n> is the PR head
# The bridge daemon forwards only session environment variables to the
# processes it runs for a CLI request, so a CLI-driven probe cannot deliver the
# PLAYHOUSE_E2E_GH_* configuration. Default to files beside this script; an
# app-process caller (the UI suite) still overrides them through its own env.
script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
: "${PLAYHOUSE_E2E_GH_STATE_PATH:=$script_directory/state}"
: "${PLAYHOUSE_E2E_GH_CALL_LOG:=$script_directory/calls}"
: "${PLAYHOUSE_E2E_GH_CREATE_LOG:=$script_directory/create-calls}"
if [ ! -f "$PLAYHOUSE_E2E_GH_STATE_PATH" ]; then
  echo 'gh fixture requires a state file (PLAYHOUSE_E2E_GH_STATE_PATH or `state` beside the script)' >&2
  exit 2
fi
touch "$PLAYHOUSE_E2E_GH_CREATE_LOG"
if [ "$1" = pr ] && [ "$2" = list ]; then
  printf 'list\t%s\t%s\n' "$PWD" "$*" >> "$PLAYHOUSE_E2E_GH_CREATE_LOG"
  printf '[]\n'
  exit 0
fi
if [ "$1" = pr ] && [ "$2" = create ]; then
  attempt=$(awk -F '\t' '$1 == "created" || $1 == "failed" { count++ } END { print count + 1 }' "$PLAYHOUSE_E2E_GH_CREATE_LOG")
  failure_attempt=
  if [ -n "${PLAYHOUSE_E2E_GH_CREATE_FAILURE_PATH:-}" ] && [ -f "$PLAYHOUSE_E2E_GH_CREATE_FAILURE_PATH" ]; then
    failure_attempt=$(cat "$PLAYHOUSE_E2E_GH_CREATE_FAILURE_PATH")
  fi
  if [ "$attempt" = "$failure_attempt" ]; then
    printf 'failed\t%s\t%s\n' "$PWD" "$*" >> "$PLAYHOUSE_E2E_GH_CREATE_LOG"
    echo 'fixture GitHub create failure' >&2
    exit 1
  fi
  printf 'create\t%s\t%s\n' "$PWD" "$*" >> "$PLAYHOUSE_E2E_GH_CREATE_LOG"
  count=$(awk -F '\t' '$1 == "created" { count++ } END { print count }' "$PLAYHOUSE_E2E_GH_CREATE_LOG")
  first_number=${PLAYHOUSE_E2E_GH_CREATE_FIRST_NUMBER:-501}
  create_number=$((first_number + count))
  printf 'created\t%s\t%s\n' "$PWD" "$create_number" >> "$PLAYHOUSE_E2E_GH_CREATE_LOG"
  printf 'https://github.com/playhouse-test/fixture/pull/%s\n' "$create_number"
  exit 0
fi
if [ "$1" != pr ] || [ "$2" != view ] || ! printf '%s' "$3" | grep -Eq '^[0-9]+$' || [ "$4" != --json ]; then
  echo 'Unexpected gh fixture command' >&2
  exit 2
fi
printf '%s\n' "$3" >> "$PLAYHOUSE_E2E_GH_CALL_LOG"
state=$(awk -F= -v number="$3" '$1 == number { print $2 }' "$PLAYHOUSE_E2E_GH_STATE_PATH")
if [ "$5" = mergedAt ]; then
  if [ "$state" = merged ]; then
    printf '{"mergedAt":"2026-10-22T00:00:00Z"}\n'
  else
    printf '{"mergedAt":null}\n'
  fi
elif [ "$5" = mergedAt,mergeable,headRefOid ]; then
  if [ -n "${PLAYHOUSE_E2E_GH_STARTED_DIRECTORY:-}" ] && [ -n "${PLAYHOUSE_E2E_GH_EXPECTED_IDS:-}" ]; then
    touch "$PLAYHOUSE_E2E_GH_STARTED_DIRECTORY/$3"
    parallel=0
    for attempt in $(seq 1 100); do
      parallel=1
      for expected in $PLAYHOUSE_E2E_GH_EXPECTED_IDS; do
        if [ ! -f "$PLAYHOUSE_E2E_GH_STARTED_DIRECTORY/$expected" ]; then parallel=0; fi
      done
      [ "$parallel" = 1 ] && break
      sleep 0.02
    done
    if [ "$parallel" != 1 ]; then echo 'Review pull request probes did not run in parallel' >&2; exit 3; fi
  fi
  if [ -n "${PLAYHOUSE_E2E_GH_REMOTE_REPOSITORY:-}" ]; then
    head=$(git --git-dir "$PLAYHOUSE_E2E_GH_REMOTE_REPOSITORY" rev-parse "refs/heads/pr-$3")
  else
    head=$(git rev-parse HEAD)
  fi
  if [ "$state" = head-mismatch ]; then
    printf '{"mergedAt":null,"mergeable":"MERGEABLE","headRefOid":"remote-head-not-pushed"}\n'
  elif [ "$state" = merged ]; then
    printf '{"mergedAt":"2026-10-22T00:00:00Z","mergeable":"MERGEABLE","headRefOid":"%s"}\n' "$head"
  elif [ "$state" = conflicting ]; then
    printf '{"mergedAt":null,"mergeable":"CONFLICTING","headRefOid":"%s"}\n' "$head"
  else
    printf '{"mergedAt":null,"mergeable":"MERGEABLE","headRefOid":"%s"}\n' "$head"
  fi
else
  echo 'Unexpected gh fixture field list' >&2
  exit 2
fi
