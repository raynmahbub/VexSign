import SwiftUI
import NimbleViews
import NimbleExtensions

struct ServerView: View {
    @AppStorage("VexSign.ipFix") private var _ipFix: Bool = false
    @AppStorage("VexSign.serverMethod") private var _serverMethod: Int = 0
    private let _serverMethods: [String] = [.localized("Fully Local"), .localized("Semi Local")]
    @State private var _identity: LocalTLSIdentity.Summary?
    @State private var _error: String?

    var body: some View {
        Group {
            Section {
                Picker(.localized("Server Type"), systemImage: "server.rack", selection: $_serverMethod) {
                    ForEach(_serverMethods.indices, id: \.description) { index in
                        Text(_serverMethods[index]).tag(index)
                    }
                }
                Toggle(.localized("Only use localhost address"), systemImage: "lifepreserver", isOn: $_ipFix)
                    .disabled(_serverMethod != 1)
            } footer: {
                Text(.localized("Fully Local uses this device's own HTTPS identity and loopback address. No certificate server is needed. Semi Local still requires an online manifest service."))
            }
            Section {
                Button(.localized("Check Local HTTPS Identity"), systemImage: "checkmark.shield") {
                    refresh()
                }
                Button(.localized("Export Root CA Profile (.mobileconfig)"), systemImage: "lock.shield") {
                    exportRootCA()
                }
                Button(.localized("Create a New Local CA"), systemImage: "arrow.triangle.2.circlepath") {
                    confirmRotation()
                }
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(.localized("Install the exported Root CA profile, then enable Full Trust under Settings → General → About → Certificate Trust Settings. Your CA stays on this device across app updates; server certificates renew locally without changing that CA. Restoring to another device or changing signing identity may require new trust."))
                    if let identity = _identity { Text(identity.detail).font(.footnote) }
                    if let error = _error { Text(error).foregroundStyle(.orange) }
                }
            }
        }
        .onAppear { refresh() }
    }

    private func refresh() {
        do {
            try DeviceTLSIdentity.ensure()
            _identity = LocalTLSIdentity.current()
            _error = nil
        } catch {
            _identity = nil
            _error = error.localizedDescription
        }
    }

    private func confirmRotation() {
        UIAlertController.showAlertWithOptions(
            title: .localized("Create a New Local CA?"),
            message: .localized("Finish active installations first. This explicitly replaces this device's CA. You must export, install and trust its new profile; the previous profile will no longer authorize this server. Normal certificate renewal does not require this."),
            actions: [
                (.localized("Replace CA"), .destructive, {
                    do {
                        try DeviceTLSIdentity.rotate()
                        refresh()
                    } catch { _error = error.localizedDescription }
                }),
                (.localized("Cancel"), .cancel, nil)
            ]
        )
    }

    private func exportRootCA() {
        refresh()
        guard _error == nil, let url = LocalCAProfile.exportProfile() else {
            UIAlertController.showAlertWithOk(title: .localized("Export Failed"),
                message: _error ?? .localized("The local CA profile could not be exported. Nothing was downloaded or replaced."))
            return
        }
        UIActivityViewController.show(activityItems: [url])
    }
}
