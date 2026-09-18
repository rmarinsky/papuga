# Papuga runtime, correctness, and resource audit

Date: 2026-08-02
Source snapshot: `redesign/papuga-prediction-engine` at `ebfb6fe7139638ae7aff5beec47373a4b9b998dd`

## Result

The highest-priority issues are not speculative micro-optimizations:

1. Papuga writes user-typed words and replacement text as **public** Unified Log fields.
2. Clipboard history ignores established concealed/transient pasteboard markers and can persist password-manager content as ordinary history.
3. Papuga launches OpenCode without its own tool-deny policy; current default installs/documentation make unintended file, shell, or network actions plausible.
4. A dismissed AutoFix proposal remains mounted with a `repeatForever` animation. Current source and a live DEV process sample strongly correlate this with sustained main-thread rendering and 21–28% CPU.
5. Status updates in the mistake store, and filtered clears in both history stores, rewrite disk from a 5,000-entry in-memory window and can silently delete older persisted history.
6. Manual switching can restore stale clipboard content over a newer user copy; `copyOnly` is functionally broken; overlapping switch tasks race on the global pasteboard.
7. AutoFix event-tap startup reports success before `CGEvent.tapCreate` runs and has stop/start races that can strand or duplicate tap threads.
8. AI provider work survives sheet dismissal, while a provider that ignores `SIGTERM` can leave Papuga polling forever.

The live process had a large reachable footprint, but `leaks` did **not** find a correspondingly large classic unreachable leak. The evidence points instead to retained SwiftUI/AppKit state, caches, clipboard payloads, and active rendering. A before/after Instruments run on an exact build is still required to assign the full footprint to individual owners.

## Confidence model

- **Confirmed (source):** a deterministic path exists in the audited source. This does not mean a user has reported it.
- **Strong correlation:** current source contains a direct mechanism and a live installed build shows the matching runtime symptom, but the installed binary was not proven bit-for-bit to come from this source snapshot.
- **Plausible:** the source permits the failure under a workload or timing condition not reproduced in this audit.
- **Hypothesis:** a platform lifecycle assumption still needs a focused reproduction.

Severity reflects user impact, not implementation size.

## Prioritized findings

| ID | Severity | Confidence | Finding |
| --- | --- | --- | --- |
| P-01 | High | Confirmed | User text is explicitly public in Unified Logs |
| S-01 | High | Confirmed | Clipboard history ignores concealed/transient markers |
| S-02 | High | Plausible | Papuga does not enforce an OpenCode tool-deny policy |
| P-02 | High | Strong correlation | Hidden AutoFix proposal keeps a forever animation alive |
| P-03 | High | Confirmed | History rewrites can silently delete records older than the memory cap |
| P-04 | High | Confirmed | Manual switching corrupts clipboard semantics and permits overlapping operations |
| P-05 | High | Confirmed | AutoFix event-tap startup/teardown has readiness and race defects |
| P-06 | High | Confirmed | AI tasks outlive the sheet; CLI termination can wait forever |
| P-07 | Medium | Confirmed | AI layout corroboration never builds its character maps |
| P-08 | Medium | Confirmed | Prediction candidate work runs on `MainActor`, not in the background |
| P-09 | Medium | Plausible | Clipboard history eagerly retains unbounded per-entry payloads |
| P-10 | Medium | Confirmed | AI bulk apply repeatedly scans, copies, and rewrites the whole store |
| P-11 | Medium | Confirmed | Onboarding retains its view graph and completes twice |
| P-12 | Medium | Confirmed | Clipboard history can merge distinct large values by sampled signature |
| P-13 | Medium | Confirmed | Keyboard hot paths perform avoidable public logging and event work |
| P-14 | Low–Medium | Confirmed | Prediction cache and detached saves have no lifecycle bound |
| P-15 | Medium | Hypothesis | Hiding the menu-bar icon may skip core configuration on relaunch |
| P-16 | Low–Medium | Confirmed | Layout selection failure is reported as success |
| M-01 | Medium | Strong inference | Up to ~129 MiB of heap shape is consistent with eager SymSpell delete indexes |
| O-01 | Medium | Confirmed | Ordinary decisions can rewrite the full aggregate file per word |

## P-01 — Public logs contain user text

**Impact:** privacy exposure to local Unified Log consumers, diagnostic collections, and support bundles. Papuga does not need to exfiltrate data for this to be a privacy defect; the sensitive content is retained outside Papuga's own history controls.

**Evidence:**

