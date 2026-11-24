//
//  SharedBackupPresentation.swift
//  VexSign
//
//  Attaches the restore offer to whatever it is applied to.
//
//  The root scene has one long modifier chain, and reading a nested observable in
//  there is enough to push the type-checker past its limit. This observes the inbox
//  itself, so the scene only has to name one modifier.
//

import SwiftUI

@MainActor
struct SharedBackupPresentation: ViewModifier {
    @ObservedObject var inbox: SharedBackupInbox

    func body(content: Content) -> some View {
        content.sheet(item: $inbox.staged) { staged in
            // No inner environment scope: the root scope wraps every presentation,
            // and a second one here is the drift the workspace boundary gate rejects.
            SharedBackupRestoreSheet(
                staged: staged,
                onDiscard: { inbox.clear(staged.id) }
            )
        }
    }
}
