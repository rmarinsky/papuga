#!/usr/bin/env bash
set -euo pipefail

APP_PATH="${PAPUGA_APP_PATH:-/Applications/papuga-dev.app}"
BUNDLE_ID="${PAPUGA_BUNDLE_ID:-ua.com.rmarinsky.papuga.dev}"
SOURCE_WORD="${PAPUGA_PROPOSAL_TEST_SOURCE:-zzpapuga}"
TARGET_WORD="${PAPUGA_PROPOSAL_TEST_TARGET:-fixedword}"
TYPO_SOURCE="${PAPUGA_TYPO_TEST_SOURCE:-wrold}"
TYPO_TARGET="${PAPUGA_TYPO_TEST_TARGET:-world}"
INCIDENT_SOURCE="${PAPUGA_INCIDENT_TEST_SOURCE:-,ed nb nen}"
INCIDENT_TARGET="${PAPUGA_INCIDENT_TEST_TARGET:-був ти тут}"
DECISION_FILE="${PAPUGA_DECISION_FILE:-$HOME/Library/Application Support/papuga/auto-fix-decisions.jsonl}"
SCREENSHOT_DIR="${PAPUGA_SCREENSHOT_DIR:-/tmp/papuga-proposal-system-test}"

if [[ ! -d "$APP_PATH" ]]; then
  echo "App not found: $APP_PATH" >&2
  echo "Run ./scripts/dev-install.sh first, or set PAPUGA_APP_PATH." >&2
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
defaults write "$BUNDLE_ID" autoFixToastEnabled -bool true
defaults write "$BUNDLE_ID" autoFixSpellingTypoGuardEnabled -bool true
defaults write "$BUNDLE_ID" autoFixSpellingTypoGuardMinWordLength -int 4
defaults write "$BUNDLE_ID" autoFixSpellingTypoGuardMaxEditDistance -int 1
defaults write "$BUNDLE_ID" replacementHistoryEnabled -bool true
defaults write "$BUNDLE_ID" autoFixBlocklist -array
defaults write "$BUNDLE_ID" customAutoReplaceRules -array "'${RULE_JSON}'"
defaults write "$BUNDLE_ID" autoFixAppPolicyOverrides -dict com.apple.TextEdit suggestOnly
killall cfprefsd >/dev/null 2>&1 || true
printf "__papuga_proposal_old_clipboard__" | pbcopy

open -n "$APP_PATH"
sleep 2.8

PAPUGA_PROPOSAL_TEST_SOURCE="$SOURCE_WORD" \
PAPUGA_PROPOSAL_TEST_TARGET="$TARGET_WORD" \
PAPUGA_TYPO_TEST_SOURCE="$TYPO_SOURCE" \
PAPUGA_TYPO_TEST_TARGET="$TYPO_TARGET" \
PAPUGA_INCIDENT_TEST_SOURCE="$INCIDENT_SOURCE" \
PAPUGA_INCIDENT_TEST_TARGET="$INCIDENT_TARGET" \
PAPUGA_DECISION_FILE="$DECISION_FILE" \
PAPUGA_SCREENSHOT_DIR="$SCREENSHOT_DIR" \
osascript <<'APPLESCRIPT'
use scripting additions

