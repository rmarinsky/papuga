#!/usr/bin/env bash
set -euo pipefail

APP_PATH="${PAPUGA_APP_PATH:-/Applications/papuga-dev.app}"
BUNDLE_ID="${PAPUGA_BUNDLE_ID:-ua.com.rmarinsky.papuga.dev}"
SOURCE_WORD="${PAPUGA_PROPOSAL_TEST_SOURCE:-zzpapuga}"
TARGET_WORD="${PAPUGA_PROPOSAL_TEST_TARGET:-fixedword}"
SCREENSHOT_DIR="${PAPUGA_SCREENSHOT_DIR:-/tmp/papuga-proposal-system-test}"

if [[ ! -d "$APP_PATH" ]]; then
  echo "App not found: $APP_PATH" >&2
  echo "Run ./scripts/dev-install.sh --no-reset-tcc first, or set PAPUGA_APP_PATH." >&2
  exit 1
fi

mkdir -p "$SCREENSHOT_DIR"

PREF_PATH="$HOME/Library/Preferences/${BUNDLE_ID}.plist"
BACKUP_DIR="$(mktemp -d)"
BACKUP_PATH="$BACKUP_DIR/${BUNDLE_ID}.plist"
HAD_PREF=0
if [[ -f "$PREF_PATH" ]]; then
  cp "$PREF_PATH" "$BACKUP_PATH"
  HAD_PREF=1
fi

restore_preferences() {
  if [[ "$HAD_PREF" == "1" && -f "$BACKUP_PATH" ]]; then
    cp "$BACKUP_PATH" "$PREF_PATH"
  else
    defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
  fi
  killall cfprefsd >/dev/null 2>&1 || true
  rm -rf "$BACKUP_DIR"
}

cleanup() {
  osascript -e 'tell application "TextEdit" to close every document saving no' >/dev/null 2>&1 || true
  restore_preferences
}
trap cleanup EXIT

RULE_JSON="{\"createdAt\":$(date +%s),\"createdFromRecommendation\":false,\"id\":\"$(uuidgen)\",\"source\":\"${SOURCE_WORD}\",\"target\":\"${TARGET_WORD}\"}"

pkill -x papuga >/dev/null 2>&1 || true
pkill -x "Papuga DEV" >/dev/null 2>&1 || true
for _ in {1..30}; do
  if ! pgrep -x papuga >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done
killall cfprefsd >/dev/null 2>&1 || true

defaults write "$BUNDLE_ID" autoFixEnabled -bool true
defaults write "$BUNDLE_ID" autoFixProposalEnabled -bool true
defaults write "$BUNDLE_ID" autoFixToastEnabled -bool false
defaults write "$BUNDLE_ID" autoFixBlocklist -array
defaults write "$BUNDLE_ID" customAutoReplaceRules -array "'${RULE_JSON}'"
defaults write "$BUNDLE_ID" autoFixAppPolicyOverrides -dict com.apple.TextEdit suggestOnly
killall cfprefsd >/dev/null 2>&1 || true
printf "__papuga_proposal_old_clipboard__" | pbcopy

open -n "$APP_PATH"
sleep 2.8

PAPUGA_PROPOSAL_TEST_SOURCE="$SOURCE_WORD" \
PAPUGA_PROPOSAL_TEST_TARGET="$TARGET_WORD" \
PAPUGA_SCREENSHOT_DIR="$SCREENSHOT_DIR" \
osascript <<'APPLESCRIPT'
use scripting additions

on run
	set sourceWord to system attribute "PAPUGA_PROPOSAL_TEST_SOURCE"
	set targetWord to system attribute "PAPUGA_PROPOSAL_TEST_TARGET"
	set shotRoot to system attribute "PAPUGA_SCREENSHOT_DIR"
	set shotPath to shotRoot & "/autofix-proposal-popup.png"
	
	tell application "TextEdit"
		activate
		make new document
	end tell
	delay 0.6
	
	tell application "System Events"
		tell process "TextEdit"
			set frontmost to true
		end tell
		repeat with ch in characters of sourceWord
			keystroke (ch as text)
			delay 0.055
		end repeat
		keystroke " "
	end tell
	
	set procName to my papugaProcessName()
	set pairVisible to my waitForVisiblePair(procName, sourceWord, targetWord, shotPath, 5)
	if pairVisible is false then
		do shell script "screencapture -x " & quoted form of shotPath
		error "AutoFix proposal source/target text is not visible: " & sourceWord & " -> " & targetWord & ". Screenshot: " & shotPath
	end if

	tell application "System Events"
		key code 36
	end tell
	delay 0.4

	set clipboardText to do shell script "pbpaste"
	if clipboardText is not targetWord then
		error "Enter did not activate the proposal primary action. Expected clipboard: " & targetWord & ", actual: " & clipboardText & ". Screenshot: " & shotPath
	end if
	
	return "AutoFix proposal source/target are visible and Enter activates primary action. Screenshot: " & shotPath
end run

on waitForVisiblePair(procName, sourceWord, targetWord, shotPath, timeoutSeconds)
	set startedAt to current date
	repeat
		set sourceVisible to my visibleTextExists(procName, sourceWord)
		set targetVisible to my visibleTextExists(procName, targetWord)
		if sourceVisible and targetVisible then
			do shell script "screencapture -x " & quoted form of shotPath
			return true
		end if
		if ((current date) - startedAt) > timeoutSeconds then exit repeat
		delay 0.2
	end repeat
	return false
end waitForVisiblePair

on visibleTextExists(procName, expectedText)
	tell application "System Events"
		if not (exists process procName) then return false
		tell process procName
			set allItems to entire contents
			repeat with itemRef in allItems
				if my itemContainsVisibleText(itemRef, expectedText) then return true
			end repeat
		end tell
	end tell
	return false
end visibleTextExists

on itemContainsVisibleText(itemRef, expectedText)
	set candidates to {}
	try
		set end of candidates to (name of itemRef as text)
	end try
	try
		set end of candidates to (value of itemRef as text)
	end try
	try
		set end of candidates to (description of itemRef as text)
	end try
	
	repeat with candidateText in candidates
		if (candidateText as text) contains expectedText then
			try
				set itemSize to size of itemRef
				if (item 1 of itemSize) > 8 and (item 2 of itemSize) > 8 then return true
			on error
				return true
			end try
		end if
	end repeat
	return false
end itemContainsVisibleText

on papugaProcessName()
	tell application "System Events"
		repeat with procName in {"papuga", "Papuga", "Papuga DEV"}
			if exists process (procName as text) then return procName as text
		end repeat
	end tell
	error "Papuga process was not found."
end papugaProcessName
APPLESCRIPT
