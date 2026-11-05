# CJ for iOS

A native SwiftUI companion for the existing CJ Mac brain. Requires iOS 17.2+ and
Xcode 26.4+; developed with Xcode 27.1. Meta's official Device Access Toolkit is
pinned to **1.0.1**, including its exact revision in `Package.resolved`.

## Build and run

1. Open `ios-app/CJ.xcodeproj` in Xcode. Let Swift Package Manager resolve Meta's SDK.
2. Choose the **CJ** scheme and an iPhone simulator, then Run. No Apple account is
   required for Simulator. Text chat and pairing can be exercised without glasses.
3. For a physical iPhone, select your Apple development team under
   **CJ → Signing & Capabilities** and change the bundle identifier if needed.
   Enable Developer Mode on the iPhone, choose it as the destination, and Run.
4. Open [CJ Bridge on the Mac](../mac-app/README.md). Choose **Codex** to use
   your ChatGPT sign-in, **Claude Code** for your Claude sign-in, or **Muse** for a gadget paired in CJ Bridge. For
   Gemini Live, choose **Gemini · API** and configure a Gemini key on the Mac.
5. In **Setup**, scan the bridge's QR code, review the address, then tap
   **Connect to Mac**. Manual address/token entry and pasted JSON also work.
   The token is the `token` field in `~/.cj/config.json`. Keep that file private.
   The app verifies both the server identity and token before saving to Keychain.
6. Tap **Talk to CJ** or enable **Listen for CJ**. In subscription mode, allow
   Speech Recognition so the iPhone can transcribe each question and speak the
   Mac's reply. You can also type a question. The iPhone speaker and connected
   Bluetooth headsets work before you link the glasses camera.

Voice defaults to **English**. Choose another language in **Setup → Speech
language**. Subscription voice needs on-device recognition for the selected
language and uses the phone's locale for the automatic setting.

