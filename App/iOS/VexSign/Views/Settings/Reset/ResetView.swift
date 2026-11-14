//
//  ResetView.swift
//  VexSign
//
//  Created by VexSign Contributors on 19.06.2025.
//

import SwiftUI
import NimbleViews
import NimbleExtensions

// MARK: - View
struct ResetView: View {
    @Environment(\.appContainer) private var appContainer
    private let injectedUseCase: WorkspaceResetUseCase?

    init(useCase: WorkspaceResetUseCase? = nil) {
        self.injectedUseCase = useCase
    }

    private var resetUseCase: WorkspaceResetUseCase {
        injectedUseCase ?? (appContainer ?? AppContainer.live()).makeWorkspaceResetUseCase()
    }

    // MARK: Body
    var body: some View {
        let summary = resetUseCase.summary()

        NBList(.localized("Reset")) {
            Section {
                Button(.localized("Reset Work Cache"), systemImage: "xmark.rectangle.portrait") {
                    resetUseCase.requestConfirmedReset(
                        title: .localized("Reset Work Cache"),
                        scope: .workCache
                    )
                }

                Button(.localized("Reset Network Cache"), systemImage: "xmark.rectangle.portrait") {
                    resetUseCase.requestConfirmedReset(
                        title: .localized("Reset Network Cache"),
                        message: summary.networkCacheSizeFormatted,
                        scope: .networkCache
                    )
                }
            }

            Section {
                Button(.localized("Reset Sources"), systemImage: "xmark.circle") {
                    resetUseCase.requestConfirmedReset(
                        title: .localized("Reset Sources"),
                        message: summary.sourcesCountText,
                        scope: .sources
                    )
                }

                Button(.localized("Reset Signed Apps"), systemImage: "xmark.circle") {
                    resetUseCase.requestConfirmedReset(
                        title: .localized("Reset Signed Apps"),
                        message: summary.signedAppsCountText,
                        scope: .signedApps
                    )
                }

                Button(.localized("Reset Imported Apps"), systemImage: "xmark.circle") {
                    resetUseCase.requestConfirmedReset(
                        title: .localized("Reset Imported Apps"),
                        message: summary.importedAppsCountText,
                        scope: .importedApps
                    )
                }

                Button(.localized("Reset Tweaks"), systemImage: "xmark.circle") {
                    resetUseCase.requestConfirmedReset(
                        title: .localized("Reset Tweaks"),
                        message: .localized("%lld tweaks", arguments: summary.tweaksCount),
                        scope: .tweaks
                    )
                }

                Button(.localized("Reset Certificates"), systemImage: "xmark.circle") {
                    resetUseCase.requestConfirmedReset(
                        title: .localized("Reset Certificates"),
                        message: summary.certificatesCountText,
                        scope: .certificates(resetAll: false)
                    )
                }
            }

            Section {
                Button(.localized("Reset Settings"), systemImage: "xmark.octagon") {
                    resetUseCase.requestConfirmedReset(
                        title: .localized("Reset Settings"),
                        scope: .userDefaults
                    )
                }

                Button(.localized("Reset All"), systemImage: "xmark.octagon") {
                    resetUseCase.requestConfirmedReset(
                        title: .localized("Reset All"),
                        scope: .all
                    )
                }
            }
            .foregroundStyle(.red)
        }
    }
}
