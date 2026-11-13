//
//  DirectInstallSheet.swift
//  VexSign
//
//  One-tap download, auto-signing, and direct installation from URL.
//

import SwiftUI
import NimbleViews
import NimbleExtensions

struct DirectInstallSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appContainer) private var appContainer
    @State private var viewModel: DirectInstallViewModel?

    enum InstallMode: String, CaseIterable, Identifiable {
        case signAndInstall
        case installWithoutSigning

        var id: String { rawValue }
        var title: String {
            switch self {
            case .signAndInstall: .localized("Sign & Install")
            case .installWithoutSigning: .localized("Install Without Signing")
            }
        }

        var domainMode: DirectInstallMode {
            switch self {
            case .signAndInstall: .signAndInstall
            case .installWithoutSigning: .installWithoutSigning
            }
        }

        init(domainMode: DirectInstallMode) {
            switch domainMode {
            case .signAndInstall: self = .signAndInstall
            case .installWithoutSigning: self = .installWithoutSigning
            }
        }
    }

    @State var urlString: String = ""
    @State var selectedMode: InstallMode = .signAndInstall

    init(
        urlString: String = "",
        selectedMode: InstallMode = .signAndInstall,
        viewModel: DirectInstallViewModel? = nil
    ) {
        self._urlString = State(initialValue: urlString)
        self._selectedMode = State(initialValue: selectedMode)
        self._viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        Group {
            if let viewModel {
                DirectInstallSheetContent(
                    viewModel: viewModel,
                    urlString: $urlString,
                    selectedMode: $selectedMode,
                    onClose: { dismiss() }
                )
            } else {
                ProgressView()
                    .onAppear {
                        let container = appContainer ?? AppContainer.live()
                        viewModel = container.makeDirectInstallViewModel(
                            initialURL: urlString,
                            initialMode: selectedMode.domainMode
                        )
                    }
            }
        }
    }
}

private struct DirectInstallSheetContent: View {
    @ObservedObject var viewModel: DirectInstallViewModel
    @Binding var urlString: String
    @Binding var selectedMode: DirectInstallSheet.InstallMode
    let onClose: () -> Void

    var body: some View {
        NBNavigationView(.localized("Direct Install"), displayMode: .inline) {
            Form {
                Section {
                    TextField(.localized("https://example.com/app.ipa"), text: $urlString)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(viewModel.isProcessing)

                    Picker(.localized("Installation Mode"), selection: $selectedMode) {
                        ForEach(DirectInstallSheet.InstallMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .disabled(viewModel.isProcessing)
                } header: {
                    Text(.localized("Package URL"))
                } footer: {
                    Text(.localized("Directly download, prepare, and install the package on your device in one step."))
                }

                if viewModel.isProcessing {
                    Section {
                        HStack {
                            ProgressView()
                                .padding(.trailing, 6)
                            Text(viewModel.statusMessage)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                } else {
                    Section {
                        Button {
                            viewModel.urlString = urlString
                            viewModel.selectedMode = selectedMode.domainMode
                            viewModel.startInstall(onComplete: onClose)
                        } label: {
                            HStack {
                                Spacer()
                                Label(.localized("Start Direct Install"), systemImage: "arrow.down.app.fill")
                                    .bold()
                                Spacer()
                            }
                        }
                        .disabled(urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .toolbar {
                NBToolbarButton(role: .cancel)
            }
        }
    }
}
