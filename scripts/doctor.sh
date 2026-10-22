#!/bin/bash
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
printf 'BolBhAI environment (read only)\n'
sw_vers
uname -m
xcode-select -p
xcrun swift --version
xcrun clang --version | head -n 1
printf 'macOS SDK: '
xcrun --sdk macosx --show-sdk-version
for tool in cmake whisper-cli lms codesign; do
    if path=$(command -v "$tool"); then printf '%s: %s\n' "$tool" "$path"; else printf '%s: missing from PATH\n' "$tool"; fi
done
if xcrun --find metal >/dev/null 2>&1; then printf 'Metal compiler: available\n'; else printf 'Metal compiler: absent (embedded runtime shaders can use CLT)\n'; fi
if [ -d /Applications/Xcode.app ]; then printf 'Full Xcode: found\n'; else printf 'Full Xcode: not found at /Applications/Xcode.app\n'; fi
if [ -x "$ROOT/.local/tools/cmake-4.3.0-macos-universal/CMake.app/Contents/bin/cmake" ]; then
    "$ROOT/.local/tools/cmake-4.3.0-macos-universal/CMake.app/Contents/bin/cmake" --version | head -n 1
fi
for file in "$ROOT/.local/whisper.cpp/build/bin/whisper-cli" "$ROOT/.local/whisper.cpp/build/bin/whisper-server" "$ROOT/.local/models/ggml-small.bin"; do
    if [ -f "$file" ]; then printf 'Found: %s\n' "$file"; else printf 'Missing: %s\n' "$file"; fi
done
printf 'LM Studio localhost model discovery: '
if curl --fail --silent --show-error --noproxy '*' --connect-timeout 2 --max-time 5 \
    http://127.0.0.1:1234/v1/models; then printf '\n'; else printf 'server unavailable; Verbatim mode remains usable\n'; fi
