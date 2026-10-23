#!/usr/bin/env bash
# Package addons/mixar_link as dist/mixar_link.zip (the zip holds mixar_link/…,
# ready to unpack into a project's addons/) and publish it as a GitHub release
# named after plugin.cfg's version. The Mixar app downloads
#   https://github.com/<owner>/mixar-engine-godot/releases/latest/download/mixar_link.zip
#   scripts/release.sh            # build + publish
#   scripts/release.sh --dry-run  # build only
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="$(sed -n 's/^version="\(.*\)"/\1/p' addons/mixar_link/plugin.cfg)"
ADAPTER="$(sed -n 's/^const ADAPTER_VERSION := "\(.*\)"/\1/p' addons/mixar_link/tools.gd)"
[ "$VERSION" = "$ADAPTER" ] || { echo "plugin.cfg ($VERSION) and ADAPTER_VERSION ($ADAPTER) differ"; exit 1; }
rm -rf dist && mkdir -p dist
(cd addons && zip -qr -X ../dist/mixar_link.zip mixar_link -x '*.uid' -x '*/.DS_Store')
echo "built dist/mixar_link.zip (v$VERSION, $(wc -c < dist/mixar_link.zip) bytes)"
[ "${1:-}" = "--dry-run" ] && exit 0
gh release create "v$VERSION" dist/mixar_link.zip --title "Mixar Link $VERSION" \
  --notes "Unzip into your Godot project's addons/ folder (the Mixar app does this for you), then enable Mixar Link in Project Settings > Plugins."
