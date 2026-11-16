public import Foundation
public import MatterMacModels
public import MatterMacCore

extension SessionViewModel {
    /// Scheduled messages shown in a pane: a thread's, or a channel's (replies included).
    public func scheduledPosts(for target: TimelineTarget) -> [ScheduledPost] {
        switch target {
        case .channel(let channel): scheduledPosts.filter { $0.channelID == channel }
        case .thread(let root, let channel): scheduledPosts.filter { $0.channelID == channel && $0.rootID == root }
        }
    }

    /// Reloads the list now, then once more shortly after the soonest message is due
    /// (the server sends it; the list should drop it). One refresh task at a time.
    public func refreshScheduledPosts() {
        guard !isDetached, !requiresAuthentication, schedulingAvailable != false else { return }
        scheduledRefreshTask?.cancel()
        scheduledRefreshTask = Task { [weak self] in
            guard let session = self?.session else { return }
            while !Task.isCancelled {
                let posts: [ScheduledPost]
                do throws(UserFacingError) {
                    posts = try await session.scheduledMessages()
                } catch {
                    if !Task.isCancelled, error == ServerSession.schedulingUnsupported {
                        self?.schedulingAvailable = false
                        self?.scheduledPosts = []
                    }
                    return
                }
                guard !Task.isCancelled, let self else { return }
                schedulingAvailable = true
                if scheduledPosts != posts { scheduledPosts = posts }
                let now = Date().timeIntervalSince1970 * 1_000
                guard let next = posts.first(where: { !$0.hasFailed && Double($0.scheduledAt.milliseconds) > now - 60_000 })
                else { return }
                let wait = max(30, (Double(next.scheduledAt.milliseconds) - now) / 1_000 + 90)
                try? await Task.sleep(for: .seconds(min(wait, 6 * 3_600)))
            }
        }
    }

    public func deleteScheduled(_ post: ScheduledPost) {
        scheduledPosts.removeAll { $0.id == post.id }
        Task {
            do throws(UserFacingError) { try await session.deleteScheduled(post.id) } catch {
                if error != .cancelled { inlineError = UserFacingErrorText.describe(error) }
            }
            refreshScheduledPosts()
        }
    }

    public func reschedule(_ post: ScheduledPost, to date: Date) {
        Task {
            do throws(UserFacingError) { _ = try await session.reschedule(post, at: MattermostTimestamp(date: date)) } catch {
                if error != .cancelled { inlineError = UserFacingErrorText.describe(error) }
            }
            refreshScheduledPosts()
        }
    }

    /// Records a newly scheduled message without waiting for the next list refresh.
    func didSchedule(_ post: ScheduledPost) {
        schedulingAvailable = true
        scheduledPosts = (scheduledPosts.filter { $0.id != post.id } + [post]).sorted { $0.scheduledAt < $1.scheduledAt }
        refreshScheduledPosts()
    }
}
