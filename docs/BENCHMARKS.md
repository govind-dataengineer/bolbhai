# Observed validation and timings

Measured on 13 and 14 October 2026 (Asia/Calcutta): Apple M4 Pro, 12 CPU cores, 24 GB RAM; macOS 26.6.2 (25G83); Apple Swift 6.4; CLT macOS SDK 27.0. Speech model is the hash-verified multilingual Whisper small from [DEPENDENCIES.md](DEPENDENCIES.md). These are individual observations, not a latency guarantee or a statistically representative corpus.

The audio was upstream whisper.cpp's `samples/jfk.wav`: 11.0 seconds of clear English speech. It transcribed the passage correctly, including “ask not.” This does not establish performance on the user's microphone, background noise, Hindi, or Hinglish.

## Final packaged build, 14 October

The final release includes conditional audio downmixing and the LM Studio logging privacy check. The offline benchmark used the **server helper inside `dist/BolBhAI.app`**, with the existing Gemma 4 E4B loaded instance `bolbhai-gemma-e4b`. Raw and cleaned text were correct on both runs.

| Engine / run | Transcription | Cleanup | Total | Interpretation |
| --- | ---: | ---: | ---: | --- |
| Packaged worker, first request | 14.001 s | 1.501 s | 15.502 s | Includes new server/model startup; shader-cache state was not isolated |
| Same packaged worker, second request | 0.393 s | 0.625 s | 1.018 s | Model remains resident |

External TCP was denied with `EPERM` under the offline profile. The final cleanup privacy check passed after LM Studio's supported UI controls disabled verbose/file/token logging, enabled content redaction, and its server restarted on `127.0.0.1`. Metadata snapshots of seven files in LM Studio's normal and Bionic server-log directories were identical before and after the two benchmark requests: **zero changed/new files**, with 1,015,743 total bytes before and after. Existing logs were not deleted or treated as evidence about other applications or every possible storage location.

The first final verification exposed an audio conversion regression: unconditional `afconvert --mix` rejected already-mono 16 kHz Int16 WAV with error `-50`. The fixed conversion applies `--mix` only to multichannel input. A generated mono Int16 WAV and stereo Int16 WAV with signal only in the right channel now pass regression checks; the final benchmark above succeeded after rebuilding with that fix.

Final `scripts/check.sh` reported **26 check groups, zero failures** on 14 October. These include audio conversion/silence, session cancellation/stale results/fallback, configuration, dictionary boundaries, history, subprocess cleanup, cleanup safeguards, and the logging privacy guard. Two final shutdown regressions verify joining previously cancelled processing and completing without an answered microphone permission request. Native microphone/shortcut/insertion integrations remain subject to the manual checks below.

`scripts/build-app.sh` rebuilt both release executables and assembled/signed the app. Strict signatures for the bundle and both helpers, plist validation, and packaged helper execution passed. The final main executable is 1,586,160 bytes with SHA-256 `7c04b0c4cb44d866d60348d29f88125bbb4593ea25f25fbe4b9178ecd27b8b9e`. Helpers remain `whisper-cli` 4,610,304 bytes and `whisper-server` 5,010,144 bytes. The final rebuild includes graceful processing cleanup before Quit, recording limits starting after permission/actual capture, terminal insertion fallback, and mode controls disabled during preparation. These native changes were compile/package verified; their interactive behavior still requires the checklist. The timing table used the same speech helper/model before those UI/session lifetime changes. This artifact identity is for a local prototype, not a distribution release.

## Earlier measurements, 13 October

| Engine / run | Transcription | Cleanup | Total | Interpretation |
| --- | ---: | ---: | ---: | --- |
| CLI, first measured process | 15.487 s | 1.849 s | 17.337 s | Includes model/process startup and observed cold shader compilation |
| CLI, repeated process | 0.651 s | 0.613 s | 1.264 s | New process reloads model; filesystem/driver caches warm |
| Resident worker, first release request | 0.712 s | 0.722 s | 1.434 s | New server/model startup; Metal driver cache already warm |
| Same resident worker, second release request | 0.366 s | 0.581 s | 0.946 s | Model remains resident |

Cleanup used the existing Gemma 4 E4B loaded instance ID `bolbhai-gemma-e4b` through LM Studio's localhost API. The first observed cleanup request is not a forced model-load cold start: the model was already loaded. Both earlier worker runs retained the meaning and negation of this sample. No different cleanup model was installed.

During initial setup on 13 October, `lms` separately reported an 11.22 s Gemma model load and 6.39 GiB of model memory. That model-load cost is separate from the cleanup request times in the table. No additional model unload/load cycle was forced for the benchmark.

The actual loaded model API reported `config.context_length: 118272` and `max_context_length: 131072`. The setup command requested `--context-length 4096`, but this run did not load a 4096-token context according to the API. The measured memory/timings reflect the reported loaded configuration; a smaller context must be verified after changing it rather than assumed from the command alone.

