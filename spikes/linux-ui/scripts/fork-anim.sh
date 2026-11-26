#!/usr/bin/env bash
# In-container: captures the SwiftCrossUI fork's animations as frame strips.
#   expand/collapse: real pointer hover + chevron clicks, frames grabbed with xwd
#   meter: PH_METER_DEMO=1 makes the first card's CPU jump 20% -> 95% -> 20%
# Writes out/fork/anim-*.png (frames + timestamps in the logs).
set -uo pipefail
source /spike/container-env.sh
BIN=${BIN:-/cache/scui-fork/release/SCUICard}
OUT=/spike/out/fork; RAW=$OUT/raw
mkdir -p "$RAW"; rm -f "$RAW"/anim-*
CARD_X=200 CARD_Y=120 CHEVRON_X=512 CHEVRON_Y=68

# grab <prefix> <count>: back-to-back screen captures with ms timestamps.
grab() {
    local prefix=$1 count=$2 t0; t0=$(date +%s%3N)
    for i in $(seq -w 1 "$count"); do
        import -window root -crop "${CROP:-600x420+0+0}" +repage "$RAW/$prefix-$i.png"; echo "$i $(( $(date +%s%3N) - t0 ))" >>"$RAW/$prefix.times"
    done
}

env PH_ACTION=idle PH_WORKING=1 PH_SHOT_DELAY=60 timeout 30 "$BIN" >"$RAW/anim-expand.log" 2>&1 &
app=$!
sleep 3; xdotool mousemove $CARD_X $CARD_Y; sleep 0.4; xdotool mousemove $CHEVRON_X $CHEVRON_Y; sleep 0.6
xdotool click 1; grab anim-expand 14
sleep 1.2; xdotool click 1; grab anim-collapse 14
kill $app 2>/dev/null; wait $app 2>/dev/null
xdotool mousemove 1500 1300

env PH_ACTION=idle PH_METER_DEMO=1 timeout 12 "$BIN" >"$RAW/anim-meter.log" 2>&1 &
app=$!
sleep 2.9; CROP=300x300+0+0 grab anim-meter 40
kill $app 2>/dev/null; wait $app 2>/dev/null
for f in "$RAW"/*.times; do echo "$(basename $f): $(tr '\n' ' ' <$f)"; done
