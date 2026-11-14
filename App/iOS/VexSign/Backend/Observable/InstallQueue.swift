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
//  The queue is split across the files below; this one holds no code.
//
//  - InstallQueueModels.swift: FailureKind, InstallOutcome, InstallQueueSurface, FailurePresentation
//  - InstallQueueCore.swift: core queue logic
//  - InstallQueueAdvanceScheduler.swift: the delay between one install finishing and the next
//