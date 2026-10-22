# Recording flow through the code

This traces the current source. It explains the implemented call sequence; it does not establish that native microphone, shortcut, or insertion integrations have passed manual testing.

**Start records audio; Stop begins transcription.** The app does not stream partial transcripts while you speak. Clean mode edits a completed transcript; it does not summarize or train a model.

## 1. Start recording

```mermaid
sequenceDiagram
    actor You
    participant UI as Button or global shortcut
    participant App as AppModel.swift
    participant Session as Session.swift
    participant Adapter as RecorderAdapter in AppModel.swift
    participant Audio as AudioRecorder in NativeServices.swift

    You->>UI: Click Start or press shortcut
    UI->>App: toggle()
    App->>App: Reject overlapping sessions; capture target app/field
    App->>App: Snapshot preferences; configure SpeechRouter
    Note over App: Select worker service or CLI fallback<br/>No new Whisper process/model load yet
    App->>Session: begin(speech, cleanup, clean, dictionary)
    Session->>Session: New generation ID; clear old result; validate configuration
    Session->>Adapter: start()
    Adapter->>Audio: requestPermission()
    Audio-->>Adapter: Microphone permission result
    Adapter->>Adapter: Check cancellation; resolve selected microphone
    Adapter->>Audio: start(deviceID:)
    Audio->>Audio: Create AVAudioEngine and private recording.caf
    Audio->>Audio: Install audio tap; start engine
    Audio-->>Adapter: Recording file URL
    Adapter-->>Session: Recording file URL
    Session->>Session: state = recording
    Session-->>App: Published state change
    App->>App: Show overlay; begin five-minute recording limit
    loop While you speak
        Audio->>Audio: Microphone buffers → RecordingSink → recording.caf
    end
```

The Start button in `SettingsView.swift` and the menu button in `BolBhAIApp.swift` both call `AppModel.toggle()`. The Carbon shortcut registered by `AppModel.registerShortcut()` calls the same method through `GlobalShortcut` in `NativeServices.swift`.

`AppModel` coordinates the desktop features. `DictationSession` in `Session.swift` controls session state. `RecorderAdapter` bridges the core recording protocol to the actual macOS recorder, including permission and device selection.

The recording is a private temporary CAF file, not a history entry. `RecordingSink` synchronizes audio writes and shutdown. Permission, configuration, or device failures take an error path rather than continuing this successful sequence.

## 2. Stop and transcribe

```mermaid
sequenceDiagram
    actor You
    participant App as AppModel.swift
    participant Session as Session.swift
    participant Audio as Adapter and AudioRecorder
    participant Speech as SpeechRouter and WhisperWorker.swift
    participant Prep as AudioPreparation in Transcription.swift
    participant Worker as Local whisper-server process

    You->>App: Stop button or shortcut → toggle()
    App->>Session: stop()
    Session->>Audio: stop()
    Audio->>Audio: Stop engine, remove tap, close audio file
    Audio-->>Session: Completed recording.caf URL
    Session->>Session: state = transcribing; start timer
    Session->>Speech: transcribe(audio, configuration)
    Speech->>Prep: convert(audio, temporary directory)
    Prep->>Prep: afconvert → mono 16 kHz 16-bit speech.wav
    Prep->>Prep: Validate duration and amplitude
    Prep-->>Speech: Validated WAV URL
    alt First request or worker/model changed
        Speech->>Worker: Launch on loopback; load Whisper model
        Speech->>Worker: Wait for health readiness
    else Existing healthy worker
        Note over Speech,Worker: Reuse resident model
    end
    Speech->>Worker: POST WAV to private /inference route
    Worker-->>Speech: JSON containing raw transcript
    Speech->>Speech: Validate response; remove temporary WAV directory
    Speech-->>Session: Raw text
    Session->>Session: Reject cancelled/stale result; publish rawTranscript
```

`SpeechRouter` lives in `AppModel.swift`. It implements `TranscriptionService`, the protocol declared in `Transcription.swift`, and normally delegates to `PersistentWhisperService` in `WhisperWorker.swift`.

If no executable worker helper is configured, the router instead calls `WhisperCLIService` in `Transcription.swift`. That path performs the same preparation, runs `whisper-cli` through `ProcessRunner.swift`, reads its temporary transcript file, and deletes the inference directory. It reloads the model on each invocation. A failed active worker request is reported as an error; it does not automatically retry through the CLI.

Audio preparation rejects recordings outside 0.35–300 seconds and recordings below the amplitude thresholds before inference. This is a silence/quietness gate, not a guarantee that audible input contains speech.

## 3. Optional cleanup, display, and insertion

