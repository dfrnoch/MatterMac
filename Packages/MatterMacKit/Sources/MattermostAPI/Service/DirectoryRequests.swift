public import MatterMacModels

/// `POST /channels`. The server trims the display name and validates everything
/// again; `ChannelNameRules` mirrors its URL-name rules for immediate feedback.
public struct NewChannelRequest: Sendable, Hashable {
    public var team: TeamID
    public var name: String
    public var displayName: String
    public var purpose: String
    public var isPrivate: Bool

    public init(team: TeamID, name: String, displayName: String, purpose: String = "", isPrivate: Bool) {
        self.team = team
        self.name = name
        self.displayName = displayName
        self.purpose = purpose
        self.isPrivate = isPrivate
    }
}

/// `POST /users/search` scoped to a team (and optionally excluding a channel's
/// members). The server requires a non-empty term and applies its own privacy rules.
public struct UserSearchQuery: Sendable, Hashable {
    public var term: String
    public var team: TeamID
    public var notInChannel: ChannelID?
    public var limit: Int

    public init(term: String, team: TeamID, notInChannel: ChannelID? = nil, limit: Int = 30) {
        self.term = term
        self.team = team
        self.notInChannel = notInChannel
        self.limit = limit
    }
}
