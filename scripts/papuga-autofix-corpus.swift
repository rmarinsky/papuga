import AppKit
import Carbon.HIToolbox
import Foundation
import Darwin

// Drives the installed app through OS keyboard events. No Papuga scoring/mapping code is linked.
struct TypingCase: Codable {
    let id: String
    let category: String
    let keys: String
    let expectedText: String
    let expectedLayout: String
    let observationDelayMS: Double
}
struct Result: Codable {
    let id: String
    let category: String
    let passed: Bool
    let expectedText: String
    let actualText: String
    let expectedLayout: String
    let actualLayout: String
    let scenarioElapsedMS: Double
    let evidenceFile: String?
    let error: String?
}
enum HarnessError: Error { case failed(String) }
@discardableResult
func command(_ executable: String, _ arguments: [String], input: String? = nil) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let output = Pipe(), errors = Pipe()
    process.standardOutput = output; process.standardError = errors
    if let input {
        let pipe = Pipe(); process.standardInput = pipe
        try process.run()
        pipe.fileHandleForWriting.write(Data(input.utf8))
        try pipe.fileHandleForWriting.close()
    } else { try process.run() }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    let errorData = errors.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw HarnessError.failed(String(decoding: errorData, as: UTF8.self))
    }
    var text = String(decoding: data, as: UTF8.self)
    if text.hasSuffix("\n") { text.removeLast() } // Strip only osascript's record delimiter, not user text.
    return text
}
@discardableResult
func appleScript(_ script: String, arguments: [String] = []) throws -> String {
    try command("/usr/bin/osascript", ["-"] + arguments, input: script)
}
func layoutID() -> String {
    let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
    return Unmanaged<CFString>.fromOpaque(TISGetInputSourceProperty(source, kTISPropertyInputSourceID)!).takeUnretainedValue() as String
}
func selectLayout(_ id: String) throws {
    let query = [kTISPropertyInputSourceID!: id] as CFDictionary
    let sources = TISCreateInputSourceList(query, false).takeRetainedValue() as! [TISInputSource]
    guard let source = sources.first, TISSelectInputSource(source) == noErr else {
        throw HarnessError.failed("Required input source unavailable: \(id)")
    }
}
// Independent physical ANSI key table; expected Unicode text comes only from the fixture.
let ansi: [Character: Int] = [
    "a":0,"s":1,"d":2,"f":3,"h":4,"g":5,"z":6,"x":7,"c":8,"v":9,"b":11,
    "q":12,"w":13,"e":14,"r":15,"y":16,"t":17,"1":18,"2":19,"3":20,"4":21,
    "6":22,"5":23,"=":24,"9":25,"7":26,"-":27,"8":28,"0":29,
    "]":30,"o":31,"u":32,"[":33,"i":34,"p":35,"\n":36,"l":37,"j":38,
    "'":39,"k":40,";":41,"\\":42,",":43,"/":44,"n":45,"m":46,".":47,"\t":48," ":49,"`":50
]
let shifted = Dictionary(uniqueKeysWithValues: zip(Array("~!@#$%^&*()_+{}|:\"<>?"), Array("`1234567890-=[]\\;',./")))
func keyCommands(_ text: String) throws -> String {
    try text.map { character in
        let lower = Character(String(character).lowercased())
        let base = shifted[character] ?? lower
        guard let code = ansi[base] else { throw HarnessError.failed("No physical key for \(character)") }
        let shift = shifted[character] != nil || character != lower
        return """
        if frontmost of process "TextEdit" is false then error "Focus left TextEdit; aborted"
        tell application "TextEdit" to if path of front document is not probePath then error "Test document lost focus; aborted"
        key code \(code)\(shift ? " using shift down" : "")
        delay 0.03
        """
    }.joined(separator: "\n")
}

func quitDev() throws {
    let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "ua.com.rmarinsky.papuga.dev")
    for app in apps { app.terminate() }
    let deadline = ProcessInfo.processInfo.systemUptime + 5
    while apps.contains(where: { kill($0.processIdentifier, 0) == 0 }) {
        guard ProcessInfo.processInfo.systemUptime < deadline else {
            throw HarnessError.failed("DEV did not quit; refusing to launch competing event taps")
        }
        Thread.sleep(forTimeInterval: 0.05)
    }
}