- [`AppLogger.swift:15-29`](../papuga/Utilities/AppLogger.swift#L15-L29) accepts an already-built dynamic `String` and interpolates the whole value with `privacy: .public`. Apple redacts dynamic strings by default specifically to avoid leaking user-sensitive data; `.public` disables that protection ([Apple `Logger`](https://developer.apple.com/documentation/os/logger)).
- Raw originals/candidates are sent at [`AutoFixController.swift:361`](../papuga/Core/AutoFixController.swift#L361), [`1402`](../papuga/Core/AutoFixController.swift#L1402), [`1477`](../papuga/Core/AutoFixController.swift#L1477), [`1798`](../papuga/Core/AutoFixController.swift#L1798), and [`2017`](../papuga/Core/AutoFixController.swift#L2017).
- User-approved dictionary words are public at [`IgnoreWordService.swift:52-56`](../papuga/Core/IgnoreWordService.swift#L52-L56).
- Additional raw words/candidates go through public debug messages at [`AutoFixController.swift:768-771`](../papuga/Core/AutoFixController.swift#L768-L771) and [`2303-2311`](../papuga/Core/AutoFixController.swift#L2303-L2311). Debug persistence is configuration-dependent, but there is no reason to mark the content public.

**Minimal correction:** make structured logger helpers accept an `OSLogMessage`, keep user text private by default, and log only lengths, rule IDs, reason codes, and non-sensitive counters at `notice`. Do not hash low-entropy words as an attempted anonymization.

**Regression evidence:** capture Unified Logs while applying, undoing, ignoring, and proposing unique sentinel strings; assert the sentinels are absent from both normal and diagnostic log collections.

## S-01 — Clipboard history ignores confidential/transient markers

**Impact:** passwords, one-time codes, and intentionally short-lived clipboard payloads can be serialized to Papuga's persistent JSONL history and shown as ordinary entries. The file is not protected by an application-level encryption or authentication boundary.

**Evidence:** `captureCurrentStateIfNeeded` proceeds from a change count directly to `ClipboardManager.save()` ([`ClipboardHistoryManager.swift:167-207`](../papuga/Core/ClipboardHistoryManager.swift#L167-L207)). The save loop reads and stores every advertised type ([`ClipboardManager.swift:9-27`](../papuga/Core/ClipboardManager.swift#L9-L27)); there is no check anywhere in source for `org.nspasteboard.ConcealedType`, `org.nspasteboard.TransientType`, `org.nspasteboard.AutoGeneratedType`, or the older `com.agilebits.onepassword` marker. The maintained [NSPasteboard.org convention](https://nspasteboard.org/) says concealed content should be obfuscated/avoided on disk and transient content should not enter clipboard history.

This is confirmed for producers that set those markers. Markers cannot protect secrets copied by producers that omit them, so this fix reduces risk rather than making clipboard history intrinsically safe.

**Minimal correction:** inspect item types **before reading any representation**; skip transient/concealed content by default, with no preview, signature, or disk write. Also consider an explicit application deny-list and communicate that unmarked clipboard content is retained locally.

**Regression evidence:** create pasteboard items containing unique sentinel text plus each marker, wait through several polls and relaunch, and assert the sentinel is absent from memory, JSONL, previews, and logs.

## S-02 — Papuga does not constrain OpenCode agent permissions

**Impact:** if the installed OpenCode version or user configuration permits tools, model-controlled file reads/writes, shell commands, and network access are possible from a prompt whose data originates in user-typed content. A prompt-injection-like token sequence inside a mistake/candidate could make the agent act rather than only classify. The temporary working directory reduces ambient project context, but it is not a tool sandbox.

**Evidence:** Papuga deliberately constrains Codex to read-only and Claude Code to plan/no-tools, but OpenCode receives only `run` ([`AISettings.swift:33-40`](../papuga/Models/AISettings.swift#L33-L40)). The runner creates an empty `0700` temporary directory and sets it as cwd ([`AIAnalysisRunner.swift:116-139`](../papuga/Core/AIAssist/AIAnalysisRunner.swift#L116-L139)), yet it inherits the user's environment and OpenCode configuration. Current OpenCode documentation says all operations are allowed by default and its built-ins include read, edit/write, shell, web, and extension tools ([OpenCode permissions](https://opencode.ai/docs/permissions/), [tools](https://dev.opencode.ai/docs/tools/)). `opencode run` is the non-interactive agent entry point ([OpenCode CLI](https://dev.opencode.ai/docs/cli/)). Source confirms that Papuga supplies no policy; this audit did not inspect the installed OpenCode version, global configuration, or a runtime canary, so effective permissions remain configuration-dependent.

**Minimal correction:** detect/version OpenCode, apply its version-supported Papuga-owned deny-all configuration, and verify it with the side-effect canary below. The documented `OPENCODE_PERMISSION` mechanism is a candidate, not a verified cross-version remedy. If enforcement cannot be guaranteed, disable the provider or warn before sending user data. Add an equally explicit policy audit for Cursor Agent.

**Regression evidence:** send a canary prompt that asks each provider to create a file, read an external sentinel, run a command, and make a network request; the provider must return text but none of the side effects may occur.

## P-02 — A hidden proposal continues animating

**Impact:** persistent CPU/energy use after the proposal disappears, plus retained SwiftUI/AttributeGraph state. This is a CPU leak: the work no longer serves visible UI.

**Source mechanism:**

- The singleton retains one panel and installs an `NSHostingView` at [`AutoFixProposalCoordinator.swift:25-30`](../papuga/Core/AutoFixProposalCoordinator.swift#L25-L30) and [`63-70`](../papuga/Core/AutoFixProposalCoordinator.swift#L63-L70).
- `hide()` only calls `orderOut`; it does not clear or replace `contentView` ([`120-128`](../papuga/Core/AutoFixProposalCoordinator.swift#L120-L128)).
- The mounted view flips `primaryPulse` on appearance ([`328-330`](../papuga/Core/AutoFixProposalCoordinator.swift#L328-L330)) and attaches an autoreversing `repeatForever` animation ([`352-362`](../papuga/Core/AutoFixProposalCoordinator.swift#L352-L362)). Ordering the panel out does not unmount that view.
- Apple documents that [`orderOut`](https://developer.apple.com/documentation/appkit/nswindow/orderout%28_%3A%29) hides a window without releasing it, while [`Animation.repeatForever`](https://developer.apple.com/documentation/swiftui/animation/repeatforever%28autoreverses%3A%29) continues until the view instance ceases to exist or changes identity.

**Runtime correlation:** the installed DEV app showed 21–28% CPU for three consecutive one-second snapshots while `lsappinfo` reported no visible Papuga windows. In a 6.35-second sample, the main thread spent roughly one third of samples in AppKit transaction/layout and SwiftUI ViewGraph rendering, including `RepeatAnimation` and branches with about 617 `NSView` layout and 559 SwiftUI render samples. The AutoFix tap thread slept in `mach_msg` for 6,349 of 6,350 samples, ruling it out as that sample's CPU source. A content-redacted heap walk still found a live `AutoFixProposalView` body. `MistakesView` has another repeating effect, but its window controller clears the hosting view on close; the retained proposal is the stronger offscreen mechanism. See “Live process evidence” for provenance limits.

**Minimal correction:** clear the panel's hosting content on hide (or mount a non-animating empty view), and recreate the proposal view on the next `show`. Also gate the pulse by actual visibility/reduce-motion state; a forever animation must not survive dismissal.

**Regression evidence:** record idle CPU/wakeups for 60 seconds, show then dismiss a proposal, and require return to baseline within two seconds. Repeat 1,000 show/dismiss cycles and assert the old hosting views deallocate and the footprint plateaus. Run the same check with Reduce Motion enabled.

## P-03 — Capped snapshots erase older history

**Impact:** silent, irreversible local data loss during ordinary status changes or filtered clears.

**Evidence:**

- `MistakeObservationStore` keeps only 5,000 entries in memory ([`MistakeObservationStore.swift:13-20`](../papuga/Core/MistakeObservationStore.swift#L13-L20), [`195-201`](../papuga/Core/MistakeObservationStore.swift#L195-L201)).
- `updateStatus` copies that capped array and rewrites the **entire** JSONL file from it ([`100-124`](../papuga/Core/MistakeObservationStore.swift#L100-L124), [`250-264`](../papuga/Core/MistakeObservationStore.swift#L250-L264)). Any still-retained on-disk row older than the newest 5,000 disappears. `clear(where:)` has the same problem ([`135-140`](../papuga/Core/MistakeObservationStore.swift#L135-L140)).
- `ReplacementHistoryStore` loads at most 5,000 rows ([`ReplacementHistoryStore.swift:41-49`](../papuga/Core/ReplacementHistoryStore.swift#L41-L49)) and `clear(where:)` rewrites from that capped memory array ([`81-88`](../papuga/Core/ReplacementHistoryStore.swift#L81-L88)).
- Rewrites also put newest-first rows on disk while future records append newest rows at EOF. Size pruning assumes the end is newest ([`MistakeObservationStore.swift:232-247`](../papuga/Core/MistakeObservationStore.swift#L232-L247); [`ReplacementHistoryStore.swift:213-226`](../papuga/Core/ReplacementHistoryStore.swift#L213-L226)), so a mixed-order file can retain the wrong half.

**Minimal correction:** perform read-modify-write against the complete disk file on the serial I/O queue, preserve one chronological disk order, and publish only the capped UI projection afterward. Batch mutations by observation ID and use an atomic replacement file.

**Regression evidence:** seed more than 5,000 uniquely identified rows, update/clear one visible row, relaunch, and prove all non-target rows remain. Add a file-cap test with known old/new timestamps and concurrent records arriving around a rewrite.

## P-04 — Manual switching can overwrite newer clipboard content

**Impact:** clipboard data loss, broken `copyOnly` behavior, and incorrect pasted/restored content under rapid triggers.

**Evidence:**

- `copyOnly` promises that converted text remains in the clipboard ([`AppSettings.swift:22-42`](../papuga/Models/AppSettings.swift#L22-L42)). The engine writes it, skips paste, then unconditionally restores the prior state ([`TextSwitchEngine.swift:78-110`](../papuga/Core/TextSwitchEngine.swift#L78-L110)). The corrected value therefore exists only transiently.
- In `copyAndPaste`, Papuga sleeps before restore but never checks whether another app or the user copied something newer. The stale saved state overwrites that newer clipboard.
- Every trigger starts another unstructured task with its own saved state and shared global pasteboard ([`TextSwitchEngine.swift:18-42`](../papuga/Core/TextSwitchEngine.swift#L18-L42)). Main-actor serialization does not prevent interleaving at the retry/sleep suspension points. Rapid triggers can read, paste, or restore one another's state, while each task retains a potentially large clipboard snapshot.
- Swift unstructured tasks can start immediately and keep running if their handle is discarded ([Apple `Task`](https://developer.apple.com/documentation/swift/task/)).

**Minimal correction:** allow only one manual switch transaction at a time. In `copyOnly`, leave the converted value in place. In `copyAndPaste`, restore only if the pasteboard change count/signature still identifies Papuga's converted value; otherwise preserve the newer clipboard.

**Regression evidence:** contract tests for both modes, a copy-during-restore-delay test, and a rapid double-trigger test through an injected pasteboard/event seam.

## P-05 — Event-tap startup and teardown race

**Impact:** AutoFix can report active without a tap, become impossible to restart, strand a tap thread after disable, or create two tap threads sharing one state object. Because the callback uses an unretained controller pointer, a stranded tap also weakens the intended lifetime guarantee.

**Evidence:**

- `start()` stores the raw pointer, launches a thread, and immediately returns `true` ([`AutoFixController.swift:2631-2645`](../papuga/Core/AutoFixController.swift#L2631-L2645)).
- `CGEvent.tapCreate` runs later and may return `nil` ([`2648-2658`](../papuga/Core/AutoFixController.swift#L2648-L2658)); Apple explicitly documents that failure result ([Apple `CGEvent.tapCreate`](https://developer.apple.com/documentation/coregraphics/cgevent/tapcreate%28tap%3Aplace%3Aoptions%3Aeventsofinterest%3Acallback%3Auserinfo%3A%29?language=objc)). The failure path never clears `thread`, so later starts return the stale `running` state.
- If `stop()` runs before the worker publishes its run loop, it has nothing to stop, then clears the pointer/callback and sets `thread = nil` ([`2689-2702`](../papuga/Core/AutoFixController.swift#L2689-L2702)). A worker that already captured those values can subsequently install an orphan tap; a new `start()` may launch a second one.
- The callback dereferences the unretained controller at [`2590-2604`](../papuga/Core/AutoFixController.swift#L2590-L2604).

**Minimal correction:** add a synchronous startup handshake that returns only after tap creation succeeds/fails. Guard all lifecycle state with one state machine/generation, make stop wait for startup and thread exit, and clear state on every worker exit path.

**Regression evidence:** inject a tap factory and deterministically test create failure, immediate start→stop, start→stop→start, and controller teardown. Assert exactly one worker/tap and no callback after stop returns.

## P-06 — AI work survives dismissal; termination can wait forever

**Impact:** hidden Ollama/CLI work, orphan child processes, repeated 10 ms wakeups, and a task that never completes if a provider ignores `SIGTERM`.

**Evidence:**

- Provider tasks are stored at [`AIAssistSheet.swift:36-41`](../papuga/Views/History/AIAssist/AIAssistSheet.swift#L36-L41). The header X and initial Cancel buttons only dismiss ([`97-99`](../papuga/Views/History/AIAssist/AIAssistSheet.swift#L97-L99), [`338-349`](../papuga/Views/History/AIAssist/AIAssistSheet.swift#L338-L349)); the view has no `onDisappear` cancellation.
- Tasks are canceled only by Back, a rerun, or an explicit per-provider action ([`AIAssistSheet.swift:350-353`](../papuga/Views/History/AIAssist/AIAssistSheet.swift#L350-L353), [`451-469`](../papuga/Views/History/AIAssist/AIAssistSheet.swift#L451-L469), [`527-531`](../papuga/Views/History/AIAssist/AIAssistSheet.swift#L527-L531)). Discarding an unstructured task handle does not stop its work ([Apple `Task`](https://developer.apple.com/documentation/swift/task/)).
- The CLI runner polls `process.isRunning` every 10 ms. On timeout/output overflow it calls `terminate()` and continues the same poll without a second deadline ([`AIAnalysisRunner.swift:162-179`](../papuga/Core/AIAssist/AIAnalysisRunner.swift#L162-L179)). Apple documents that `terminate()` sends `SIGTERM`, which a process may ignore ([Apple `Process.terminate`](https://developer.apple.com/documentation/foundation/process/terminate%28%29)).
- On Swift-task cancellation, the `defer` sends `SIGTERM` but does not wait for exit ([`AIAnalysisRunner.swift:148-176`](../papuga/Core/AIAssist/AIAnalysisRunner.swift#L148-L176)).
- A canceled old provider task can later write `.cancelled` into the same provider state after a replacement run has started ([`AIAssistSheet.swift:468-495`](../papuga/Views/History/AIAssist/AIAssistSheet.swift#L468-L495)).
- Bulk apply launches another untracked task ([`AIAssistSheet.swift:602-633`](../papuga/Views/History/AIAssist/AIAssistSheet.swift#L602-L633)). `applyAsync` never checks cancellation between mutations ([`AISuggestionApplier.swift:35-53`](../papuga/Core/AIAssist/AISuggestionApplier.swift#L35-L53)), so dismissing during apply can continue changing rules, dictionary, and observation status after the UI is gone.

**Minimal correction:** track and cancel both provider and apply tasks in `onDisappear`; check cancellation before every apply mutation; assign a run generation and ignore stale progress/completions. Replace 10 ms polling with `terminationHandler`/a continuation raced against a timeout. After a bounded grace period, kill the child/process group and reap it.

**Regression evidence:** use a fixture executable that traps/ignores `SIGTERM`, close the sheet, and assert the task returns and no process remains. Dismiss mid-apply and assert no subsequent mutation. Start a second generation before the first completes and assert stale state cannot overwrite it.

## P-07 — Layout corroboration is a no-op

**Impact:** a valid layout-only AI correction is unnecessarily marked “needs review”; the code comment's deterministic safety promise is not met. Independent engine or recorded candidates can mask the defect.

**Evidence:** `corroborator()` creates a new `CharacterMapper` and immediately calls `convert` for each source-ID pair ([`AIAssistSheet.swift:636-669`](../papuga/Views/History/AIAssist/AIAssistSheet.swift#L636-L669)). It never calls `buildMap`. `CharacterMapper.convert` returns the original text when either map is missing ([`CharacterMapper.swift:62-68`](../papuga/Core/CharacterMapper.swift#L62-L68)).

**Minimal correction:** inject a configured mapper/layout manager or resolve and build each listed input source before creating the corroborator. Do not rebuild maps per validation.

**Regression evidence:** validate a known US→Ukrainian layout pair that has no engine/recorded candidate and assert it is independently corroborated.

## P-08 — “Background” prediction work is on the main actor

**Impact:** UI stalls and delayed event handling scale with the number of new mistake groups and synchronous spell-check fallbacks.

**Evidence:**

- The engine is `@MainActor` ([`PredictionEngine.swift:13-15`](../papuga/Core/Prediction/PredictionEngine.swift#L13-L15)). Group derivation runs synchronously there ([`157-182`](../papuga/Core/Prediction/PredictionEngine.swift#L157-L182)).
- Candidate generation explicitly runs in `Task { @MainActor ... }`, forty groups per chunk by default ([`190-221`](../papuga/Core/Prediction/PredictionEngine.swift#L190-L221)). `Task.yield()` allows other work to be scheduled; it does not move computation off the actor and may resume the same task immediately ([Apple `Task.yield`](https://developer.apple.com/documentation/swift/task/yield%28%29?changes=_5__2)).
- The analyzer itself documents synchronous `NSSpellChecker` IPC as its dominant fallback cost ([`MistakeObservationEngine.swift:171-182`](../papuga/Core/MistakeObservationEngine.swift#L171-L182)).
- Apple's energy guidance recommends keeping processor-intensive and potentially unbounded work off the main thread ([Energy Efficiency Best Practices](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/BestPractices.html)).

**Minimal correction:** snapshot sendable inputs, generate candidates on a non-main worker, and publish only bounded result batches on `MainActor`. Reuse the engine's existing detached clustering pattern rather than inventing another scheduler.

**Regression evidence:** signpost an analysis of 5,000 representative groups, assert a bounded maximum main-thread slice, and keep typing/window interaction responsive during the run.

## P-09 — Clipboard payloads have no memory budget

**Impact:** large images, PDFs, file contents, RTF, or multi-representation items can cause large transient and retained memory growth and main-thread stalls. This is a memory-pressure risk, not a proven unreachable leak.

**Evidence:**

- `ClipboardManager.save()` asks every pasteboard item for every advertised representation and retains every returned `Data` ([`ClipboardManager.swift:9-27`](../papuga/Core/ClipboardManager.swift#L9-L27)). AppKit supports data providers/lazy fulfillment, so reading each advertised type can force work/data that the UI did not otherwise need ([Apple `NSPasteboardItem`](https://developer.apple.com/documentation/appkit/nspasteboarditem?changes=l_5&language=objc)).
- Each history entry owns the complete state ([`SavedPasteboardState.swift:3-10`](../papuga/Models/SavedPasteboardState.swift#L3-L10); [`ClipboardHistoryEntry.swift:3-10`](../papuga/Models/ClipboardHistoryEntry.swift#L3-L10)). The only immediate in-memory limit is 1,000 **entries**, not bytes ([`ClipboardHistoryManager.swift:19-23`](../papuga/Core/ClipboardHistoryManager.swift#L19-L23), [`38-45`](../papuga/Core/ClipboardHistoryManager.swift#L38-L45)).
- The 150 MB disk guard runs during periodic cleanup after capture ([`ClipboardHistoryManager.swift:228-246`](../papuga/Core/ClipboardHistoryManager.swift#L228-L246)); it does not bound one entry's allocation or the live state before cleanup.
- RTF/HTML preview decoding is also performed synchronously on the main thread ([`ClipboardHistoryManager.swift:461-491`](../papuga/Core/ClipboardHistoryManager.swift#L461-L491)).

**Minimal correction:** define per-representation, per-entry, and aggregate byte budgets. Prefer only representations needed for restore/preview, record metadata for skipped oversized payloads, and move expensive preview parsing off-main where AppKit permits. Make the product trade-off explicit for oversized clipboard restore.

**Regression evidence:** copy synthetic 100 MB image/file-content items and multi-representation items; measure peak RSS, capture latency, and steady-state footprint under retention churn.

## P-10 — AI bulk apply is N full-store mutations

**Impact:** large AI batches amplify main-thread CPU and disk I/O, and they repeatedly exercise P-03's lossy rewrite path.

**Evidence:** for every suggestion, each observation ID performs a linear `entries.first` lookup ([`AISuggestionApplier.swift:58-70`](../papuga/Core/AIAssist/AISuggestionApplier.swift#L58-L70)); then each item calls `updateStatus` ([`78-109`](../papuga/Core/AIAssist/AISuggestionApplier.swift#L78-L109)), which copies the store and queues a full JSONL rewrite. `applyAsync` only yields **after** each synchronous item ([`35-53`](../papuga/Core/AIAssist/AISuggestionApplier.swift#L35-L53)). Defaults-backed arrays are also scanned/copied per rule.

**Minimal correction:** precompute the open-ID set once, accumulate rule/dictionary/status changes, apply one store mutation and one disk rewrite, then trigger one prediction refresh. Keep progress based on processed suggestions rather than persistence calls.

**Regression evidence:** apply 1,000 suggestions to 5,000 observations and assert one persistence transaction, bounded main-thread slices, and result equivalence with single-item apply.

## P-11 — Onboarding retains its graph and completes twice

**Impact:** a singleton-held one-time view graph remains reachable for the app lifetime; programmatic completion executes permission refresh/start logic twice.

**Evidence:** the view's `onComplete` calls `closeOnboarding()` and then `completion()` ([`OnboardingWindowController.swift:20-26`](../papuga/Core/OnboardingWindowController.swift#L20-L26)). Closing the window invokes its delegate, which also calls `completion()` ([`50-55`](../papuga/Core/OnboardingWindowController.swift#L50-L55), [`70-79`](../papuga/Core/OnboardingWindowController.swift#L70-L79); Apple [`windowWillClose`](https://developer.apple.com/documentation/appkit/nswindowdelegate/windowwillclose%28_%3A%29?changes=_2)). `closeOnboarding()` clears the window/delegate but not `hostingView` ([`63-67`](../papuga/Core/OnboardingWindowController.swift#L63-L67)). The analogous history controller does clear its hosting view ([`HistoryWindowController.swift:109-113`](../papuga/Core/HistoryWindowController.swift#L109-L113)).

**Minimal correction:** give completion exactly one owner (the close delegate is sufficient), make it idempotent, capture the controller weakly where appropriate, and clear `hostingView` on close.

**Regression evidence:** programmatically finish and manually close onboarding; assert exact-once completion and deallocation of a weak sentinel in the hosted graph.

## P-12 — Sampled clipboard signatures merge distinct data

**Impact:** clipboard history can silently drop or promote the wrong large item even without a random hash collision.

**Evidence:** the signature hashes type, byte count, the first 128 bytes, and the last 64 bytes only ([`ClipboardHistorySignature.swift:24-44`](../papuga/Core/ClipboardHistorySignature.swift#L24-L44)). Two same-sized representations with identical edges but different middle bytes have exactly the same signature. The manager treats any matching signature as the same item and removes the older entry ([`ClipboardHistoryManager.swift:190-215`](../papuga/Core/ClipboardHistoryManager.swift#L190-L215)).

**Minimal correction:** compare the complete saved state on a sampled-signature hit, or use a full streaming cryptographic digest. Do not fix correctness by merely adding more sampled bytes.

**Regression evidence:** construct two payloads with equal sizes/edges and different middle bytes and assert both remain distinct.

## P-13 — Event hot paths do unnecessary logging and work

**Impact:** avoidable CPU, Unified Log traffic, disk pressure, and energy wakeups while the user types or while Papuga is idle.

**Evidence:**

- `HotkeyListener` subscribes to every `keyDown` and `flagsChanged` ([`HotkeyListener.swift:21-38`](../papuga/Core/HotkeyListener.swift#L21-L38)). It emits a `notice` on every key down and several messages per modifier transition ([`71-129`](../papuga/Core/HotkeyListener.swift#L71-L129)); `AppLogger.action` maps to public `logger.notice` ([`AppLogger.swift:19-21`](../papuga/Utilities/AppLogger.swift#L19-L21)).
- AutoFix subscribes to `flagsChanged` ([`AutoFixController.swift:45-49`](../papuga/Core/AutoFixController.swift#L45-L49)), extracts Unicode text/PID and dispatches every such event to main ([`175-200`](../papuga/Core/AutoFixController.swift#L175-L200)), but `processEvent` ignores it ([`245-270`](../papuga/Core/AutoFixController.swift#L245-L270)).
- Clipboard history runs a main-run-loop timer every 0.35 seconds without tolerance ([`ClipboardHistoryManager.swift:38-41`](../papuga/Core/ClipboardHistoryManager.swift#L38-L41), [`91-106`](../papuga/Core/ClipboardHistoryManager.swift#L91-L106)). Apple recommends event-driven work where possible and at least 10% tolerance for repeating timers ([Minimize Timer Usage](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/Timers.html)).

The live sample did **not** implicate the AutoFix tap thread; it was asleep for 6,349/6,350 samples. These are source-proven optimization targets, not the explanation for P-02's sampled CPU episode.

**Minimal correction:** remove per-event notice/debug logs from release hot paths; remove AutoFix `flagsChanged` from its mask; only decode Unicode/PID for event types that use them. Give the clipboard timer tolerance and measure whether a 0.75–1.0 second interval preserves product feel. Keep the double-press listener's necessary events but make the no-match path allocation/log free.

**Regression evidence:** compare idle wakeups and typing CPU with Instruments Energy Log/System Trace before and after; verify shortcut latency and clipboard capture latency at the 95th percentile.

## P-14 — Prediction cache never shrinks

**Impact:** long-session/disk growth under mistake churn and redundant detached writes. This is bounded by user activity, but not by current code.

**Evidence:** the cache is loaded wholesale and saved wholesale ([`PredictionEngine.swift:473-489`](../papuga/Core/Prediction/PredictionEngine.swift#L473-L489)). Analysis computes current groups but removes cache entries only on explicit force refresh ([`157-180`](../papuga/Core/Prediction/PredictionEngine.swift#L157-L180)). Deleted, expired, dismissed, or regrouped keys therefore remain. Every save launches an untracked detached writer, so two snapshots can complete out of order.

**Minimal correction:** intersect cache keys with current group IDs (plus an explicitly justified warm set), cap the cache, and coalesce/serialize saves. Because the data is recomputable, prefer simple replacement over a complex journal.

**Regression evidence:** churn many generations of unique groups and assert memory/file size plateau; force overlapping saves and assert the newest generation wins.

## P-15 — Hidden menu-bar relaunch may skip configuration

**Impact:** with a persisted hidden menu-bar icon, layout/clipboard/AutoFix managers may remain nil even though global shortcuts are registered; Open Papuga can present an initialization error.

**Evidence:** `PapugaApp` creates managers as scene state, but the only calls to `appDelegate.configure` are `onAppear` handlers inside a conditionally inserted `MenuBarExtra` ([`papugaApp.swift:5-31`](../papuga/papugaApp.swift#L5-L31)). `showMenuBarIcon` persists and can be false ([`AppSettings.swift:113`](../papuga/Models/AppSettings.swift#L113)). AppDelegate explicitly depends on later scene configuration ([`AppDelegate.swift:121-126`](../papuga/AppDelegate.swift#L121-L126)).

This is a **hypothesis** because whether either `onAppear` fires for an initially non-inserted `MenuBarExtra` is SwiftUI lifecycle behavior that was not reproduced on an exact build during this audit.

**Minimal correction:** configure core services from an unconditional lifecycle seam; menu-bar visibility should affect only presentation.

**Regression evidence:** set the preference false, terminate, relaunch, invoke Open Papuga and both replacement shortcuts, and assert managers/services are configured once.

## P-16 — Input-source failure is treated as success

**Impact:** Papuga can update its own `currentLayoutID` and report completion even when macOS rejected the input-source selection. Later conversion/paste behavior then proceeds against stale assumptions.

**Evidence:** [`LayoutManager.switchTo`](../papuga/Core/LayoutManager.swift#L164-L173) ignores the `OSStatus` returned by `TISSelectInputSource`, unconditionally assigns `currentLayoutID`, and logs completion.

**Minimal correction:** check `noErr`, update local state only on success (or wait for the system notification), and propagate a failure result to manual-switch/AutoFix callers so they can avoid claiming success.

**Regression evidence:** inject a selector that returns an error and assert no state/history/success feedback changes.

## M-01 — Eager SymSpell indexes are consistent with up to ~129 MiB

**Impact:** potentially high steady memory even when correction features are idle or disabled. This is a strongly inferred optimization target, not evidence of an unreachable leak.

**Evidence:** a content-redacted live `heap` summary reported 75,397,440 bytes in 978,520 `Swift._ContiguousArrayStorage<String>` objects and 60,293,120 bytes in exactly two `Swift._DictionaryStorage<String, Array<String>>` objects—129.4 MiB combined. The only production property with the exact `[String: [String]]` shape is the pair of 50,000-row Ukrainian/English `SymSpell.deletes` indexes, where generated deletes store original strings ([`SymSpell.swift:21-25`](../papuga/Core/Prediction/SymSpell.swift#L21-L25), [`39-50`](../papuga/Core/Prediction/SymSpell.swift#L39-L50)). `HybridSpellChecker.production` eagerly builds both bundled indexes once the singleton is touched ([`HybridSpellChecker.swift:10-25`](../papuga/Core/Prediction/HybridSpellChecker.swift#L10-L25)); normal `AppDelegate.configure` constructs `AutoFixController` and touches the default dependency even if AutoFix is disabled ([`AutoFixController.swift:81-92`](../papuga/Core/AutoFixController.swift#L81-L92)). However, the generic heap types were not linked to SymSpell by allocation stacks or a before/after build, so 129.4 MiB is an upper-bound attribution rather than proven exact ownership. P-15 is the caveat against claiming that configure runs on literally every launch.

**Minimal correction:** first defer index construction until a feature actually requests mapped spelling and measure an exact before/after build. Only if that confirms material SymSpell ownership, replace repeated `String` references with compact integer word IDs in contiguous posting lists. Preserve the system checker fallback while a lazy build completes.

**Regression evidence:** compare cold/idle footprint and heap allocation stacks from the same exact build before and after lazy loading, with AutoFix disabled and after the first enabled query. If compacted, benchmark lookup quality/latency and require a material measured reduction without changing suggestions.

## O-01 — Decision aggregates rewrite on every ordinary word

**Impact:** continuous read/sort/encode/atomic-write churn while typing. At 40 completed words/minute, this design permits roughly 2,400 full aggregate-file rewrites per hour.

**Evidence:** non-reviewable decisions route to `recordAggregate` ([`AutoFixDecisionHistoryStore.swift:112-119`](../papuga/Core/AutoFixDecisionHistoryStore.swift#L112-L119)). Each one searches/sorts/bounds aggregates on main ([`209-234`](../papuga/Core/AutoFixDecisionHistoryStore.swift#L209-L234)), then the serial queue reloads the entire JSON aggregate file, merges, sorts/bounds, encodes, and atomically rewrites it ([`333-386`](../papuga/Core/AutoFixDecisionHistoryStore.swift#L333-L386)). Ordinary AutoFix paths mark valid/non-reviewable words aggregate-only before the decision is finished ([`AutoFixController.swift:711-749`](../papuga/Core/AutoFixController.swift#L711-L749), [`1129-1135`](../papuga/Core/AutoFixController.swift#L1129-L1135)).

**Minimal correction:** merge into memory in O(1), debounce/coalesce persistence, and flush a bounded snapshot on a timer, app deactivation, and termination. A small SQLite table with an upsert is justified only if the simple coalesced snapshot still exceeds measured write/latency budgets.

**Regression evidence:** type/replay 2,400 ordinary words, count file writes and main-thread time, and prove aggregate counts survive termination after the lifecycle flush.

## Secondary correctness, retention, and accessibility findings

These are real source findings but rank below the lifecycle/data-loss/privacy issues above.

| Finding | Confidence and evidence | Minimal correction |
| --- | --- | --- |
| The AutoFix “Backspace undo window” slider has no runtime effect | Confirmed. The key/UI exist ([`AppSettings.swift:150`](../papuga/Models/AppSettings.swift#L150), [`AutoFixTab.swift:27-34`](../papuga/Views/Settings/AutoFixTab.swift#L27-L34)), but there is no production read. Backspace explicitly clears `lastFix` ([`AutoFixController.swift:322-328`](../papuga/Core/AutoFixController.swift#L322-L328)); the toast uses a fixed 2.5 s default ([`FixToastCoordinator.swift:16-38`](../papuga/Core/FixToastCoordinator.swift#L16-L38)). | Either wire the setting to one clearly described undo mechanism, or remove the setting and correct the copy. |
| Low-volume analytics never satisfy 30-day retention | Confirmed. `PapugaEventLog` returns early for files at or below 1 MB before decoding timestamps ([`PapugaEventLog.swift:68-84`](../papuga/Analytics/PapugaEventLog.swift#L68-L84)). Pruning is called at launch, so a small file can retain rows indefinitely. | Check retention on a low-frequency schedule regardless of size; use size only for byte-cap trimming. |
| Long-running stores can exceed advertised file caps until another lifecycle event | Confirmed. `PapugaEventLog` prunes only when called; replacement/mistake stores append without threshold pruning ([`ReplacementHistoryStore.swift:53-69`](../papuga/Core/ReplacementHistoryStore.swift#L53-L69), [`MistakeObservationStore.swift:75-90`](../papuga/Core/MistakeObservationStore.swift#L75-L90)). | Debounce a cheap threshold check after appends and prune on size/retention cadence, not only launch/settings. |
| Replacement/mistake bootstrap can overwrite records captured during load | Confirmed race. Both asynchronously load then replace their main-memory arrays while `record` may insert concurrently ([`ReplacementHistoryStore.swift:41-69`](../papuga/Core/ReplacementHistoryStore.swift#L41-L69), [`MistakeObservationStore.swift:63-90`](../papuga/Core/MistakeObservationStore.swift#L63-L90)). Replacement pruning also publishes the uncapped retained set ([`ReplacementHistoryStore.swift:228-236`](../papuga/Core/ReplacementHistoryStore.swift#L228-L236)). | Merge disk snapshot with post-bootstrap mutations by ID/revision and enforce the memory cap on every publish. |
| A correction can bridge two applications | Confirmed. App activation calls `resetEditingState` ([`AutoFixController.swift:148-170`](../papuga/Core/AutoFixController.swift#L148-L170)), but that clears only `activeCorrection`, not `lastCompleted` ([`MistakeObservationEngine.swift:605-664`](../papuga/Core/MistakeObservationEngine.swift#L605-L664)). A backspace in app B within 12 seconds can use app A's word as the source. | Clear `lastCompleted` on app/session/target changes and require source/target bundle IDs to match. |
| Manual copy retry gives up when the flavor lags the change count | Confirmed. On the first changed count, `getTextWithRetry` immediately returns `getText()`, even when it is temporarily nil; remaining retries are skipped ([`TextSwitchEngine.swift:121-135`](../papuga/Core/TextSwitchEngine.swift#L121-L135)). | Continue retrying changed-but-unreadable states until the existing deadline. |
| Provider readiness/auth and Ollama model discovery repeat per batch | Confirmed. Every batch calls `run`, which repeats discovery/probe before generation ([`AIAssistSheet.swift:459-524`](../papuga/Views/History/AIAssist/AIAssistSheet.swift#L459-L524); [`AIProviderDiscovery.swift:13-35`](../papuga/Core/AIAssist/AIProviderDiscovery.swift#L13-L35)). | Resolve provider/model once per run generation and reuse the executable/model for all batches. |
| A 1–1 AI provider disagreement has a nondeterministic winner | Confirmed. `Dictionary.max` compares only group counts, then confidence only inside the chosen group ([`AIAssistSheet.swift:539-560`](../papuga/Views/History/AIAssist/AIAssistSheet.swift#L539-L560)). Dictionary iteration is not a product tie-break contract. | On a tie, require review and use a stable provider/target order; do not call either target a consensus winner. |
| Safe AI suggestions require manual selection despite the review view's pre-selected UX comment | Observed implementation/comment mismatch, not a confirmed product requirement. Both result paths assign `selected = []` ([`AIAssistSheet.swift:571-579`](../papuga/Views/History/AIAssist/AIAssistSheet.swift#L571-L579), [`589-599`](../papuga/Views/History/AIAssist/AIAssistSheet.swift#L589-L599)), while the review view describes safe suggestions as pre-selected ([`AISuggestionReviewView.swift:3-5`](../papuga/Views/History/AIAssist/AISuggestionReviewView.swift#L3-L5)). | Decide the intended behavior: either preselect only `needsReview == false`, or update the comment, copy, and tests to make all rows opt-in. |
| Ollama's 2 MB cap does not cap buffering | Confirmed. `URLSession.data(for:)` fully buffers the response before `data.count` is checked ([`AIAnalysisRunner.swift:67-90`](../papuga/Core/AIAssist/AIAnalysisRunner.swift#L67-L90)). | Stream bytes with an incremental limit and a request timeout/cancellation handler. |
| Dictionary actions and AI disclosures are not keyboard/VoiceOver controls | Confirmed. Dictionary edit/delete buttons exist only while pointer hover is true ([`DictionaryTab.swift:143-184`](../papuga/Views/Settings/DictionaryTab.swift#L143-L184), [`215-255`](../papuga/Views/Settings/DictionaryTab.swift#L215-L255)); AI disclosures use tap gestures on non-control rows ([`AISuggestionReviewView.swift:97-126`](../papuga/Views/History/AIAssist/AISuggestionReviewView.swift#L97-L126)). | Keep actions present for focus/assistive technology and use `Button`/`DisclosureGroup` with labels, traits, and keyboard focus. |

## Live process evidence

This runtime evidence is useful but is **not exact-HEAD proof**:

- Process: `/Applications/papuga-dev.app/Contents/MacOS/papuga`
- Bundle/version: `ua.com.rmarinsky.papuga.dev`, `1.3.0 (1)`, ARM64
- Executable SHA-256: `068da0184bc90d65dbb3ec3cb68a266749ce3469dcab96460067a2700f48e7a8`
- Executable mtime: 2026-07-29 17:10:47 +0300; process launched 2026-07-29 17:10:48 +0300
- Current audited commit time: 2026-07-29 17:09:39 +0300. The proximity makes a relationship plausible, but the binary has no source revision metadata proving it.
- Sample time/platform: 2026-08-02 16:52:17 +0300 on macOS 26.5.2 (25F84)

Observed:

- `lsappinfo` reported `windows=[NULL]`: no visible Papuga windows during the CPU/heap observation.
- Five one-second `top` snapshots: `0.0%`, `27.3%`, `28.1%`, `21.0%`, `0.0%` CPU; footprint about 748 MB.
- `top` also reported 17:25:11 cumulative CPU time over about 95.8 hours since launch: approximately 18.2% of one core averaged across the process lifetime. That is aggregate evidence of sustained background work, not attribution to one source path.
- `/usr/bin/sample`, 6,350 × 1 ms: about 4,228 main-thread samples asleep in `mach_msg`; roughly one third showed AppKit/SwiftUI transaction, layout, and render work. AutoFix tap thread slept 6,349/6,350 samples.
- `vmmap -summary`: 747.8 MB physical footprint, 795.6 MB peak; 5,197,725 live malloc-zone allocations / 519.1 MB. The largest reported groups were the default zone (3,451,326 allocations / 435.7 MB) and AttributeGraph plus graph data (about 1.67 million allocations / 77.2 MB).
- A content-redacted `heap` summary several minutes later reported 5,197,736 live nodes / 519.1 MB—only 11 more nodes. Its strongest specific type-shape inference was the up-to-129.4 MiB SymSpell shape documented in M-01; it also retained an `AutoFixProposalView` body while no window was visible.
- Content-redacted `leaks -quiet -noContent -nostacks -groupByType`: 476 unreachable allocations / 23,760 bytes, mostly NSXPCConnection cycles.

Interpretation: the 748 MB footprint is overwhelmingly reachable retained/cache/render state, not a 748 MB classic unreachable leak. Allocation count was effectively stable in this short window, so there is no evidence here of an actively growing memory leak. P-02 is a strong CPU-root-cause candidate and a plausible retained-state contributor. M-01 is consistent with a measured part of steady memory; P-09 and P-14 are source-visible growth risks. Allocation stacks and longer before/after snapshots are still required to apportion the remainder.

## Verification performed

1. Static analysis:

   ```sh
   xcodebuild analyze \
     -project papuga.xcodeproj \
     -scheme papuga \
     -configuration Debug \
     -disableAutomaticPackageResolution \
     -onlyUsePackageVersionsFromResolvedFile \
     CODE_SIGNING_ALLOWED=NO
   ```

   Result: `** ANALYZE SUCCEEDED **`; no source analyzer diagnostics. The broader test build emitted a concurrency warning for an `AISuggestionApplier` default `.shared` argument crossing MainActor isolation; the compiler states this becomes an error in Swift 6 mode.

2. Full test suite:

   ```sh
   xcodebuild test \
     -project papuga.xcodeproj \
     -scheme papuga \
     -destination platform=macOS \
     -disableAutomaticPackageResolution \
     -onlyUsePackageVersionsFromResolvedFile \
     CODE_SIGNING_ALLOWED=NO
   ```

   Result: `** TEST SUCCEEDED **`; 338 tests executed, 332 passed, 6 skipped, 0 failed.

The suite does not currently exercise the system/lifecycle paths behind P-02 through P-07, the >5,000-row persistence contract, or clipboard memory budgets. Passing tests therefore do not contradict these findings.

## Recommended execution order

1. Remove public user text from logs, skip concealed/transient clipboard content, and deny AI-provider tools; verify all three with sentinels/canaries.
2. Unmount/gate the hidden proposal animation; rerun the exact idle CPU/footprint scenario.
3. Fix full-file history mutations before adding more bulk actions; protect with >5,000-row tests.
4. Make manual switch a single clipboard transaction with ownership-aware restore and correct `copyOnly` semantics.
5. Make event-tap and provider-process lifecycles explicit, joinable, and testable.
6. Fix the no-op layout corroborator and move prediction work off `MainActor`.
7. Lazy-load/compact SymSpell, coalesce aggregate writes, batch AI apply, and add byte/cache budgets; measure each change independently.

## What was not proven

- No exact-HEAD Instruments Allocations/Leaks/Energy run was performed.
- The installed DEV binary's source revision is unknown despite timestamps close to the audited commit.
- The 748 MB footprint was not attributed to individual allocations because the privacy-safe `leaks` run omitted content/stacks.
- The generic heap type totals were not directly attributed to SymSpell by allocation stacks or a before/after build.
- The short live window showed a stable allocation count; it cannot establish long-term growth or prove a future plateau.
- P-15 still needs a real relaunch with `showMenuBarIcon = false`.
- No evidence supports calling the AutoFix tap thread a CPU leak in the sampled process; it was effectively idle.

## Primary platform sources

- Apple, [`Logger`](https://developer.apple.com/documentation/os/logger) and [Generating Log Messages](https://developer.apple.com/documentation/os/generating-log-messages-from-your-code)
- Apple, Swift [`Task`](https://developer.apple.com/documentation/swift/task/), [`cancel()`](https://developer.apple.com/documentation/swift/task/cancel%28%29), and [`yield()`](https://developer.apple.com/documentation/swift/task/yield%28%29?changes=_5__2)
- Apple, [`CGEvent.tapCreate`](https://developer.apple.com/documentation/coregraphics/cgevent/tapcreate%28tap%3Aplace%3Aoptions%3Aeventsofinterest%3Acallback%3Auserinfo%3A%29?language=objc)
- Apple, [`Process.terminate`](https://developer.apple.com/documentation/foundation/process/terminate%28%29) and [`terminationHandler`](https://developer.apple.com/documentation/foundation/process/terminationhandler)
- Apple, [`NSPasteboardItem`](https://developer.apple.com/documentation/appkit/nspasteboarditem?changes=l_5&language=objc) and [`data(forType:)`](https://developer.apple.com/documentation/appkit/nspasteboarditem/data%28fortype%3A%29?language=objc)
- Apple, [Energy Efficiency Best Practices](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/BestPractices.html) and [Minimize Timer Usage](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/Timers.html)
- Apple, [`NSWindowDelegate.windowWillClose`](https://developer.apple.com/documentation/appkit/nswindowdelegate/windowwillclose%28_%3A%29?changes=_2)
- Apple, [`NSWindow.orderOut`](https://developer.apple.com/documentation/appkit/nswindow/orderout%28_%3A%29) and [`Animation.repeatForever`](https://developer.apple.com/documentation/swiftui/animation/repeatforever%28autoreverses%3A%29)
- OpenCode, [permissions](https://opencode.ai/docs/permissions/), [tools](https://dev.opencode.ai/docs/tools/), and [CLI `run`](https://dev.opencode.ai/docs/cli/)
- NSPasteboard.org, [transient and concealed clipboard conventions](https://nspasteboard.org/)
