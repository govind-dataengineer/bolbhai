# BolBhAI

A local-first macOS menu bar dictation prototype: toggle a shortcut, speak, toggle again, and receive text in the original focused field when macOS lets the app verify and edit it. SwiftUI, AVAudioEngine, multilingual Whisper small through whisper.cpp, and optional Gemma cleanup through LM Studio on loopback. No cloud inference, screen context, tools, accounts, or telemetry.

New to the project? Start with the [user guide](docs/USER-GUIDE.md) for what has been built, first use, storage, verification status, and a map of the code.

Implemented source and benchmark are in this repository. The app is a local prototype; target-application integration and human multilingual dictation still require the checks in [manual verification](docs/MANUAL-VERIFICATION.md). Build, benchmark, cancellation, and cleanup evidence is recorded in [benchmark results](docs/BENCHMARKS.md) and [cleanup evaluation](docs/CLEANUP-EVALUATION.md). Those results do not establish general dictation accuracy.

## Setup and build

Tested on Apple M4 Pro, macOS 26.6.2, Apple Swift 6.4 and macOS SDK 27.0. Full Xcode, Homebrew installation, FFmpeg, Ollama, and paid Apple credentials are unnecessary for this prototype. Apple Command Line Tools must be selected (`xcode-select -p`).

```bash
# First setup downloads pinned CMake, whisper.cpp, and multilingual Whisper small.
./scripts/setup-whisper.sh
# Meaningful behavioral checks; no XCTest or additional package downloads required.
./scripts/check.sh
# Release executables and an ad hoc signed local app.
./scripts/build-app.sh
# Quit any running earlier BolBhAI build through its menu before opening this one.
open dist/BolBhAI.app
```

`scripts/setup-whisper.sh --offline` rebuilds using cached dependencies and refuses downloads. `--cpu` disables Metal if needed; inference will be slower. Embedded Metal source compiles at runtime, so `xcrun metal` and full Xcode are unnecessary. First GPU use can take considerably longer while macOS compiles shaders. Pins, checksums, upstream sources, and packaging details are in [dependencies](docs/DEPENDENCIES.md).

All dependency files and downloaded models live under ignored `.local/`; Swift output under `.build/`; packaged apps under `dist/`. The packaged app contains Whisper CLI and server helpers, but excludes the 488 MB model. No Swift package dependency is fetched. Keep the checkout available or copy `.local/models/ggml-small.bin` to `~/Library/Application Support/BolBhAI/Models/ggml-small.bin` and select it in Settings. Source/model paths are validated before recording. The app defaults to bundled helpers and searches the checkout for the model when launched from `dist/`.

For a different local signing identity, set `BOLBHAI_SIGN_IDENTITY` when packaging. Without one, the script uses ad hoc signing (`-`). Signature verification and bundle assembly are local checks; Developer ID distribution, hardened runtime, notarization, and installation on another Mac are unverified. Rebuilding may require re-enabling macOS permissions for the app. This app is not App Store sandboxed.

## First run and operation

1. Open the waveform menu bar item → **Settings & transcripts** → **Settings**. Validate the model and helper paths. Select the system microphone or an available device.
2. On the first recording attempt, allow Microphone access. The permission buttons open the relevant System Settings pages. The app records only between explicit Start/Stop actions, with a five-minute limit.
3. Use **Enable Accessibility** if automatic insertion is wanted. Without Accessibility, recording/transcription still work and the transcript can be copied. Global shortcut registration uses Carbon and does not require monitoring arbitrary keyboard input.
4. Default shortcut is **Command–Shift–Space**, toggle to start and stop. Change modifiers/key in Settings if it conflicts. Focus the destination text field before starting. The recording overlay is a nonactivating, mouse-ignoring panel.
5. **Verbatim** bypasses the LLM and dictionary. **Clean** uses conservative cleanup, then explicit dictionary mappings after successful cleanup. Raw text remains available for review. Copy intentionally replaces the clipboard; automatic clipboard fallback preserves obtainable formats and refuses to overwrite a clipboard changed during dictation.

The app remembers both application and focused Accessibility element. If the application or field changed, the target is secure/unsupported, or permissions are absent, it leaves the transcript ready for manual copying. It never presses Enter. An accepted Accessibility write or dispatched paste is reported as an insertion request; macOS provides no general acknowledgement that the app consumed it. Test your daily target apps before relying on insertion.

