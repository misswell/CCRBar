import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var appState: AppState
    @State private var errorMessage: String?

    private var productName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "CCRBar"
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "Unknown"
    }

    private var ccrIsActive: Bool {
        switch appState.statusMonitor.status {
        case .starting, .stopping, .running, .partiallyRunning:
            return true
        case .stopped, .error:
            return false
        }
    }

    private var startDisabled: Bool {
        !appState.resolver.canRunCCR || appState.serviceManager.isBusy || ccrIsActive
    }

    private var stopDisabled: Bool {
        !appState.resolver.canRunCCR
            || appState.serviceManager.isStopping
            || appState.statusMonitor.status == .stopping
            || !ccrIsActive
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(productName)
                    .font(.headline)
                Text("Version \(appVersion)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)

            Divider()

            StatusView(
                status: appState.statusMonitor.status,
                gatewayUp: appState.statusMonitor.gatewayUp,
                managementUp: appState.statusMonitor.managementUp,
                nodeRuntimeDescription: appState.resolver.nodeRuntimeDescription,
                managementPort: appState.managementPortValue
            )

            if appState.resolver.runtime.issue != nil {
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
                    await appState.startCCR(
                        port: appState.managementPortValue,
                        startGateway: !appState.statusMonitor.gatewayUp
                    )
                }
            }
            .disabled(startDisabled)

            Button("Open Dashboard") {
                appState.serviceManager.openDashboard(port: appState.managementPortValue)
            }
            .disabled(!appState.resolver.canRunCCR)

            Button("Restart CCR") {
                Task {
                    await appState.restartCCR(port: appState.managementPortValue)
                }
            }
            .disabled(!appState.resolver.canRunCCR || appState.serviceManager.isBusy)

            Button("Stop CCR") {
                Task {
                    await appState.stopCCR()
                }
            }
            .disabled(stopDisabled)

            Divider()

            Toggle("Start CCR at App Launch", isOn: $appState.autoStartCCR)
            HStack {
                Text("Management Port")
                Spacer()
                TextField(
                    "3458",
                    value: $appState.managementPort,
                    format: .number.grouping(.never)
                )
                .multilineTextAlignment(.trailing)
                .frame(width: 72)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    appState.managementPortChanged()
                }
            }
            Text("CCR management UI and status port; changes restart CCR")
                .font(.caption)
                .foregroundStyle(.secondary)
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
                openCCRDataFolder()
            }

            Button("Refresh") {
                appState.refresh()
            }

            Button("Check for Updates") {
                appState.checkForUpdates()
            }

            Divider()

            Button("Quit") {
                NSApp.terminate(nil)
            }
        }
        .padding(10)
        .frame(minWidth: 300)
        .onAppear {
            appState.refreshStatus()
        }
        .alert("Error", isPresented: .init(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func openCCRDataFolder() {
        let path = NSHomeDirectory() + "/.claude-code-router"
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false

        if fileManager.fileExists(atPath: path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                errorMessage = String(localized: "CCR data path is not a folder.")
                return
            }
        } else {
            do {
                try fileManager.createDirectory(atPath: path, withIntermediateDirectories: true)
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }

        NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
    }

    @ViewBuilder
    private var setupErrorSection: some View {
        switch appState.resolver.runtime.issue {
        case .ccrNotFound:
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
        case .nodeNotFound:
            Label("Node.js 22+ Required", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text("Node.js 22 or newer is required to run CCR.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .unsupportedNode(let version):
            Label("Node.js \(version) detected", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text("Node.js 22+ is required.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .desktopRuntimeUnavailable:
            Label("CCR Desktop Runtime Unavailable", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text("The desktop app's bundled Node.js runtime could not be detected.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case nil:
            EmptyView()
        }
    }
}
