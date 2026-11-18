# Walsey app (Stage 2)

Main app: connect to the LEDDMX controller over BLE, validate FFE0/FFE1, then
send **one explicitly requested LEDDMX frame per button press**.

**No frame in this app has ever been sent to real hardware yet.** Everything
below the BLE connection itself is decompiled-app evidence
(`Evidence.decompiledApp`), not hardware-confirmed. The protocol has **no state
read-back**, so the app only ever reports "last command sent", never "the LEDs
are green now".

## Run it

Android is the only platform with verified BLE connectivity
(`LEDDMX-03-6B4A`, 2026-10-23). Windows builds now pass, but Windows BLE has not
been run against a controller; see "Windows build" below and
`docs/hardware_checklist.md` for the validation sequence.

```bash
cd apps/walsey
flutter pub get
flutter analyze
flutter test

# Android (minSdk 24)
flutter devices                    # find the device id
flutter run -d <android-device-id>
# or build + install without attaching a debugger:
flutter build apk --debug
adb install -r build/app/outputs/flutter-apk/app-debug.apk
```

Diagnostics: every line is printed as `[WalseyApp] <time>  <text>` and also
written with `developer.log(name: 'WalseyApp')`.

```bash
adb logcat -s flutter:D | Select-String WalseyApp     # PowerShell
adb logcat -s flutter:D | grep WalseyApp              # bash
```

The same lines appear in the desktop diagnostic dock (below the content), in
*Activity → Diagnostics*, and in *Settings → Open diagnostics*. The dock can be
hidden from Settings; the raw log is always one tap away.

Pipeline stages use fixed prefixes so a transcript can never be mistaken for a
write: `VOICE RECOGNIZED:` → `VOICE INTERPRETED:` → `ACTION STARTED:` /
`PLAN STEP i/n` → `RESULT … BLE WRITE OK …` (frame written only). Only
`HARDWARE RESPONSE: PASSWORD REPLY:` is a controller reply, and only
`USER OBSERVATION:` records a visible LED change.

## Navigation

- **Windows** uses a fixed sidebar: Home, Devices, Connect (planned), Studio,
  Automations (planned), Assistant, plus Activity and Settings pinned at the
  bottom. The diagnostic dock is opt-in via Settings.
- **Android** uses five bottom destinations: Home, Devices, Studio, Assistant,
  Settings. Activity is reached from the dashboard header or Settings.
- *Connect* (Phone ↔ PC) and *Automations* are visible **planned-capability**
  pages. They explain what is required and contain no pretend controls.
- *Studio* keeps explicit **Apply** actions for the colour picker and
  brightness; preset swatches and favourite colours send immediately because
  tapping them is itself the explicit action. Segments and music modes are
  shown as **Not supported** rather than simulated.
- *Device details* (from Devices) contains the GATT findings, resolved variant
  and the controlled first-hardware-test procedure.

### Android setup

- `minSdk = 24` in `android/app/build.gradle.kts`.
- `BLUETOOTH_SCAN` (`neverForLocation`), `BLUETOOTH_CONNECT`, and
  `ACCESS_FINE_LOCATION`/`ACCESS_COARSE_LOCATION` for API ≤ 30 are declared in
  `android/app/src/main/AndroidManifest.xml`.
- Grant **Nearby devices** when asked. A permanently denied permission is
  reported in the log and opens app settings instead of silently failing.
- Voice only: `RECORD_AUDIO` is requested when a take or a model install needs
  it. `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_MICROPHONE` and
  `POST_NOTIFICATIONS` exist only for the opt-in microphone foreground service
  (`WakeWordForegroundService.kt` + `lib/voice/android_wake_service.dart`). That
  service is a **visible lifecycle shell**: it shows the mandatory notification
  with a *Stop listening* action and opens no microphone. It is only started by
  `VoiceSessionController.startWakeListening`, which needs an explicitly
  injected wake pipeline; this build injects none, so the service is never
  started here.

## First hardware test (do it in this order)

1. Power the strip from the correct supply; confirm the vendor app (LED LAMP)
   still controls it.
2. **Force-close the vendor app.** These controllers typically accept one
   central at a time.
