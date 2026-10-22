# BolBhAI user guide

This guide explains the project as it stands on **14 October 2026**. Start here before changing code. You can read it without running the app or downloading anything.

**We have built the source code, a command-line benchmark, automated behavior checks, and a locally packaged macOS app.** Local speech transcription and optional cleanup have been exercised with test inputs. The app's microphone, shortcut, overlay, and insertion into other applications still need hands-on verification. Treat it as a working prototype under validation, rather than a finished daily-use product.

For an initial understanding, read sections **1–2** (purpose and progress), **6** (your data), and **7** (test evidence). Sections **3–5** walk through using the app; **8** explains the code and development commands.

For the file-by-file call sequence, see [Recording flow and sequence diagrams](RECORDING-FLOW.md).

## 1. What BolBhAI is meant to do

BolBhAI turns your voice into text on your Mac:

1. Focus the text field where you want to write.
2. Press a shortcut to begin recording.
3. Speak, then press the shortcut again to stop.
4. Whisper transcribes the recording locally.
5. Optionally, a local model cleans up punctuation and obvious filler.
6. BolBhAI requests insertion into the original field, or leaves the text available to copy.

The current shortcut is **Command–Shift–Space** by default. It is a toggle: press once to start and again to stop. Holding a key to record is not implemented.

### The two modes

| Mode | What happens | Needs LM Studio? |
| --- | --- | --- |
| **Verbatim** | Returns Whisper's transcript directly. Bypasses LLM cleanup and the personal dictionary. | No |
| **Clean** | Sends the transcript to local Gemma cleanup. Checks the response, then applies your dictionary if cleanup succeeds. Keeps the raw transcript for comparison. | Yes |

“Verbatim” means no extra rewriting after Whisper. It does not mean perfect word-for-word recognition: Whisper can still make transcription errors.

Clean mode is conservative. It aims to remove obvious filler/repetitions and fix punctuation/capitalization, while preserving meaning, language, numbers, names, technical terms, and negations. It is instructed to preserve dictated questions and commands as text, rather than answer or follow them. If the server fails, privacy checks fail, or the candidate changes protected content, the final text falls back to the raw transcript with an explanation. These safeguards cannot guarantee a faithful edit.

## 2. The parts we have built

```text
Your microphone
    ↓ AVAudioEngine records temporary local audio
Audio validation and conversion
    ↓ rejects too-short or very quiet audio
Whisper small, through whisper.cpp
    ↓ raw transcript
Verbatim ──────────────────────────┐
Clean → LM Studio → output checks  │
        → personal dictionary      │
                                  ↓
                           Final text in the app
                                  ↓
               Original text field, or Copy/manual paste
```

**Whisper** is the speech model: it turns audio into text. We downloaded the multilingual `small` model, about 488 MB, so English and Hindi can be evaluated with the same engine. Hinglish accuracy and script choice remain empirical questions. Whisper may return Devanagari even when you expect Roman-script Hinglish.

**whisper.cpp** runs that model on this Mac. The app normally starts its own local worker and keeps the model loaded between recordings. This avoids reloading it for every session. A command-line fallback is also available, but it reloads the model each time.

**LM Studio** provides optional text cleanup. We used your existing Gemma 4 E4B model; no Ollama or replacement cleanup model was installed. Its on-disk ID was verified as `google/gemma-4-e4b`; the loaded instance used in testing was `bolbhai-gemma-e4b`. Refresh the app's model list rather than assuming an old loaded-instance ID still exists.

**The native app** provides a menu bar item, settings/transcript window, recording controls, status overlay, shortcut, and insertion handling. SwiftUI draws the interface; AppKit and macOS Accessibility APIs handle the desktop integration.

### Progress against the original milestones

