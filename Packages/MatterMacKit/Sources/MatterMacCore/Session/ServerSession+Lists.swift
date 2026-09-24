import Foundation
public import MatterMacModels
import MattermostAPI

// Recent mentions, saved (flagged) and pinned messages share the bounded search
// result storage and snapshot (SPEC §12: server-side, capped, cancellable).
extension ServerSession {
    static let listPageSize = 20

    public func showRecentMentions() { beginList(.recentMentions) }
    public func showSavedPosts() { beginList(.saved) }
    public func showPinnedPosts(channel: ChannelID) { beginList(.pinned(channel)) }

    func beginList(_ kind: SearchKind) {
        tasks[.search]?.cancel()
        releaseSearchResults()
        searchKind = kind
        searchState.generation &+= 1
        searchState.terms = ""
        searchState.page = 0
        searchState.canLoadMore = false
        searchState.isTruncated = false
        guard isActiveSessionAlive, let team = selectedTeam else {
            searchState.state = .idle
            markDirty(.search)
            return
        }
        searchState.state = .searching
        markDirty(.search)
        runList(kind, team: team, page: 0)
    }

    func runList(_ kind: SearchKind, team: TeamID, page: Int) {
        let generation = searchState.generation
        let offset = Int(deps.timeZone().secondsFromGMT())
        let username = me.username
        run(.search) { session in
            let epoch = session.epoch
            do {
                let result: PostPage
                var pageSize = Self.listPageSize
                switch kind {
                case .terms:
                    return
                case .recentMentions:
                    // The official client searches for the user's @-mention.
                    result = try await session.service.searchPosts(
                        SearchQuery(team: team, terms: "@" + username, isOrSearch: true, timeZoneOffsetSeconds: offset,
                                    page: page, perPage: pageSize))
                case .saved:
                    result = try await session.service.flaggedPosts(me: session.me.id, page: page, perPage: pageSize)
                case .pinned(let channel):
                    result = try await session.service.pinnedPosts(channel: channel)
                    pageSize = .max
                }
                guard session.epoch == epoch, session.searchState.generation == generation else { return }
                session.ingestListResults(result.posts, pageSize: pageSize)
            } catch {
                guard session.epoch == epoch, session.searchState.generation == generation else { return }
                session.handleAuthenticationFailureIfNeeded(error)
                session.searchState.state = .failed(Self.userFacing(error))
                session.markDirty(.search)
            }
        }
    }

    private func ingestListResults(_ posts: [Post], pageSize: Int) {
        let cap = budget.searchResults.count
        for post in posts where searchState.results.count < cap && !post.isDeleted {
            store.upsert(post)
            if !searchState.results.contains(post.id) {
                store.retain(post.id)
                searchState.results.append(post.id)
            }
            if directory.peekUser(post.userID) == nil { missingUsers.insert(post.userID) }
        }
        scheduleUserFetch()
        searchState.isTruncated = searchState.results.count >= cap
        searchState.canLoadMore = posts.count >= pageSize && !searchState.isTruncated
        searchState.state = .results
        enforceRetention()
        markDirty(.search)
    }
}
