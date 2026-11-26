# Dev helper: SwiftCrossUI startup scaling (content frame ms) by card count and variant.
source /spike/container-env.sh
cd /spike/scui && swift build -c release --scratch-path /cache/scui 2>&1 | grep -E "error" -A3
for v in ${VARIANTS:-"full"}; do for n in ${COUNTS:-50 100 200}; do
  noclock=0; [[ $v == *noclock* ]] && noclock=1
  r=$(env PH_NO_CLOCK=$noclock PH_VARIANT=$v PH_T0_US=$(($(date +%s%N) / 1000)) PH_ACTION=startup PH_SCENE=board PH_CARDS=$n timeout ${LIMIT:-240} $SCUI_BIN 2>/dev/null | grep -E "content_frame|\"startup\"" | sed -E 's/.*"ms":([0-9.]*).*/content_ms=\1/; s/.*"hwm_kb":([0-9]*).*"cpu_s":([0-9.]*).*/hwm_kb=\1 cpu_s=\2/' | tr '\n' ' ')
  echo "variant=$v cards=$n ${r:-timeout}"
done; done
