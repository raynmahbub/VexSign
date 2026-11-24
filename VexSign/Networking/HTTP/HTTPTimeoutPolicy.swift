//
//  HTTPTimeoutPolicy.swift
//  VexSign
//
//  One place for request timeouts so a transfer never inherits an unbounded
//  default. Package and firmware transfers keep the values they always had;
//  metadata calls use a shorter bound because a stalled feed must not hold a
//  download slot open.

import Foundation

enum HTTPTimeoutPolicy {
    /// One-off package file downloads (direct-install IPAs).
    static let packageDownload: TimeInterval = 60
    /// Firmware IPSW downloads, which are large and slow on poor links.
    static let firmwareDownload: TimeInterval = 120
    /// Small JSON metadata calls (API health, premium URL lists, feeds).
    static let metadataFetch: TimeInterval = 30
}
