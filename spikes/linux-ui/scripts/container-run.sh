#!/usr/bin/env bash
# Runs inside the spike image (see ../run.sh): builds both demos, takes the
# screenshots, runs the checks and benchmarks, and writes everything to
# /spike/out. Stages: build shots checks perf (default: all), plus the
# SwiftCrossUI fork's stages: forkbuild forkshots forkchecks forkperf forkanim
# (see REPORT.md, "Fork"; ../run.sh fork runs them all).
set -uo pipefail
source /spike/container-env.sh
OUT=/spike/out
mkdir -p "$OUT/raw" "$OUT/perf"
STAGES="${*:-build shots checks perf}"
RUNS="${PH_RUNS:-3}"
LIBS=("scui:$SCUI_BIN" "adwaita:$ADW_BIN")

log() { echo "[$(date +%T)] $*" >&2; }
has_stage() { [[ " $STAGES " == *" $1 "* ]]; }

build() {
    log "build SwiftCrossUI"
    (cd /spike/scui && swift build -c release --scratch-path /cache/scui 2>&1 | grep -E "error|warning: unre|Compiling SCUICard|Build complete") || return 1
    log "build Adwaita for Swift"
    (cd /spike/adwaita && swift package resolve --scratch-path /cache/adwaita >/dev/null 2>&1 \
        && /spike/patches/adwaita-glib-2.86.sh /cache/adwaita \
        && swift build -c release --scratch-path /cache/adwaita 2>&1 | grep -E "error|Compiling AdwCard|Build complete") || return 1
}

# Trims a window snapshot to the card and gives it the native shot's 12 pt (24 px) gutter.
trim() { convert "$1" -bordercolor '#1E1E1E' -border 4 -fuzz 3% -trim +repage -bordercolor '#1E1E1E' -border 24 "$2"; }

# shot <lib> <bin> <name> [env...]: PH_SHOT_DELAY gives xdotool time to act.
shot() {
    local lib=$1 bin=$2 name=$3; shift 3
    env PH_ACTION=shot PH_SHOT="$OUT/raw/$lib-$name.png" "$@" timeout 40 "$bin" >"$OUT/raw/$lib-$name.log" 2>&1
    trim "$OUT/raw/$lib-$name.png" "$OUT/$lib-$name.png"
}

# Pointer helpers (window at 0,0 without a window manager; X pixels are 2x).
CARD_X=200 CARD_Y=120         # inside the card body
# The expand toggle at the title row's trailing edge (logical ~256,34). The
# libadwaita window's surface adds a 5 pt shadow margin before its origin.
chevron() { [ "$1" = adwaita ] && echo "522 78" || echo "512 68"; }

