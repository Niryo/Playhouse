#!/bin/sh
# Deterministic stand-in for the GitHub CLI used by the bridge and UI suites.
# It answers pull-request list/create calls and `gh pr view <number> --json
# mergedAt[,mergeable,headRefOid]` from a state file (lines of
# `<number>=<merged|unmerged|conflicting|head-mismatch>`) and logs each probe.
# The full review probe also reports `statusCheckRollup` from an optional
# `<number>.checks=<success|failure|pending|none|rerun-success|rerun-failure|workflows|workflows-failing|statuses|untimed>` line (default success), and
# `gh api graphql` review-thread reads answer from `<number>.threads=<count>`
# unresolved threads (default 0), logging `threads <number>` to the call log.
# `gh repo view --json ...MergeAllowed` allows every merge method, or only those
# in a `repo.methods=<squash,merge,rebase>` line, and `gh pr merge <number>
# --<method> ...` logs `merged<TAB><number><TAB>--<method>` to the create log and
# marks the PR merged, unless a `<number>.merge=<message>` line makes it fail with
# that message (logged as `merge-failed`). A merge not pinned with
# `--match-head-commit <current HEAD>` is refused the same way.
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
if [ "$1" = repo ] && [ "$2" = view ]; then
  methods=$(awk -F= '$1 == "repo.methods" { print $2 }' "$PLAYHOUSE_E2E_GH_STATE_PATH")
  methods=${methods:-squash,merge,rebase}
  allowed() { case ",$methods," in *",$1,"*) echo true ;; *) echo false ;; esac; }
  printf '{"squashMergeAllowed":%s,"mergeCommitAllowed":%s,"rebaseMergeAllowed":%s}\n' "$(allowed squash)" "$(allowed merge)" "$(allowed rebase)"
  exit 0
fi
if [ "$1" = pr ] && [ "$2" = merge ]; then
  refusal=$(awk -F= -v key="$3.merge" '$1 == key { print $2 }' "$PLAYHOUSE_E2E_GH_STATE_PATH")
  # Like GitHub, refuse a merge that is not pinned to the PR's current head.
  if [ "$5" != --match-head-commit ] || [ "$6" != "$(git rev-parse HEAD)" ]; then
    refusal="Head branch was modified. Review and try the merge again."
  fi
  if [ -n "$refusal" ]; then
    printf 'merge-failed\t%s\t%s\n' "$3" "$4" >> "$PLAYHOUSE_E2E_GH_CREATE_LOG"
    echo "$refusal" >&2
    exit 1
  fi
  printf 'merged\t%s\t%s\n' "$3" "$4" >> "$PLAYHOUSE_E2E_GH_CREATE_LOG"
  awk -F= -v number="$3" 'BEGIN { OFS = "=" } $1 == number { $2 = "merged" } { print }' "$PLAYHOUSE_E2E_GH_STATE_PATH" > "$PLAYHOUSE_E2E_GH_STATE_PATH.tmp"
  mv "$PLAYHOUSE_E2E_GH_STATE_PATH.tmp" "$PLAYHOUSE_E2E_GH_STATE_PATH"
  exit 0
