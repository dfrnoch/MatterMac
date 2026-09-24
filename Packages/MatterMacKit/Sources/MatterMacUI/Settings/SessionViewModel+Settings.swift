import AppKit
import SwiftUI
public import MatterMacModels
public import MatterMacCore

/// Explicit server-side setting changes for the Settings window and the channel
/// "Notification Preferences…" sheet. Each call is one user action; errors are
/// returned to the caller so they can be shown next to the control.
extension SessionViewModel {
    var canChangeServerSettings: Bool { !isDetached && !requiresAuthentication }

    func setAlertPreviews(_ enabled: Bool) {
        guard !isDetached else { return }
        let session = session
        Task { await session.setAlertPreviews(enabled) }
    }

    public func setMilitaryTime(_ enabled: Bool) async throws(UserFacingError) {
        guard canChangeServerSettings else { throw .authenticationRequired }
        try await session.setMilitaryTime(enabled)
    }

    public func setNameFormat(_ format: NameFormat) async throws(UserFacingError) {
        guard canChangeServerSettings else { throw .authenticationRequired }
        try await session.setNameFormat(format)
    }

    public func setCollapsedThreads(_ enabled: Bool) async throws(UserFacingError) {
        guard canChangeServerSettings else { throw .authenticationRequired }
        try await session.setCollapsedThreads(enabled)
    }

    public func updateAccountNotifications(_ change: @escaping @Sendable (inout UserNotifyProps) -> Void)
        async throws(UserFacingError) {
        guard canChangeServerSettings else { throw .authenticationRequired }
        try await session.updateAccountNotifications(change)
    }

    public func channelNotificationPreferences(_ channel: ChannelID) async throws(UserFacingError)
        -> ChannelNotificationPreferences {
        guard canChangeServerSettings else { throw .authenticationRequired }
        return try await session.channelNotificationPreferences(channel)
    }

    public func setChannelNotificationPreferences(_ channel: ChannelID, desktop: ChannelDesktopLevel, muted: Bool,
                                                  ignoreChannelMentions: IgnoreChannelMentions) async throws(UserFacingError) {
        guard canChangeServerSettings else { throw .authenticationRequired }
        try await session.setChannelNotificationPreferences(channel, desktop: desktop, muted: muted,
                                                            ignoreChannelMentions: ignoreChannelMentions)
        channelInfoRevision &+= 1
    }

    /// Presents "Notification Preferences…" for a channel as a sheet on the main window.
    public func showNotificationPreferences(_ channel: ChannelID) {
        guard canChangeServerSettings else { return }
        ChannelNotificationSheet.present(session: self, channel: channel)
    }
}
