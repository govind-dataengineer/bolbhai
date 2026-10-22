#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
# Avoid sandbox-denied user caches and make all generated files disposable.
mkdir -p "$ROOT/.local/module-cache" "$ROOT/.local/swiftpm-cache" "$ROOT/.local/swiftpm-config" "$ROOT/.local/swiftpm-security" "$ROOT/dist"
export CLANG_MODULE_CACHE_PATH="$ROOT/.local/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT/.local/module-cache"
SWIFT_FLAGS=(--cache-path "$ROOT/.local/swiftpm-cache" --config-path "$ROOT/.local/swiftpm-config" --security-path "$ROOT/.local/swiftpm-security" --disable-sandbox)
swift build -c release --product BolBhAI "${SWIFT_FLAGS[@]}"
swift build -c release --product bolbhai-benchmark "${SWIFT_FLAGS[@]}"
BIN=$(swift build -c release --show-bin-path "${SWIFT_FLAGS[@]}")
WHISPER_CLI_PATH=${WHISPER_CLI_PATH:-"$ROOT/.local/whisper.cpp/build/bin/whisper-cli"}
WHISPER_SERVER_PATH=${WHISPER_SERVER_PATH:-"$ROOT/.local/whisper.cpp/build/bin/whisper-server"}
[ -x "$WHISPER_CLI_PATH" ] || { printf 'Missing whisper-cli. Run scripts/setup-whisper.sh first.\n' >&2; exit 1; }

# Assemble in a new directory; a failed build preserves the last packaged app.
STAGING=$(mktemp -d "$ROOT/dist/.BolBhAI-build.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT
APP="$STAGING/BolBhAI.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bin" "$APP/Contents/Frameworks"
cp "$ROOT/Packaging/Info.plist" "$APP/Contents/Info.plist"
cp "$BIN/BolBhAI" "$APP/Contents/MacOS/BolBhAI"
cp "$WHISPER_CLI_PATH" "$APP/Contents/Resources/bin/whisper-cli"
if [ -x "$WHISPER_SERVER_PATH" ]; then cp "$WHISPER_SERVER_PATH" "$APP/Contents/Resources/bin/whisper-server"; fi
if [ -f "$ROOT/.local/whisper.cpp/LICENSE" ]; then cp "$ROOT/.local/whisper.cpp/LICENSE" "$APP/Contents/Resources/whisper.cpp-LICENSE"; fi

# Our pinned static build needs only Apple system libraries. If a custom CLI uses
# dylibs, bundle its dependency closure and replace checkout-specific paths.
python3 - "$APP" "$WHISPER_CLI_PATH" "$WHISPER_SERVER_PATH" <<'PY'
import pathlib, subprocess, sys
app = pathlib.Path(sys.argv[1])
frameworks = app / "Contents/Frameworks"
queue = []
for name, source in zip(("whisper-cli", "whisper-server"), sys.argv[2:]):
    destination = app / "Contents/Resources/bin" / name
    if destination.exists(): queue.append((pathlib.Path(source).resolve(), destination))
copied = {}
while queue:
    source, destination = queue.pop(0)
    lines = subprocess.check_output(["otool", "-L", str(source)], text=True).splitlines()[1:]
    for line in lines:
        dep = line.strip().split(" (", 1)[0]
        if dep.startswith(("/System/Library/", "/usr/lib/")): continue
        if source.suffix == ".dylib" and dep in subprocess.check_output(["otool", "-D", str(source)], text=True).splitlines()[1:]: continue
        name = pathlib.Path(dep).name
        if dep.startswith("@loader_path/"):
            candidate = source.parent / dep.removeprefix("@loader_path/")
        elif dep.startswith("@executable_path/"):
            candidate = pathlib.Path(sys.argv[2]).resolve().parent / dep.removeprefix("@executable_path/")
        elif dep.startswith("@rpath/"):
            # CMake may place whisper and ggml libraries in different subdirs.
            matches = {p.resolve() for p in source.parents[2].rglob(name)}
            if len(matches) != 1: raise SystemExit(f"Cannot resolve dependency {dep} of {source}; use the pinned static build.")
            candidate = next(iter(matches))
        else:
            candidate = pathlib.Path(dep)
        candidate = candidate.resolve()
        if not candidate.is_file(): raise SystemExit(f"Missing dependency: {candidate}")
        if name in copied and copied[name] != candidate: raise SystemExit(f"Library basename conflict: {name}")
        if name not in copied:
            import shutil
            copied[name] = candidate
            target = frameworks / name
            shutil.copy2(candidate, target)
            subprocess.run(["install_name_tool", "-id", f"@rpath/{name}", str(target)], check=True)
            queue.append((candidate, target))
        subprocess.run(["install_name_tool", "-change", dep, f"@rpath/{name}", str(destination)], check=True)
    # Runtime search paths refer to the bundle, never the original checkout.
    rpath = "@loader_path" if destination.parent == frameworks else "@loader_path/../../Frameworks"
    existing = subprocess.check_output(["otool", "-l", str(destination)], text=True)
    paths = []
    for block in existing.split("Load command ")[1:]:
        if "cmd LC_RPATH\n" in block:
            for line in block.splitlines():
                if line.strip().startswith("path "):
                    paths.append(line.strip()[5:].split(" (offset ", 1)[0])
    for path in paths:
        if path != rpath:
            subprocess.run(["install_name_tool", "-delete_rpath", path, str(destination)], check=True)
    if copied and rpath not in paths:
        subprocess.run(["install_name_tool", "-add_rpath", rpath, str(destination)], check=True)
PY

/usr/bin/plutil -lint "$APP/Contents/Info.plist"
SIGN_IDENTITY=${BOLBHAI_SIGN_IDENTITY:--}
while IFS= read -r -d '' file; do codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$file"; done < <(find "$APP/Contents/Frameworks" -type f -name '*.dylib' -print0)
for helper in "$APP/Contents/Resources/bin/"*; do codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$helper"; done
codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$APP"
codesign --verify --deep --strict "$APP"
"$APP/Contents/Resources/bin/whisper-cli" --help >/dev/null 2>&1
if [ -e "$ROOT/dist/BolBhAI.app" ]; then rm -rf "$ROOT/dist/BolBhAI.app"; fi
mv "$APP" "$ROOT/dist/BolBhAI.app"
printf '\nPackaged: %s\nSigning identity: %s\n' "$ROOT/dist/BolBhAI.app" "$SIGN_IDENTITY"
printf 'Launch with: open "%s"\n' "$ROOT/dist/BolBhAI.app"
printf 'Local packaging only; distribution signing and notarization are not verified.\n'
