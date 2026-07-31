# Inline preview companion (palette input method)

The palette-type InputMethodKit bundle that renders Epos's inline preview:
`InlinePreviewSession` streams volatile text to it over a Unix socket and it
draws the marked text in the focused field. Started as the falsifying probe for
`specs/inline-preview-feasibility.md`; the probe passed (2026-07-31) and this
is now a product component, built and installed in lockstep with the app by
`scripts/install-signed-app.sh` (which calls `install` below).

It stays outside `Package.swift` and the root `project.yml` on purpose — input
methods are their own bundles in `~/Library/Input Methods`, not code the app
links. Bundle id is `com.steez.inputmethod.EposProbe`, distinct from the purged
historical `com.steez.inputmethod.Epos` (kept stable: re-registering a new id
costs a logout).

## Files

| Path | Role |
|------|------|
| `Sources/main.swift` | `IMKServer` bootstrap; no UI, no keyboard handling |
| `Sources/ProbeInputController.swift` | `setMarkedText` / `insertText` / discard, plus the per-pass focus lock |
| `Sources/ProbeCommandSocket.swift` | AF_UNIX line protocol: `ping status begin end mark markplain commit cancel quit` |
| `Sources/ProbeSupport.swift` | Socket path (`confstr(_CS_DARWIN_USER_TEMP_DIR)`) and log path |
| `Driver/main.swift` | `run-stream` driver: TIS enable/select, streams words, commits or cancels |
| `Tools/tisctl.swift` | TIS query/register helper used by `install` / `uninstall` |
| `Info.plist` | `InputMethodType = palette`, `ComponentInvisibleInSystemUI = true` |
| `install` / `uninstall` / `run-stream` | Operator commands |

Log: `~/Library/Caches/EposProbe/probe.log` — records every `activateServer`,
`deactivateServer`, mark, commit and cancel with the client bundle id, plus every
connection and composition-teardown decision (`connection N accepted/ended`,
`release connection=…`, `clear reason=…`).

## Composition ownership and teardown

The focused field must never be left holding marked text: hosts that commit on
unmark turn a stranded composition into document text. So the probe tracks *which
client currently holds marked text* as its own record — bundle id, owning session,
and the command connection that put it there — separately from the per-pass focus
lock, and every teardown path tries to remove it instead of refusing:

- **`cancel`** goes to the recorded owner, not the lock. A lock that stopped
  resolving mid-pass (hosts tear an IMK session down and build a new one
  constantly) no longer means "refuse and leave it on screen". `ok` means no
  marked text of ours remains; `err` means some may still be live and nothing
  could reach it. If the owning session died, a live session for the same bundle
  id is used instead (`viaOwner=false` in the log); zero-length marked text is a
  no-op on a session that has no composition.
- **Losing the command connection** is a teardown, not a pause. The peer that
  dropped was the only process that could have asked us to un-mark, so its
  composition is cleared and its focus lock released. `killall Epos` mid-recording
  no longer strands a composition.
- **`deactivateServer`** clears the composition when the session being torn down
  is the one holding it — after the teardown it is no longer addressable.
- **`commitComposition`** still never inserts, and is now scoped: only the session
  that owns the composition acts on it, so a background app finalizing cannot wipe
  a recording in progress.

`commit` is the one path that inserts, and the only one that still refuses on an
unresolvable lock — Epos treats an `err` reply as proof `insertText` did not run.
`end` only releases the lock and never touches text.

Exactly one client is legitimate, so **a new connection supersedes the current
one**: the previous peer is shut down (which runs its teardown) and each
connection is served on its own thread, so a stuck peer can never wedge the accept
loop. The cost is that connecting a second client — running `run-stream` during a
live Epos recording, say — drops the first one; it degrades that recording to
HUD-only and is logged, but never writes text. Replies are written with
`SO_NOSIGPIPE` + a process-wide `SIGPIPE` ignore and a bounded `SO_SNDTIMEO`, so a
peer that departs before reading its reply costs one failed write instead of
killing the input method.

## Install

```sh
probes/inline-preview/install
```

Builds, signs with your Apple Development identity, copies to
`~/Library/Input Methods/EposProbe.app`, runs `lsregister` +
`TISRegisterInputSource`, restarts `TextInputMenuAgent TextInputSwitcher lsd
cfprefsd`, then polls for the source. Prints `registered live` (exit 0) or tells
you a logout is needed (exit 1; rerun `install --verify-only` after logging back
in). **On this machine live registration worked — no logout was needed.**

## Per-target test recipe

The palette source is additive: selecting it does not change your keyboard
layout (verified — `TISSelectInputSource` succeeds and the current keyboard
source stays `com.apple.keylayout.ABC`).

1. Open the target app and click into the field you want to test. Leave a known
   sentinel string in it so you can prove the cancel pass changed nothing.
