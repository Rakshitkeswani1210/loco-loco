#!/bin/zsh
# Builds Loco Loco.app, installs it in ~/Applications and opens it.
# Usage: scripts/build.sh [--no-install] [--test-hooks]
#   --test-hooks  compiles in Sources/LocoLoco/TestHooks.swift, which drives the panel for screenshots.
set -euo pipefail
cd "${0:A:h}/.."

install=1
flags=()
for arg in "$@"; do
  case $arg in
    --no-install) install=0 ;;
    --test-hooks) flags+=(-Xswiftc -DTEST_HOOKS) ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

swift build -c release --product LocoLoco $flags
bin=$(swift build -c release --show-bin-path)

if [[ ! -f build/AppIcon.icns || scripts/make-icon.swift -nt build/AppIcon.icns || Sources/LocoLoco/Octopus.swift -nt build/AppIcon.icns ]]; then
  mkdir -p build
  rm -rf build/AppIcon.iconset
  swiftc -parse-as-library -O scripts/make-icon.swift Sources/LocoLoco/Octopus.swift -o build/make-icon
  build/make-icon build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi

app="build/Loco Loco.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/LocoLoco" "$app/Contents/MacOS/LocoLoco"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp build/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
codesign --force --sign - --identifier com.rakshit.locoloco "$app"
echo "Built $app"

(( install )) || exit 0

# Quit the running copy so it saves its history, then replace it.
perl -e 'alarm 10; exec @ARGV' osascript -e 'tell application id "com.rakshit.locoloco" to quit' 2>/dev/null || true
for _ in {1..50}; do pgrep -qx LocoLoco || break; sleep 0.1; done
mkdir -p ~/Applications
rm -rf ~/Applications/"Loco Loco.app"
ditto "$app" ~/Applications/"Loco Loco.app"
open ~/Applications/"Loco Loco.app"
echo "Installed ~/Applications/Loco Loco.app"
