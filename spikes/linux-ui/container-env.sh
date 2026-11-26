#!/usr/bin/env bash
# Sourced inside the container: a virtual X display at HiDPI scale 2 with
# software GL (llvmpipe), as both demos run under it.
if ! xdpyinfo -display :99 >/dev/null 2>&1; then
    Xvfb :99 -screen 0 1600x1400x24 -nolisten tcp >/dev/null 2>&1 &
    for _ in $(seq 50); do xdpyinfo -display :99 >/dev/null 2>&1 && break; sleep 0.1; done
fi
export DISPLAY=:99 GDK_BACKEND=x11 GDK_SCALE=2 LIBGL_ALWAYS_SOFTWARE=1 GTK_A11Y=none NO_AT_BRIDGE=1
export GSK_RENDERER="${GSK_RENDERER:-gl}"
SCUI_BIN=/cache/scui/release/SCUICard
ADW_BIN=/cache/adwaita/release/AdwCard
# The app font for both libraries, through GTK's own settings so that layout
# measurement (SwiftCrossUI measures text with Pango itself) and rendering agree.
mkdir -p "$HOME/.config/gtk-4.0"
printf '[Settings]\ngtk-font-name=Inter 10\ngtk-application-prefer-dark-theme=true\ngtk-enable-animations=true\n' > "$HOME/.config/gtk-4.0/settings.ini"
export GTK_CSD=0
