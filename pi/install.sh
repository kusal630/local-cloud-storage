#!/usr/bin/env bash
# LocalVault Raspberry Pi installer.
#
# Installs system deps + Flutter, builds the Linux ARM64 release with your
# storage baked in, and enables an always-on node via systemd + Xvfb
# (headless virtual display — the shelf server doesn't need a real screen).
#
# Usage:
#   STORAGE=/mnt/cloud PASS='choose-a-strong-password' ./pi/install.sh
#   # optional: USERNAME=owner NAME='Pi Cloud' PORT=8484 ./pi/install.sh
set -euo pipefail

STORAGE="${STORAGE:?Set STORAGE to the folder/drive to use as cloud (e.g. /mnt/cloud)}"
PASS="${PASS:?Set PASS to the cloud password (min 6 chars)}"
USERNAME="${USERNAME:-owner}"
NAME="${NAME:-Pi Cloud}"
PORT="${PORT:-8484}"

echo "==> Installing system dependencies…"
sudo apt update
sudo apt install -y clang cmake ninja-build pkg-config libgtk-3-dev \
  libsqlite3-dev xvfb curl git unzip xz-utils zip libglu1-mesa

if ! command -v flutter >/dev/null 2>&1; then
  echo "==> Installing Flutter…"
  git clone --depth 1 -b stable https://github.com/flutter/flutter.git "$HOME/flutter"
  export PATH="$HOME/flutter/bin:$PATH"
fi
export PATH="$HOME/flutter/bin:$PATH"

echo "==> Building LocalVault (Linux ARM64, first build takes a while)…"
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SCRIPT_DIR"
flutter pub get
flutter build linux --release \
  --dart-define=LOCALVAULT_STORAGE="$STORAGE" \
  --dart-define=LOCALVAULT_USER="$USERNAME" \
  --dart-define=LOCALVAULT_PASS="$PASS" \
  --dart-define=LOCALVAULT_NAME="$NAME"

echo "==> Installing bundle to $HOME/localvault…"
rm -rf "$HOME/localvault"
cp -r build/linux/arm64/release/bundle "$HOME/localvault"

echo "==> Enabling systemd service (localvault)…"
mkdir -p "$HOME/.config/systemd/user"
sed -e "s|@HOME@|$HOME|g" -e "s|@PORT@|$PORT|g" \
  "$SCRIPT_DIR/pi/localvault.service" > "$HOME/.config/systemd/user/localvault.service"
systemctl --user daemon-reload
systemctl --user enable --now localvault.service

echo ""
echo "LocalVault Pi node is starting. Check status with:"
echo "  systemctl --user status localvault.service"
echo "Find the IP with: hostname -I"
echo "Then open the app on your phone → Connect → enter https://<pi-ip>:$PORT"
echo "and verify the TLS fingerprint shown by: (see README, Pi section)"
