# CJ Bridge for Mac

CJ Bridge runs the existing brain server and connects the iPhone to **Codex with
ChatGPT sign-in** or **Claude Code with Claude sign-in**. The default for a new
bridge is Codex. Both use their existing Mac configuration, tools, plugins and
subscription quotas. Credentials remain managed by the installed CLI.

Build and open the development app:

```sh
bash scripts/build-mac.sh
open "mac-app/build/CJ Bridge.app"
```

The build creates the Python environment if necessary. This ad-hoc signed app
uses the brain and virtual environment in this checkout; keep the checkout in
place. It is a local development app, not a standalone distribution installer.

1. Sign in on this Mac with `codex login` (choose ChatGPT) and/or
   `claude auth login` (choose your Claude account).
2. Open CJ Bridge and choose the assistant and working folder. Settings are
   saved in `~/.cj/config.json`, preserving existing API keys and pairing tokens.
3. Keep the Mac awake and on the same Wi-Fi as the iPhone. In CJ's Setup, scan
   the QR code. Existing pairings continue to work if the Mac address is unchanged.
4. Tap **Talk to CJ**, or enable **Listen for CJ**. The iPhone detects the wake
   phrase and transcribes each question using on-device Apple recognition. The
   Mac assistant answers; the iPhone renders an Apple voice through the existing
   Bluetooth audio engine. Typed questions and attached photos use the same assistant.

Subscription voice is turn-based: question recognition pauses while the Mac is
working and while CJ speaks, then resumes. Say “bye” to end a conversation, or
tap End to cancel the current request. With wake listening enabled, ending a
conversation returns to wake detection. Visual questions such as “look at this”
request a fresh glasses photo; typed questions can include an attached photo.

## Execution and billing

Both assistants run with unrestricted execution as requested:

- Codex: `--dangerously-bypass-approvals-and-sandbox`.
- Claude Code: `--dangerously-skip-permissions --permission-prompts none`.

No tool allowlist or bridge sandbox is imposed. The chosen working folder is
the starting directory, not a filesystem boundary. macOS permissions and the
assistant's own account capabilities still apply. The legacy Claude Code job
runner also uses unrestricted tool execution.

Subscription requests require subscription authentication. API-key environment
variables are removed from these child processes; failures are returned to the
phone rather than falling back to Gemini, OpenAI API, Claude API or API speech.
The model comes from the local CLI configuration. The bridge starts a fresh CLI
turn with the recent CJ conversation history; it does not import existing chats.

Gemini API remains an explicit selectable option for the original streaming
voice implementation. Selecting it uses the saved Gemini API key and its billing.

Only paired clients can ask the assistants or read account status. Pairing stays
required even though assistant execution is unrestricted. Stopping a phone
request cancels its CLI process group; quitting the Mac app shuts down its brain.
If a separately launched brain already owns port 8765, the app reports it and
leaves process control with that terminal.

## Verification

Run `cd brain && .venv/bin/python -m pytest -q` for backend and fake-CLI tests,
`cd ios-app && swift test --jobs 2` for core iOS tests, and build both apps.
Physical glasses speech, wake handoff, photos and long-running sessions need
device testing; a build or a successful CLI reply alone does not verify those paths.
