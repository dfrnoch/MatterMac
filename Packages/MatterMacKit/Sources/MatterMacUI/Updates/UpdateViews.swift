import SwiftUI
import MatterMacPlatform

/// "MatterMac 1.0.1 is ready" with Restart to Update, and update notices.
struct UpdateBanner: View {
    let updater: AppUpdater

    var body: some View {
        if let label = updater.bannerLabel {
            FloatingBanner(tone: .info, systemImage: "arrow.down.circle",
                           message: String(localized: "MatterMac \(label) is ready to install.")) {
                HStack {
                    Button("Release Notes") { updater.openReleaseNotes() }
                    Button("Later") { updater.dismissBanner() }
                    if case .installing = updater.phase {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Restart to Update") { updater.restartToUpdate() }
                            .glassButtonStyle(prominent: true)
                    }
                }
            }
            .accessibilityIdentifier("updateBanner")
            .transition(.move(edge: .top).combined(with: .opacity))
        } else if let notice = updater.notice {
            FloatingBanner(tone: updater.offersDiskImage ? .warning : .info, systemImage: "arrow.down.circle",
                           message: notice) {
                HStack {
                    if updater.offersDiskImage {
                        Button("Download Disk Image") { updater.downloadDiskImage() }
                    }
                    Button("Dismiss") { updater.dismissNotice() }
                }
            }
            .accessibilityIdentifier("updateNotice")
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

/// Settings › General › Updates.
struct UpdateSettingsSection: View {
    let environment: AppEnvironment

    var body: some View {
        Section {
            if let updater = environment.updater {
                Toggle("Check for updates automatically", isOn: Binding(
                    get: { environment.settings.checksForUpdates },
                    set: { environment.settings.checksForUpdates = $0 }))
                    .accessibilityIdentifier("automaticUpdatesToggle")
                Picker("Update channel", selection: Binding(get: { updater.channel }, set: { updater.channel = $0 })) {
                    Text("Stable").tag(UpdateChannel.stable)
                    Text("Nightly").tag(UpdateChannel.nightly)
                }
                .accessibilityIdentifier("updateChannelPicker")
                Text(updater.channel == .stable
                     ? "Production releases only."
                     : "Nightly builds of the latest development version, and production releases.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Installed version") {
                    Text(verbatim: "\(updater.configuration.currentLabel) (\(updater.configuration.currentBuild))")
                        .textSelection(.enabled)
                }
                HStack {
                    Text(status(updater)).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Check Now") { updater.check(userInitiated: true) }
                        .disabled(updater.phase == .checking)
                        .accessibilityIdentifier("checkForUpdatesButton")
                }
                Text("Checking contacts github.com; no account or message data is sent.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("This build does not update itself. Release builds from GitHub do.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            VStack(alignment: .leading, spacing: 2) {
                Label("Updates", systemImage: "arrow.down.circle")
                Text("From MatterMac's releases on GitHub; saved on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func status(_ updater: AppUpdater) -> String {
        switch updater.phase {
        case .idle: return String(localized: "Not checked yet.")
        case .checking: return String(localized: "Checking…")
        case .upToDate(let date):
            return String(localized: "Up to date. Last checked \(date.formatted(date: .omitted, time: .shortened)).")
        case .downloading(let label): return String(localized: "Downloading \(label)…")
        case .ready(let label): return String(localized: "\(label) is ready: restart MatterMac to install it.")
        case .installing(let label): return String(localized: "Installing \(label)…")
        case .failed(let message): return message
        }
    }
}
