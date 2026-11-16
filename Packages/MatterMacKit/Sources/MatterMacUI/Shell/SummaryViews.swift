import AppKit
import SwiftUI
import MatterMacModels
import MatterMacCore

extension LocalSettings.AssistantChoice {
    var title: String {
        switch self {
        case .off: String(localized: "Off")
        case .onDevice: String(localized: "On-device model")
        case .claudeAPI: String(localized: "Claude API")
        case .claudeCode: String(localized: "Claude Code")
        case .codex: String(localized: "Codex")
        }
    }
}

/// An assistant summary with its progress, source note and failure, used for the
/// thread popover and the Today sheet. Starts when it appears; closing it cancels.
struct SummaryPanel: View {
    let title: LocalizedStringKey
    let providerName: String
    let load: () async -> Result<AssistantSummary, AssistantFailure>
    var close: (() -> Void)?
    @State private var result: Result<AssistantSummary, AssistantFailure>?
    @State private var attempt = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(title, systemImage: "sparkles").font(.headline)
                Spacer()
                if case .success(let summary) = result {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(summary.text, forType: .string)
                    }
                    .controlSize(.small)
                }
                if result != nil {
                    Button("Again") {
                        result = nil
                        attempt += 1
                    }
                    .controlSize(.small)
                    .help("Ask for a new summary")
                }
                if let close { Button("Done", action: close).controlSize(.small).keyboardShortcut(.cancelAction) }
            }
            switch result {
            case nil:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Summarizing with \(providerName)…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
            case .success(let summary):
                ScrollView {
                    Text(summary.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text(Self.source(summary, providerName: providerName))
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("summarySource")
            case .failure(let failure):
                Label(failure.message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
            }
        }
        .padding(16)
        .task(id: attempt) {
            let loaded = await load()
            if !Task.isCancelled { result = loaded }
        }
    }

    /// "From 42 messages (18 older ones left out) · Claude API. Check anything important."
    static func source(_ summary: AssistantSummary, providerName: String) -> String {
        var text = summary.coveredMessages == 1 ? String(localized: "From 1 message")
                                               : String(localized: "From \(summary.coveredMessages) messages")
        if summary.omittedMessages > 0 {
            text += " " + String(localized: "(\(summary.omittedMessages) more left out to fit)")
        }
        return text + " · " + providerName + ". " + String(localized: "Summaries can be wrong; check anything important.")
    }
}

/// "Summarize" in the thread pane's header.
struct ThreadSummaryButton: View {
    let session: SessionViewModel
    let target: TimelineTarget
    @State private var isPresented = false

    private var root: PostID? {
        if case .thread(let root, _) = target { return root }
        return nil
    }

    var body: some View {
        if let root, let environment = session.app?.environment, environment.settings.assistant != .off {
            Button("Summarize") { isPresented = true }
                .controlSize(.small)
                .glassButtonStyle(prominent: false)
                .help("Summarize this thread with the assistant")
                .accessibilityIdentifier("threadSummaryButton")
                .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                    SummaryPanel(title: "Thread Summary", providerName: environment.settings.assistant.title,
                                 load: { await session.summarizeThread(root: root) })
                        .frame(width: 360)
                        .frame(minHeight: 120, maxHeight: 420)
                }
                .onChange(of: root) { _, _ in isPresented = false }
        }
    }
}

/// Go ▸ Summarize Today.
struct TodaySummarySheet: View {
    let session: SessionViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SummaryPanel(title: "Today", providerName: session.app?.environment.settings.assistant.title ?? "",
                     load: { await session.summarizeToday() }, close: { dismiss() })
            .frame(width: 480)
            .frame(minHeight: 220, maxHeight: 560)
    }
}
