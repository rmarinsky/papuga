# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Papuga is a macOS menu bar utility that converts already-typed text between keyboard layouts. Select text typed in the wrong layout (e.g., Ukrainian instead of English), trigger a hotkey, and Papuga remaps characters, pastes the corrected text, and switches the system layout.

- **Platform:** macOS 14.0+ (Sonoma), Swift/SwiftUI
- **Bundle ID:** `ua.com.rmarinsky.papuga` (release) / `ua.com.rmarinsky.papuga.dev` (dev)
- **Required permissions:** Accessibility + Input Monitoring (both mandatory for hotkeys and auto-paste)
- **UI language:** Ukrainian

## Build Commands

```bash
# Open in Xcode (no XcodeGen needed — uses .xcodeproj directly)
open papuga.xcodeproj          # Run "papuga" scheme

# Dev install (reset TCC, build, install to /Applications)
./scripts/dev-install.sh
./scripts/dev-install.sh --build-only        # Build only
./scripts/dev-install.sh --no-reset-tcc      # Skip TCC reset
./scripts/dev-install.sh --install-name name # Custom app name

# Release
./release.sh                    # Build, sign, notarize, create DMG
./release.sh --skip-notarize    # Without notarization

# Command-line build
xcodebuild -project papuga.xcodeproj -scheme papuga -configuration Debug build
```

## Release process

**NEVER push directly to `main`** — not commits, not tags. Everything goes through a PR.
**NEVER create or push `v*` tags by hand** — CI does that.
**NEVER hand-edit** `MARKETING_VERSION` in the Xcode project or the Sparkle `appcast.xml`.

To ship a release:

1. Open a PR into `main`.
2. Add exactly one label: `release:patch` (bug fix / internal), `release:minor`
   (new user-facing capability), `release:major` (breaking change), or
   `release:skip` (no release for this PR).
3. Merge the PR.

CI does the rest: `prepare-release.yml` computes the next version from the
latest tag, pushes tag `vX.Y.Z`, and dispatches `release.yml`, which builds,
notarizes, signs, creates the GitHub Release, and updates the Sparkle
`appcast.xml` on the **`gh-pages`** branch. The app version comes **from the
git tag** — `MARKETING_VERSION` in the project is only a placeholder.

Workflows: `.github/workflows/release-label-check.yml` (PR gate),
`prepare-release.yml` (tag on merge), `release.yml` (build + publish).
Version math: `scripts/next-version.sh`.

Sparkle EdDSA: `SPARKLE_EDDSA_PRIVATE_KEY` secret holds the raw 44-char
base64 seed exported via Sparkle's `generate_keys`. Do not add a length
guard — `sign_update` is the source of truth for key validity.

## Architecture

### Text Switching Flow (End-to-End)

```
1. User triggers hotkey (double-press modifier or custom shortcut)
2. AppDelegate → textSwitchEngine.performSwitch(direction: .forward)
3. Guard: isServiceRunning + hasSelectedTextInFocusedElement (AX API check)
4. ClipboardHistoryManager.suspendTracking() — prevent capturing intermediates
5. ClipboardManager.save() — snapshot all pasteboard items (full multi-type fidelity)
6. ClipboardManager.simulateCopy() — CGEvent Cmd+C
7. Wait 0.1s, poll for clipboard change (3 retries × 0.05s)
8. LayoutManager.getCurrentLayoutID() → nextLayout(after:direction:)
9. CharacterMapper.convert(text, fromSourceID, toSourceID)
   └── source char → keyCode (forward map) → target char (reverse map)
10. ClipboardManager.setText(converted) → simulatePaste() (Cmd+V)
11. Update analytics (replacement count, words, seconds saved)
12. Wait 0.1s → LayoutManager.switchTo(targetID)
13. Wait 0.5s → ClipboardManager.restore(savedState) — original clipboard back
14. ClipboardHistoryManager.resumeTracking()
```

### Character Mapping

`CharacterMapper` builds two maps per keyboard layout via `UCKeyTranslate` (keyCodes 0–127):
- **Forward map** `[Character: KeyMapping]` — char → keyCode + shift state
- **Reverse map** `[UInt16: KeycodeCharacters]` — keyCode → char (normal + shifted)

Conversion: source char → keyCode (source forward map) → target char (target reverse map), preserving shift state. Maps are cached per source ID.

### Double-Press Detection

