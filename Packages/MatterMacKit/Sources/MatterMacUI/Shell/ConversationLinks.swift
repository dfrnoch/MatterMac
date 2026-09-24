import AppKit
import MatterMacModels
import MatterMacCore

extension SessionViewModel {
    /// Opens a permalink, channel or direct-message link for this server inside the
    /// app: the channel is selected and focused on the linked post. Only channels the
    /// user belongs to are opened; nothing is joined implicitly.
    func open(_ link: MattermostLink) {
        guard !isDetached, !requiresAuthentication else { return }
        Task {
            do throws(UserFacingError) {
                let destination = try await session.resolve(link)
                guard !isDetached else { return }
                switch destination {
                case .channel(let channel, let post): select(channel: channel, focusing: post)
                case .directMessage(let user): openDirectMessage(with: user)
                }
            } catch {
                guard !isDetached, error != .cancelled else { return }
                inlineError = error == .notFoundOrInaccessible
                    ? String(localized: "That message or channel isn’t available: it was deleted, or you aren’t a member of its channel.")
                    : UserFacingErrorText.describe(error)
            }
        }
    }
}