| Milestone | Delivered | Evidence and remaining work |
| --- | --- | --- |
| 1. Local benchmark | Audio input/conversion, Whisper transcription, optional cleanup, configurable paths/models/language, timings and errors. | Real English sample and local cleanup tested. Human Hindi/Hinglish audio remains untested. |
| 2. Desktop app | Menu bar app, window, recording controls, states, overlay, raw/final text, Copy, Cancel, Verbatim/Clean. | Builds and packages. Live microphone and UI behavior need manual testing. |
| 3. Shortcut and insertion | Configurable toggle shortcut, remembered target app/field, Accessibility insertion, clipboard fallback. | Source implemented; real shortcuts, focus behavior, and target-app insertion remain unverified. |
| 4. Reliability/settings | Microphone selection, permission guidance, path validation, model discovery, dictionary, optional history, cancellation and recovery paths. | Core behavior checks pass. Native disconnect/sleep/wake recovery needs manual testing. |
| 5. Packaging | Reproducible scripts, `.app`, bundled speech helpers, microphone metadata, local ad hoc signing, documentation. | Local assembly/signature/helper checks passed. Distribution signing, notarization, and another-Mac installation remain unverified. |

## 3. Your first use, without changing code

The app and speech model already exist in this checkout. You do not need to rerun setup just to try the current build.

1. Quit an earlier running BolBhAI build through its menu bar menu.
2. From the project folder in VS Code's terminal, run:

   ```bash
   open dist/BolBhAI.app
   ```

3. Look for the waveform icon in the macOS menu bar. BolBhAI is a menu bar app; a normal Dock icon is not expected.
4. Choose **Settings & transcripts…**, then **Settings**.
5. Under **Speech**, check the model/helper paths and click **Validate**. The current model is `.local/models/ggml-small.bin`; packaged helpers are inside the app. The app attempts to find these automatically.
6. Select **System default** or your microphone. Use **Refresh microphones** after connecting a device.
7. Turn off **Insert into the original focused field when safe** for this first test. Leave history disabled.
8. In **Dictation**, choose **Verbatim** and click **Start recording**. Allow Microphone access when macOS asks. Speak a short sentence, then click **Stop recording**.
9. Review **Raw transcript** and **Final text**. Click **Copy final text** and paste into a disposable document yourself.

This walkthrough is a manual verification task; the implementation agent has not performed it. If it fails, keep the visible error and use the troubleshooting table below.

### What the status means

| Status | Meaning |
| --- | --- |
| Idle | Ready to begin. |
| Recording | The microphone is being captured. Recording has a five-minute limit. |
| Transcribing | Local Whisper is processing the audio. |
| Cleaning | Optional local text cleanup is running. |
| Ready | Final text is available to review/copy; inspect any insertion or cleanup message. |
| Error | The session could not finish; the message explains what to fix. |

**Cancel** discards the active session and clears its displayed result. Older work completing later cannot replace a newer session's transcript. Starting a new session also clears the previous in-memory result. Copy anything you want to keep first, or deliberately enable history.

Only one dictation session runs at a time. Quit through **Quit BolBhAI** so the app can wait for processing cleanup and stop its owned speech worker.

## 4. Using the shortcut and automatic insertion

After the first copy-only test works:

1. In Settings, choose **Enable Accessibility…** and grant BolBhAI access in macOS System Settings. Microphone and Accessibility are separate permissions.
2. Enable **Insert into the original focused field when safe**.
3. Open a disposable note in Notes and place the caret in its text.
4. Press **Command–Shift–Space**, speak, then press it again. Keep the original field focused until processing finishes.
5. Inspect the destination text. Repeat in a browser text field and a VS Code untitled text file.

Use the global shortcut when targeting another app. Starting from BolBhAI's own window is intended for reviewing and copying text.

BolBhAI checks both the original application and its focused field before inserting. Switching apps or fields, missing permissions, password/secure fields, or unsupported fields should produce manual-copy guidance. An “Insertion requested” message means an API call or paste event was accepted/dispatched; it does not prove the destination consumed it.