let args = CommandLine.arguments
guard args.count >= 3 else {
    fputs("Usage: swift scripts/papuga-autofix-corpus.swift CORPUS.json REPORT.json [case-id-prefix]\n", stderr)
    exit(2)
}
let originalLayout = layoutID()
var testFile: URL?
var relaunched = false
var cleanupFailed = false
func cleanUp() {
    if let file = testFile {
        _ = try? appleScript("""
        on run argv
          tell application "TextEdit"
            set ownedDocuments to every document whose path is item 1 of argv
            repeat with d in ownedDocuments
              close d saving yes
            end repeat
          end tell
        end run
        """, arguments: [file.path])
        fputs("Interrupted test document retained: \(file.path)\n", stderr)
    }
do { try selectLayout(originalLayout) }
catch { cleanupFailed = true; fputs("Could not restore keyboard layout: \(error)\n", stderr) }
    if relaunched {
        // Quit only the DEV bundle, then relaunch without test-only argument-domain overrides.
        do {
            try quitDev()
            try command("/usr/bin/open", ["/Applications/papuga-dev.app"])
        } catch {
            cleanupFailed = true
            fputs("Could not relaunch normal DEV: \(error)\n", stderr)
        }
    }
}
var results: [Result] = []
do {
    let corpus = try JSONDecoder().decode([TypingCase].self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
    let cases = corpus.filter { args.count < 4 || $0.id.hasPrefix(args[3]) }
    guard !cases.isEmpty, Set(corpus.map(\.id)).count == corpus.count else { throw HarnessError.failed("Empty selection or duplicate IDs") }
let running = NSWorkspace.shared.runningApplications.filter { $0.localizedName == "papuga" }
guard running.allSatisfy({ $0.bundleIdentifier == "ua.com.rmarinsky.papuga.dev" }) else {
    throw HarnessError.failed("Close release/test-host Papuga instances before running this interactive check")
}
guard AXIsProcessTrusted() else { throw HarnessError.failed("Accessibility permission is required for this runner") }
    try selectLayout("com.apple.keylayout.Ukrainian-PC")
    try selectLayout(originalLayout)
    // Foundation's argument domain overrides settings for this process only, never persisted preferences.
    try quitDev()
    relaunched = true
    try command("/usr/bin/open", ["-n", "/Applications/papuga-dev.app", "--args",
        "-autoFixEnabled", "YES", "-isServiceRunning", "YES",
        "-autoFixAppPolicyOverrides", "{\"com.apple.TextEdit\" = autoMutate;}",
        "-autoFixLayoutSwitchPolicy", "alwaysSwitchToReplacementLayout",
        "-autoFixBlocklist", "()", "-autoFixAllowlist", "()", "-customAutoReplaceRules", "()",
        "-autoFixThreshold", "0.5", "-autoFixMinWordLength", "2",
        "-openHistoryOnAppLaunch", "NO", "-replacementHistoryEnabled", "NO"])
    Thread.sleep(forTimeInterval: 2)
    for tc in cases {
        let file = URL(fileURLWithPath: "/private/tmp/papuga-corpus-\(UUID().uuidString).txt")
        guard FileManager.default.createFile(atPath: file.path, contents: Data()) else { throw HarnessError.failed("Cannot create test document") }
        testFile = file
        try command("/usr/bin/open", ["-a", "TextEdit", file.path])
        try appleScript("tell application \"TextEdit\" to activate")
        try selectLayout("com.apple.keylayout.US")
        let script = """
        on run argv
          set probePath to item 1 of argv
          tell application "TextEdit" to activate
          tell application "TextEdit" to if (text of (first document whose path is probePath) as text) is not "" then error "Test document was not empty"
          delay 0.2
          tell application "System Events"
            \(try keyCommands(tc.keys))
          end tell
          delay \(tc.observationDelayMS / 1000)
          tell application "TextEdit" to return text of (first document whose path is probePath)
        end run
        """
        let start = ProcessInfo.processInfo.systemUptime
        let actual = try appleScript(script, arguments: [file.path])
        let current = layoutID()
        let passed = actual == tc.expectedText && current == tc.expectedLayout
        let result = Result(id: tc.id, category: tc.category, passed: passed, expectedText: tc.expectedText,
            actualText: actual, expectedLayout: tc.expectedLayout, actualLayout: current,
            scenarioElapsedMS: (ProcessInfo.processInfo.systemUptime - start) * 1000, evidenceFile: passed ? nil : file.path, error: nil)
        results.append(result)
        print("\(passed ? "PASS" : "FAIL") \(tc.id): \(String(reflecting: actual)) layout=\(current)")
        fflush(stdout)
        try appleScript("""
        on run argv
          tell application "TextEdit" to close (first document whose path is item 1 of argv) saving yes
        end run
        """, arguments: [file.path])
        if passed { try FileManager.default.removeItem(at: file) }
        else { print("Failure document retained: \(file.path)") }
        testFile = nil
    }
} catch {
let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
try? encoder.encode(results).write(to: URL(fileURLWithPath: args[2]))
fputs("HARNESS ERROR: \(error); partial report: \(args[2])\n", stderr)
    cleanUp()
    exit(2)
}
cleanUp()
let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
try encoder.encode(results).write(to: URL(fileURLWithPath: args[2]))
print("\(results.filter(\.passed).count)/\(results.count) passed; report: \(args[2])")
exit(cleanupFailed ? 2 : (results.allSatisfy(\.passed) ? 0 : 1))
