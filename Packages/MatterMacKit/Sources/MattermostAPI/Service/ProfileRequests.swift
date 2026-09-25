public import Foundation
public import MatterMacModels

// Own-profile editing, detailed presence and file search values
// (docs/decisions/0026-profile-editing-and-file-search.md).

/// Profile fields to change with `PUT /users/{id}/patch`; `nil` fields are not sent,
/// so the server keeps them (and every other user field) unchanged.
public struct UserProfilePatch: Sendable, Hashable {
    public var firstName: String?
    public var lastName: String?
    public var nickname: String?
    public var position: String?

    public init(firstName: String? = nil, lastName: String? = nil, nickname: String? = nil, position: String? = nil) {
        self.firstName = firstName
        self.lastName = lastName
        self.nickname = nickname
        self.position = position
    }

    public var isEmpty: Bool { firstName == nil && lastName == nil && nickname == nil && position == nil }

    /// Server limits in Unicode scalars (`model/user.go`, identical in 10.11 and 11.11).
    public static let firstNameLimit = 64
    public static let lastNameLimit = 64
    public static let nicknameLimit = 64
    public static let positionLimit = 128

    public enum Field: Sendable, Hashable, CaseIterable {
        case firstName, lastName, nickname, position

        public var limit: Int {
            switch self {
            case .firstName: UserProfilePatch.firstNameLimit
            case .lastName: UserProfilePatch.lastNameLimit
            case .nickname: UserProfilePatch.nicknameLimit
            case .position: UserProfilePatch.positionLimit
            }
        }
    }

    public subscript(field: Field) -> String? {
        switch field {
        case .firstName: firstName
        case .lastName: lastName
        case .nickname: nickname
        case .position: position
        }
    }

    /// The first field over its server limit.
    public var fieldOverLimit: Field? {
        Field.allCases.first { (self[$0]?.unicodeScalars.count ?? 0) > $0.limit }
    }
}

/// One user's presence as `GET /users/{id}/status` reports it.
public struct UserStatusDetail: Sendable, Hashable {
    public let userID: UserID
    public let status: PresenceStatus
    public let isManual: Bool
    /// When a timed Do Not Disturb ends (`dnd_end_time`); `nil` without an end.
    public let doNotDisturbEnd: Date?

    public init(userID: UserID, status: PresenceStatus, isManual: Bool = false, doNotDisturbEnd: Date? = nil) {
        self.userID = userID
        self.status = status
        self.isManual = isManual
        self.doNotDisturbEnd = doNotDisturbEnd
    }
}

/// One page of `POST /teams/{id}/files/search`, in the server's order (newest first).
public struct FileSearchPage: Sendable, Hashable {
    public let files: [FileInfo]
    /// Entries in the response that were malformed or not listed in `order`.
    public let skippedMalformed: Int

    public init(files: [FileInfo], skippedMalformed: Int = 0) {
        self.files = files
        self.skippedMalformed = skippedMalformed
    }
}