The app never sends Enter. Destination applications can still react to pasted text. Automatic insertion into Apple Terminal and identifiable terminal fields is disabled because pasted newlines can execute commands. Some embedded terminals cannot be identified reliably; use a plain document/text field, including when testing VS Code.

The **Allow clipboard/paste fallback** setting lets the app try Command–V when direct Accessibility editing is unavailable. It saves obtainable clipboard formats, restores them after 750 ms if its own clipboard value is still present, and refuses fallback if the clipboard changed during dictation. Slow apps and unreadable clipboard formats may require manual copying. Clicking **Copy final text** intentionally replaces the clipboard.

Avoid moving the caret within the same field during processing: the app verifies the field, not your original caret position. Detailed focus and clipboard checks are in [Manual verification](MANUAL-VERIFICATION.md).

## 5. Trying Clean mode

Start with Verbatim; add cleanup after basic recording works. Clean mode needs LM Studio's local server to stay running. Verbatim remains usable independently.

In the tested LM Studio installation, open **Developer → Developer Logs → More options** and ensure:

- **Redact Content:** ON.
- **Verbose Logging:** OFF.
- **Log Incoming Tokens:** OFF.
- **File Logging Mode:** OFF.

Restart the localhost server after changing these controls. These settings matter because LM Studio can log prompts and responses even when chat storage is disabled. BolBhAI checks the persisted logging configuration before sending dictation, and refuses unsafe or unknown settings. Older log files are not removed by disabling logging.

The existing model/server can be started from the terminal if needed:

```bash
lms server start --bind 127.0.0.1 --port 1234
lms load google/gemma-4-e4b --identifier bolbhai-gemma-e4b --yes
python3 scripts/verify-lm-privacy.py
```

The privacy script sends a fresh synthetic test phrase and checks diagnostic files; it does not use your private dictation. It passed for the tested configuration. Repeat it after changing logging settings or updating LM Studio: persisted settings alone cannot prove what a running server does.

In BolBhAI Settings, use `http://127.0.0.1:1234`, click **Refresh models**, and select an actual available/loaded ID. Choose **Clean** in Dictation. Compare raw and final text, especially names, numbers, dates, negations, quotations, and code terms. Conservative guards can reject a useful edit; successful cleanup is also not a guarantee of perfect fidelity.

The personal dictionary uses one mapping per line, for example:

```text
bol bhai = BolBhAI
```

Mappings apply to complete words/phrases after successful Clean-mode cleanup, with a maximum of 100 entries. They do not retrain Whisper, affect Verbatim, or run when cleanup falls back to raw text.

## 6. Where your data goes

**Transcript history is disabled by default.** Ordinary transcript display is in app memory, cleared by starting another session, cancelling, or quitting.

| Data | Location / lifetime |
| --- | --- |
| Raw/final text currently displayed | App memory. No automatic permanent transcript file with history disabled. |
| Optional history | `~/Library/Application Support/BolBhAI/history.json`; plaintext raw/final text, timestamps and IDs. |
| Recorded/converted audio and CLI output | Private temporary directories; removed after normal success, failure, or cancellation. Crashes/force-kill can leave temporary files. |
| Preferences and dictionary | Local macOS UserDefaults; separate from transcript history. |
| Downloaded Whisper model | Currently `.local/models/ggml-small.bin` in this project. Can be selected from another local location. |
| Cleanup model | Your existing LM Studio model storage. |
| Copied or inserted text | Clipboard or destination application; that application's saving/sync behavior applies. |

If you enable **History → Save local history**, the app keeps up to 100 entries for seven days. Retention is applied when history is accessed or appended, rather than continuously in the background. Disabling history or clicking **Delete all history** removes the saved file, not your model or preferences. File deletion is not secure disk erasure. History does not save audio.

The app adds no cloud inference, telemetry, accounts, screen reading, or transcript logging. Cleanup sends text only to a loopback endpoint on the same Mac. Initial dependency/model downloads need internet; normal inference is designed to use local files. Complete app operation with the network physically disconnected remains to be verified.

## 7. What has actually been verified

