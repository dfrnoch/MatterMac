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
        CommandMenu("Go") {
            Button("Quick Switcher…") { session?.isQuickSwitcherVisible = true }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(session == nil)
            Button("Search Messages…") { session?.isSearchVisible = true }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(session == nil)
            Divider()
            Button(session?.isChannelInfoVisible == true ? "Hide Channel Info" : "Show Channel Info") {
                session?.isChannelInfoVisible.toggle()
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])
            .disabled(session?.selectedChannel == nil)
            Button("Close Thread") { session?.closeThread() }
                .disabled(session?.isThreadVisible != true)
        }
    }
}
