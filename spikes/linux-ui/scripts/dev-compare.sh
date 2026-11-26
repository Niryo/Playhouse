# Dev helper: rebuild both demos, shoot the reference card, trim, and append to native.
source /spike/container-env.sh
cd /spike/scui && swift build -c release --scratch-path /cache/scui 2>&1 | grep -E "error" -A3
cd /spike/adwaita && swift build -c release --scratch-path /cache/adwaita 2>&1 | grep -E "error" -A3
for b in $SCUI_BIN $ADW_BIN; do n=$(basename $b); env PH_ACTION=shot PH_SHOT=/tmp/$n.png "$@" timeout 30 $b 2>&1 | grep -E "PERF|rror" | grep -v observation
  convert /tmp/$n.png -bordercolor '#1E1E1E' -border 4 -fuzz 3% -trim +repage -bordercolor '#1E1E1E' -border 24 /spike/out/$n-test.png; done
cd /spike/out && convert native-card.png SCUICard-test.png AdwCard-test.png -background '#111' -splice 16x0 +append compare-test.png