```mermaid
sequenceDiagram
    participant Session as Session.swift
    participant Clean as LMStudioCleanupService in Cleanup.swift
    participant LM as Local LM Studio and Gemma
    participant App as AppModel.swift
    participant Insert as TextInserter in NativeServices.swift
    participant History as HistoryStore in Storage.swift

    alt Verbatim mode
        Session->>Session: Final text = raw transcript; no dictionary edits
    else Clean mode
        Session->>Session: state = cleaning
        Session->>Clean: clean(raw, configuration)
        Clean->>LM: Discover actual model IDs/capabilities
        Clean->>Clean: Check logging policy in CleanupPrivacy.swift
        Note over Clean: Refuse unsafe settings before sending transcript
        Clean->>LM: POST transcript with conservative cleanup prompt
        LM-->>Clean: Edited candidate
        Clean->>Clean: Validate response, numbers, negations, language and terms
        alt Cleanup accepted
            Clean-->>Session: Edited text
            Session->>Session: Apply explicit dictionary mappings
        else Cleanup fails or candidate rejected
            Clean-->>Session: Error
            Session->>Session: Final text = raw; explain fallback
        end
    end
    Session->>Session: Reject cancelled/stale result
    Session->>Session: Publish raw/final text and timings; state = ready
    Session-->>App: onReady(result) → completed(result)
    App->>App: Hide overlay; start completion task
    opt Automatic insertion enabled
        App->>Insert: insert(final, remembered target, fallback preference)
        Insert->>Insert: Recheck focused app/field, permissions and field support
        Insert->>Insert: Request AX edit or eligible clipboard paste; otherwise manual guidance
        Insert-->>App: Insertion request or manual-copy status
    end
    App->>History: append(raw, final, enabled: historyEnabled)
    Note over History: Save only if enabled; otherwise clear any saved history
    Note over Session: Processing task's defer removes original recording
```

The cleanup diagram shows the native LM Studio API path. Model discovery uses `/api/v1/models`; cleanup uses `/api/v1/chat`. If native discovery is unsupported, `Cleanup.swift` has an OpenAI-compatible local API fallback. All accepted origins are loopback; this does not send text to a cloud model. Logging checks run immediately before a transcript POST.

`PersonalDictionary.apply` lives in `Configuration.swift`. It runs only after successful Clean-mode cleanup. The raw transcript is preserved separately.

The UI observes published state; it does not need to poll or explicitly request a redraw. `SettingsView.swift` displays `session.rawTranscript`, `session.result`, status, and processing timings. `onReady` is the separate callback that begins insertion/history work.

Insertion is asynchronous and may finish after the original recording has already been deleted. `DictationSession.stop()` installs a `defer` for recording deletion around its processing task; it does not wait for `AppModel`'s separate insertion/history task. The diagram's final note marks cleanup ownership, not a strict ordering after history.

An accepted Accessibility write or dispatched paste is an insertion request, not proof that the target visibly received the text. Focus changes, secure/unsupported fields, and clipboard conflicts can require manual Copy. No Enter is sent. Automatic Terminal insertion is blocked, and some embedded command fields cannot be recognized reliably.

History defaults off. When enabled, it stores plaintext raw/final text at `~/Library/Application Support/BolBhAI/history.json`, retaining at most 100 entries for seven days on access.

## Cancellation and errors

- `AppModel.cancel()` invalidates its generation ID, cancels preparation/insertion/timer work, calls `session.cancel()`, and hides the overlay.
- `DictationSession.cancel()` invalidates its own generation ID, cancels processing, stops recording, deletes owned recording files, clears text, and returns to `idle`.
- Checks after asynchronous operations discard results from cancelled or superseded sessions. A late result cannot replace a newer transcript.
- Worker cancellation terminates its owned speech process; temporary inference directories are cleaned as tasks unwind. A later request starts a fresh worker.
- Speech/recording failure produces an error. Cleanup failure usually retains raw text and reaches `ready` with fallback status. Cancellation is treated separately and does not publish a completed result.
- Graceful Quit awaits retiring processing tasks and shuts down the owned worker. A force-kill or crash cannot guarantee cleanup.

## Suggested code-reading order

1. `Sources/BolBhAI/SettingsView.swift` — see the button calling `model.toggle()`.
2. `Sources/BolBhAI/AppModel.swift` — follow `toggle()`, `RecorderAdapter`, `SpeechRouter`, then `completed()`.
3. `Sources/BolBhAICore/Session.swift` — follow `begin()`, `stop()`, `cancel()` and the state changes.
4. `Sources/BolBhAI/NativeServices.swift` — inspect actual microphone capture and insertion.
5. `Sources/BolBhAICore/WhisperWorker.swift` and `Transcription.swift` — follow conversion and speech inference.
6. `Sources/BolBhAICore/Cleanup.swift`, `CleanupPrivacy.swift`, `Configuration.swift`, and `Storage.swift` — optional editing, checks, dictionary, and history.

Build/setup scripts are used to prepare the executables and app; the recording button does not invoke those scripts. `Tests/BolBhAICoreTests/` exercises behavior with test services and fixtures; test files are not part of a normal dictation session.