For cellular or remote Wi-Fi, connect both devices to the same Tailscale network,
choose **Tailscale** in CJ Bridge and scan its HTTPS pairing code in **Setup**.
See the [Mac bridge guide](../mac-app/README.md#pair-over-tailscale). Use a trusted
local network for the original brain's HTTP endpoint. The app also supports
HTTPS/WSS endpoints, preserving ATS protections for internet hosts. Do not expose
the original HTTP server publicly. In subscription mode the phone sends transcripts
and requested photos to the Mac. Gemini Live also streams microphone audio.
The iPhone keeps conversation history in memory.

## Link glasses

Pair the glasses in the Meta AI app and enable its **Developer Mode**. Open CJ's
**Glasses** tab, tap **Link with Meta AI**, and complete the callback. Preview the
camera to grant camera permission. Wear the glasses with their arms open.

Developer Mode uses `META_APP_ID = 0`, so no Meta app credentials are needed for
local development. For other release channels, configure `META_APP_ID`,
`CLIENT_TOKEN`, and your Apple development team using your own Meta developer
app. Follow Meta's distribution requirements before distributing a signed build.

The app captures a fresh JPEG frame from the supported streaming API, rather
than the experimental high-resolution capture API. A photo is sent only when
attached to a question or requested during live voice. Camera streaming stops
when the app backgrounds. Already-started voice sessions use iOS's audio
background mode. Route changes rebuild the audio paths; interruptions, an
unrecoverable audio change, or connection loss end the session and pause wake
listening until it is enabled again.

## Listen for CJ

After pairing the Mac, enable **Listen for CJ** in Conversation or Setup and allow
Speech Recognition and microphone access. Say **CJ** or **Hey CJ**, followed by
your question. The detector uses Apple's on-device English speech recognition;
it refuses to enable if on-device recognition is unavailable. It does not send
idle audio or transcripts to a recognition server. A bounded in-memory buffer
retains the wake phrase and the following question while the Mac connects.

Saying **bye** or tapping **End conversation** returns to wake listening. The same
microphone capture continues through both modes. The **Listen for CJ** switch defaults to off on each launch. To release the idle
microphone, turn off both **Listen for CJ** and **Listen for Start while stopped**.

An active audio session may continue while the phone is locked. A force-quit app
cannot hear either phrase. Keeping the microphone active can increase battery use
and change Bluetooth audio quality. CJ uses the iPhone's active audio session.
Recognition restarts periodically without reopening the microphone. Repeated
recognizer failures, audio interruptions, or connection errors pause wake mode.
Long-running lock-screen behavior and wake accuracy require hardware validation.

## RayBridge chimes and voice commands

A rising two-note chime means CJ is listening for a question. The falling chime
means CJ has submitted it. A quiet double pulse repeats while the assistant is
thinking. Toggle the heartbeat in **Setup → Sound cues and voice commands**.

Say each English command on its own. CJ confirms it aloud.

| Command | What happens |
| --- | --- |
| **Start** | Starts a conversation while CJ is open, paired, and has microphone and speech permissions. Wait for the rising chime before asking your question. |
| **Cancel** | Drops the current question or stops its reply, then listens for another question. |
| **Stop** | Ends the conversation and returns to standby. |
| **Mute** | Pauses new questions. The current reply can finish. |
| **Unmute** | Restores input after Mute. |

Voice commands and foreground Start are enabled by default and have separate
switches in Setup. While muted, the phone listens locally for Unmute. With the
updated Mac bridge, Gemini receives the original microphone audio for accepted
questions. When local recognition is unavailable, voice commands are disabled,
or the bridge predates this feature, Gemini uses its existing streaming mode.

## Feature coverage

| Feature | iOS implementation |
| --- | --- |
| QR, pasted JSON, manual pairing | Yes; token in device-only Keychain; authentication checked |
| Typed questions and recent conversation context | Yes; existing `/api/ask` protocol |
| Image questions | Photo picker or a fresh glasses camera frame |
| Live voice | 16 kHz PCM upload, 24 kHz PCM playback, transcripts, interruption handling |
| Bluetooth glasses microphone/speaker | Standard iOS HFP route; physical-device validation required |
| Glasses camera | DAT registration, permission, session lifecycle, preview, fresh-frame capture |
| Mac tools, TV, smart home, quick notes | Existing brain handles them; integrations and Mac permissions still required |
| Spoken text replies | Brain-provided audio, with iOS speech synthesis fallback |
| Timers | Local notifications, subject to permission |
| Calls | Explicit user-tapped handoff to the Phone app |
| Android phone agent | Unsupported; iOS cannot use Android accessibility services |
| “CJ” wake word | Opt-in on-device recognition during an active microphone session; no wake after force-quit |
| Continuous meeting dictation, split-output translation | Not implemented; requests reported as unsupported |
| Automatic visual memory, location nudges, job polling, Bonjour rediscovery | Not implemented; pair again if the Mac's address changes |

This is an initial iOS port, not full Android feature parity. The Mac brain can
return phone actions originating from Android-specific tools; the app explicitly
reports unsupported actions. Hardware audio quality, background behavior, Meta
registration, and camera capture must be verified with your iPhone and glasses.
No App Store signing or distribution is configured.

## Verification

Build without a signing identity:

```sh
xcodebuild -project ios-app/CJ.xcodeproj -scheme CJ \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath ios-app/build CODE_SIGNING_ALLOWED=NO build
```

Run unit tests and UI tests, including a real HTTP round trip to the existing
Python brain in forced mock mode:

```sh
./scripts/test-ios.sh
```

The script starts a loopback-only fixture on port 18765 with a temporary `CJ_HOME`,
a test-only token, and empty provider keys. It removes the fixture on exit and
never reads your real `~/.cj`. Set `CJ_TEST_SIMULATOR` to a simulator UUID or
`CJ_TEST_PYTHON` to an environment containing the brain's requirements if needed.
Outside this script, the integration UI test skips when the fixture is absent.
Unit coverage includes malformed pairing data, auth headers, WS/WSS URLs,
authentication beyond public health, history bounds, photo encoding, and errors.

Run the original backend tests with `cd brain && .venv/bin/python -m pytest -q`.

For a lighter check that does not start Simulator, run
`cd ios-app && swift test --jobs 2`. This exercises the same pairing and HTTP
client sources on macOS, plus wake-phrase matching and bounded audio handoff.
Verification passed all 13 core tests and all 151
backend tests, including explicit speech-language preferences. The simulator UI run was blocked by the simulator test
runner stalling under memory pressure, so a compile result alone is not a UI or
hardware test result.

The signed iPhone build was installed and launched on a physical iPhone 16 Plus.
The user confirmed microphone transcription and CJ wake-word activation. Longer
sessions and wake listening while locked still need hardware verification.

Camera preview was subsequently confirmed on physical glasses after installing a
pending glasses update. CJ now waits for the SDK's device selector to become
ready before starting the camera. Live replies were silent on the first Talk
session after launch but audible after ending and starting another conversation.
A direct Mac service test returned non-silent reply audio. Audio startup now waits
for the selected input and output route to settle, explicitly matches the
voice-processing I/O formats, and checks playback with a silent buffer before
uploading microphone audio. Route changes rebuild both audio paths and retain
unplayed reply buffers. The user confirmed that the first reply after opening the
updated app is audible through the glasses with wake listening off, without ending
and restarting the conversation.

The checked-in project builds without XcodeGen. After adding/removing source files
or editing project settings, regenerate it with:

```sh
xcodegen generate --spec ios-app/project.yml
```

Regeneration resets manually selected signing settings; reselect your development
team in Xcode afterward. Avoid regenerating while another person is editing the
project in Xcode.

`scripts/make-ios-icon.swift` regenerates the app's original procedural icon.

## Architecture and references

- `Core/`: pairing validation, Keychain, and authenticated HTTP requests.
- `Audio/`: bounded microphone buffering, sample conversion, WebSocket events,
  echo cancellation, playback, and cancellation cleanup.
- `Glasses/`: Meta DAT registration and camera session ownership.
- `AppModel.swift` and `Views/`: conversation, attachments, setup, and explicit
  handoffs for supported phone actions.
- [Meta iOS SDK and samples](https://github.com/facebook/meta-wearables-dat-ios)
- [Meta iOS setup guide](https://github.com/facebook/meta-wearables-dat-ios/blob/main/plugins/mwdat-ios/skills/getting-started/SKILL.md)
- [Apple local-network ATS configuration](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking)
- [Apple voice-chat audio mode](https://developer.apple.com/documentation/avfaudio/avaudiosession/mode-swift.struct/voicechat)
- [Gemini transcription language hints](https://ai.google.dev/api/live#AudioTranscriptionConfig)

Original CJ source and this port use the repository's MIT license. The Meta SDK
is a separate dependency governed by Meta's own terms; it is not relicensed here.