on run
	set sourceWord to system attribute "PAPUGA_PROPOSAL_TEST_SOURCE"
	set targetWord to system attribute "PAPUGA_PROPOSAL_TEST_TARGET"
	set typoSource to system attribute "PAPUGA_TYPO_TEST_SOURCE"
	set typoTarget to system attribute "PAPUGA_TYPO_TEST_TARGET"
	set incidentSource to system attribute "PAPUGA_INCIDENT_TEST_SOURCE"
	set incidentTarget to system attribute "PAPUGA_INCIDENT_TEST_TARGET"
	set decisionFile to system attribute "PAPUGA_DECISION_FILE"
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
	delay 0.45
	do shell script "screencapture -x " & quoted form of shotPath

	tell application "System Events"
		key code 53
	end tell
	if my waitForWindowTitle(procName, "Повернути підказку", 3) is false then
		error "Escape did not expose the recoverable proposal action. Screenshot: " & shotPath
	end if
	if my clickFirstButtonInWindowTitle(procName, "Повернути підказку") is false then
		error "Could not click the proposal recovery action. Screenshot: " & shotPath
	end if
	delay 0.35

	tell application "System Events" to key code 36
	delay 0.35

	set appliedText to my textEditDocumentText()
	if appliedText is not (targetWord & " ") then
		error "Enter did not replace TextEdit content. Expected: " & targetWord & " , actual: " & appliedText & ". Screenshot: " & shotPath
	end if
	if my waitForWindowTitle(procName, "Скасувати заміну", 3) is false then
		error "Accepted replacement did not expose Undo. Screenshot: " & shotPath
	end if
	if my clickFirstButtonInWindowTitle(procName, "Скасувати заміну") is false then
		error "Could not click Undo. Screenshot: " & shotPath
	end if
	delay 0.25
	if my textEditDocumentText() is not (sourceWord & " ") then
		error "Undo did not restore the original TextEdit content. Screenshot: " & shotPath
	end if
	if my clickFirstButtonInWindowTitle(procName, "Застосувати знову") is false then
		error "Undo did not expose Apply again. Screenshot: " & shotPath
	end if
	delay 0.25
	if my textEditDocumentText() is not (targetWord & " ") then
		error "Apply again did not restore the replacement. Screenshot: " & shotPath
	end if

	my resetTextEditDocument()
	my typeTextWithBoundary(typoSource)
	if my waitForVisiblePair(procName, typoSource, typoTarget, shotPath, 5) is false then
		error "Spelling proposal is not visible: " & typoSource & " -> " & typoTarget & ". Screenshot: " & shotPath
	end if
	tell application "System Events" to key code 36
	delay 0.35
	if my textEditDocumentText() is not (typoTarget & " ") then
		error "Spelling acceptance did not change the current TextEdit occurrence. Actual: " & my textEditDocumentText()
	end if

	delay 1.0
	set retainedBeforeCorrectWord to my lineCount(decisionFile)
	my resetTextEditDocument()
	my typeTextWithBoundary("hello")
	delay 1.0
	set retainedAfterCorrectWord to my lineCount(decisionFile)
	if retainedAfterCorrectWord is not retainedBeforeCorrectWord then
		error "A correctly spelled word created a noisy full decision-history row. Before: " & retainedBeforeCorrectWord & ", after: " & retainedAfterCorrectWord
	end if

	set incidentRowsBefore to my lineCount(decisionFile)
	my resetTextEditDocument()
	my typeTextWithBoundary(incidentSource)
	if my waitForVisiblePair(procName, incidentSource, incidentTarget, shotPath, 5) is false then
		error "Whole-sentence layout proposal is not visible: " & incidentSource & " -> " & incidentTarget & ". Screenshot: " & shotPath
	end if
	tell application "System Events" to key code 36
	delay 0.35
	if my textEditDocumentText() is not (incidentTarget & " ") then
		error "Whole-sentence acceptance did not replace TextEdit atomically. Actual: " & my textEditDocumentText()
	end if
	if my waitForWindowTitle(procName, "Скасувати заміну", 3) is false then
		error "Whole-sentence replacement did not expose one Undo action. Screenshot: " & shotPath
	end if
	if my clickFirstButtonInWindowTitle(procName, "Скасувати заміну") is false then
		error "Could not undo the whole-sentence replacement. Screenshot: " & shotPath
	end if
	delay 0.25
	if my textEditDocumentText() is not (incidentSource & " ") then
		error "Whole-sentence Undo did not restore the exact source. Actual: " & my textEditDocumentText()
	end if
	if my clickFirstButtonInWindowTitle(procName, "Застосувати знову") is false then
		error "Whole-sentence Undo did not expose Apply again. Screenshot: " & shotPath
	end if
	delay 0.25
	if my textEditDocumentText() is not (incidentTarget & " ") then
		error "Whole-sentence Apply again did not restore the candidate. Actual: " & my textEditDocumentText()
	end if
	delay 1.0
	set incidentRowsAfter to my lineCount(decisionFile)
	if incidentRowsAfter is not (incidentRowsBefore + 1) then
		error "Whole-sentence capture should retain exactly one decision row. Before: " & incidentRowsBefore & ", after: " & incidentRowsAfter
	end if

	return "Proposal recovery, spelling acceptance, whole-sentence replacement, undo/reapply, and noise filtering passed. Screenshot: " & shotPath
end run

on resetTextEditDocument()
	tell application "TextEdit"
		close every document saving no
		make new document
		activate
	end tell
	delay 0.45
end resetTextEditDocument

on typeTextWithBoundary(valueToType)
	tell application "System Events"
		repeat with ch in characters of valueToType
			keystroke (ch as text)
			delay 0.055
		end repeat
		keystroke " "
	end tell
end typeTextWithBoundary

on lineCount(filePath)
	try
		return (do shell script "test -f " & quoted form of filePath & " && wc -l < " & quoted form of filePath & " || echo 0") as integer
	on error
		return 0
	end try
end lineCount

on textEditDocumentText()
	tell application "TextEdit" to return (text of document 1 as text)
end textEditDocumentText

on waitForIdentifier(procName, identifier, timeoutSeconds)
	set startedAt to current date
	repeat
		if my elementWithIdentifierExists(procName, identifier) then return true
		if ((current date) - startedAt) > timeoutSeconds then exit repeat
		delay 0.15
	end repeat
	return false
end waitForIdentifier

on waitForIdentifierOrText(procName, identifier, expectedText, timeoutSeconds)
	set startedAt to current date
	repeat
		if my elementWithIdentifierExists(procName, identifier) then return true
		if my visibleTextExists(procName, expectedText) then return true
		if ((current date) - startedAt) > timeoutSeconds then exit repeat
		delay 0.15
	end repeat
	return false
end waitForIdentifierOrText