The recorded results are from this M4 Pro Mac on 13–14 October 2026; they are historical results, not a new test run performed while writing this guide.

- **26 automated check groups passed**, covering session transitions, cancellation, stale results, cleanup fallback, configuration, dictionary boundaries, history, audio conversion/silence, subprocess cleanup, and cleanup/privacy safeguards. Native microphone and target-app APIs are not exercised by these mocks.
- A real **11-second clear English sample** transcribed correctly using multilingual Whisper small.
- The resident speech worker reused its model; cancellation, recovery, shutdown, and normal temporary-file cleanup were exercised. Benchmark Ctrl–C/SIGTERM cleanup was also checked.
- **Eleven synthetic cleanup cases** exercised Gemma E4B: nine candidates accepted, two rejected with raw fallback. These included Hindi/Hinglish text, numbers, negations, code terms, and dictated instructions. This tests cleanup text, not Hindi/Hinglish speech recognition.
- Local packaging, plist metadata, helper execution, and ad hoc signatures passed.
- The benchmark worked with external network connections denied for its process tree. LM Studio was already running outside that restriction, so this is narrower than disconnecting the Mac's network.
- After correcting LM Studio logging controls, a synthetic privacy check found no new/changed diagnostic files or occurrences of its test phrase in the inspected locations.

### Observed performance

For the same 11-second English sample, using the packaged worker and an already-loaded Gemma model:

| Run | Transcription | Cleanup | Total processing |
| --- | ---: | ---: | ---: |
| First request to a new worker | 14.001 s | 1.501 s | 15.502 s |
| Second request, same resident worker | 0.393 s | 0.625 s | 1.018 s |

The first run includes worker/model startup; shader-cache state was not isolated. These timings exclude speaking/recording and insertion. They are a few observations, not a promised latency. See [Benchmark results](BENCHMARKS.md) and [Cleanup evaluation](CLEANUP-EVALUATION.md) for the full evidence.

Still unverified: actual microphone permissions/capture, shortcut/overlay behavior, Notes/browser/VS Code insertion, focus and clipboard behavior, native sleep/disconnect recovery, real English/Hindi/Hinglish microphone samples, and physically offline full-app operation. Use [Manual verification](MANUAL-VERIFICATION.md) to record Pass/Fail/Not exercised.

## 8. How to find your way around the project

| File or folder | Purpose |
| --- | --- |
| `Sources/BolBhAI/BolBhAIApp.swift` | App entry point, menu bar menu, settings window, graceful Quit. |
| `Sources/BolBhAI/AppModel.swift` | Connects settings, session, microphone, shortcut, overlay, insertion, and history. |
| `Sources/BolBhAI/SettingsView.swift` | Dictation, Settings, and History interface. |
| `Sources/BolBhAI/NativeServices.swift` | Actual macOS recording, shortcut, Accessibility and clipboard integration. |
| `Sources/BolBhAICore/Session.swift` | Session states, cancellation, stale-result protection, cleanup fallback. |
| `Sources/BolBhAICore/WhisperWorker.swift` | Keeps local Whisper loaded and supervises its worker. |
| `Sources/BolBhAICore/Transcription.swift` | Speech abstraction, audio preparation, CLI fallback. |
| `Sources/BolBhAICore/Cleanup.swift` and `CleanupPrivacy.swift` | Local cleanup API, output checks, logging privacy guard. |
| `Sources/BolBhAICore/Storage.swift` and `Configuration.swift` | Optional history, configuration and dictionary rules. |
| `Sources/BolBhAIBenchmark/main.swift` | File-based benchmark; uses the same core services as the app. |
| `Tests/BolBhAICoreTests/` | Behavior checks. `CheckRunner.swift` runs them; `SessionTests.swift`, `LifecycleChecks.swift`, and `CleanupTests.swift` supply cases. |
| `Package.swift` | Defines the Swift library and executable targets. |
| `Packaging/` | App metadata and benchmark-only offline test profile. |
| `.local/`, `.build/`, `dist/` | Downloaded dependencies/models, build output, and packaged app respectively; ignored by Git. |

