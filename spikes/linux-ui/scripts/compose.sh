#!/usr/bin/env bash
# Runs in the container after the shots: labelled comparison images in out/.
set -euo pipefail
cd /spike/out
BG='#161616'
FONT=$(fc-match -f '%{file}' 'Inter:semibold')

# panel <image> <label> <out>: the image under a caption, on the page background.
panel() {
    convert "$1" -background "$BG" -gravity center -extent "$(identify -format '%[fx:w+48]x%[fx:h+16]' "$1")" \
        \( -size "$(identify -format '%[fx:w+48]' "$1")x64" xc:"$BG" -font "$FONT" -pointsize 26 -fill '#C5C5C5' \
           -gravity center -annotate +0+4 "$2" \) +swap -append "$3"
}

# row <out> <panel>...: panels side by side, top-aligned.
row() {
    local out=$1; shift
    convert "$@" -background "$BG" -gravity north +append -bordercolor "$BG" -border 16 "$out"
}

panel native-card.png "macOS · SwiftUI (native)" /tmp/p-native.png
panel scui-card.png "SwiftCrossUI · GTK 4" /tmp/p-scui.png
panel adwaita-card.png "Adwaita for Swift · libadwaita" /tmp/p-adwaita.png
row side-by-side.png /tmp/p-native.png /tmp/p-scui.png /tmp/p-adwaita.png

for lib in scui adwaita; do
    name=$([ $lib = scui ] && echo SwiftCrossUI || echo "Adwaita for Swift")
    panel $lib-hover.png "$name · hover (live clock)" /tmp/p-$lib-hover.png
    panel $lib-expanded.png "$name · expanded (toggle clicked)" /tmp/p-$lib-expanded.png
    row $lib-states.png /tmp/p-$lib-hover.png /tmp/p-$lib-expanded.png
    panel $lib-selected.png "$name · selected" /tmp/p-$lib-selected.png
    panel $lib-menu.png "$name · right-click menu" /tmp/p-$lib-menu.png
done
row selected.png /tmp/p-scui-selected.png /tmp/p-adwaita-selected.png
row menus.png /tmp/p-scui-menu.png /tmp/p-adwaita-menu.png
echo "composed: $(ls side-by-side.png *-states.png menus.png selected.png | tr '\n' ' ')"

# Expand transition: screen captures right after clicking the toggle, and 0.6 s later.
for lib in scui adwaita; do
    convert raw/$lib-anim-1.png raw/$lib-anim-2.png raw/$lib-anim-3.png raw/$lib-anim-7.png -resize 60% \
        -background "$BG" -splice 12x0 +append -bordercolor "$BG" -border 12 $lib-anim.png
done

# SwiftCrossUI fork: looks unchanged, plus the animation POC strips.
if [ -f scui-fork-card.png ]; then
    panel scui-card.png "SwiftCrossUI (upstream)" /tmp/p-up.png
    panel scui-fork-card.png "SwiftCrossUI fork" /tmp/p-fork.png
    row fork-looks.png /tmp/p-up.png /tmp/p-fork.png
    echo "fork vs upstream card, differing pixels: $(compare -metric AE scui-card.png scui-fork-card.png null: 2>&1 || true)"
fi
# strip <prefix> <out> <title> <frame>...: frames with their capture time.
strip() {
    local prefix=$1 out=$2 title=$3; shift 3
    local frames=() t0=""
    for i in "$@"; do
        local t; t=$(awk -v i="$i" '$1 == i { print $2 }' fork/raw/$prefix.times)
        [ -z "$t0" ] && t0=$t
        convert fork/raw/$prefix-$i.png -background "$BG" -gravity center -extent "$(identify -format '%[fx:w+16]x%[fx:h]' fork/raw/$prefix-$i.png)" \
            \( -size "$(identify -format '%[fx:w+16]' fork/raw/$prefix-$i.png)x52" xc:"$BG" -font "$FONT" -pointsize 24 -fill '#C5C5C5' \
               -gravity center -annotate +0+0 "+$((t - t0)) ms" \) -append /tmp/f-$i.png
        frames+=(/tmp/f-$i.png)
    done
    # Two rows so the strip stays legible at a normal published width.
    local half=$(( (${#frames[@]} + 1) / 2 ))
    convert "${frames[@]:0:$half}" -background "$BG" +append /tmp/row1.png
    convert "${frames[@]:$half}" -background "$BG" +append /tmp/row2.png
    convert /tmp/row1.png /tmp/row2.png -background "$BG" -gravity west -append /tmp/strip.png
    convert /tmp/strip.png \( -size "$(identify -format '%w' /tmp/strip.png)x64" xc:"$BG" -font "$FONT" -pointsize 28 -fill '#E6E6E6' \
        -gravity west -annotate +24+0 "$title" \) +swap -append -bordercolor "$BG" -border 12 "$out"
}
if [ -f fork/raw/anim-expand.times ]; then
    strip anim-expand fork-anim-expand.png "SwiftCrossUI fork · withAnimation(.spring) expand: height springs open, chips fade in" 01 03 04 05 06 09
    strip anim-collapse fork-anim-collapse.png "SwiftCrossUI fork · collapse: height animates (chips leave at once: no removal transitions)" 01 02 03 04 05 08
    echo "composed fork animation strips"
fi
if [ -f fork/raw/anim-meter.times ]; then
    strip anim-meter fork-anim-meter.png "Fork · meter .animation(.easeInOut(duration: 1.2)): 20% → 95%" 03 08 13 18 23 28 33 38
fi
if [ -f "fork/raw/granular,lazy-mid.png" ]; then
    panel "fork/raw/granular,lazy-mid.png" "LazyVStack, 500 cards: at #87" /tmp/p-lazy-mid.png
    panel "fork/raw/granular,lazy-back.png" "scrolled back up to #44" /tmp/p-lazy-back.png
    row fork-lazy.png /tmp/p-lazy-mid.png /tmp/p-lazy-back.png
    echo "composed fork-lazy.png"
fi