shots() {
    for entry in "${LIBS[@]}"; do
        local lib=${entry%%:*} bin=${entry#*:}
        read -r CHEVRON_X CHEVRON_Y <<<"$(chevron "$lib")"
        log "shots $lib"
        shot "$lib" "$bin" card
        shot "$lib" "$bin" selected PH_SELECTED=1
        # Hover: the real pointer over the card (working task, so the clock runs).
        (sleep 2.5; xdotool mousemove $CARD_X $CARD_Y; sleep 0.3; xdotool mousemove $((CARD_X + 2)) $CARD_Y) &
        local pointer=$!
        shot "$lib" "$bin" hover PH_WORKING=1 PH_SHOT_DELAY=4.5
        wait $pointer
        # Expanded by clicking the hover-revealed toggle (local @State), not by an env flag.
        (sleep 2.5; xdotool mousemove $CARD_X $CARD_Y; sleep 0.4; xdotool mousemove $CHEVRON_X $CHEVRON_Y; sleep 0.4; xdotool click 1; sleep 0.2; xdotool mousemove 1500 1300) &
        pointer=$!
        shot "$lib" "$bin" expanded PH_WORKING=1 PH_SHOT_DELAY=5.5
        wait $pointer
        # Expand animation: frames right after clicking the toggle (screen captures).
        env PH_ACTION=idle PH_WORKING=1 timeout 12 "$bin" >"$OUT/raw/$lib-anim.log" 2>&1 &
        local anim=$!
        sleep 3; xdotool mousemove $CARD_X $CARD_Y; sleep 0.4; xdotool mousemove $CHEVRON_X $CHEVRON_Y; sleep 0.6
        xdotool click 1
        for frame in 1 2 3 4 5 6; do import -window root -crop 620x440+0+0 +repage "$OUT/raw/$lib-anim-$frame.png"; done
        sleep 0.6; import -window root -crop 620x440+0+0 +repage "$OUT/raw/$lib-anim-7.png"
        kill $anim 2>/dev/null; wait $anim 2>/dev/null
        xdotool mousemove 1500 1300
        # Context menu: right-click, then capture the screen (the popover is its own surface).
        env PH_ACTION=idle PH_WORKING=1 timeout 12 "$bin" >"$OUT/raw/$lib-menu.log" 2>&1 &
        local pid=$!
        sleep 3; xdotool mousemove $CARD_X $CARD_Y click 3; sleep 1.2
        import -window root -crop 760x800+0+0 +repage "$OUT/raw/$lib-menu.png"
        # Pick the second item with the keyboard to show menus are keyboard-navigable.
        xdotool key Down Down Return; sleep 0.8
        kill $pid 2>/dev/null; wait $pid 2>/dev/null
        trim "$OUT/raw/$lib-menu.png" "$OUT/$lib-menu.png"
        grep -h '"event":"menu"' "$OUT/raw/$lib-menu.log" | sed "s/^PERF /$lib /" >&2
        xdotool mousemove 1500 1300
    done
}

checks() {
    for entry in "${LIBS[@]}"; do
        local lib=${entry%%:*} bin=${entry#*:}
        log "redraw check $lib"
        PH_ACTION=redraw PH_SCENE=board PH_CARDS=5 timeout 60 "$bin" 2>/dev/null | grep -E '"observation_check"|"redraw_check"' | sed "s/^PERF /$lib /" | tee "$OUT/perf/$lib-checks.jsonl"
        log "state identity check $lib"
        PH_ACTION=identity PH_SCENE=board PH_CARDS=4 PH_NO_CLOCK=1 timeout 60 "$bin" 2>/dev/null | grep -E '"identity_check"' | sed "s/^PERF /$lib /" | tee -a "$OUT/perf/$lib-checks.jsonl"
    done
}

# One JSON line per run: {"lib","test","run",...event fields}.
RESULTS="$OUT/perf/results.jsonl"
record() {
    local lib=$1 test=$2 run=$3
    grep '^PERF ' | sed "s/^PERF {/{\"lib\":\"$lib\",\"test\":\"$test\",\"run\":$run,/" >>"$RESULTS"
}

# run_measured <lib> <test> <run> <timeout> <bin> [env...]: records the run's
# probe events, or a timeout event when no content frame was painted in time.
run_measured() {
    local lib=$1 test=$2 run=$3 limit=$4 bin=$5; shift 5
    local start=$(date +%s.%N)
    env PH_T0_US=$(($(date +%s%N) / 1000)) "$@" timeout "$limit" "$bin" 2>/dev/null >/tmp/run.out
    if ! grep -q '"content_frame"' /tmp/run.out; then
        echo "PERF {\"event\":\"timeout\",\"limit_s\":$limit}" >>/tmp/run.out
    fi
    record "$lib" "$test" "$run" </tmp/run.out
    log "  $lib $test run $run: $(grep -oE '"content_frame","ms":[0-9.]+|"event":"timeout"|"cpu_percent":[0-9.]+' /tmp/run.out | tr '\n' ' ')"
}

perf() {
    : >"$OUT/perf/results.jsonl"
    # Startup: first render only, so the app clock is off (PH_NO_CLOCK); its
    # cost is part of the live-update test.
    for run in $(seq "$RUNS"); do
        for entry in "${LIBS[@]}"; do
            local lib=${entry%%:*} bin=${entry#*:}
            for cards in 50 500 2000; do
                run_measured "$lib" "startup-$cards" "$run" 360 "$bin" PH_NO_CLOCK=1 PH_ACTION=startup PH_SCENE=board PH_CARDS=$cards
            done
        done
    done
    for run in $(seq "$RUNS"); do
        for entry in "${LIBS[@]}"; do
            local lib=${entry%%:*} bin=${entry#*:}
            run_measured "$lib" "scroll-500" "$run" 600 "$bin" PH_NO_CLOCK=1 PH_ACTION=scroll PH_SCENE=board PH_CARDS=500
            # 100 cards on the board, all updating usage + tokens, plus the clock, 10x a second for 30 s.
            run_measured "$lib" "live-100" "$run" 300 "$bin" PH_ACTION=live PH_SCENE=board PH_CARDS=100 PH_LIVE_CARDS=100 PH_DURATION=30
        done
    done
}

# --- SwiftCrossUI fork (pinned revision + patches/swiftcrossui-fork.patch) ---
FORK_BIN=/cache/scui-fork/release/SCUICard

forkbuild() {
    log "build SwiftCrossUI fork"
    (cd /spike/scui && PH_SCUI_FORK=1 swift build -c release -Xswiftc -g --scratch-path /cache/scui-fork 2>&1 \
        | grep -E "error|Compiling SCUICard|Build complete") || return 1
}

forkshots() {
    # Same shots as upstream SwiftCrossUI (the fork must look identical);
    # the animation strips come from forkanim.
    read -r CHEVRON_X CHEVRON_Y <<<"$(chevron scui)"
    log "shots scui-fork"
    shot scui-fork "$FORK_BIN" card
    (sleep 2.5; xdotool mousemove $CARD_X $CARD_Y; sleep 0.3; xdotool mousemove $((CARD_X + 2)) $CARD_Y) &
    local pointer=$!
    shot scui-fork "$FORK_BIN" hover PH_WORKING=1 PH_SHOT_DELAY=4.5
    wait $pointer
    (sleep 2.5; xdotool mousemove $CARD_X $CARD_Y; sleep 0.4; xdotool mousemove $CHEVRON_X $CHEVRON_Y; sleep 0.4; xdotool click 1; sleep 0.2; xdotool mousemove 1500 1300) &
    pointer=$!
    shot scui-fork "$FORK_BIN" expanded PH_WORKING=1 PH_SHOT_DELAY=6.5
    wait $pointer
}

forkchecks() {
    : >"$OUT/perf/scui-fork-checks.jsonl"
    for variant in plain granular granular,lazy; do
        log "redraw + identity checks scui-fork ($variant)"
        { PH_VARIANT=$variant PH_ACTION=redraw PH_SCENE=board PH_CARDS=5 timeout 60 "$FORK_BIN" 2>/dev/null | grep -E '"observation_check"|"redraw_check"'
          PH_VARIANT=$variant PH_ACTION=identity PH_SCENE=board PH_CARDS=4 PH_NO_CLOCK=1 timeout 60 "$FORK_BIN" 2>/dev/null | grep -E '"identity_check"'
        } | sed "s/^PERF /scui-fork-${variant//,/+} /" | tee -a "$OUT/perf/scui-fork-checks.jsonl"
    done
}

forkperf() {
    RESULTS="$OUT/perf/results-fork.jsonl"
    : >"$RESULTS"
    # Startup and scrolling: the plain card, the granular card (live values in
    # their own views) and the granular card on a LazyVStack board.
    # Live updates: animations off for a like-for-like comparison with
    # Adwaita (the fork animates the meter on every CPU change otherwise),
    # plus one animated row.
    for run in $(seq "$RUNS"); do
        for variant in plain granular granular,lazy; do
            local lib=scui-fork-${variant//,/+}
            for cards in 50 500 2000; do
                run_measured "$lib" "startup-$cards" "$run" 360 "$FORK_BIN" PH_VARIANT=$variant PH_NO_CLOCK=1 PH_ACTION=startup PH_SCENE=board PH_CARDS=$cards
            done
            run_measured "$lib" "scroll-500" "$run" 600 "$FORK_BIN" PH_VARIANT=$variant PH_NO_CLOCK=1 PH_ACTION=scroll PH_SCENE=board PH_CARDS=500
        done
        for variant in plain,noanim granular,noanim granular granular,lazy,noanim; do
            local lib=scui-fork-${variant//,/+}
            run_measured "$lib" "live-100" "$run" 300 "$FORK_BIN" PH_VARIANT=$variant PH_ACTION=live PH_SCENE=board PH_CARDS=100 PH_LIVE_CARDS=100 PH_DURATION=30
        done
    done
}

forkanim() {
    BIN="$FORK_BIN" bash /spike/scripts/fork-anim.sh
    # The lazy board mid-scroll (real mouse wheel).
    BIN="$FORK_BIN" VARIANT=granular,lazy bash /spike/scripts/fork-lazyshot.sh
}

has_stage build && { build || { log "build failed"; exit 1; }; }
has_stage shots && shots
has_stage checks && checks
has_stage perf && perf
has_stage forkbuild && { forkbuild || { log "fork build failed"; exit 1; }; }
has_stage forkshots && forkshots
has_stage forkchecks && forkchecks
has_stage forkperf && forkperf
has_stage forkanim && forkanim
log "done"
