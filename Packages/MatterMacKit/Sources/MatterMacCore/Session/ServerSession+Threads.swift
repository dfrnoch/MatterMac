import Foundation
public import MatterMacModels
import MattermostAPI

// Followed threads for collapsed reply threads (CRT), docs/research/posts.md §6.
// Pages are fetched on demand and returned to the caller; only unread totals are
// kept here. Participants and authors go into the bounded directory.
extension ServerSession {
    public static let threadsPageSize = 25

    /// Refreshes the unread totals (coalesced; one request at a time).
    func refreshThreadTotals() {
        guard isActiveSessionAlive else { return }
        threadTotalsPending = true
        guard !isRunning(.threadTotals) else { return }
        run(.threadTotals) { session in
            let epoch = session.epoch
            while session.threadTotalsPending, session.epoch == epoch, !Task.isCancelled {
                // Coalesce bursts without losing events arriving during the request.
                try? await session.deps.clock.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                session.threadTotalsPending = false
                guard session.collapsedThreadsActive, let team = session.selectedTeam else {
                    session.publishThreadActivity(unreadThreads: 0, unreadMentions: 0)
                    continue
                }
                guard let list = try? await session.service.userThreads(team: team, me: session.me.id, before: nil,
                                                                        perPage: 1, unreadOnly: false, totalsOnly: true),
                      session.epoch == epoch, !Task.isCancelled, session.selectedTeam == team else { continue }
                session.publishThreadActivity(unreadThreads: list.totalUnreadThreads, unreadMentions: list.totalUnreadMentions)
            }
        }
    }

    /// `changed` bumps the revision (views refetch); plain fetches only update totals,
    /// so a view that reloads on revision changes cannot loop.
    func publishThreadActivity(unreadThreads: Int, unreadMentions: Int, changed: Bool = true) {
        if changed { threadActivityRevision &+= 1 }
        threadActivityContinuation.yield(ThreadActivity(
            scope: scope, revision: threadActivityRevision, isAvailable: collapsedThreadsActive,
            unreadThreads: unreadThreads, unreadMentions: unreadMentions))
    }

    public var threadsAvailable: Bool { collapsedThreadsActive }

    public func followedThreads(unreadOnly: Bool, before: PostID?) async throws(UserFacingError) -> ThreadsPage {
        guard isActiveSessionAlive else { throw .authenticationRequired }
        guard collapsedThreadsActive else { throw .unsupportedCapability(String(localized: "collapsed reply threads")) }
        guard let team = selectedTeam else { throw .notFoundOrInaccessible }
        let epoch = epoch
        let list: UserThreadList
        do {
            list = try await service.userThreads(team: team, me: me.id, before: before, perPage: Self.threadsPageSize,
                                                 unreadOnly: unreadOnly, totalsOnly: false)
        } catch {
            handleAuthenticationFailureIfNeeded(error)
            throw Self.userFacing(error)
        }
        guard self.epoch == epoch, isActiveSessionAlive, selectedTeam == team, !Task.isCancelled else { throw .cancelled }
        var missing = Set<UserID>()
        let summaries = list.threads.map { thread -> ThreadSummary in
            for user in thread.participants { directory.upsertUser(user) }
            let root = thread.root
            if directory.peekUser(root.userID) == nil { missing.insert(root.userID) }
            let author = directory.peekUser(root.userID)
            let channel = directory.channels[root.channelID]
            let preview = deps.documents.document(for: root).plainText
            return ThreadSummary(
                rootID: root.id, channelID: root.channelID,
                channelName: channel.map { displayName(of: $0) } ?? String(localized: "Unavailable channel"),
                authorID: root.userID,
                authorName: root.props.overrideUsername ?? author.map { directory.nameFormat.displayName(for: $0) } ?? "",
                authorAvatarRevision: author?.lastPictureUpdate.milliseconds ?? 0,
                preview: String(preview.prefix(280)), replyCount: thread.replyCount, lastReplyAt: thread.lastReplyAt,
                unreadReplies: thread.unreadReplies, unreadMentions: thread.unreadMentions,
                participants: thread.participants.prefix(5).map {
                    .init(id: $0.id, name: directory.nameFormat.displayName(for: $0),
                          avatarRevision: $0.lastPictureUpdate.milliseconds)
                })
        }
        if !missing.isEmpty {
            missingUsers.formUnion(missing)
            scheduleUserFetch()
        }
        publishThreadActivity(unreadThreads: list.totalUnreadThreads, unreadMentions: list.totalUnreadMentions,
                              changed: false)
        return ThreadsPage(threads: summaries, hasMore: list.threads.count >= Self.threadsPageSize,
                           unreadThreads: list.totalUnreadThreads, unreadMentions: list.totalUnreadMentions)
    }

    /// Whether the user follows the thread; `nil` when unknown or threads are off.
    public func isFollowingThread(_ root: PostID) async -> Bool? {
        guard isActiveSessionAlive, collapsedThreadsActive, let team = selectedTeam else { return nil }
        let epoch = epoch
        do {
            let thread = try await service.userThread(root, team: team, me: me.id)
            guard self.epoch == epoch, isActiveSessionAlive, selectedTeam == team, !Task.isCancelled else { return nil }
            return thread != nil
        } catch {
            return nil
        }
    }

    public func setThreadFollowing(_ root: PostID, _ following: Bool) async throws(UserFacingError) {
        guard isActiveSessionAlive else { throw .authenticationRequired }
        guard let team = selectedTeam else { throw .notFoundOrInaccessible }
        do {
            try await service.setThreadFollowing(root, following: following, team: team, me: me.id)
        } catch {
            handleAuthenticationFailureIfNeeded(error)
            throw Self.userFacing(error)
        }
        refreshThreadTotals()
    }

    /// Explicit "mark as read" for one thread, or all followed threads of the team.
    public func markThreadRead(_ root: PostID?) async throws(UserFacingError) {
        guard isActiveSessionAlive else { throw .authenticationRequired }
        guard let team = selectedTeam else { throw .notFoundOrInaccessible }
        do {
            try await service.markThreadRead(root, at: now(), team: team, me: me.id)
        } catch {
            handleAuthenticationFailureIfNeeded(error)
            throw Self.userFacing(error)
        }
        refreshThreadTotals()
    }
}
