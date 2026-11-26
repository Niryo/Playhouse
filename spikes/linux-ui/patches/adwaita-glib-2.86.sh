#!/usr/bin/env bash
# Adwaita for Swift main (af5598f) references two GLib flags as Swift members
# (`GApplicationFlags.APPLICATION_HANDLES_OPEN`,
# `GFileQueryInfoFlags.FILE_QUERY_INFO_NOFOLLOW_SYMLINKS`). Swift 6.3.2 imports
# GLib 2.86's (Ubuntu 25.10) plain C enums as structs with global constants, so
# the package fails to compile. Use the global constants instead.
set -euo pipefail
CHECKOUT="$1/checkouts/adwaita-swift/Sources/Adwaita/Model"
sed -i 's/GApplicationFlags\.APPLICATION_HANDLES_OPEN/G_APPLICATION_HANDLES_OPEN/' "$CHECKOUT/AdwaitaApp.swift"
sed -i 's/\.FILE_QUERY_INFO_NOFOLLOW_SYMLINKS/G_FILE_QUERY_INFO_NOFOLLOW_SYMLINKS/' "$CHECKOUT/FileDropTarget.swift"