The initial direct Metal sanity check logged 14.919 seconds compiling the embedded shader libraries, followed by a Whisper internal total of 812.94 ms. The internal timer excludes shader initialization; it is unsuitable as a cold end-to-end measurement. Plain CLT successfully built and ran the Metal engine without the `metal` command or full Xcode.

The release worker measurements ran with all external network connections denied for the benchmark process tree. Beforehand, a Python socket attempt to a non-loopback IP failed with `EPERM`, confirming the test profile was active. The worker and localhost cleanup still succeeded. The already-running LM Studio process was outside that profile, so a physically network-disconnected end-to-end check remains manual.

## Reproduction

```sh
scripts/setup-whisper.sh
scripts/build-app.sh

# Change the cleanup model ID to one reported by your local server.
scripts/offline-check.sh --audio .local/whisper.cpp/samples/jfk.wav \
  --model .local/models/ggml-small.bin --language en --runs 2 \
  --worker dist/BolBhAI.app/Contents/Resources/bin/whisper-server \
  --clean --cleanup-model bolbhai-gemma-e4b

# Omit --worker to measure repeated CLI launches.
.build/release/bolbhai-benchmark --audio .local/whisper.cpp/samples/jfk.wav \
  --model .local/models/ggml-small.bin --language en --runs 2
```

The process-cold label does not imply a cleared operating-system shader cache. Rebooting or purging caches was not used, and would not reproduce every cold condition reliably. Timers include audio conversion/validation, process/worker readiness, and API calls, but exclude microphone recording duration and desktop text insertion.

## Verified worker behavior

A separate local Swift probe used the same `PersistentWhisperService` against the real model. Its first request took 0.598 s and its same-worker second request took 0.346 s (debug core build; already-warm shader cache). Cancelling the third request after 100 ms returned `CancellationError`; the following request started a clean worker and correctly transcribed the sample. Explicit shutdown completed. No `BolBhAI-worker-*` temporary audio directories remained after the probe.

The benchmark's SIGINT/SIGTERM handler was additionally verified on 14 October after a benchmark-only update. For both debug and release binaries, a subprocess probe waited until its own `whisper-server` child appeared, sent SIGINT only to the benchmark PID after 150 ms, and observed explicit exit code 130. The captured owned worker was gone and no new `BolBhAI-*` temporary directories remained. An initially inferred main-actor signal callback produced a runtime warning; the final explicitly `@Sendable` callback passed the same check without that warning. No unrelated application or worker was stopped. This verifies client/owned speech-process cancellation, not termination of LM Studio's internal generation.

The updated release benchmark also completed a normal one-run offline transcription using the packaged helper: correct text, cleanup bypassed, 0.719 s transcription/total, with external TCP denied. A later smoke run after the shutdown fix completed with cleanup enabled: correct raw/final text, 0.714 s transcription, 1.521 s cleanup, and 2.235 s total. A separate release probe verified SIGTERM and repeated SIGINT after rebuilding: explicit exit130, zero remaining owned workers, zero new temporary directories, and no main-actor runtime warning.

Source inspection of the pinned server confirmed that audio file writing occurs only in its optional FFmpeg-conversion branch. That branch is disabled in BolBhAI. The server decodes the uploaded validated WAV in memory. Its stdout/stderr are connected to `/dev/null`; responses are returned as in-memory JSON. The CLI prototype temporarily writes its output into private directories and removes them on completion or cancellation.

`scripts/setup-whisper.sh --offline` completed using the cached source, toolchain, and verified model. Local `.app` assembly, plist validation, ad hoc signing, strict signature verification, and packaged helper execution completed successfully. Distribution signing/notarization and installation on another machine are unverified.

## Required manual checks

- Grant microphone permission and capture real speech; check silent/quiet and disconnected microphones.
- Exercise the configurable shortcut and non-focus-stealing overlay.
- Verify insertion in Notes, a browser text field, and a code editor; change focus during processing and try secure/unsupported fields.
- Test Clean mode with LM Studio closed, and test sleep/wake recovery.
- Dictate English, Hindi, and Hinglish with negations, names, dates, numbers, and technical terms.
- Disconnect the network after setup and test both Verbatim and Clean mode.

Core automated state/configuration/cleanup checks are run by `scripts/check.sh` (26 groups passed in the final 14 October run). Passing those checks does not claim the native permission, shortcut, microphone, or Accessibility integrations have been manually verified.

## Next measurements

Use a consented local corpus of short real microphone clips in English, Hindi, and Hinglish; compare raw and cleaned output separately. Record several cold process starts and resident requests rather than inferring percentiles from these few observations. The measured startup cost justified retaining the multilingual small model in a supervised local worker. Additional cleanup models should be considered only if accuracy or latency measurements show a concrete problem with the existing Gemma model.