3. App → *Devices* → **Start scan** → tap `LEDDMX-03-6B4A`.
   Expected log: `SELECTED TARGET … layout=LeddmxLayout.filler`, then
   `GATT TRANSPORT RESULT: FFE0/FFE1 validated`, then
   `CONTROL API BOUND …`. No frame is written during connect.
4. App → *Devices* → **Device details** → *Diagnostics*, press **Send** on one
   step at a time and watch the strip:

   | Step | Frame | Expected |
   |---|---|---|
   | 1. Authenticate | `2a 02 ** ** ** ** <tb> <min> af` (password redacted in logs) | No LED change; sets the controller clock |
   | 2. Password status | `2a 05 ff ff ff ff ff ff af` | Only documented reply; may print `wrongPassword`, `allSameDigits`, `resendRequested`, `unknown` or "no reply" |
   | 3. Power OFF | `7b 04 04 00 ff ff ff ff bf` | Strip turns off (never observed yet) |
   | 4. Power ON | `7b 04 04 01 ff ff ff ff bf` | Strip turns on |
   | 5. RED | `7b ff 07 ff 00 00 00 ff bf` | Strip turns red |

5. Tell the app what you saw (*LEDs changed* / *No visible change*) in the same
   Diagnostics section so it is in the log next to the write result. That entry
   is manual evidence and does not automatically raise the protocol's evidence
   level.
6. **If step 3 or 4 produces no change, stop.** Do not try random frames or the
   other layout. Capture the log and investigate `docs/research.md` first.
7. *ALL OFF* (bottom of the Diagnostics section) sends the same power-off frame
   and is always available as the escape hatch.

Studio: power, a filled colour wheel plus HEX/RGB entry, presets, brightness
0–100 % (filler layout sends `floor(v*32/100)`), effects by id (1–210, 255) and
favourite colours stored locally. Preset effect names exist only for ids 3, 4
and 255 — the repository has no names for the others, so no names are invented.

## Guarantees the app enforces

- One scan at a time, one connection attempt at a time; scanning is refused
  while connected.
- The link stays open after validation until *Disconnect*, link loss, or app
  exit. No connect timer, retry loop, automatic rescan or auto-reconnect.
- No frame is sent automatically, not even the handshake.
- Commands are serialised (one in flight, ≥ 50 ms gap, 5 s write timeout; a
  timed-out write blocks further writes until reconnect).
- Writes use `withResponse`, matching the vendor app's default.
- A write failure or timeout is reported as `FAILED`, never as success.
- Controls stay disabled for any advertised name that is not a documented
  `LEDDMX-NN` variant; a `FAIL:` GATT finding aborts the connection.

## Voice assistant

The *Assistant* page drives the Whisper.cpp recognizer (Vosk selectable as an
explicit fallback) through the app's `VoiceSessionController`. Recognition is
batch-based, so no partial Whisper transcript is displayed.

**Hold-to-talk**, not tap-to-toggle: pressing the microphone starts a take,
releasing it (even outside the button) ends the take, and a pointer cancel or
lifecycle change cancels it. Only one session can run at a time.

The transcript is interpreted by `VoicePlanParser`. A single sentence keeps the
Stage 1 guarantees; compound sentences become an **ordered plan** (scan, select
a real supported device, connect, then power/colour/brightness/effect). A
`CommandExecutor` runs the plan sequentially over the existing
`LedConnectionService`, re-checks prerequisites before each step, stops on the
first failure, and reports each step's real status. A successful BLE write is
never presented as confirmed LED state. Scenes are recognized but not
implemented, so they are reported as not executed.

Typed sentences use the same interpreter for inspection only and are **never**
executed; the page states that next to the input. Recognition outcomes and
parser outcomes stay separate, and a transcript is never cleaned up to make it
parse.

Everyday phrasings are mapped by a **literal** table before the unchanged grammar
(`could you switch the lighting on`, `I want the lights enabled`, `power up`,
`switch off`). Brightness words are fixed percentages (`half`, `quarter`, `full`,
`maximum`, `minimum`). A status question (`are the lights on`, `what is the
brightness`) is recognized and answered honestly: the controller protocol has no
state read-back, so nothing is sent and the LED state stays unknown. The result
banner says *Answer — nothing sent* instead of *Executed*, because no frame was
written. Statements
and any question containing an action verb are still refused. A pronoun follow-up
(`make them blue`) can reuse the last successfully targeted device through
`VoiceConversation` (10-minute expiry, cleared on disconnect); it only proposes a
reconnect, and the normal parser/executor checks still decide what runs.

