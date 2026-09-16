import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var appState: AppState
    @State private var errorMessage: String?
    @State private var confirmCCRUpdate = false

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

            Divider()

            ccrVersionSection

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
            HStack {
                Text("Gateway Access")
                Spacer()
                Picker("Gateway Access", selection: Binding(
                    get: { appState.gatewayHostMode },
                    set: { appState.setGatewayHostMode($0) }
                )) {
                    Text("This Mac only").tag(AppSettings.GatewayHostMode.loopback)
                    Text("Local network").tag(AppSettings.GatewayHostMode.lan)
                    Text("Custom address").tag(AppSettings.GatewayHostMode.custom)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 150)
            }

            if appState.gatewayHostMode == .custom {
                HStack {
                    Text("Gateway Host")
                    Spacer()
                    TextField(
                        "127.0.0.1",
                        text: $appState.gatewayHost
                    )
                    .multilineTextAlignment(.trailing)
                    .frame(width: 140)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        appState.gatewayHostChanged()
                    }
                }
            }

            if appState.gatewayHostMode == .lan {
                HStack(spacing: 6) {
                    Image(systemName: "network")
                        .foregroundStyle(.secondary)
                    Text(localGatewayAddressText)
                        .font(.callout)
                        .textSelection(.enabled)
                    Spacer()
                    if appState.localNetwork.ipv4Address != nil {
                        Button("Copy") {
                            copyLocalGatewayAddress()
                        }
                        .controlSize(.small)
                    }
                }
            }

            Text(gatewayAccessCaption)
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
        .confirmationDialog("Update CCR?", isPresented: $confirmCCRUpdate, titleVisibility: .visible) {
            Button("Update CCR") {
                Task {
                    await appState.updateCCR()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will run npm install -g @musistudio/claude-code-router@latest.")
        }
    }

    private var localGatewayAddressText: String {
        guard let address = appState.localNetwork.ipv4Address else {
            return String(localized: "Detecting local address…")
        }
        return "http://\(address):\(AppSettings.defaultGatewayPort)"
    }

    private var gatewayAccessCaption: String {
        switch appState.gatewayHostMode {
        case .loopback:
            return String(localized: "Listens on 127.0.0.1 only; other devices cannot reach the gateway.")
        case .lan:
            return String(localized: "Listens on 0.0.0.0:3456 — 127.0.0.1 and the local network both work, even when the IP changes.")
        case .custom:
            return String(localized: "Gateway API listen address (port 3456); changes restart CCR")
        }
    }

    private func copyLocalGatewayAddress() {
        guard let address = appState.localNetwork.ipv4Address else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("http://\(address):\(AppSettings.defaultGatewayPort)", forType: .string)
    }

    @ViewBuilder
    private var ccrVersionSection: some View {
        switch appState.ccrUpdateManager.status {
        case .idle, .unavailable:
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.secondary)
                Text("CCR version unknown")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Check for CCR Updates") {
                    Task {
                        await appState.checkForCCRUpdates()
                    }
                }
                .controlSize(.small)
            }
        case .checking:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Checking CCR for updates…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .available(let current, let latest):
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundStyle(.orange)
                    Text("CCR Update Available")
                        .fontWeight(.semibold)
                        .foregroundStyle(.orange)
                }
                Text("Version \(current.description) → \(latest.description)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if appState.ccrUpdateManager.canInstallAvailableUpdate {
                    Button("Update CCR") {
                        confirmCCRUpdate = true
                    }
                } else {
                    Button("Download Update") {
                        appState.openCCRReleases()
                    }
                    Text("CCR Desktop installs its own updates; this opens the official download page.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        case .upToDate(let version):
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("CCR \(version.description) is up to date")
                    .font(.callout)
                Spacer()
                Button("Check Again") {
                    Task {
                        await appState.checkForCCRUpdates()
                    }
                }
                .controlSize(.small)
            }
        case .updating:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Updating CCR…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .updated(let version):
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("CCR Updated")
                    .fontWeight(.semibold)
                Spacer()
                Text("Now using version \(version.description)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("CCR Update Failed")
                        .fontWeight(.semibold)
                }
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let installed = appState.ccrUpdateManager.installedVersion {
                    Text("Installed CCR \(installed.description)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Button("Try Again") {
                    Task {
                        await appState.checkForCCRUpdates()
                    }
                }
            }
        }
    }

    private func openCCRDataFolder() {
        let path = CCRExecutableResolver.ccrDataFolder(home: NSHomeDirectory())
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
