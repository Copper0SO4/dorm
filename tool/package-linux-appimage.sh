#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE_DIR="$ROOT_DIR/build/linux/x64/release/bundle"
OUT_DIR="$ROOT_DIR/dist"
APP_DIR="$ROOT_DIR/build/linux/x64/Dorm.AppDir"
OUT_FILE="$OUT_DIR/Dorm-Linux-x86_64.AppImage"
ICON_SRC="$ROOT_DIR/android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png"
APPIMAGETOOL="${APPIMAGETOOL:-$(command -v appimagetool || echo "$HOME/.local/bin/appimagetool")}"

if [[ ! -x "$BUNDLE_DIR/dormos" ]]; then
  echo "Release bundle not found at $BUNDLE_DIR. Run 'flutter build linux --release --target-platform linux-x64' first." >&2
  exit 1
fi

if [[ ! -x "$APPIMAGETOOL" ]]; then
  echo "appimagetool not found at $APPIMAGETOOL." >&2
  exit 1
fi

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/usr/bin" "$APP_DIR/usr/share/icons/hicolor/256x256/apps" "$OUT_DIR"

cp -a "$BUNDLE_DIR/." "$APP_DIR/usr/bin/"
cp "$ICON_SRC" "$APP_DIR/dormos.png"
cp "$ICON_SRC" "$APP_DIR/usr/share/icons/hicolor/256x256/apps/dormos.png"

cat > "$APP_DIR/dormos.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Dorm
GenericName=Dorm Organizes Roomates' Matters
Comment=Offline dorm collaboration with optional GitHub sync
Exec=dormos
Icon=dormos
Categories=Utility;Office;
Terminal=false
StartupWMClass=org.dormos.dormos
EOF

if command -v desktop-file-validate >/dev/null 2>&1; then
  desktop-file-validate "$APP_DIR/dormos.desktop"
fi

cat > "$APP_DIR/AppRun" <<'EOF'
#!/usr/bin/env bash
HERE="$(dirname "$(readlink -f "$0")")"
export LD_LIBRARY_PATH="$HERE/usr/bin/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
exec "$HERE/usr/bin/dormos" "$@"
EOF
chmod +x "$APP_DIR/AppRun"

ARCH=x86_64 "$APPIMAGETOOL" --appimage-extract-and-run "$APP_DIR" "$OUT_FILE"
chmod +x "$OUT_FILE"
ls -lh "$OUT_FILE"
