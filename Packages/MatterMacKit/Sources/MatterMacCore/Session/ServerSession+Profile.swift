public import Foundation
public import MatterMacModels
public import MattermostAPI

extension ServerSession {
    public func updateProfile(_ patch: UserProfilePatch) async throws(UserFacingError) -> User {
        guard isActiveSessionAlive else { throw .authenticationRequired }
        guard patch.fieldOverLimit == nil else { throw .malformedServerData }
        guard !patch.isEmpty else { return me }
        let epoch = epoch
        do throws(APIError) {
            let user = try await service.patchProfile(patch, me: me.id)
            guard self.epoch == epoch, isActiveSessionAlive else { throw APIError.cancelled }
            guard user.id == me.id else { throw APIError.malformedResponse }
            adoptCurrentUser(user)
            markDirty([.sidebar, .timeline, .thread, .header, .search])
            return user
        } catch {
            handleAuthenticationFailureIfNeeded(error)
            if error == .unexpectedStatus(409) { throw .profileFieldLocked }
            throw Self.userFacing(error)
        }
    }
    public func updateProfilePicture(_ png: Data?) async throws(UserFacingError) -> User {
        guard isActiveSessionAlive else { throw .authenticationRequired }
        let epoch = epoch
        do throws(APIError) {
            if let png { try await service.setProfileImage(png: png, me: me.id) }
            else { try await service.removeProfileImage(me: me.id) }
            guard self.epoch == epoch, isActiveSessionAlive else { throw .cancelled }
            // The mutation succeeded even if the refresh fails. Invalidate the old
            // avatar immediately; the next user update supplies the server revision.
            let revision = max(min(me.lastPictureUpdate.milliseconds, Int64.max - 1) + 1, Int64(Date.now.timeIntervalSince1970 * 1_000))
            me.lastPictureUpdate = MattermostTimestamp(milliseconds: png == nil ? -revision : revision)
            directory.pin(me)
            markDirty([.sidebar, .timeline, .thread, .search])
            if let user = try? await service.currentUser(), self.epoch == epoch, isActiveSessionAlive, user.id == me.id {
                adoptCurrentUser(user)
                markDirty([.sidebar, .timeline, .thread, .search])
            }
            return me
        } catch {
            handleAuthenticationFailureIfNeeded(error)
            if error == .unexpectedStatus(409) { throw .profileFieldLocked }
            throw Self.userFacing(error)
        }
    }

}