2. From a *different* pane or window, run the driver with the target's bundle id:

   ```sh
   probes/inline-preview/run-stream --target com.mitchellh.ghostty --hold 15
   ```

   `--target` is a hard guard: the pass refuses to write anywhere else. Use
   `--focus-delay 5` if you need time to click back into the field, and
   `--hold N` to freeze the marked text for N seconds so you can look at it.
   Pass 1 streams four words then commits; pass 2 streams then cancels.
   `--commit-only` / `--cancel-only` run one pass. `--plain` sends an unstyled
   string instead of the underlined attributed run.
3. For the held-fn condition, hold fn while the marked text is on screen
   (Ghostty #4634: preedit can die on a modifier, and Epos is fn-hold by
   construction).

Bundle ids: `com.cmuxterm.app`, `com.mitchellh.ghostty`,
`com.microsoft.VSCode`, `com.tinyspeck.slackmacgap`, `com.apple.TextEdit`,
`com.apple.Safari`.

Record for each target:

| Target | Preedit renders? | Underline style | Survives held fn | Commit lands exactly once | Cancel leaves field byte-identical | Focus change mid-stream |
|---|---|---|---|---|---|---|
| cmux | | | | | | |
| Ghostty | | | | | | |
| VS Code | | | | | | |
| Slack | | | | | | |
| TextEdit | yes | native blue single underline | not tested | yes | yes | n/a |
| Safari field | | | | | | |

## Driving it from real dictation (preferred over the manual matrix)

Epos itself can act as the driver, so organic usage answers the per-app rendering
question instead of a scripted test pass. Behind `EPOS_INLINE_PREVIEW=1` the
coordinator mirrors its volatile transcript into the fn-press field as marked
text and discards it before the authoritative write:

```sh
# 1. the installed app must contain the spike
scripts/build-signed-app.sh && scripts/install-signed-app.sh

# 2. the probe must be running (it usually already is; the system launches it)
pgrep -x EposProbe || open ~/Library/Input\ Methods/EposProbe.app

# 3. relaunch Epos with the spike on
killall Epos 2>/dev/null
open -a /Applications/Epos.app --env EPOS_INLINE_PREVIEW=1
```

`--env` is required: a plain `open` does not pass the caller's environment, and
launching the bundle through `open` (not the inner binary) is what keeps the
installed app's TCC grants.

Then dictate normally into whatever app you are already using. One
`inline preview target=… began=… marks=… cancelAck=… failure=…` line per recording
lands in `~/Library/Caches/Epos/logs/` (category `inject`); the probe's own view
of the same pass is in `~/Library/Caches/EposProbe/probe.log`.

Without the variable Epos never opens the socket. Any failure — probe not
running, no session for the target bundle id, timeout — degrades to today's
HUD-only behavior for the rest of that recording.

## Kill criterion (pre-registered)

**If preedit fails in both cmux and Ghostty, close this line of work.**
App-dependent preview in only the easy apps is worse than today's uniform HUD.

## Findings so far

- Live registration works without logout (contradicts DevForums 775526). The
  source appears in `TISCreateInputSourceList` immediately after `lsregister` +
  `TISRegisterInputSource` + the agent restarts.
- **`TISEnableInputSource` is user-gated.** Each call raises a macOS consent
  dialog ("Allow … to enable EposProbe?"). Neither `install` nor `run-stream`
  calls it when the source is already enabled, because repeated calls re-prompt.
  For the product this is a real UX cost: enabling the input source needs one
  explicit user approval, on top of the existing TCC grants.
- The source registers as `TISCategoryPaletteInputSource` /
  `TISTypeCharacterPalette`, selectable, and selecting it leaves the keyboard
  layout alone.
- TextEdit: marked text renders inline at the caret with the native blue
  underline, commit inserts exactly once, cancel leaves the field byte-identical.
- `unmarkText` is *not* implemented by the IMK client proxy (`unmarkText=false`).
  Discard works because the probe first sets zero-length marked text.
- A plain `String` payload renders with **no** underline; the attributed run with
  `.underlineStyle` + `NSMarkedClauseSegment` is what produces the native look.
- **`activateServer` order is not a proxy for "the focused field."** Background
  processes activate spuriously — System Settings / the Keyboard Settings
  extension repeatedly took the most-recent slot while TextEdit was frontmost,
  and an early unguarded run committed into System Settings instead of the
  intended target. Hence `begin <bundle-id>`, which resolves the session by
  bundle id and pins it for the pass. Any real implementation needs the same
  guard.

## Uninstall

```sh
probes/inline-preview/uninstall
```

Deselects and disables the source, deletes the bundle from
`~/Library/Input Methods` and `.build`, rebuilds LaunchServices for the user,
local and system domains, restarts the input agents, then verifies via
`TISCreateInputSourceList` that the source is gone. Exit 0 only on a confirmed
purge.
