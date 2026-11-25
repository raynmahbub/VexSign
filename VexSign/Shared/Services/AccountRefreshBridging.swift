//
//  AccountRefreshBridging.swift
//  VexSign
//
//  Exact-value bridges from the account workspace's handoff objects into the
//  refresh workflow. No fallback is provided: if the account layer cannot name
//  the exact identity it just produced, the refresh must stop rather than guess.
//

import Foundation

enum AccountRefreshBridging {
    static func receipt(from value: AppleAccountProvisioningReceipt) -> AccountRefreshReceipt {
        AccountRefreshReceipt(profileUUID: value.profileUUID, expiresAt: value.expiresAt)
    }

    static func handoff(from value: AppleAccountSigningHandoff) -> AccountRefreshHandoff {
        AccountRefreshHandoff(
            certificateUUID: value.certificateUUID,
            profileUUID: value.profileUUID,
            bundleIdentifier: value.bundleIdentifier,
            expiresAt: value.expiresAt
        )
    }
}
