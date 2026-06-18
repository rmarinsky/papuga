# Papuga AutoFix: target safety, VS Code, and mixed-language typing

Date: 2026-06-14

## Problem

AutoFix currently listens to global key events, keeps a local `WordBuffer`, and on a word boundary mutates the active app by sending repeated Backspace events and then Unicode key events.

This works in ordinary text fields, but it has three weak spots:

1. Target drift: the word was typed in one text target, but by the time Papuga applies the replacement another target has focus. Example: an app field plus Spotlight/Search overlay with its own caret.
2. Code editors: VS Code/Electron editors can have multiple cursors, custom text input handling, and limited Accessibility text state. Blind Backspace/type is not safe there.
3. Mixed-language typing: people intentionally write Ukrainian text with English acronyms, product names, code terms, commands, and short terminology. AutoFix must not fight that flow.

The fix is not one more threshold. We need a target/session layer before mutation, an app-specific editor policy, and a mixed-language decision policy.

## Current implementation evidence

Relevant files:

- `papuga/Core/AutoFixController.swift`
- `papuga/Core/AutoFixDecision.swift`
- `papuga/Core/AutoFixEditingGuard.swift`
- `papuga/Core/AppContextProvider.swift`
- `papuga/Core/LanguageScoring/*`
- `papugaTests/AutoFixEditingGuardTests.swift`
- `papugaTests/MultiLanguageEndToEndTests.swift`

Observed from code:

- `AutoFixController` uses a listen-only `CGEventTap` for key/mouse events.
- It stores only the typed token, not the target text field identity.
- It calls `AppContextProvider.frontmostBundleID()` at evaluation time, not when the token started.
- It mutates text with `deleteCharacters(count:)` and `typeText(_:)`.
- Existing editing guard suppresses obvious edit fragments after Backspace/navigation, but it does not validate the active target.
- Only Apple `NLLanguageRecognizer` is implemented. `ngram` and `cld3` are currently stubs that fall back to AppleNL.

## Phase 0 diagnostics

Before changing VS Code behavior, add focused debug logging behind a dev flag.

For each completed token log:

- event target PID if CoreGraphics exposes it;
- frontmost bundle ID at first character and at boundary;
- focused AX role/subrole/window signature if available;
- `typedString` length for printable keys;
- word buffer before boundary;
- current layout, target layout, candidate;
- skip reason or mutation strategy;
- whether `deleteCharacters` and `typeText` were attempted.

This separates three different VS Code failures:

1. Papuga does not receive useful typed characters.
2. Papuga receives characters but skips by decision/threshold.
3. Papuga decides correctly, but text injection does not apply in the editor.

Do not guess which one it is. Instrument it first.

## Design principle

Papuga should only mutate text when it can prove the target is the same text session that produced the buffer.

If it cannot prove that, it should do one of these:

- skip and record a local observation;
- show a compact proposal;
- require manual hotkey/manual accept;
- disable auto-mutation for that app profile.

Wrong replacement location is worse than a missed replacement.

## Target session model

Add a new local type:

```swift
struct AutoFixTargetSession: Equatable {
    let tokenID: UUID
    let startedAt: TimeInterval
    let targetPID: pid_t?
    let bundleID: String?
    let appName: String?
    let focusedElementSignature: FocusedElementSignature?
    let firstKeyCode: UInt16
    let firstCharacter: String
}

struct FocusedElementSignature: Equatable {
    let pid: pid_t
    let role: String?
    let subrole: String?
    let windowTitleHash: Int?
    let elementIdentifier: String?
    let frameHash: Int?
    let selectedRangeLocation: Int?
}
```

Capture the session on the first printable character after a reset:

- target PID from the `CGEvent` if available;
- frontmost bundle ID from `NSWorkspace`;
- focused AX element from `AXUIElementCreateSystemWide()`;
- role/subrole/window/title/frame/selected range where available.

Validate it on every printable key and before every mutation:

- same target PID if event target PID is available;
- same frontmost app bundle;
- same focused element signature where AX exposes it;
- selected range/caret should move forward with the typed token when range is available;
- no mouse down, app activation, command shortcut, focus loss, or navigation key since session start.

If validation fails:

- reset `WordBuffer`;
- reset `PhraseBuffer`;
- consume current token as `skipReason = target_changed`;
- do not show an accept button that would mutate the target.

New skip reasons:

- `target_changed`
- `target_unverifiable`
- `unsafe_editor`
- `multiple_cursor_risk`

## Focus and activation resets

Current reset sources are key/mouse based. Add passive resets:

- `NSWorkspace.didActivateApplicationNotification`
- `NSApplication.didResignActiveNotification` for Papuga UI
- optional polling on focused AX element while a token is active, max every 150-250 ms

