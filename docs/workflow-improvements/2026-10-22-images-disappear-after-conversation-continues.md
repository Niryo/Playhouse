# Images disappear after conversation continues

Task: A6658725-FF56-47D3-922C-6A90CD97EADA, follow-up to “Preserve Images When Steering Conversations” (2026-10-22, Asia/Jerusalem).

## Timeline and evidence

This is a **partial timeline**. The conversation summary and task progress record do not expose the follow-up request time, individual review timestamps, or an end timestamp. File modification times bound some work but do not measure active agent time. The task-specific verification ledger supplied to this analysis records the final gate; no failed retry was recorded.

| Phase | Observed interval or duration | Basis |
| --- | --- | --- |
| User report, investigation, and planning | Start and duration unknown; after the preceding report's 14:22:11 IDT file timestamp | Conversation summary and file metadata; request timestamp unavailable |
| Parser, fixture, and paired assertion edits | Parser last modified 14:43:54 IDT; UI test last modified 14:50:51 IDT; these markers span 6m 57s, including unknown gaps | File metadata; derived span, **not** active work time |
| Static checks and reviews | Duration unknown; parity 56 cases, Python compile, and diff check passed; task and UI reviewers approved fingerprint `0d88e1c4f3f0be83bcc7b445267f8fb01061b838fae63909a4b5feb2d11890f5`; architecture approval retained because its relevant inputs did not change | Task verification ledger; no timed reviewer output |
| Full CLI/XPC verification | 141s total: build 71s, cases 68s, other phases about 2s | `scripts/test-e2e.sh` phase output; integer-second measurements; 56/56 cases passed |
| App relaunch and handoff | Relaunch in progress when this report was written; duration and completion unknown | Parent task progress |

The 141s suite is the only complete timed phase: build was about 50% and cases about 48% of that run. The remaining 2s covers static checks and fixture setup at the script's one-second resolution. The 6m 57s edit-marker span and 141s suite cannot be added into a full task duration because review, wait, and relaunch intervals are unmeasured. First and final task signals are missing, so total wall time and active agent time remain unknown. No individual slowest case can be ranked: the suite emits per-case durations, but its `bridge-tests.log` under a temporary `/tmp/stationai-bridge.*` directory was unavailable during this audit.

Sources checked: current conversation and task progress summary, supplied verification ledger, file metadata, `scripts/test-e2e.sh` and `scripts/test-bridge.py` timing emission, and available `/tmp/stationai-bridge.*` logs. The missing per-case values are **unretained task evidence**, not evidence that the runner lacks case timing. The request/review/relaunch timestamps are **unavailable in the supplied task record**; this does not establish whether another system retains them.

## Improvements

1. **Keep history fixtures aligned with the app-server image payload.** The preceding 56-case pass missed disappearing images because the fixture used `image_url` while `thread/items/list` supplies image `url`; refreshing history replaced visible messages. This caused one user-reported repair cycle and another measured 141s full gate. The current repair uses `url` in the fixture and asserts that earlier images remain after a later text turn in the paired CLI/UI case. For future history changes, compare fixture fields with the protocol payload during review and keep the continuation assertion in that case. Verify by changing the fixture or parser back to `image_url` and confirming the focused CLI case fails.
2. **Retain the suite's existing per-case timing in the verification ledger.** The runner prints each case duration, but the temporary bridge log was unavailable for this audit, preventing slowest-case ranking within the measured 68s case phase. Copy the per-case duration lines or the bridge log path and retained artifact into the task ledger after a full run. Verify that the next task report can name and rank its slowest cases without rerunning the suite.