`HotkeyListener` uses `CGEvent.tapCreate` with `.listenOnly` watching `flagsChanged` + `keyDown`:
- Any `keyDown` resets double-press state
- On `flagsChanged`: detects modifier chord release (e.g., Opt+Shift released)
- Two releases within `doublePressInterval` (default 0.4s, range 0.2–0.8s) = double-press → fire
- Presets: `optionShift` (default), `commandShift`, `controlShift`
- Auto-re-enables if system disables the event tap

### Activation Modes (mutually exclusive)

| Mode | Setting | Mechanism |
|------|---------|-----------|
| Double-press (default) | `useDoublePress = true` | `HotkeyListener` CGEventTap |
| Custom shortcut | `useDoublePress = false` | `KeyboardShortcuts.onKeyUp(.switchForward)` |

### Clipboard History

`ClipboardHistoryManager` polls `NSPasteboard.general.changeCount` every 0.35s:
- Deduplicates via hash signature (item count + types + data samples)
- Preview detection: file URLs, plain text (strips RTF/HTML), images
- Max 120 entries, pruned by retention preset (1h/1d/2d/1w)
- Suspension mechanism (reference counted) prevents capturing Papuga's own operations

### Layout Manager

`LayoutManager` (`@Observable`) enumerates selectable input sources via `TISCreateInputSourceList`, persists user-defined cycling order. Observes `kTISNotifySelectedKeyboardInputSourceChanged` for live tracking. `switchTo()` calls `TISSelectInputSource`.

### Key Components

| Component | Purpose |
|-----------|---------|
| `TextSwitchEngine` | Core orchestrator — coordinates copy, convert, paste, restore |
| `CharacterMapper` | UCKeyTranslate-based character remapping between layouts |
| `LayoutManager` | TIS input source enumeration, ordering, switching |
| `ClipboardManager` | NSPasteboard save/restore, CGEvent Cmd+C/Cmd+V simulation |
| `ClipboardHistoryManager` | Polling-based clipboard monitoring with history |
| `HotkeyListener` | CGEventTap double-press modifier detection |
| `AppDelegate` | Wires everything, manages lifecycle and settings observation |

## Settings (UserDefaults via Defaults library)

| Key | Default | Purpose |
|-----|---------|---------|
| `isServiceRunning` | true | Master enable/disable |
| `useDoublePress` | true | Double-press vs custom shortcut |
| `doublePressInterval` | 0.4 | Seconds between presses |
| `doublePressShortcut` | "optionShift" | Modifier preset |
| `layoutOrder` | [] | User-defined layout cycling order |
| `switchResultMode` | "copyAndPaste" | "copyOnly" or "copyAndPaste" |
| `clipboardHistoryRetention` | "oneDay" | 1h/1d/2d/1w |

## Timing Constants

```
clipboardWaitDuration       = 0.1s    # After simulateCopy before reading
clipboardRestoreDelay       = 0.5s    # After simulatePaste before restoring
clipboardRetryCount         = 3       # Retries for changeCount update
clipboardRetryInterval      = 0.05s   # Between retries
estimatedSecondsPerWord     = 1.6     # Analytics time estimate
maxKeyCode                  = 127     # UCKeyTranslate range
```

## Logging

`AppLogger` wraps `OSLog.Logger` with semantic methods: `pre()` (debug), `action()` (notice), `post()` (debug), `warn()` (warning), `error()` (error).

Categories: `Lifecycle`, `Hotkey`, `SwitchEngine`, `Clipboard`, `Layout`, `Mapper`, `UI`

## Onboarding

4-step flow: welcome → accessibility permission → input monitoring permission → complete. Stored in UserDefaults with version tracking (allows re-triggering on major bumps). NSWindow hosting SwiftUI.

## SPM Dependencies

- **Defaults** (sindresorhus) — typed UserDefaults with `@Default`
- **KeyboardShortcuts** (sindresorhus) — shortcut recorder + handler
- **LaunchAtLogin** (sindresorhus) — launch at login toggle
- **Sauce** — keyboard layout key resolution

## Key Files to Edit

| Task | Files |
|------|-------|
| Modify text conversion | `TextSwitchEngine.swift`, `CharacterMapper.swift` |
| Change hotkey detection | `HotkeyListener.swift` |
| Modify clipboard handling | `ClipboardManager.swift` |
| Add/change settings | `AppSettings.swift` + relevant settings view |
| Modify layout switching | `LayoutManager.swift` |
| Change menu bar content | `MenuBarView.swift` |
| Modify clipboard history | `ClipboardHistoryManager.swift` |
