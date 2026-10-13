#!/bin/zsh
# Runs the LocoCore tests. With only the Command Line Tools installed, SwiftPM needs to be told where Testing lives.
set -euo pipefail
cd "${0:A:h}/.."

flags=()
clt=/Library/Developer/CommandLineTools/Library/Developer
if [[ "$(xcode-select -p)" == /Library/Developer/CommandLineTools* && -d $clt/Frameworks/Testing.framework ]]; then
  flags=(-Xswiftc -F -Xswiftc $clt/Frameworks -Xlinker -F -Xlinker $clt/Frameworks
         -Xlinker -rpath -Xlinker $clt/Frameworks -Xlinker -rpath -Xlinker $clt/usr/lib)
fi
swift test $flags "$@"