on waitForWindowIdentifier(procName, identifier, timeoutSeconds)
	set startedAt to current date
	repeat
		if my windowWithIdentifierExists(procName, identifier) then return true
		if ((current date) - startedAt) > timeoutSeconds then exit repeat
		delay 0.1
	end repeat
	return false
end waitForWindowIdentifier

on waitForWindowTitle(procName, expectedTitle, timeoutSeconds)
	set startedAt to current date
	repeat
		tell application "System Events"
			if exists process procName then
				tell process procName
					if exists window expectedTitle then return true
				end tell
			end if
		end tell
		if ((current date) - startedAt) > timeoutSeconds then exit repeat
		delay 0.1
	end repeat
	return false
end waitForWindowTitle

on windowWithIdentifierExists(procName, identifier)
	tell application "System Events"
		if not (exists process procName) then return false
		tell process procName
			repeat with windowRef in windows
				try
					if value of attribute "AXIdentifier" of windowRef is identifier then return true
				end try
			end repeat
		end tell
	end tell
	return false
end windowWithIdentifierExists

on elementWithIdentifierExists(procName, identifier)
	tell application "System Events"
		if not (exists process procName) then return false
		tell process procName
			repeat with itemRef in entire contents
				try
					if value of attribute "AXIdentifier" of itemRef is identifier then return true
				end try
			end repeat
		end tell
	end tell
	return false
end elementWithIdentifierExists

on clickIdentifier(procName, identifier)
	tell application "System Events"
		if not (exists process procName) then return false
		tell process procName
			repeat with itemRef in entire contents
				try
					if value of attribute "AXIdentifier" of itemRef is identifier then
						click itemRef
						return true
					end if
				end try
			end repeat
		end tell
	end tell
	return false
end clickIdentifier

on clickIdentifierOrText(procName, identifier, expectedText)
	if my clickIdentifier(procName, identifier) then return true
	return my clickVisibleButton(procName, expectedText)
end clickIdentifierOrText

on clickVisibleButton(procName, expectedText)
	tell application "System Events"
		if not (exists process procName) then return false
		tell process procName
			repeat with itemRef in entire contents
				try
					if value of attribute "AXRole" of itemRef is "AXButton" then
						if my itemContainsVisibleText(itemRef, expectedText) then
							perform action "AXPress" of itemRef
							return true
						end if
					end if
				end try
			end repeat
		end tell
	end tell
	return false
end clickVisibleButton

on clickFirstButtonInWindow(procName, identifier)
	tell application "System Events"
		if not (exists process procName) then return false
		tell process procName
			repeat with windowRef in windows
				try
					if value of attribute "AXIdentifier" of windowRef is identifier then
						repeat with itemRef in entire contents of windowRef
							try
								if value of attribute "AXRole" of itemRef is "AXButton" then
									perform action "AXPress" of itemRef
									return true
								end if
							end try
						end repeat
					end if
				end try
			end repeat
		end tell
	end tell
	return false
end clickFirstButtonInWindow

on clickFirstButtonInWindowTitle(procName, expectedTitle)
	tell application "System Events"
		if not (exists process procName) then return false
		tell process procName
			if not (exists window expectedTitle) then return false
			repeat with itemRef in entire contents of window expectedTitle
				try
					if value of attribute "AXRole" of itemRef is "AXButton" then
						perform action "AXPress" of itemRef
						return true
					end if
				end try
			end repeat
		end tell
	end tell
	return false
end clickFirstButtonInWindowTitle

on waitForVisiblePair(procName, sourceWord, targetWord, shotPath, timeoutSeconds)
	set startedAt to current date
	repeat
		set sourceVisible to my visibleTextExistsInProposalWindow(procName, sourceWord)
		set targetVisible to my visibleTextExistsInProposalWindow(procName, targetWord)
		if sourceVisible and targetVisible then
			do shell script "screencapture -x " & quoted form of shotPath
			return true
		end if
		if ((current date) - startedAt) > timeoutSeconds then exit repeat
		delay 0.2
	end repeat
	return false
end waitForVisiblePair

on visibleTextExistsInWindow(procName, identifier, expectedText)
	tell application "System Events"
		if not (exists process procName) then return false
		tell process procName
			repeat with windowRef in windows
				try
					if value of attribute "AXIdentifier" of windowRef is identifier then
						repeat with itemRef in entire contents of windowRef
							if my itemContainsVisibleText(itemRef, expectedText) then return true
						end repeat
					end if
				end try
			end repeat
		end tell
	end tell
	return false
end visibleTextExistsInWindow

on visibleTextExistsInProposalWindow(procName, expectedText)
	tell application "System Events"
		if not (exists process procName) then return false
		tell process procName
			repeat with expectedTitle in {"Можлива заміна", "Можливе виправлення"}
				if exists window (expectedTitle as text) then
					repeat with itemRef in entire contents of window (expectedTitle as text)
						if my itemContainsVisibleText(itemRef, expectedText) then return true
					end repeat
				end if
			end repeat
		end tell
	end tell
	return false
end visibleTextExistsInProposalWindow

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
