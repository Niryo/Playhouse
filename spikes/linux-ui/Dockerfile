# Linux UI spike image: Swift 6.3.2 (the Mac's toolchain version) with GTK 4.20
# and libadwaita 1.8, plus a headless X server for screenshots.
#
# Why not the official swift:6.3.2-noble image: Ubuntu 24.04 ships libadwaita
# 1.5, and Adwaita for Swift's main branch generates bindings for widgets added
# in libadwaita 1.6/1.7 (see REPORT.md). Both libraries are built in this same
# image so the comparison stays fair. The toolchain is swift.org's official
# Ubuntu 24.04 tarball, which runs unchanged on 25.10.
FROM ubuntu:25.10

ARG SWIFT_VERSION=6.3.2
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl binutils git gnupg2 libc6-dev libcurl4-openssl-dev \
        libedit2 libgcc-15-dev libpython3-dev libsqlite3-dev libstdc++-15-dev \
        libxml2-dev libz3-dev pkg-config tzdata unzip zlib1g-dev libncurses-dev \
        libgtk-4-dev libadwaita-1-dev gir1.2-adw-1 gir1.2-gtk-4.0 \
        xvfb xdotool x11-utils imagemagick \
        libgl1-mesa-dri mesa-utils \
        fonts-inter fonts-dejavu-core fonts-jetbrains-mono \
        adwaita-icon-theme \
        procps time python3 dbus-x11 \
    && rm -rf /var/lib/apt/lists/*

# The 24.04 toolchain links libxml2.so.2 (25.10 moved to libxml2.so.16):
# unpack noble's libxml2 and the ICU it needs beside the system libraries.
# x86-64 packages live on archive.ubuntu.com; ports.ubuntu.com serves only the other architectures.
RUN MIRROR=$([ "$(uname -m)" = "x86_64" ] && echo "http://archive.ubuntu.com/ubuntu" || echo "http://ports.ubuntu.com/ubuntu-ports") \
    && echo "deb $MIRROR noble main" > /etc/apt/sources.list.d/noble.list \
    && apt-get update && cd /tmp && apt-get download libxml2/noble libicu74/noble \
    && for deb in /tmp/*.deb; do dpkg -x "$deb" /; done \
    && rm -f /tmp/*.deb /etc/apt/sources.list.d/noble.list && rm -rf /var/lib/apt/lists/* && ldconfig

RUN ARCH=$([ "$(uname -m)" = "aarch64" ] && echo "-aarch64" || echo "") \
    && PLATFORM=$([ "$(uname -m)" = "aarch64" ] && echo "ubuntu2404-aarch64" || echo "ubuntu2404") \
    && curl -fsSL "https://download.swift.org/swift-${SWIFT_VERSION}-release/${PLATFORM}/swift-${SWIFT_VERSION}-RELEASE/swift-${SWIFT_VERSION}-RELEASE-ubuntu24.04${ARCH}.tar.gz" \
        | tar -xz --strip-components=1 -C / \
    && swift --version

WORKDIR /spike

# "monospace" → JetBrains Mono (closest installed face to SF Mono).
RUN mkdir -p /etc/fonts/conf.d && printf '%s\n' '<?xml version="1.0"?>' '<!DOCTYPE fontconfig SYSTEM "fonts.dtd">' \
      '<fontconfig><alias binding="strong"><family>monospace</family><prefer><family>JetBrains Mono</family></prefer></alias></fontconfig>' \
      > /etc/fonts/conf.d/10-ph-mono.conf && fc-cache -f >/dev/null && fc-match monospace