This covers the visible “two active cursors” case: if Spotlight/Search overlay appears and becomes the real target, the token session changes and Papuga skips instead of replacing in the wrong field.

## Mutation strategies

Add:

```swift
enum AutoFixMutationStrategy {
    case directUnicodeEvents
    case clipboardPaste
    case proposalOnly
    case disabled
}
```

Default strategy:

- ordinary native text fields: `directUnicodeEvents`;
- browser content/editors: `proposalOnly` unless target verification is strong;
- code editors: `proposalOnly` by default;
- secure/unknown targets: `disabled`.

Do not use clipboard paste as a universal replacement. It may be useful for specific apps where Unicode key events fail, but it still has the same multi-cursor risk unless the target is verified.

## VS Code and code editors

### Why VS Code is special

VS Code is not a normal `NSTextView`.

Risks:

- multiple cursors/selections;
- Electron custom input handling;
- limited AX selected text/range;
- Backspace/type can apply to every cursor;
- Papuga cannot reliably infer active editor state through macOS Accessibility.

### MVP policy

Default code-editor policy:

```swift
enum AutoFixAppPolicy {
    case autoMutate
    case suggestOnly
    case manualOnly
    case disabled
}
```

Recommended defaults:

- `com.microsoft.VSCode`: `suggestOnly`
- `com.todesktop.230313mzl4w4u92`: `suggestOnly` for Cursor if bundle ID matches locally
- JetBrains IDEs: `suggestOnly`
- Xcode: start with `suggestOnly`, upgrade only after manual testing
- Terminal/iTerm/Warp: `disabled` by default

In `suggestOnly`, Papuga can still detect the candidate, show a compact proposal, and let the user copy/apply manually. It must not blindly Backspace/type into the editor.

### Better VS Code path

For reliable auto-apply in VS Code, build an optional VS Code extension later.

Extension responsibility:

- read `activeTextEditor.selections`;
- refuse if `selections.length != 1`;
- inspect the exact range before the active cursor;
- verify it equals `source + boundary`;
- replace that range with `target + boundary` through VS Code editor API;
- return success/failure to Papuga.

Communication options:

- local WebSocket on localhost;
- custom URL scheme;
- local file/Unix socket handshake.

This is the only robust way to support VS Code multi-cursor safely. Without an extension, Papuga should not promise perfect VS Code auto-mutation.

## Mixed-language policy

Add a decision layer before `shouldReplace`:

```swift
enum MixedLanguageDecision {
    case autoReplace
    case propose
    case skipAsIntentional
    case learnAsTerm
}
```

### Tokens to skip as intentional

Skip auto-replacement for:

- all-caps Latin acronyms: `QA`, `API`, `REST`, `JSON`, `URL`, `CI`, `CD`;
- short mixed-case product terms: `iOS`, `macOS`, `SwiftUI`, `GitHub`, `OpenAI`;
- camelCase/PascalCase/snake_case/kebab-case tokens;
- tokens with digits or version shapes: `GPT-5`, `OAuth2`, `HTTP/2`, `M1`;
- code-like tokens: `npm`, `git`, `xcodebuild`, `localhost`, paths, env vars;
- words added to allowlist/dictionary;
- words repeatedly undone by the user.

Do not treat these as spelling mistakes by default. They are usually intentional mixed-language islands.

### Smart replacement in mixed text

Use the rolling `PhraseBuffer`, but extend it into a real `TypingContextBuffer`:

```swift
struct TypingContextToken {
    let original: String
    let candidate: String
    let currentLanguageScore: Double
    let candidateLanguageScore: Double
    let tokenKind: TokenKind
    let wasReplaced: Bool
}
```

Rules:

- If one isolated token is ambiguous inside otherwise valid current-language text, show proposal instead of auto-replacing.
- If 2+ consecutive tokens strongly point to the other layout, auto-replace and consider switching layout.
- If 3+ words form a wrong-layout phrase, phrase-fix is allowed.
- If the token is a known acronym/term, skip and keep typing flow.
- If the user undoes the same replacement twice, recommend adding it to the dictionary.

## Layout switching policy

Current AutoFix switches system layout to `targetLayoutID` after replacement. That is useful when the user accidentally left the wrong layout active, but harmful for one-off English terms inside Ukrainian text.

Add:

```swift
enum AutoFixLayoutSwitchPolicy {
    case alwaysSwitchToReplacementLayout
    case keepCurrentLayout
    case adaptive
}
```

Recommended default: `adaptive`.

Adaptive rules:

- phrase fix or 2+ consecutive replacements in same direction: switch to target layout;
- one isolated replacement inside current-language context: keep current layout;
- custom rule: follow rule setting, default keep current layout;
- proposal accept: ask implicitly through action wording:
  - `Замінити`
  - `Замінити і перейти на English`

