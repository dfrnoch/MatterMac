import AppKit
public import SwiftUI

extension FocusedValues {
    /// The session shown in the key main window, for menu commands.
    @Entry public var matterMacSession: SessionViewModel?
}

/// Menu commands with their standard shortcuts (SPEC §4 "Interaction rules").
/// Commands act on the focused window's session and are disabled without one.
public struct MatterMacCommands: Commands {
    let environment: AppEnvironment
    @FocusedValue(\.matterMacSession) private var session

    public init(environment: AppEnvironment) {
        self.environment = environment
    }

    public var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About MatterMac") { environment.appModel?.isCompatibilityVisible = true }
        }
        CommandMenu("Format") {
            // Sent to the focused composer; shortcuts are handled there while typing.
            formatItem("Bold", #selector(ComposerTextView.formatBold(_:)), "b", .command)
            formatItem("Italic", #selector(ComposerTextView.formatItalic(_:)), "i", .command)
            formatItem("Strikethrough", #selector(ComposerTextView.formatStrikethrough(_:)), "x", [.command, .shift])
            formatItem("Code", #selector(ComposerTextView.formatCode(_:)), "c", [.command, .option])
            formatItem("Link", #selector(ComposerTextView.formatLink(_:)), "k", [.command, .option])
            Button("Quote") { NSApp.sendAction(#selector(ComposerTextView.formatQuote(_:)), to: nil, from: nil) }
        }
        CommandMenu("Go") {
            Button("Quick Switcher…") { session?.isQuickSwitcherVisible = true }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(session == nil)
            Button("Search Messages…") { session?.isSearchVisible = true }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(session == nil)
            Button("Recent Mentions") { session?.showRecentMentions() }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(session == nil)
            Button("Saved Messages") { session?.showSavedPosts() }
                .disabled(session == nil)
            Divider()
            Button(session?.isChannelInfoVisible == true ? "Hide Channel Info" : "Show Channel Info") {
                session?.isChannelInfoVisible.toggle()
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])
            .disabled(session?.selectedChannel == nil)
            Button(session?.isThreadsViewVisible == true ? "Hide Threads" : "Show Threads") {
                session?.isThreadsViewVisible.toggle()
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])
            .disabled(session == nil)
            Button("Close Thread") { session?.closeThread() }
                .disabled(session?.isThreadVisible != true)
        }
    }

    private func formatItem(_ title: LocalizedStringKey, _ action: Selector, _ key: KeyEquivalent,
                            _ modifiers: EventModifiers) -> some View {
        Button(title) { NSApp.sendAction(action, to: nil, from: nil) }
            .keyboardShortcut(key, modifiers: modifiers)
    }
}
