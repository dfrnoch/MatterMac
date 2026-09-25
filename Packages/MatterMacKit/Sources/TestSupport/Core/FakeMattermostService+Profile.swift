public import Foundation
import os
public import MatterMacModels
public import MattermostAPI

/// Scriptable state for own-profile editing, detailed presence and file search.
public struct ProfileFakeState: Sendable {
    public var patches: [UserProfilePatch] = []
    public var patchError: APIError?
    public var uploadedImages: [Data] = []
    public var imageError: APIError?
    public var removedImages = 0
    /// `dnd_end_time` per user, in seconds.
    public var doNotDisturbEnds: [UserID: Date] = [:]
    /// Files returned by `searchFiles`, newest first; `fileSearchHandler` wins when set.
    public var files: [FileInfo] = []
    public var fileSearches: [SearchQuery] = []
    public var fileSearchHandler: (@Sendable (SearchQuery) async throws -> FileSearchPage)?
    /// Picture revisions handed out by uploads and resets.
    public var nextPictureRevision: Int64 = 10_000

    public init() {}
}

extension FakeMattermostService {
    public func withProfile<T: Sendable>(_ body: @Sendable (inout ProfileFakeState) -> T) -> T {
        profileState.withLock { body(&$0) }
    }

    private func noteCall(_ call: String) { withState { $0.calls.append(call) } }

    private func updateMe(_ body: @Sendable (inout User) -> Void) -> User {
        withState { state in
            body(&state.me)
            state.users[state.me.id] = state.me
            return state.me
        }
    }

    public func patchProfile(_ patch: UserProfilePatch, me: UserID) async throws(APIError) -> User {
        noteCall("patchProfile")
        if let error = withProfile({ state -> APIError? in
            state.patches.append(patch)
            return state.patchError
        }) { throw error }
        return updateMe { user in
            if let value = patch.firstName { user.firstName = value }
            if let value = patch.lastName { user.lastName = value }
            if let value = patch.nickname { user.nickname = value }
            if let value = patch.position { user.position = value }
        }
    }

    public func setProfileImage(png: Data, me: UserID) async throws(APIError) {
        noteCall("setProfileImage")
        let result = withProfile { state -> Result<Int64, APIError> in
            if let error = state.imageError { return .failure(error) }
            state.uploadedImages.append(png)
            state.nextPictureRevision += 1
            return .success(state.nextPictureRevision)
        }
        let revision = try result.get()
        _ = updateMe { $0.lastPictureUpdate = MattermostTimestamp(milliseconds: revision) }
    }

    public func removeProfileImage(me: UserID) async throws(APIError) {
        noteCall("removeProfileImage")
        let result = withProfile { state -> Result<Int64, APIError> in
            if let error = state.imageError { return .failure(error) }
            state.removedImages += 1
            state.nextPictureRevision += 1
            return .success(state.nextPictureRevision)
        }
        let revision = try result.get()
        // Like the server: a reset stores the negated time.
        _ = updateMe { $0.lastPictureUpdate = MattermostTimestamp(milliseconds: -revision) }
    }

    public func userStatus(_ id: UserID) async throws(APIError) -> UserStatusDetail {
        noteCall("userStatus")
        let status = withState { $0.statuses[id] ?? .online }
        let end = withProfile { $0.doNotDisturbEnds[id] }
        return UserStatusDetail(userID: id, status: status, isManual: true,
                                doNotDisturbEnd: status == .doNotDisturb ? end : nil)
    }

    public func setDoNotDisturb(until end: Date, me: UserID) async throws(APIError) {
        noteCall("setDoNotDisturb")
        withState { $0.statuses[me] = .doNotDisturb }
        withProfile { $0.doNotDisturbEnds[me] = end }
    }

    public func searchFiles(_ query: SearchQuery) async throws(APIError) -> FileSearchPage {
        noteCall("searchFiles")
        let handler = withProfile { state -> (@Sendable (SearchQuery) async throws -> FileSearchPage)? in
            state.fileSearches.append(query)
            return state.fileSearchHandler
        }
        if let handler { return try await Self.typed { try await handler(query) } }
        let (files, channels) = (withProfile { $0.files }, withState { $0.channels })
        let words = query.terms.lowercased().split(separator: " ").map(String.init)
        let matches = files.filter { file in
            words.allSatisfy { word in
                if word.hasPrefix("in:") {
                    let name = String(word.dropFirst(3))
                    return file.channelID.flatMap { channels[$0]?.name } == name
                }
                if word.hasPrefix("ext:") { return file.fileExtension.lowercased() == word.dropFirst(4) }
                return file.name.lowercased().contains(word)
            }
        }
        let start = max(0, query.page) * max(1, query.perPage)
        guard start < matches.count else { return FileSearchPage(files: []) }
        return FileSearchPage(files: Array(matches[start..<min(matches.count, start + max(1, query.perPage))]))
    }
}
