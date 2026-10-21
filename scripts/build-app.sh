#!/bin/zsh

# Builds the Kuro app (app/) into build/Kuro.app.
#
#   scripts/build-app.sh             build/Kuro.app
#   scripts/build-app.sh --install   and copy it to ~/Applications
#   scripts/build-app.sh --zip       and zip it for a release, build/Kuro.zip
#
# Needs only the command line tools. Their macOS 27 SDK makes SwiftUI's
# property wrappers macros whose plugin ships with Xcode alone, so without
# Xcode the newest macOS 26 SDK is used instead; the app targets macOS 26.
# Signed ad hoc: it runs on the Mac that built it, and a downloaded copy meets
# Gatekeeper once (right-click, Open).

set -eu
REPO="${0:A:h:h}"
APP_SRC="$REPO/app"
OUT="$REPO/build"
APP="$OUT/Kuro.app"
INSTALL=0 ZIP=0
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    --zip) ZIP=1 ;;
    *) print -u2 "build-app.sh: unknown option $arg"; exit 2 ;;
  esac
done

sdk=""
if [[ "$(/usr/bin/xcode-select -p 2>/dev/null)" != *Xcode*.app* ]]; then
  for candidate in /Library/Developer/CommandLineTools/SDKs/MacOSX26.*.sdk(NOn); do
    [[ -L "$candidate" ]] || { sdk="$candidate"; break; }
  done
fi

print -r -- "==> Building the Kuro app${sdk:+ (SDK ${sdk:t})}"
if [[ -n "$sdk" ]]; then
  SDKROOT="$sdk" swift build -c release --package-path "$APP_SRC"
else
  swift build -c release --package-path "$APP_SRC"
fi
bin=$(swift build -c release --package-path "$APP_SRC" --show-bin-path 2>/dev/null)/Kuro

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$bin" "$APP/Contents/MacOS/Kuro"
version=$(git -C "$REPO" describe --tags --always 2>/dev/null || print -r -- 0)
sed -e "s/__VERSION__/${version#v}/" "$APP_SRC/Resources/Info.plist" > "$APP/Contents/Info.plist"

# The bar itself, for the welcome screen.
cp "$REPO/docs/bar-left.png" "$REPO/docs/bar-right.png" "$APP/Contents/Resources/"

# The icon from the brand master: every size an .icns carries.
iconset="$OUT/Kuro.iconset"
rm -rf "$iconset"; mkdir -p "$iconset"
master="$REPO/docs/brand/master.png"
for size in 16 32 128 256 512; do
  sips -z $size $size "$master" --out "$iconset/icon_${size}x${size}.png" >/dev/null
  sips -z $(( size * 2 )) $(( size * 2 )) "$master" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$iconset"

# Finder tags and quarantine flags on the copied images would fail the signature.
/usr/bin/xattr -cr "$APP"
codesign --force --sign - --timestamp=none "$APP" >/dev/null
print -r -- "==> Built ${APP#$REPO/} ($version)"

if (( INSTALL )); then
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/Kuro.app"
  cp -R "$APP" "$HOME/Applications/Kuro.app"
  print -r -- "==> Installed ~/Applications/Kuro.app"
fi
if (( ZIP )); then
  rm -f "$OUT/Kuro.zip"
  /usr/bin/ditto -c -k --keepParent "$APP" "$OUT/Kuro.zip"
  print -r -- "==> Zipped build/Kuro.zip"
fi
