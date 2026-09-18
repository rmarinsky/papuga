#!/usr/bin/env bash
# Real physical typing -> proposal window -> Enter -> exact TextEdit contents.
# Run on an unlocked Mac; do not type or change focus during this check.
# Uses current DEV settings. Never rewrites preferences, clipboard, or user documents.
set -euo pipefail

scenario=${1:-word}
case "$scenario" in word|phrase|english) ;; *) echo 'Usage: bash scripts/papuga-autofix-proposal-system-test.sh [word|phrase|english]' >&2; exit 2 ;; esac
domain=ua.com.rmarinsky.papuga.dev
[[ $(defaults read "$domain" autoFixEnabled) == 1 ]] || { echo 'Enable auto-fix in DEV first' >&2; exit 1; }
[[ $(defaults read "$domain" autoFixProposalEnabled) == 1 ]] || { echo 'Enable proposals in DEV first' >&2; exit 1; }
defaults read "$domain" autoFixAppPolicyOverrides | grep -Eq '"com.apple.TextEdit" = suggestOnly;' || {
  echo 'Set TextEdit policy to suggestOnly in DEV first' >&2; exit 1;
}
pgrep -f '^/Applications/papuga-dev.app/Contents/MacOS/papuga$' >/dev/null || {
  echo 'Start /Applications/papuga-dev.app first' >&2; exit 1;
}

[[ $(pgrep -x papuga | wc -l | tr -d ' ') == 1 ]] || {
  echo 'Close other Papuga instances before this UI check' >&2; exit 1;
}

layout() {

  swift - "$@" <<'SWIFT'
import Carbon
let current = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
if CommandLine.arguments.count == 1 {
    print(Unmanaged<CFString>.fromOpaque(TISGetInputSourceProperty(current, kTISPropertyInputSourceID)!).takeUnretainedValue())
} else {
    let query = [kTISPropertyInputSourceID!: CommandLine.arguments[1]] as CFDictionary
    let sources = TISCreateInputSourceList(query, false).takeRetainedValue() as! [TISInputSource]
    guard let source = sources.first, TISSelectInputSource(source) == noErr else { exit(1) }
}
SWIFT
}

original_layout=$(layout)
probe_file=$(mktemp /private/tmp/papuga-proposal-check.XXXXXX)
cleanup() {
  local result=$?
  trap - EXIT
  osascript - "$probe_file" <<'APPLESCRIPT' || result=1
on run argv
  tell application "TextEdit"
    set testDocuments to every document whose path is item 1 of argv
    repeat with d in testDocuments
      close d saving no
    end repeat
  end tell
end run
APPLESCRIPT
  layout "$original_layout" || result=1
  # Delete only the exact test document created by mktemp above.
  rm -f -- "$probe_file"
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

open -a TextEdit "$probe_file"
osascript -e 'tell application "TextEdit" to activate'
layout com.apple.keylayout.US

osascript - "$probe_file" "$scenario" <<'APPLESCRIPT'
on run argv
  set probePath to item 1 of argv
  tell application "TextEdit" to set probeDoc to first document whose path is probePath
  set scenario to item 2 of argv
  set physicalKeys to {5, 4, 11, 2, 1, 45, 49}
  set sourceText to "ghbdsn "
  set targetText to "привіт "
  if scenario is "phrase" then
    set physicalKeys to {43, 14, 2, 49, 45, 11, 49, 45, 14, 45, 49}
    set sourceText to ",ed nb nen "
    set targetText to "був ти тут "
  else if scenario is "english" then
    set physicalKeys to {4, 14, 37, 37, 31, 49}
    set sourceText to "hello "
  end if
  delay 0.5
  tell application "System Events"
    if not UI elements enabled then error "Accessibility permission is required"
    if frontmost of process "TextEdit" is false then error "TextEdit lost focus"
    -- Physical US keyboard keys, not Unicode text injection.
    repeat with code in physicalKeys
      if frontmost of process "TextEdit" is false then error "TextEdit lost focus"
      tell application "TextEdit" to if path of front document is not probePath then error "Test document lost focus"
      key code (code as integer)
      delay 0.08
    end repeat
  end tell
  tell application "TextEdit" to set actualText to text of probeDoc as text
  if actualText is not sourceText then error "Physical input precondition failed: " & actualText
  set proposalFound to false
  repeat 30 times
    tell application "System Events" to tell process "papuga" to set titles to name of every window
    if titles contains "Можлива заміна" then
      set proposalFound to true
      exit repeat
    end if
    delay 0.1
  end repeat
  if scenario is "english" then
    if proposalFound then error "Unexpected proposal for ordinary English"
    tell application "TextEdit" to set actualText to text of probeDoc as text
    if actualText is not sourceText then error "Ordinary English was modified"
    return "PASS: ordinary English stays unchanged without a proposal"
  end if
  if not proposalFound then error "No suggestion window after physical wrong-layout input"
  tell application "System Events"
    if frontmost of process "TextEdit" is false then error "TextEdit lost focus before acceptance"
    tell application "TextEdit" to if path of front document is not probePath then error "Test document lost focus"
    key code 36
  end tell
  repeat 30 times
    tell application "TextEdit" to set actualText to text of probeDoc as text
    if actualText is targetText then exit repeat
    delay 0.1
  end repeat
  if actualText is not targetText then error "Enter did not insert exact correction with trailing space: " & actualText
  return "PASS: " & scenario & " -> visible proposal -> Enter -> exact correction with trailing space"
end run
APPLESCRIPT
