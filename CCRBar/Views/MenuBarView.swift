import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var appState: AppState
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            StatusView(
                status: appState.statusMonitor.status,
                gatewayUp: appState.statusMonitor.gatewayUp,
                managementUp: appState.statusMonitor.managementUp,
                nodeVersion: appState.resolver.nodeVersionString
            )

            if appState.resolver.lastError != nil {
                Divider()
                setupErrorSection
            }

            if let serviceError = appState.serviceManager.lastErrorText {
                Divider()
                Label(serviceError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            Divider()

            Button("Start CCR") {
                Task {
                    await appState.serviceManager.start()
                }
            }
            .disabled(!appState.resolver.isCCRInstalled || appState.serviceManager.isBusy)

            Button("Open Dashboard") {
                appState.serviceManager.openDashboard()
            }
            .disabled(!appState.resolver.isCCRInstalled)

            Button("Restart CCR") {
                Task {
                    await appState.serviceManager.restart()
                }
            }
            .disabled(!appState.resolver.isCCRInstalled || appState.serviceManager.isBusy)

            Button("Stop CCR") {
                Task {
                    await appState.serviceManager.stop()
                }
            }
            .disabled(!appState.resolver.isCCRInstalled || appState.serviceManager.isBusy)

            Divider()

            Toggle("Start CCR at App Launch", isOn: $appState.autoStartCCR)
            Toggle("Launch App at Login", isOn: $appState.launchAtLogin)
                .onChange(of: appState.launchAtLogin) { _, newValue in
                    do {
                        try LoginItemManager.setEnabled(newValue)
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }

            Divider()

            Button("Open CCR Data Folder") {
                if let url = URL(string: NSHomeDirectory() + "/.claude-code-router") {
                    NSWorkspace.shared.open(url)
                }
            }

            Button("Refresh") {
                appState.refresh()
            }

            Divider()

            Button("Quit") {
                NSApp.terminate(nil)
            }
        }
        .padding(10)
        .frame(minWidth: 300)
        .alert("Error", isPresented: .init(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var setupErrorSection: some View {
        if !appState.resolver.isCCRApp {
            if !appState.resolver.isNodeInstalled {
                Label("Node.js 22+ Required", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text("Node.js 22 or newer is required to run CCR.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if !appState.resolver.nodeMeetsRequirement {
                Label("Node.js \(appState.resolver.nodeVersionString ?? "?") detected", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text("Node.js 22+ is required.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        if !appState.resolver.isCCRInstalled {
            Text("CCR Not Installed")
                .fontWeight(.semibold)
            Text("npm install -g @musistudio/claude-code-router")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Copy Install Command") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString("npm install -g @musistudio/claude-code-router", forType: .string)
                }
                Spacer()
            }
        }
    }
}
