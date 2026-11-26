# Linux UI spike: SwiftCrossUI vs Adwaita for Swift

The board's task card rebuilt in both libraries, run in a Linux container and
compared with the native macOS card. Findings are in [REPORT.md](REPORT.md).

```sh
colima start --cpu 6 --memory 12   # or any Docker host
./run.sh                           # everything; output in out/
./run.sh shots compose             # just the screenshots (after one full run)
PH_RUNS=5 ./run.sh perf compose    # more benchmark runs
./run.sh fork compose              # the SwiftCrossUI fork: build, shots, checks, benchmarks, animation strips
# Demo variants (PH_VARIANT, fork builds): granular (live values in their own views),
# lazy (LazyVStack board), noanim (animations off); combine with commas.
```

| Path | What |
|---|---|
| `Dockerfile` | Ubuntu 25.10 + swift.org Swift 6.3.2 + GTK 4.20 + libadwaita 1.8 + Xvfb |
| `native/` | Renders the app's real `TaskItemView` (compiled read-only from `Playhouse/App`) on macOS |
| `shared/` | `CardModel` (the `@Observable` model, sample data, theme values), `CardHarness` (screenshots, checks, benchmarks), `GtkProbe` (C: GTK frame clock, scroll driver, widget snapshots, right-click/hover controllers, popover menus) |
| `scui/` | The card in SwiftCrossUI (GTK 4 backend) |
| `adwaita/` | The card in Adwaita for Swift |
| `patches/` | The two-line fix Adwaita for Swift needs to compile against GLib 2.86, and `swiftcrossui-fork.patch` (the fork's performance fixes, animation POC and `LazyVStack`, REPORT.md §8) |
| `fork/` | (git-ignored) the pinned SwiftCrossUI checkout with the fork patch applied; `run.sh fork` creates it. The same fork is pushed to [Niryo/swift-cross-ui](https://github.com/Niryo/swift-cross-ui/tree/playhouse-perf) (branch `playhouse-perf`, tag `playhouse-perf-v0.1`); `PH_SCUI_FORK=remote` builds the demo against it |
| `Dockerfile.profile`, `scripts/fork-dev.sh`, `scripts/fd`, `scripts/perf-callers.py` | Fork dev loop: build, startup/live timings, layout counters, `perf` profiles |
| `scripts/fork-anim.sh` | Captures the fork's expand/collapse and meter animations as frames |
| `scripts/fork-lazyshot.sh` | The lazy board (`PH_VARIANT=granular,lazy`) scrolled with the real mouse wheel |
| `scripts/perf-within.py` | Self-time breakdown of `perf` samples under one frame (e.g. the update path) |
| `scripts/container-run.sh` | In-container stages: build, shots (xdotool drives hover/click/right-click), checks, perf |
| `scripts/compose.sh`, `scripts/summarize.py` | Labelled comparison images and the benchmark tables |
