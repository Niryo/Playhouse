#!/usr/bin/env bash
set -euo pipefail

confirmation_result="$(osascript <<'APPLESCRIPT'
set response to display dialog "StationAI visible UI tests will take control of this Mac. Save your work and leave the display unlocked. Choose Cancel if you plan to use the mouse or keyboard during the run. Tests will start automatically after 7 seconds if unanswered." buttons {"Cancel", "Start UI tests"} default button "Start UI tests" cancel button "Cancel" giving up after 7 with icon caution
if gave up of response then return "Start UI tests"
return button returned of response
APPLESCRIPT
)" || {
  printf 'Visible UI tests were cancelled or the confirmation dialog failed; no UI test was started.\n' >&2
  exit 1
}

if [[ "${confirmation_result}" != "Start UI tests" ]]; then
  printf 'Visible UI tests were cancelled; no UI test was started.\n' >&2
  exit 1
fi