Automatic insertion into Apple Terminal and fields identified as terminal subroles is disabled: pasted newlines can execute shell commands without an Enter event. Other applications' command inputs and embedded terminals may not identify themselves; use a plain editor/document field for dictation. Manual Copy remains available.

Clipboard paste restoration waits 750 ms and restores only if the app's clipboard value has not changed. Promised/unreadable clipboard formats cause manual fallback. Slow apps, quitting during restoration, and application-specific paste handling remain limitations. Moving the caret within the same field during processing changes where insertion lands; avoid editing that field while dictation is processing.

## Optional LM Studio cleanup

Verbatim does not need LM Studio. For Clean mode, LM Studio's local service must remain running. The installed version tested here is 0.4.25+1; E4B is available as `google/gemma-4-e4b`, with reasoning-off capability verified through `/api/v1/models`.

```bash
lms server start --bind 127.0.0.1 --port 1234
lms ls --json
lms load google/gemma-4-e4b --identifier bolbhai-gemma-e4b --yes
```

Use **Refresh models** to discover actual IDs, loading state, and capabilities. A loaded instance is selected when available; native LM Studio can load an available on-disk model on request, which adds cold latency. No replacement cleanup model is installed. Only loopback origins are accepted, DNS for `localhost` is canonicalized, proxies are disabled, and redirects are rejected. The native request is stateless (`store: false`), disables integrations, bounds output, and requests reasoning off only when supported. An older compatible API can be used when native discovery is unsupported, with fewer capability details.

LM Studio logs prompts and responses by default even when `store: false`. Before enabling Clean mode, go to **Developer → Developer Logs → More options**, turn **Redact Content ON**, **Verbose Logging OFF**, **Log Incoming Tokens OFF**, and **File Logging Mode OFF**, then restart the localhost server. BolBhAI refuses to send dictation if the persisted logging settings are missing, unsafe, unsupported, or do not match the endpoint's port and loopback binding. Verify the active server after setup or LM Studio updates:

```bash
python3 scripts/verify-lm-privacy.py
```

This read-only check sends only fresh synthetic text and checks for new diagnostic content. It passed on this machine after the supported UI changes and server restart. Editing LM Studio's JSON while it runs can be overwritten by its in-memory settings. The persisted-settings guard cannot guarantee the behavior of a separately running server after external changes; repeat the synthetic check after changing settings. Turning logging off preserves existing files, including the earlier synthetic benchmark logs.

Dictation is JSON-encoded as untrusted text, never executable instructions. Output checks reject obvious number, negation, language/script, code-term, or lexical changes. These checks and the prompt cannot prove fidelity. Cleanup failure/rejection retains the raw transcript and explains the reason. Review important numbers, names, negations, and technical text. See the measured prompt-injection and mixed-language failures in [cleanup evaluation](docs/CLEANUP-EVALUATION.md).

## Benchmark

```bash
.build/release/bolbhai-benchmark \
  --audio /path/to/recording.m4a \
  --model .local/models/ggml-small.bin \
  --language auto --runs 2

# Same local sample, resident-model worker plus optional cleanup.
.build/release/bolbhai-benchmark \
  --audio .local/whisper.cpp/samples/jfk.wav \
  --model .local/models/ggml-small.bin \
  --worker .local/whisper.cpp/build/bin/whisper-server \
  --language en --clean --cleanup-model google/gemma-4-e4b --runs 2

.build/release/bolbhai-benchmark --list-models
.build/release/bolbhai-benchmark --cleanup-text 'do not deploy build 42'
```

`--whisper-cli`, `--model`, `--language auto|en|hi`, `--threads 1..12`, `--endpoint`, `--cleanup-model`, `--runs 1..20`, and `--worker` are configurable. Audio is converted by Apple's `afconvert` to mono 16 kHz 16-bit WAV, validated, and limited to 0.35–300 seconds. Silent/very quiet recordings fail before inference. This amplitude gate is not speech detection: audible background noise can still lead to Whisper hallucinations.

The benchmark explicitly prints raw/final text and wall-clock times. It does not invent results or retain input audio copies. CLI repeats launch a fresh process and reload weights: later timings are filesystem/shader-cache warm, not resident inference. With `--worker`, the first run starts a private local server and later runs reuse its loaded model. Compare runs with the same audio, language, and mode. No latency target is promised.