The native app entry point is now `BolBhAIApp.swift`; the earlier `Sources/BolBhAI/main.swift` placeholder is no longer used. The behavior checks use a custom runner, so use the supplied check script rather than assuming `swift test` runs them.

### Commands to know when you resume development

Run these from the project folder. You do not need to run them just to understand this guide.

| Command | Purpose |
| --- | --- |
| `./scripts/doctor.sh` | Inspect tools, local files, and localhost server availability. Does not start a server. |
| `./scripts/check.sh` | Build/run the automated core checks. |
| `./scripts/build-app.sh` | Build release app/benchmark, assemble and locally sign `dist/BolBhAI.app`. Quit the previous build before opening the rebuilt one. |
| `./scripts/setup-whisper.sh` | Initial pinned dependency/model download and speech-helper build. Already completed here. |
| `./scripts/setup-whisper.sh --offline` | Rebuild speech helpers using the cached dependencies; refuses downloads. |
| `python3 scripts/verify-lm-privacy.py` | Verify the current cleanup logging configuration with synthetic text. |

Apple Command Line Tools were sufficient for the tested build; full Xcode and paid Apple credentials were not required. This local ad hoc signature is separate from signing/notarizing a distributable product. Rebuilding can require granting macOS permissions again.

To benchmark speech without using the microphone or cleanup:

```bash
.build/release/bolbhai-benchmark \
  --audio .local/whisper.cpp/samples/jfk.wav \
  --model .local/models/ggml-small.bin \
  --worker dist/BolBhAI.app/Contents/Resources/bin/whisper-server \
  --language en --runs 2
```

This prints the supplied sample's raw/final text and timings to the terminal. It does not measure shortcut or insertion behavior. More options and cleanup examples are in the [README](../README.md).

## 9. When something fails

| Symptom | First action |
| --- | --- |
| No menu bar item/window | Quit an old build, reopen `dist/BolBhAI.app`, look for the waveform menu bar icon. |
| Invalid model/helper path | Use **Choose…** and **Validate**. Select multilingual `ggml-small.bin`, not an English-only model. |
| Microphone permission denied | Use **Microphone permission…**, enable BolBhAI in System Settings, retry/restart if required. |
| Disconnected microphone | Reconnect, **Refresh microphones**, select a connected device. |
| Silent/too-short audio rejected | Speak for a few seconds and check the selected microphone. The amplitude gate is not a full speech detector. |
| First transcription unusually slow | Allow for model loading and initial Metal shader compilation; compare a later resident run. |
| Clean mode falls back to raw | Read its status, check LM Studio/server/model availability and logging controls. Verbatim can be used independently. |
| Shortcut fails | Check its registration status and choose another supported key/modifier combination. |
| Text is ready but not inserted | Inspect Accessibility permissions, focus and field support; Copy/paste manually. |

After an unexpected crash, the speech worker can be orphaned. Use Activity Monitor to identify the BolBhAI-related `whisper-server` before stopping it; do not stop unrelated local services. Normal Quit/cancellation performs cleanup, but crashes cannot guarantee it.

## 10. What to do next

Before adding features, complete the first copy-only microphone test, then the shortcut/insertion tests in Notes, a browser, and VS Code. Compare raw and cleaned transcripts using your own English, Hindi, and Hinglish samples. Test focus changes, silent recordings, LM Studio failure, and network-disconnected operation. Record failures in the [manual checklist](MANUAL-VERIFICATION.md).

Use those observations to choose the next code change: microphone/insertion fixes, better noise/silence detection, multilingual tuning, or more stable development signing. Existing measurements support keeping the resident Whisper worker and trying the existing E4B model before installing another cleanup model.

Meeting transcription, voice-controlled actions, screen context, accounts/cloud sync, mobile/Windows support, and model training remain outside version 1.
