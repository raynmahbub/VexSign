//
//  InstallQueue.swift
//  VexSign
//
//  Created by VexSign Team on 24.08.2026.
//
//  Every install and export runs through here. One sheet at a time keeps the OTA server from
//  starting twice and lets a job survive a dismissed sheet. On failure the queue no longer
//  abandons the whole run: it marks the app failed, keeps the rest, and offers retry / skip.
//

import Foundation
import SwiftUI
import NimbleExtensions
import IDeviceSwift

// InstallQueue is composed of:
// - InstallQueueModels.swift: FailureKind, InstallOutcome, InstallQueueSurface, FailurePresentation
// - InstallQueueCore.swift: Core queue logic
// - InstallQueueAdvanceScheduler.swift: Advance scheduling (already separate)
// - InstallQueueSurface.swift: Surface resolution (already in Models)