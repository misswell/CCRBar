import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Toggle("Start CCR at App Launch", isOn: $appState.autoStartCCR)
            Toggle("Launch App at Login", isOn: $appState.launchAtLogin)
                .onChange(of: appState.launchAtLogin) { _, newValue in
                    do {
                        try LoginItemManager.setEnabled(newValue)
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }

            Section("Updates") {
                Button("Check for Updates") {
                    appState.checkForUpdates()
                }

                Text("CCRBar checks for updates automatically once a day.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 360)
        .alert("Error", isPresented: .init(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }
}
