#!/usr/bin/env swift
// Is a word in the dictionary? The same call `Replacements.isRealWord` makes.
//
//     swift scripts/real-words.swift praise Praisy Prissy
//
// One line per word, `  word: true|false`, ready to paste into a YAML.
//
// This *reproduces* the app's gate rather than calling it. The app is a bundle;
// a spike harness in Python cannot link it. The body below is copied from
// `Sources/ParrotFlow/Replacements.swift` — same lowercasing, same two
// languages, same `NSNotFound` reading — so if that file changes, this stops
// being the app's answer and has to be recopied.
//
// The lookup is not deterministic. `checkSpelling` returns `NSNotFound` both
// for a known word and for a failed lookup, so a slow call reads as "real".
// That is why the answers are cached in `tests/real-words.yaml` and read from
// there: a rerun that flips one word would silently move a routing number.
import AppKit
import Foundation

for word in CommandLine.arguments.dropFirst() {
    let key = word.lowercased()
    var known = false
    for language in ["en", "fr"] {
        let range = NSSpellChecker.shared.checkSpelling(
            of: key, startingAt: 0, language: language,
            wrap: false, inSpellDocumentWithTag: 0, wordCount: nil
        )
        if range.location == NSNotFound { known = true; break }
    }
    print("  \(word): \(known)")
}