fi
if [ "$1" = api ] && [ "$2" = graphql ]; then
  number=$(printf '%s\n' "$@" | sed -n 's/^number=//p' | head -n 1)
  if ! printf '%s' "$number" | grep -Eq '^[0-9]+$'; then
    echo 'gh fixture graphql call is missing number=<n>' >&2
    exit 2
  fi
  printf 'threads %s\n' "$number" >> "$PLAYHOUSE_E2E_GH_CALL_LOG"
  threads=$(awk -F= -v key="$number.threads" '$1 == key { print $2 }' "$PLAYHOUSE_E2E_GH_STATE_PATH")
  threads=${threads:-0}
  nodes=
  index=0
  while [ "$index" -lt "$threads" ]; do
    nodes="${nodes}${nodes:+,}{\"isResolved\":false}"
    index=$((index + 1))
  done
  printf '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[%s{"isResolved":true}]}}}}}\n' "${nodes}${nodes:+,}"
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
elif [ "$5" = mergedAt,mergeable,headRefOid,statusCheckRollup ]; then
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
  checks=$(awk -F= -v key="$3.checks" '$1 == key { print $2 }' "$PLAYHOUSE_E2E_GH_STATE_PATH")
  case "${checks:-success}" in
    success) rollup='[{"__typename":"CheckRun","name":"fixture-ci","status":"COMPLETED","conclusion":"SUCCESS"}]' ;;
    failure) rollup='[{"__typename":"CheckRun","name":"fixture-ci","status":"COMPLETED","conclusion":"FAILURE"}]' ;;
    pending) rollup='[{"__typename":"CheckRun","name":"fixture-ci","status":"IN_PROGRESS","conclusion":""}]' ;;
    none) rollup='[]' ;;
    rerun-success) rollup='[{"__typename":"CheckRun","name":"fixture-ci","workflowName":"CI","status":"COMPLETED","conclusion":"FAILURE","startedAt":"2026-11-09T10:00:00Z","completedAt":"2026-11-09T10:05:00Z"},{"__typename":"CheckRun","name":"fixture-ci","workflowName":"CI","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-11-09T11:00:00Z","completedAt":"2026-11-09T11:05:00Z"}]' ;;
    rerun-failure) rollup='[{"__typename":"CheckRun","name":"fixture-ci","workflowName":"CI","status":"COMPLETED","conclusion":"FAILURE","startedAt":"2026-11-09T11:00:00Z","completedAt":"2026-11-09T11:05:00Z"},{"__typename":"CheckRun","name":"fixture-ci","workflowName":"CI","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-11-09T10:00:00Z","completedAt":"2026-11-09T10:05:00Z"}]' ;;
    workflows) rollup='[{"__typename":"CheckRun","name":"build","workflowName":"Lint","status":"COMPLETED","conclusion":"FAILURE","startedAt":"2026-11-09T10:00:00Z"},{"__typename":"CheckRun","name":"build","workflowName":"Test","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-11-09T11:00:00Z"}]' ;;
    workflows-failing) rollup='[{"__typename":"CheckRun","name":"build","workflowName":"Lint","status":"COMPLETED","conclusion":"FAILURE","startedAt":"2026-11-09T10:00:00Z"},{"__typename":"CheckRun","name":"build","workflowName":"Test","status":"COMPLETED","conclusion":"FAILURE","startedAt":"2026-11-09T11:00:00Z"}]' ;;
    statuses) rollup='[{"__typename":"StatusContext","context":"ci/legacy","state":"ERROR","createdAt":"2026-11-09T10:00:00Z"},{"__typename":"StatusContext","context":"ci/legacy","state":"SUCCESS","createdAt":"2026-11-09T11:00:00Z"}]' ;;
    untimed) rollup='[{"__typename":"CheckRun","name":"fixture-ci","status":"COMPLETED","conclusion":"FAILURE"},{"__typename":"CheckRun","name":"fixture-ci","status":"COMPLETED","conclusion":"SUCCESS"}]' ;;
    *) echo 'Unexpected gh fixture checks state' >&2; exit 2 ;;
  esac
  if [ "$state" = head-mismatch ]; then
    printf '{"mergedAt":null,"mergeable":"MERGEABLE","headRefOid":"remote-head-not-pushed","statusCheckRollup":%s}\n' "$rollup"
  elif [ "$state" = merged ]; then
    printf '{"mergedAt":"2026-10-22T00:00:00Z","mergeable":"MERGEABLE","headRefOid":"%s","statusCheckRollup":%s}\n' "$head" "$rollup"
  elif [ "$state" = conflicting ]; then
    printf '{"mergedAt":null,"mergeable":"CONFLICTING","headRefOid":"%s","statusCheckRollup":%s}\n' "$head" "$rollup"
  else
    printf '{"mergedAt":null,"mergeable":"MERGEABLE","headRefOid":"%s","statusCheckRollup":%s}\n' "$head" "$rollup"
  fi
else
  echo 'Unexpected gh fixture field list' >&2
  exit 2
fi
