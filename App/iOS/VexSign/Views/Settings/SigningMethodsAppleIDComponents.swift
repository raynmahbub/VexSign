// MARK: - SigningMethodsAppleIDComponents
/// Supporting sheets and status formatting for Apple ID authentication in SigningMethodsView.

import SwiftUI
import NimbleExtensions
import NativeSigning

struct AppleIDLoginView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var appleID: String
    @Binding var password: String
    @Binding var xcodeVersion: String
    @Binding var isAuthenticating: Bool
    @Binding var authError: String?
    let onSubmit: () -> Void
    @State private var providerConsent = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(.localized("Apple ID"), text: $appleID)
                        .textContentType(.username)
                        .autocapitalization(.none)
                    SecureField(.localized("Password"), text: $password)
                        .textContentType(.password)
                    TextField(.localized("Xcode Version"), text: $xcodeVersion)
                    Toggle(.localized("I approve using the selected anisette provider"), isOn: $providerConsent)
                } header: {
                    Text(.localized("Credentials"))
                } footer: {
                    Text(.localized("Your password is used to authenticate with Apple. The selected anisette provider receives provisioning and device metadata, not your Apple ID or password. Session tokens may be saved in device-only Keychain storage."))
                        .font(.caption)
                }

                if let error = authError {
                    Section {
                        Text(error).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(.localized("Sign in with Apple ID"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(.localized("Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(.localized("Sign In")) { onSubmit() }
                        .disabled(appleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty || isAuthenticating || !providerConsent)
                }
            }
            .overlay {
                if isAuthenticating {
                    ProgressView(.localized("Authenticating…"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black.opacity(0.1))
                }
            }
        }
        .presentationDetents([.large])
    }
}

struct TeamSelectionView: View {
    let teams: [NativeAccountTeam]
    let onSelect: (String) -> Void

    var body: some View {
        NavigationStack {
            List {
                ForEach(teams, id: \.identifier) { team in
                    Button {
                        onSelect(team.identifier)
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(team.identifier)
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                Text(team.membership.displayName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: team.membership == .free ? "person" : "checkmark.seal")
                                .foregroundStyle(team.membership == .free ? .orange : .green)
                        }
                    }
                }
            }
            .navigationTitle(.localized("Select Team"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(.localized("Cancel")) { onSelect("") }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Extensions

extension NativeAccountPhase {
    var icon: String {
        switch self {
        case .signedOut: return "person.crop.circle.badge.xmark"
        case .authenticating: return "person.crop.circle.badge.questionmark"
        case .awaitingTwoFactor: return "person.crop.circle.badge.exclamationmark"
        case .awaitingTeamSelection: return "person.2.fill"
        case .signedIn: return "person.crop.circle.fill.badge.checkmark"
        case .expired: return "person.crop.circle.badge.clock"
        }
    }

    var color: Color {
        switch self {
        case .signedOut: return .secondary
        case .authenticating, .awaitingTwoFactor, .awaitingTeamSelection: return .orange
        case .signedIn: return .green
        case .expired: return .red
        }
    }

    var displayTitle: String {
        switch self {
        case .signedOut: return .localized("Signed Out")
        case .authenticating: return .localized("Authenticating…")
        case .awaitingTwoFactor: return .localized("Two-Factor Required")
        case .awaitingTeamSelection: return .localized("Select Team")
        case .signedIn(let context): return .localized("Signed In: %@", arguments: context.team.identifier)
        case .expired: return .localized("Session Expired")
        }
    }
}

extension NativeAccountMembership {
    var displayName: String {
        switch self {
        case .free: return .localized("Free")
        case .paidVerified: return .localized("Paid (Verified)")
        case .developerProgramUnverified: return .localized("Developer Program (Unverified)")
        }
    }
}
