#!/usr/bin/env bash
# Drafts user-facing release notes for scripts/release.sh with Claude Opus.
#
#   scripts/release-notes.sh <previous-tag> [<repository>]
#
# Collects every non-merge commit in <previous-tag>..HEAD with its message, the
# files it changed and, for subjects ending in "(#123)", that pull request's
# description from GitHub. Sends all of it to the latest Claude Opus through the
# installed Claude Code CLI (`claude -p`, using its existing sign-in) and prints
# concise notes of the major user-visible changes, split into "New features:" and
# "Bug fixes:", on stdout.
# Exits non-zero when the CLI is missing or fails, so the caller can fall back.
set -euo pipefail

since="${1:?usage: release-notes.sh <previous-tag> [<repository>]}"
repository="${2:-Niryo/Playhouse}"
repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
model="${PLAYHOUSE_RELEASE_NOTES_MODEL:-opus}"   # the CLI's alias for the latest Opus
max_pr_chars=4000

command -v claude >/dev/null || { printf 'release-notes: the Claude Code CLI (claude) is not installed.\n' >&2; exit 1; }

changes="$(mktemp)"
trap 'rm -f "${changes}"' EXIT

commits=()
while IFS= read -r hash; do commits+=("${hash}"); done \
  < <(git -C "${repository_root}" log --no-merges --reverse --format='%H' "${since}..HEAD")
[[ ${#commits[@]} -gt 0 ]] || { printf 'release-notes: no commits since %s.\n' "${since}" >&2; exit 1; }

for hash in "${commits[@]}"; do
  subject="$(git -C "${repository_root}" log -1 --format='%s' "${hash}")"
  {
    printf '=== Commit: %s\n' "${subject}"
    body="$(git -C "${repository_root}" log -1 --format='%b' "${hash}" | grep -viE '^(co-authored-by|signed-off-by):' || true)"
    [[ -z "${body//[[:space:]]/}" ]] || printf '%s\n' "${body}"
    printf -- '--- Files changed:\n'
    git -C "${repository_root}" show --stat=200 --format= "${hash}" | sed '$d'
    if [[ "${subject}" =~ \(#([0-9]+)\)$ ]]; then
      pr_body="$(gh pr view "${BASH_REMATCH[1]}" --repo "${repository}" --json body --jq .body 2>/dev/null || true)"
      if [[ -n "${pr_body}" ]]; then
        printf -- '--- Pull request description:\n%s\n' "${pr_body:0:${max_pr_chars}}"
      fi
    fi
    printf '\n'
  } >> "${changes}"
done

read -r -d '' system_prompt <<'PROMPT' || true
You write release notes for Playhouse, a macOS app for running and managing AI coding agents (Claude and Codex) on a task board.

You receive every change merged since the previous release: commit messages, changed files and pull request descriptions. Write the release notes that end users will read in the app's "What's new" window.

Rules:
- Output exactly this plain-text format and nothing else (no title, preamble, closing remark, Markdown headings, bold or code fences), because the app shows the notes as plain text:

New features:
- <one feature per line>

Bug fixes:
- <one fix per line>

- "New features" covers new capabilities and notable behavior changes; "Bug fixes" covers fixes for things that were broken. Leave out a section, heading included, when it has no bullets, and separate the two sections with one blank line.
- Be highly selective. Include a change only if it passes this test: would a typical user who skims the list be glad to learn about it, because it gives them a new capability, noticeably changes how they work, or fixes a bug that disrupted their work? When in doubt, leave it out.
- Leave out everything minor, even when it is user-visible:
  - styling and visual polish, spacing, colors, icons, wording and copy tweaks, small layout adjustments;
  - small UX tweaks to existing dialogs, prompts, buttons or menus, such as adding, removing or renaming a button or option, or making a step required or optional;
  - hiding, showing, enabling or disabling a control in edge cases (for example when something isn't installed or configured);
  - fixes for rare or cosmetic glitches, and small conveniences like a new way to dismiss or close something;
  - refactors, tests, CI, build or release tooling, documentation, internal changes and developer-only details.
- Merge related changes into one bullet. Prefer fewer bullets: usually 1 to 3 per section, never more than 5 in total. A short list is better than a complete one.
- Keep each bullet to one short sentence in plain language, describing what the user can now do or what changed for them. No file names, class names, PR numbers or test details.
- If nothing qualifies for either section, output exactly: "- Bug fixes and improvements." (no heading).
PROMPT

# Run outside the repository so project instructions and settings aren't loaded.
cd "${TMPDIR:-/tmp}"
notes="$(claude -p --model "${model}" --tools "" --no-session-persistence --strict-mcp-config \
  --setting-sources "" --system-prompt "${system_prompt}" < "${changes}")" \
  || { printf 'release-notes: claude failed.\n' >&2; exit 1; }
[[ -n "${notes//[[:space:]]/}" ]] || { printf 'release-notes: claude returned nothing.\n' >&2; exit 1; }
printf '%s\n' "${notes}"
