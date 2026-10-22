# Pinned local dependencies

Setup and inference do not require a paid Apple developer account. `scripts/setup-whisper.sh` installs inside the ignored `.local` directory; it does not install Homebrew, Ollama, or Python model packages. After initial downloads, setup can be rerun with `--offline` and normal dictation uses local files.

| Dependency | Pin / verification | Source |
| --- | --- | --- |
| whisper.cpp | v1.9.4, commit `927cfce34f31707e17f2bff35c349632fb9e2c3a` | [Official release](https://github.com/ggml-org/whisper.cpp/releases/tag/v1.9.4) |
| CMake | 4.3.0 macOS universal tarball; SHA-256 `5bd933daf6e9234a53a9a43092746993870d9f162b6c399fd6e4a05cdd475e67` | [Official checksums](https://github.com/Kitware/CMake/releases/download/v4.3.0/cmake-4.3.0-SHA-256.txt) |
| Whisper multilingual small | `ggml-small.bin`, 487,601,967 bytes; SHA-256 `1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b` | [Official model repository pointer](https://huggingface.co/ggerganov/whisper.cpp/raw/main/ggml-small.bin) |
| Apple tools | Use installed CLT Swift/compiler and macOS SDK; record versions with `scripts/doctor.sh` | [Apple command line tools](https://developer.apple.com/documentation/xcode/installing-the-command-line-tools) |
| LM Studio | Existing user installation and existing model files; discover actual server IDs | [LM Studio local server](https://lmstudio.ai/docs/developer/core/server) |

The model download address uses the upstream `main` path, but setup accepts its content only if it matches the pinned SHA-256. Upstream's [model table](https://github.com/ggml-org/whisper.cpp/blob/v1.9.4/models/README.md) also lists SHA-1 `55356645c2b361a969dfd0ef2c5a50d530afd8d5`. Use `small`, never `small.en`, for English, Hindi, and Hinglish evaluation.

## Build

```sh
scripts/doctor.sh
scripts/setup-whisper.sh
scripts/build-app.sh
open dist/BolBhAI.app
```

The speech build enables Metal and Accelerate, disables external dependency fetching, and statically links whisper/ggml into the CLI and server helpers. The packaging script includes helpers and the whisper.cpp license, validates the plist and signatures, and checks helper execution. Model weights remain outside the `.app` and Git; select the model path in settings. The packaged helper location is `BolBhAI.app/Contents/Resources/bin/whisper-cli`.

SwiftPM uses workspace-local cache, config, security, and module-cache directories to avoid depending on writable user caches. Full Xcode is not a prerequisite for this prototype. In the pinned [Metal CMake implementation](https://github.com/ggml-org/whisper.cpp/blob/v1.9.4/ggml/src/ggml-metal/CMakeLists.txt), `GGML_METAL_EMBED_LIBRARY=ON` embeds shader source; Metal compiles it at runtime. Turning that flag off invokes the `metal`/`metallib` compiler tools, which are absent from the inspected plain CLT installation. If runtime Metal fails on a particular machine, rebuild with `scripts/setup-whisper.sh --cpu` and repackage. CPU latency must be measured separately.

Setup preserves an existing whisper source directory that has the wrong commit or tracked edits, and preserves a model/archive with the wrong checksum. Move those aside yourself before retrying. It deletes incomplete downloads on exit.

## Local signing

Packaging defaults to ad hoc signing (`codesign --sign -`), verifies the completed bundle, and needs no paid credentials. If an installed development signing identity is available, set it explicitly:

```sh
BOLBHAI_SIGN_IDENTITY='Apple Development: Your Name (TEAMID)' scripts/build-app.sh
```

Microphone and Accessibility permissions require interactive verification after launching the packaged app. Rebuilding an ad hoc signed app may cause macOS to ask for permissions again. Developer ID distribution, hardened runtime, notarization, and installation on another Mac are separate, unverified release work.

## Offline and persistent engine checks

`scripts/setup-whisper.sh --offline` validates the pinned source and model, and rebuilds with cached tools without making download requests. This is a build check; manual network-disconnected dictation remains necessary to verify the complete application. LM Studio must be running locally for Clean mode. Verbatim mode does not need it.

The optional `scripts/offline-check.sh` wrapper runs the benchmark and its worker under a process-scoped macOS `sandbox-exec` profile that permits loopback connections and denies external connections. It first verifies that a non-loopback TCP attempt returns `EPERM`. It changes no system network setting and permits localhost LM Studio cleanup. Example:

```sh
scripts/offline-check.sh --audio .local/whisper.cpp/samples/jfk.wav \
  --model .local/models/ggml-small.bin --language en --runs 2 \
  --worker .local/whisper.cpp/build/bin/whisper-server
```

Add `--clean --cleanup-model YOUR_DISCOVERED_ID` to include LM Studio. The wrapper constrains the benchmark process tree; an already running LM Studio server is outside that tree. Verifying both processes with the network physically disconnected remains a manual first-run check. `sandbox-exec` availability and syntax may change on later macOS versions; this profile was tested on macOS 26.6.2.

The benchmark's CLI mode loads the speech model for each invocation. `PersistentWhisperService` supervises the bundled `whisper-server` and retains its model between dictation sessions. It binds to `127.0.0.1` on a kernel-selected port, uses a per-process unpredictable request prefix, checks the owned process and its health response, and disables HTTP proxies, cookies, caching, and redirects. It restarts on configuration/model-file changes and kills the worker on cancellation or shutdown. Speech requests use the pinned server's supported multipart `/inference` interface, and WAV decoding occurs in memory in the server (`--convert` is not enabled).

This worker is a local HTTP service, so other software running as the same user can potentially inspect its process arguments and reach its listener. The random route prevents ordinary browser origins or unrelated listeners from accidentally using it; it is not a security boundary against malicious local software. Cold worker startup and warm requests must be measured separately. An explicit app quit/sleep handler should call `shutdown()`; an abrupt process crash can leave an orphan worker requiring manual termination.
