//
//  FilePreviewReading.swift
//  VexSign
//
//  The read-only slice of the file workspace a preview needs.
//
//  `FilePreviewLoader` renders for two screens that hold different objects: the
//  application use case, and the presentation model that wraps it. Depending on
//  either one would make the loader a presentation-to-feature dependency; naming
//  only the six reads it performs keeps it independent of both, and keeps the size
//  gate in one place instead of per caller.
//
//  Main-actor: every read here is reached from a screen that is appearing, and the
//  presentation model that satisfies it is main-actor isolated already. The
//  application use case is not, and a nonisolated method satisfies a main-actor
//  requirement, so both can conform without either owner changing isolation.
//

import Foundation

@MainActor
protocol FilePreviewReading {
    /// Size on disk, so a read can be refused before it happens.
    func size(at url: URL) -> Int64
    func text(at url: URL) -> String?
    func plistText(at url: URL) -> String?
    func plist(at url: URL) -> Any?
    func data(at url: URL) -> Data?
    func head(of url: URL, count: Int) -> Data?
}
