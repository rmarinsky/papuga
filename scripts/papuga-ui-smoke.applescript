use scripting additions

property defaultShotRoot : "/Users/rmarinskyi/IdeaProjects/personal/mac apps/.redesign/papuga-ui-smoke"
property processNames : {"papuga", "Papuga"}

on run
	set shotRoot to system attribute "PAPUGA_SCREENSHOT_DIR"
	if shotRoot is "" then set shotRoot to defaultShotRoot
	do shell script "mkdir -p " & quoted form of shotRoot
	do shell script "find " & quoted form of shotRoot & " -maxdepth 1 -name '*.png' -delete"
	
	openPapuga()
	prepareWindow()
	
	repeat with themeName in {"light", "dark"}
		set darkModeEnabled to ((themeName as text) is "dark")
		setDarkMode(darkModeEnabled)
		delay 0.8
		prepareWindow()
		
		selectSidebarRow(1)
		captureWindow(shotRoot, themeName & "-01-overview")
		
		selectSidebarRow(2)
		captureWindow(shotRoot, themeName & "-02-history-replacements")
		clickWindowOffset(918, 82)
		captureWindow(shotRoot, themeName & "-03-history-clipboard")
		
		selectSidebarRow(3)
		captureWindow(shotRoot, themeName & "-04-mistakes")
		
		selectSidebarRow(4)
		captureWindow(shotRoot, themeName & "-05-suggestions")
		
		selectSidebarRow(6)
		captureWindow(shotRoot, themeName & "-06-settings-general")
		
		selectSidebarRow(7)
		captureWindow(shotRoot, themeName & "-07-settings-languages")
		
		selectSidebarRow(8)
		captureWindow(shotRoot, themeName & "-08-settings-rules-autofix")
		clickWindowOffset(918, 82)
		captureWindow(shotRoot, themeName & "-09-settings-rules-dictionary")
		clickWindowOffset(330, 430)
		captureWindow(shotRoot, themeName & "-10-rule-modal")
		pressEscape()
		
		selectSidebarRow(9)
		captureWindow(shotRoot, themeName & "-11-settings-shortcuts")
		
		selectSidebarRow(10)
		captureWindow(shotRoot, themeName & "-12-settings-account")
	end repeat
	
	return "Papuga UI smoke screenshots saved to " & shotRoot
end run

on openPapuga()
	do shell script "pkill -x papuga 2>/dev/null || true; pkill -x Papuga 2>/dev/null || true"
	delay 0.4
	set appPath to system attribute "PAPUGA_APP_PATH"
	if appPath is not "" then
		do shell script "open " & quoted form of appPath
	else
		do shell script "open -a papuga 2>/dev/null || open -a Papuga"
	end if
	delay 1.2
end openPapuga

on prepareWindow()
	set procName to papugaProcessName()
	waitForWindow(procName)
	tell application "System Events"
		tell process procName
			set frontmost to true
			set position of window 1 to {80, 80}
			set size of window 1 to {1000, 680}
		end tell
	end tell
	delay 0.3
end prepareWindow

on setDarkMode(shouldUseDarkMode)
	tell application "System Events"
		tell appearance preferences
			set dark mode to shouldUseDarkMode
		end tell
	end tell
end setDarkMode

on selectSidebarRow(rowIndex)
	set procName to papugaProcessName()
	waitForWindow(procName)
	tell application "System Events"
		tell process procName
			tell outline 1 of scroll area 1 of group 1 of splitter group 1 of group 1 of window 1
				select row rowIndex
			end tell
		end tell
	end tell
	delay 0.45
end selectSidebarRow

on clickWindowOffset(dx, dy)
	set procName to papugaProcessName()
	waitForWindow(procName)
	tell application "System Events"
		tell process procName
			set {wx, wy} to position of window 1
		end tell
		click at {wx + dx, wy + dy}
	end tell
	delay 0.45
end clickWindowOffset

on clickText(labelText)
	set procName to papugaProcessName()
	waitForWindow(procName)
	tell application "System Events"
		tell process procName
			set allItems to entire contents of window 1
			repeat with itemRef in allItems
				try
					if (name of itemRef as text) is labelText then
						click itemRef
						delay 0.45
						return
					end if
				end try
			end repeat
			error "Could not find UI text: " & labelText
		end tell
	end tell
end clickText

on pressEscape()
	tell application "System Events"
		key code 53
	end tell
	delay 0.25
end pressEscape

on captureWindow(shotRoot, shotName)
	set procName to papugaProcessName()
	waitForWindow(procName)
	tell application "System Events"
		tell process procName
			set {wx, wy} to position of window 1
			set {ww, wh} to size of window 1
		end tell
	end tell
	set outPath to shotRoot & "/" & shotName & ".png"
	do shell script "screencapture -x -R" & wx & "," & wy & "," & ww & "," & wh & " " & quoted form of outPath
	delay 0.15
end captureWindow

on papugaProcessName()
	tell application "System Events"
		repeat with procName in processNames
			if exists process (procName as text) then return procName as text
		end repeat
	end tell
	error "Papuga process was not found."
end papugaProcessName

on waitForWindow(procName)
	tell application "System Events"
		repeat 30 times
			tell process procName
				if (count of windows) > 0 then return
			end tell
			delay 0.2
		end repeat
	end tell
	error "Papuga window is not visible. Launch the app with openHistoryOnAppLaunch enabled or open the main window manually."
end waitForWindow