Ctrl–C or SIGTERM cancels the benchmark's inference/HTTP task and stops its owned worker before exit. It preserves your supplied source audio. An unexpected process crash or SIGKILL cannot run this cleanup.

Whisper is multilingual small, never small.en. Hindi and Hinglish quality, script choice, and code-switch accuracy need real samples. `auto` detects a language, but does not guarantee Roman-script Hinglish output. Whisper may output Devanagari. Cleanup is instructed to preserve whatever script Whisper returned, rather than translate it.

## Architecture and reliability

`BolBhAICore` owns configuration, session state, speech/cleanup protocols, subprocess handling, audio preparation, dictionary boundaries, and optional history. `BolBhAI` owns SwiftUI/settings, AVAudioEngine, Carbon shortcut registration, nonactivating overlay, and AX/clipboard insertion. The benchmark uses the same services.

The main actor owns UI/session transitions. Inference and HTTP requests run away from UI work. A session generation rejects stale results after cancellation; overlapping sessions are blocked. Recording failures stop/discard audio. Sleep cancels the session and stops the worker; wake refreshes microphones. The recorder uses a fresh AVAudioEngine per session and selected microphone UID is resolved against current hardware. Inference failures tear down the worker so the next attempt starts cleanly. Missing/unavailable cleanup falls back to raw text.

The default speech router uses a supervised loopback `whisper-server` with a random port/request prefix and retained model. Only one request can run. Cancellation terminates inference, escalating to kill if needed; graceful Quit joins all retiring processing tasks before worker shutdown so their temporary-file cleanup finishes. Unanswered microphone permission requests have no recording resources and do not block Quit. The recording limit begins when recording actually starts. CLI fallback is available if no worker helper is configured. The worker is accessible to other processes on the same Mac, so this is not isolation from malicious local software. Unexpected app termination can orphan a worker; terminate the `whisper-server` process in Activity Monitor if necessary.

## Storage and privacy

Audio is captured into a private temporary CAF and converted into a per-request temporary WAV. Temporary audio and CLI transcript files are removed after success, failure, or cancellation. Unexpected process/system crashes can leave temporary files until macOS cleans them; this prototype does not claim secure erasure. Worker stdout/stderr are discarded. The app does not record screen contents, send audio externally, or log transcripts. Explicit benchmark output contains its supplied test transcript. Native cleanup requests disable stored chats and integrations; a local logging guard and synthetic verification cover LM Studio's separate diagnostic controls as described above.

Preferences and dictionary are local UserDefaults. History is **off by default**. Enabling it stores raw and final text in plaintext at `~/Library/Application Support/BolBhAI/history.json`, directory mode 700/file mode 600. At startup, refresh, or a new entry, entries older than seven days are pruned and the newest 100 retained. Disabling history or **Delete all history** removes the file. Retention is enforced on access rather than by a background timer. Preferences/model files are unaffected by clearing history.

## Troubleshooting and next steps

- **Missing speech engine/model:** run setup, select multilingual GGML model, validate paths. `scripts/doctor.sh` reports tool availability without starting a network listener.
- **Microphone denied or disconnected:** use permission guidance, reconnect/refresh/select the microphone, retry. Too-short or quiet audio is intentionally discarded.
- **No insertion:** inspect status, permissions, focus, and field support; Copy provides a manual fallback. Safari/Chromium/Electron/editor Accessibility implementations vary.
- **LM Studio unavailable/authentication required:** Verbatim works independently; Clean retains raw on error. The prototype does not yet manage LM Studio API authentication tokens.
- **Metal failure in automation sandbox:** direct GPU access can be denied by the automation sandbox; local benchmark/helper runs were tested separately. CPU setup is available. Build cache settings in scripts avoid unwritable user cache paths.
- **Shortcut conflict:** choose another supported combination. Hold-to-record is intentionally deferred until reliable event behavior is measured.

Next work should start with the [manual verification checklist](docs/MANUAL-VERIFICATION.md), especially human Hindi/Hinglish accuracy, real microphone recordings, Notes/browser/VS Code insertion, and a physically disconnected network. Then tune silence/VAD based on failures, improve stable development signing, and evaluate in-process Whisper if the persistent HTTP worker becomes a reliability or packaging bottleneck.