Each session reports measured latency (engine/model, recorder open, press → first
audio, release → transcript, parse, end-to-end) in the UI and as a
`VOICE LATENCY:` log line. Nothing is estimated.

Optional **spoken responses**: *Settings → Spoken responses* (off by default,
persisted as `spokenResponses`). When enabled the assistant speaks one short,
fixed outcome (`Done.`, `Command not executed.`, `Cancelled.`, `Plan ready.
Nothing was sent.`) using the operating system's installed voice via
`flutter_tts`. No model or voice is downloaded, typed input is never spoken, and
the controller silences the engine before each take so a response cannot be
transcribed. A missing platform voice is logged and never blocks recognition.

Wake word is **implemented and opt-in wired, but unavailable in this build**:
`VoskWakeWordDetector` (streaming Vosk + `PhoneticWakeMatcher`),
`OnnxWakeWordDetector` (frame-scoring seam), `VoiceActivityDetector`,
`BufferedSpeechRecognizer` and `WakeWordCommandLoop` (pre-roll → VAD → stop
detector → batch decode) live in `walsey_voice_speech`. `VoiceSessionController`
can start the loop only from an explicit call, and the Assistant shows a consent
switch plus *Start listening* only when a loop is injected. This build injects
none: no trained "Walsey" model and no ONNX `WakeWordScorer` backend exists, so
the card says so instead of showing a fake control. The measured Vosk result is
0/36 synthetic positives with 0/60 false activations — not usable. When a loop
is present, a hold pauses listening (and resumes it after the take), a spoken
response is silenced on detection, and every wake transcript goes through the
same parser/executor. Background listening is Android-only via the visible
foreground-service notification. See `docs/wake_word.md`.

Music-reactive mode and split-by-parts (segments) remain **unsupported** and are
shown that way in Studio. The investigations and the offline (never-sent) FFT
prototype are in `docs/music_mode.md` and `docs/led_segments.md`. The
opt-in LED-feedback abstraction (`lib/control/led_feedback.dart`) is present but
dormant: nothing enables or calls it, so it never sends a frame.

Current measured state, including recognition numbers, the wake benchmarks, the
background-listening capability table and every unverified item, is in
`docs/voice_assistant_report.md`.

Model downloads are explicit from **Manage offline models**. Windows developer
files can be installed with `tools/fetch_whisper_windows.ps1` and
`tools/fetch_vosk_windows.ps1`, passing a destination under
`apps/walsey/windows/`. Android Whisper libraries are built explicitly with
`tools/build_whisper_android.ps1 -Destination apps/walsey/android/app/src/main/jniLibs-whisper`.
The app still builds and typed controls remain usable when native Whisper files
are absent.

## Windows build (nuget + MSVC 14.51 `/await` workaround)

`flutter build windows --debug` **passes** (2026-11-06). Two prerequisites:

1. **`nuget.exe` on `PATH`.** The `flutter_tts` Windows plugin runs
   `nuget install Microsoft.Windows.CppWinRT` at CMake configure time and fails
   with `nuget.exe not found. Please install it.` Download it outside the repo
   (`https://dist.nuget.org/win-x86-commandline/latest/nuget.exe`) and prepend
   its folder to `PATH` for the build. It is not committed.
2. The `/await` workaround below. The original failure was inside third-party
   plugin code, not this app:

```
experimental\coroutine(37,1): error C2338: static assertion failed: 'error STL1011:
The /await compiler option ... are deprecated by Microsoft and will be REMOVED SOON'
  [build\windows\x64\plugins\bluetooth_low_energy_windows\...vcxproj]
  [build\windows\x64\plugins\permission_handler_windows\...vcxproj]
```

Both plugins compile C++/WinRT coroutines as C++17 with `/await`.
`windows/CMakeLists.txt` removes `/await` from those two targets and builds them
as C++20, where coroutines are native. The pub cache is untouched and Android is
unaffected. Remove the block once both plugins raise their own language
standard. Windows BLE is still **unverified on hardware**; use the checklist in
`docs/hardware_checklist.md`.
