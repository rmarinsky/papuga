#!/usr/bin/env swift
//
// Regenerates papuga/Resources/FrequencyWords/frequency_<lang>.txt from a raw
// hermitdave/FrequencyWords dump.
//
//   swift scripts/build-frequency-list.swift <lang> <raw-input> <output>
//
// Why this exists
// ---------------
// The raw uk list is OpenSubtitles-derived and heavily Russian-contaminated:
// 3206 entries carry Russian-only letters, and `что` is its 8th most frequent
// "Ukrainian" word at 49617. Because the index promotes anything it contains,
// Russian was being accepted as valid Ukrainian — a layout flip could land on
// a Russian word, and a guess could rank one above the genuine Ukrainian form.
//
// The filter is deliberately simple: keep only what the macOS dictionary for
// that language accepts, and let it arbitrate. A blanket Russian-lexicon
// subtraction would be wrong (`так`, `він`, `тебе` are legitimately shared),
// and a count threshold is worse than useless here because the contaminating
// words are high-frequency by construction.
//
// Over-deletion is cheap now, and only because the list was demoted first: it
// is a ranking signal and a promotion overlay, not the spelling authority. A
// valid word dropped here just loses its frequency boost and falls through to
// the system dictionary, which accepts it anyway.
//
// The list must stay reproducible, or the next person re-imports the raw dump
// and silently reintroduces all of this. Record any change in NOTICE.md.

import AppKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 4 else {
    FileHandle.standardError.write(Data(
        "usage: build-frequency-list.swift <lang> <raw-input> <output>\n".utf8
    ))
    exit(2)
}

let language = arguments[1]
let inputPath = arguments[2]
let outputPath = arguments[3]

let checker = NSSpellChecker.shared
guard checker.availableLanguages.contains(where: {
    $0.lowercased().hasPrefix(language.lowercased())
}) else {
    FileHandle.standardError.write(Data(
        "macOS has no '\(language)' dictionary; cannot arbitrate. Aborting.\n".utf8
    ))
    exit(1)
}

let raw = try String(contentsOfFile: inputPath, encoding: .utf8)

/// Russian-only letters. Kept as a fast pre-filter and as documentation of the
/// contamination; the spell-check pass below would catch these anyway.
let russianOnly = Set("ыэъё")

func isAcceptedByDictionary(_ word: String) -> Bool {
    let range = checker.checkSpelling(
        of: word,
        startingAt: 0,
        language: language,
        wrap: false,
        inSpellDocumentWithTag: 0,
        wordCount: nil
    )
    return range.location == NSNotFound
}

var kept: [(String, Int)] = []
var droppedRussian = 0
var droppedRejected = 0
var droppedShape = 0

for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
    let parts = line.split(separator: " ", maxSplits: 1)
    guard let rawWord = parts.first else { continue }
    let word = String(rawWord)
    let count = parts.count > 1 ? Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 1 : 1

    // Single characters are entries in the raw list with enormous counts
    // (`я 168773`, `в 69533`) and are pure ranking noise.
    guard word.count >= 2, word.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "-" }) else {
        droppedShape += 1
        continue
    }
    if language == "uk", word.contains(where: { russianOnly.contains($0) }) {
        droppedRussian += 1
        continue
    }
    guard isAcceptedByDictionary(word) else {
        droppedRejected += 1
        continue
    }
    kept.append((word, count))
}

let body = kept.map { "\($0.0) \($0.1)" }.joined(separator: "\n") + "\n"
try body.write(toFile: outputPath, atomically: true, encoding: .utf8)

print("""
\(language): kept \(kept.count) of \(kept.count + droppedRussian + droppedRejected + droppedShape)
  dropped \(droppedShape) on shape (single chars, digits, symbols)
  dropped \(droppedRussian) containing Russian-only letters
  dropped \(droppedRejected) rejected by the macOS '\(language)' dictionary
""")
