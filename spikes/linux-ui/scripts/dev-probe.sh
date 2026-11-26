# Dev helper: one startup run per library at the given card count.
source /spike/container-env.sh
cd /spike/adwaita && swift build -c release --scratch-path /cache/adwaita 2>&1 | grep -E "error" -A3
cd /spike/scui && swift build -c release --scratch-path /cache/scui 2>&1 | grep -E "error" -A3
for b in $SCUI_BIN $ADW_BIN; do
  echo "== $(basename $b) $1 cards"
  /usr/bin/time -f "wall %es cpu %Us+%Ss maxrss %MKB" env PH_T0_US=$(($(date +%s%N) / 1000)) PH_ACTION=startup PH_SCENE=board PH_CARDS=$1 timeout ${2:-300} $b 2>&1 | grep -E "first_frame|content_frame|wall|\"startup\"" | cut -c1-260
done
