#!/usr/bin/env bash
# In-container: the fork's lazy board (500 cards) scrolled with the real mouse
# wheel, captured mid-board and after scrolling partway back.
source /spike/container-env.sh
BIN=${BIN:-/cache/scui-fork/release/SCUICard}
RAW=/spike/out/fork/raw; mkdir -p "$RAW"
env PH_VARIANT=${VARIANT-lazy} PH_ACTION=idle PH_SCENE=board PH_CARDS=${CARDS:-500} PH_NO_CLOCK=1 timeout 120 "$BIN" >"$RAW/lazy.log" 2>&1 &
app=$!
sleep ${WAIT:-4}; xdotool mousemove 200 400
for i in $(seq ${SCROLL:-120}); do xdotool click 5; done
sleep 1.5; import -window root -crop 600x1400+0+0 +repage "$RAW/${VARIANT-lazy}-mid.png"
for i in $(seq 60); do xdotool click 4; done
sleep 1.5; import -window root -crop 600x1400+0+0 +repage "$RAW/${VARIANT-lazy}-back.png"
kill $app 2>/dev/null; wait $app 2>/dev/null
