#!/usr/bin/env bash
# Dev loop for the SwiftCrossUI fork (runs in the profiling image):
#   fork-dev.sh build            build scui against ../fork/swift-cross-ui (release + debug info)
#   fork-dev.sh startup N [k]    k startup runs of a board of N cards, prints content_frame ms
#   fork-dev.sh perf N           perf record a startup of N cards, prints the top symbols
#   fork-dev.sh live [s]         the live test (100 cards, 10 Hz) for s seconds
set -uo pipefail
source /spike/container-env.sh
BIN=/cache/scui-fork/release/SCUICard
cmd=$1; shift
case $cmd in
build)
    cd /spike/scui && PH_SCUI_FORK=1 swift build -c release -Xswiftc -g --scratch-path /cache/scui-fork 2>&1 \
        | grep -E "error:|Compiling SCUICard|Build complete|warning: var" | head -40 ;;
startup)
    n=$1; k=${2:-1}
    for i in $(seq "$k"); do
        PH_T0_US=$(($(date +%s%N) / 1000)) PH_NO_CLOCK=1 PH_ACTION=startup PH_SCENE=board PH_CARDS=$n timeout 400 $BIN 2>/dev/null \
            | grep -oE '"event":"(content_frame|rss)[^}]*' | tr '\n' ' '; echo
    done ;;
perf)
    n=$1
    PH_NO_CLOCK=1 PH_ACTION=startup PH_SCENE=board PH_CARDS=$n perf record -F 999 -g -o /tmp/perf.data $BIN >/dev/null 2>&1
    cp /tmp/perf.data /spike/out/perf-$n.data 2>/dev/null
    perf report -i /tmp/perf.data --no-children --sort dso,symbol -g none --stdio 2>/dev/null | swift demangle --simplified | grep -E '^ +[0-9]' | cut -c1-200 | head -${3:-45}
    echo ---- inclusive
    perf report -i /tmp/perf.data --children --sort symbol -g none --stdio 2>/dev/null | swift demangle --simplified | grep -E '^ +[0-9]' | cut -c1-200 | head -${4:-70} ;;
checks)
    PH_ACTION=redraw PH_SCENE=board PH_CARDS=5 timeout 60 $BIN 2>/dev/null | grep -E '"observation_check"|"redraw_check"'
    PH_ACTION=identity PH_SCENE=board PH_CARDS=4 PH_NO_CLOCK=1 timeout 60 $BIN 2>/dev/null | grep -E '"identity_check"' ;;
stats)
    # stats N [types]: layout work counters for a startup of N cards
    PH_LAYOUT_STATS=${2:-1} PH_NO_CLOCK=1 PH_ACTION=startup PH_SCENE=board PH_CARDS=$1 timeout 400 $BIN 2>/dev/null | grep -E 'layout_stats|content_frame' ;;
scroll)
    PH_T0_US=$(($(date +%s%N) / 1000)) PH_NO_CLOCK=1 PH_ACTION=scroll PH_SCENE=board PH_CARDS=${1:-500} timeout 600 $BIN 2>/dev/null | grep -E '"scroll"|content_frame' ;;
perflive)
    PH_LAYOUT_STATS=1 PH_ACTION=live PH_SCENE=board PH_CARDS=100 PH_LIVE_CARDS=100 PH_DURATION=${1:-10} perf record -F 499 -g -o /tmp/perf.data $BIN 2>/dev/null | grep -E 'live_summary|layout_stats'
    cp /tmp/perf.data /spike/out/perf-live.data
    perf report -i /tmp/perf.data --children --sort symbol -g none --stdio 2>/dev/null | swift demangle --simplified | grep -E '^ +[0-9]' \
        | grep -vE 'partial apply|protocol witness|withUnsafeMutablePointer|generateAccessList|% +0x' | cut -c1-170 | head -${2:-70} ;;
livestats)
    # livestats [s]: layout counters by node type during a live run (minus startup)
    PH_LAYOUT_STATS=types PH_ACTION=live PH_SCENE=board PH_CARDS=100 PH_LIVE_CARDS=100 PH_DURATION=${1:-5} timeout 300 $BIN 2>/dev/null | grep -E 'live_summary|layout_stats' ;;
live)
    PH_T0_US=$(($(date +%s%N) / 1000)) PH_ACTION=live PH_SCENE=board PH_CARDS=100 PH_LIVE_CARDS=100 PH_DURATION=${1:-30} timeout 300 $BIN 2>/dev/null | grep '^PERF' | tail -5 ;;
esac
