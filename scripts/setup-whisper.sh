#!/bin/bash
set -euo pipefail

# Installs only inside the checkout. Downloads are needed once; inference is local.
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
LOCAL="$ROOT/.local"
WHISPER_COMMIT=927cfce34f31707e17f2bff35c349632fb9e2c3a
WHISPER_TAG=v1.9.4
CMAKE_VERSION=4.3.0
CMAKE_SHA256=5bd933daf6e9234a53a9a43092746993870d9f162b6c399fd6e4a05cdd475e67
MODEL_SHA256=1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b
MODEL_URL=https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin
METAL=ON
DOWNLOAD_MODEL=1
OFFLINE=0

usage() {
    printf '%s\n' 'Usage: scripts/setup-whisper.sh [--cpu] [--skip-model] [--offline]' \
        '  --cpu         Build without Metal; use if runtime Metal compilation fails.' \
        '  --skip-model  Build tools only.' \
        '  --offline     Refuse network access; require cached source/tools/model.'
}
for arg in "$@"; do
    case "$arg" in
        --cpu) METAL=OFF ;;
        --skip-model) DOWNLOAD_MODEL=0 ;;
        --offline) OFFLINE=1 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done
[ "$(uname -s)" = Darwin ] || { printf 'This setup script targets macOS.\n' >&2; exit 1; }
xcrun --find clang >/dev/null
xcrun --sdk macosx --show-sdk-path >/dev/null
mkdir -p "$LOCAL/downloads" "$LOCAL/tools" "$LOCAL/models"

download() {
    local url=$1 destination=$2 expected=$3 actual
    if [ -f "$destination" ]; then
        actual=$(shasum -a 256 "$destination" | awk '{print $1}')
        [ "$actual" = "$expected" ] && return 0
        printf 'Checksum mismatch: %s. Move it aside before retrying.\n' "$destination" >&2
        return 1
    fi
    [ "$OFFLINE" -eq 0 ] || { printf 'Offline setup is missing %s\n' "$destination" >&2; return 1; }
    # Atomic rename leaves no partial model visible to the app.
    curl --fail --location --show-error --retry 3 --connect-timeout 20 \
        --output "$destination.part" "$url"
    actual=$(shasum -a 256 "$destination.part" | awk '{print $1}')
    [ "$actual" = "$expected" ] || { rm -f "$destination.part"; printf 'Download checksum failed: %s\n' "$url" >&2; return 1; }
    mv "$destination.part" "$destination"
}
trap 'rm -f "$LOCAL/downloads/cmake-$CMAKE_VERSION-macos-universal.tar.gz.part" "$LOCAL/models/ggml-small.bin.part"' EXIT

# Always use the pinned CMake, independent of the caller's PATH.
CMAKE_ROOT="$LOCAL/tools/cmake-$CMAKE_VERSION-macos-universal"
CMAKE="$CMAKE_ROOT/CMake.app/Contents/bin/cmake"
if [ ! -x "$CMAKE" ]; then
    ARCHIVE="$LOCAL/downloads/cmake-$CMAKE_VERSION-macos-universal.tar.gz"
    download "https://github.com/Kitware/CMake/releases/download/v$CMAKE_VERSION/cmake-$CMAKE_VERSION-macos-universal.tar.gz" "$ARCHIVE" "$CMAKE_SHA256"
    tar -xzf "$ARCHIVE" -C "$LOCAL/tools"
fi
"$CMAKE" --version

SOURCE="$LOCAL/whisper.cpp"
if [ ! -d "$SOURCE/.git" ]; then
    [ ! -e "$SOURCE" ] || { printf 'Preserving existing non-Git directory %s; move it before setup.\n' "$SOURCE" >&2; exit 1; }
    [ "$OFFLINE" -eq 0 ] || { printf 'Offline setup is missing whisper.cpp source.\n' >&2; exit 1; }
    git clone --depth 1 --branch "$WHISPER_TAG" https://github.com/ggml-org/whisper.cpp.git "$SOURCE"
fi
ACTUAL_COMMIT=$(git -C "$SOURCE" rev-parse HEAD)
[ "$ACTUAL_COMMIT" = "$WHISPER_COMMIT" ] || { printf 'Preserving existing source at %s; expected %s.\n' "$ACTUAL_COMMIT" "$WHISPER_COMMIT" >&2; exit 1; }
if [ -n "$(git -C "$SOURCE" status --porcelain --untracked-files=no)" ]; then
    printf 'Preserving modified whisper.cpp source; clean or move it before reproducible setup.\n' >&2
    exit 1
fi

# EMBED_LIBRARY=ON in this release embeds source and compiles it at runtime.
# OFF invokes xcrun metal/metallib and would require tools absent from plain CLT.
"$CMAKE" -S "$SOURCE" -B "$SOURCE/build" -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DCMAKE_OSX_ARCHITECTURES="$(uname -m)" \
    -DBUILD_SHARED_LIBS=OFF -DGGML_BACKEND_DL=OFF -DGGML_METAL="$METAL" \
    -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_ACCELERATE=ON -DGGML_OPENMP=OFF \
    -DGGML_CPU_KLEIDIAI=OFF -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_EXAMPLES=ON \
    -DWHISPER_SDL2=OFF -DWHISPER_COREML=OFF -DWHISPER_COMMON_FFMPEG=OFF
if ! JOBS=$(sysctl -n hw.ncpu 2>/dev/null); then JOBS=6; fi
JOBS=${BOLBHAI_BUILD_JOBS:-$JOBS}
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || { printf 'BOLBHAI_BUILD_JOBS must be a positive integer.\n' >&2; exit 1; }
"$CMAKE" --build "$SOURCE/build" --config Release --parallel "$JOBS" \
    --target whisper-cli whisper-server
"$SOURCE/build/bin/whisper-cli" --help >/dev/null 2>&1
if [ "$DOWNLOAD_MODEL" -eq 1 ]; then
    download "$MODEL_URL" "$LOCAL/models/ggml-small.bin" "$MODEL_SHA256"
fi
printf '\nwhisper.cpp %s (%s), Metal=%s\n' "$WHISPER_TAG" "$WHISPER_COMMIT" "$METAL"
printf 'CLI: %s\nModel: %s\n' "$SOURCE/build/bin/whisper-cli" "$LOCAL/models/ggml-small.bin"
