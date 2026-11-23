//
//  TweakFolderRules.swift
//  VexSign
//
//  The two rules behind tweak folders, lifted out of `TweakManager`.
//
//  Both were private methods on an `ObservableObject` that reads and writes three JSON files on
//  first use, so neither could be tested without a file system and a published object: the
//  collision suffix that keeps two folders distinguishable, and the rule that deleting a folder
//  never deletes a tweak. They are string and array functions, so they live here and
//  `TweakFolderRulesTests` exercises them directly.
//

import Foundation

enum TweakFolderRules {
    /// A name that is unique among `taken`, ignoring case and surrounding whitespace.
    ///
    /// An empty request becomes `fallback` rather than an unnamed folder, and a collision gets
    /// " 2", " 3"… — the suffix the manager has always used, kept here so a rename and a creation
    /// cannot disagree about it.
    static func uniqueName(_ desired: String, taken: some Sequence<String>, fallback: String) -> String {
        var base = desired.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { base = fallback }
        let existing = Set(taken.map { $0.lowercased() })
        guard existing.contains(base.lowercased()) else { return base }
        var suffix = 2
        while existing.contains("\(base) \(suffix)".lowercased()) { suffix += 1 }
        return "\(base) \(suffix)"
    }

    /// The folder a tweak lands in once `deleted` is removed: uncategorized, never removed.
    ///
    /// Deleting a folder moves its tweaks to uncategorized because a folder is a label, and losing
    /// the label is not a reason to lose the tweak.
    static func folder(afterDeleting deleted: UUID, from current: UUID?) -> UUID? {
        current == deleted ? nil : current
    }
}
