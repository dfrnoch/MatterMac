public import MatterMacModels
import MattermostAPI

/// Scheduled messages (`/posts/schedule`). The server keeps and sends them, so they go
/// out even while MatterMac is closed. Only licensed servers with
/// `ServiceSettings.ScheduledPosts` on offer them; others answer 400 and the feature
/// is reported unavailable instead of failing each time.
extension ServerSession {
    /// Earliest time accepted from now: the server rejects past times, and a short lead
    /// keeps clock skew from turning a "send later" into an error.
    public static let minimumScheduleLeadMilliseconds: Int64 = 60_000

    /// `nil` until the server answered once; `false` after a "disabled/unlicensed" answer.
    public var schedulingAvailable: Bool? { scheduledPostsAvailable }

    public func scheduleMessage(_ text: String, channel: ChannelID, rootID: PostID?, at time: MattermostTimestamp)
        async throws(UserFacingError) -> ScheduledPost {
        guard isActiveSessionAlive else { throw .authenticationRequired }
        guard scheduledPostsAvailable != false else { throw Self.schedulingUnsupported }
        guard directory.memberships[channel] != nil else { throw .notFoundOrInaccessible }
        guard time.milliseconds >= now().milliseconds + Self.minimumScheduleLeadMilliseconds / 2 else {
            throw .unsupportedCapability(String(localized: "scheduling a message in the past"))
        }
        let epoch = epoch
        let post: ScheduledPost
        do {
            post = try await service.createScheduledPost(channel: channel, rootID: rootID, message: text, at: time)
        } catch {
            throw scheduledFailure(error)
        }
        guard self.epoch == epoch, isActiveSessionAlive else { throw .cancelled }
        scheduledPostsAvailable = true
        deps.diagnostics.record(.send, .info, "message scheduled")
        return post
    }

    /// The user's scheduled messages in the selected team and in direct/group messages,
    /// soonest first, limited to conversations the session knows.
    public func scheduledMessages() async throws(UserFacingError) -> [ScheduledPost] {
        guard isActiveSessionAlive else { throw .authenticationRequired }
        guard scheduledPostsAvailable != false else { throw Self.schedulingUnsupported }
        guard let team = selectedTeam else { return [] }
        let epoch = epoch
        let posts: [ScheduledPost]
        do {
            posts = try await service.scheduledPosts(team: team)
        } catch {
            throw scheduledFailure(error)
        }
        guard self.epoch == epoch, isActiveSessionAlive else { throw .cancelled }
        scheduledPostsAvailable = true
        return posts.filter { directory.memberships[$0.channelID] != nil }
    }

    public func reschedule(_ post: ScheduledPost, at time: MattermostTimestamp) async throws(UserFacingError) -> ScheduledPost {
        guard isActiveSessionAlive else { throw .authenticationRequired }
        guard time.milliseconds >= now().milliseconds + Self.minimumScheduleLeadMilliseconds / 2 else {
            throw .unsupportedCapability(String(localized: "scheduling a message in the past"))
        }
        var updated = post
        updated.scheduledAt = time
        do {
            return try await service.updateScheduledPost(updated)
        } catch {
            throw scheduledFailure(error)
        }
    }

    public func deleteScheduled(_ id: ScheduledPostID) async throws(UserFacingError) {
        guard isActiveSessionAlive else { throw .authenticationRequired }
        do {
            try await service.deleteScheduledPost(id)
        } catch {
            throw scheduledFailure(error)
        }
    }

    public static var schedulingUnsupported: UserFacingError {
        .unsupportedCapability(String(localized: "scheduled messages"))
    }

    private func scheduledFailure(_ error: APIError) -> UserFacingError {
        handleAuthenticationFailureIfNeeded(error)
        if case .badRequest(let info) = error, info.id.hasPrefix("api.scheduled_posts.") {
            scheduledPostsAvailable = false
            return Self.schedulingUnsupported
        }
        // Servers before 10.3 have no such route (the generic "not found" handler).
        if case .notFound(let info) = error, info.id == "api.context.404.app_error" {
            scheduledPostsAvailable = false
            return Self.schedulingUnsupported
        }
        if case .notImplemented = error {
            scheduledPostsAvailable = false
            return Self.schedulingUnsupported
        }
        return Self.userFacing(error)
    }
}