This makes bilingual writing less hostile.

## Compact proposal behavior

The current proposal UI exists. Extend it:

- place near caret when AX caret/frame is available; use mouse fallback only when not available;
- in unsafe editor policy, proposal should not have a blind `Застосувати` action;
- proposal actions:
  - `Замінити` only when target is verified;
  - `Скопіювати заміну`;
  - `Не чіпати це слово`;
  - `Створити правило`;
  - `Завжди пропонувати, не автозаміняти в цій апці`.

For VS Code MVP, default proposal action should be `Скопіювати заміну` or manual shortcut, not blind mutation.

## Product settings

Replace the raw “Поріг впевненості” first-level UX with mode presets:

- `Обережний` — fewer automatic changes, more proposals.
- `Збалансований` — default.
- `Агресивний` — for users who want more auto-fix.

Advanced settings can remain behind disclosure:

- threshold;
- proposal window;
- app policy overrides;
- layout switch policy;
- mixed-language protection.

Add per-app rows:

| App | Default policy |
|---|---|
| Messages/Notes/native fields | Auto-replace |
| Browsers | Propose unless stable field verified |
| VS Code/Cursor/JetBrains/Xcode | Propose only |
| Terminal/iTerm/Warp | Disabled |

## Implementation plan

### Phase 1 — target safety MVP

Add:

- `AutoFixTargetSession`
- `FocusedElementSignature`
- `AutoFixTargetValidator`
- new skip reasons
- app activation/focus reset hooks

Change:

- `AutoFixController.processEvent` captures/updates target session with each printable key.
- `evaluateAndMaybeFix` validates target before applying/proposing.
- `applyFix`, `applyPhraseFix`, `applyProposal`, `applyCustomRule`, and `undo` validate target before mutation.

Tests:

- target PID changed before boundary -> skip;
- frontmost bundle changed before mutation -> skip;
- focused element signature changed -> skip;
- mouse/app activation resets buffer;
- undo does not mutate if target changed.

### Phase 2 — app policy and VS Code safe default

Add:

- `AutoFixAppPolicy`
- default policy map
- settings UI for per-app policy

Change:

- VS Code/Cursor/JetBrains/Xcode default to `suggestOnly`;
- Terminal-like apps default to `disabled`;
- proposal UI adapts actions to policy.

Tests:

- VS Code bundle returns `suggestOnly`;
- unsafe editor does not call mutation path;
- user override to `autoMutate` is persisted but marked risky.

Manual QA:

- VS Code ordinary editor;
- VS Code with two cursors;
- VS Code command palette/search;
- Cursor;
- Xcode source editor;
- Notes/TextEdit native fields.

### Phase 3 — mixed-language protection

Add:

- `TokenClassifier`
- `MixedLanguagePolicy`
- `TypingContextBuffer`
- `AutoFixLayoutSwitchPolicy`

Change:

- skip obvious acronyms/product terms/code tokens;
- isolated ambiguous tokens show proposal;
- repeated wrong-layout runs can auto-fix phrase and adapt layout switching;
- undo feedback recommends dictionary/rule entries.

Tests:

- `API`, `QA`, `REST`, `JSON`, `iOS`, `macOS`, `SwiftUI` are skipped;
- `црут` on Ukrainian layout still maps to `when`;
- Ukrainian sentence with `API` does not flip layout;
- two consecutive wrong-layout English words can trigger phrase/target layout switch;
- single wrong-layout word inside Ukrainian context keeps current layout under adaptive policy.

### Phase 4 — optional VS Code extension

Only after Phase 1-3.

Build extension if we still need true VS Code auto-apply:

- verify exactly one selection;
- verify the range before cursor equals source;
- replace through editor API;
- reject multi-cursor safely.

This can be a separate install path, not a hard dependency.

## Risks

- AX focused element signatures will be incomplete in some apps. That is fine; incomplete means “do not auto-mutate”.
- Proposal-only in code editors may feel less magical, but it avoids destructive multi-cursor bugs.
- Mixed-language heuristics can become too conservative. Use local observations and “create rule” to let users tune it.
- Real n-gram/CLD3 work is separate. Do not market those algorithms as implemented until they are.

## Definition of done

- Papuga never replaces text after target/focus changes.
- Papuga does not auto-mutate in VS Code multi-cursor scenarios by default.
- VS Code unsupported cases become visible as `suggestOnly`, not silent failure.
- Acronyms and technical terms are skipped or learned without fighting the user.
- Layout switching is adaptive, not always forced.
- New behavior is covered by unit tests and manual QA across native apps, browsers, VS Code, Cursor, Xcode, and terminal apps.
