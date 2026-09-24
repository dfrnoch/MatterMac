public import MatterMacModels
public import MattermostAPI

/// One logical send, from the moment the user pressed Send until the server confirmed
/// a canonical post or the user discarded it (SPEC §11).
public struct PendingSend: Sendable {
    public enum State: Sendable, Hashable {
        case queued
        case uploading(completed: Int, total: Int)
        case sending
        case failed(UserFacingError)
        /// The POST may have reached the server. `sentAt` is when the attempt began.
        case outcomeUnknown
    }

    public struct Attachment: Sendable, Hashable {
        public let clientID: String
        public let source: UploadSource
        public var uploadedFileID: FileID?
        public init(clientID: String, source: UploadSource, uploadedFileID: FileID? = nil) {
            self.clientID = clientID
            self.source = source
            self.uploadedFileID = uploadedFileID
        }
    }

    public let pendingID: PendingPostID
    public let channelID: ChannelID
    public let rootID: PostID?
    public let message: String
    public var attachments: [Attachment]
    public var state: State
    public let createdAt: MattermostTimestamp
    /// Wall-clock milliseconds of the first POST attempt (dedup window reference).
    public var firstPostAttemptAt: MattermostTimestamp?
    public var postAttempts: Int
    public var automaticRetriesUsed: Int
    var revision: UInt64 = 0
    public let reservation: UnsentWorkLedger.Reservation

    public init(pendingID: PendingPostID, channelID: ChannelID, rootID: PostID?, message: String,
                attachments: [Attachment], createdAt: MattermostTimestamp, reservation: UnsentWorkLedger.Reservation) {
        self.pendingID = pendingID
        self.channelID = channelID
        self.rootID = rootID
        self.message = message
        self.attachments = attachments
        self.state = .queued
        self.createdAt = createdAt
        self.firstPostAttemptAt = nil
        self.postAttempts = 0
        self.automaticRetriesUsed = 0
        self.reservation = reservation
    }

    public var target: TimelineTarget {
        if let rootID { .thread(root: rootID, channel: channelID) } else { .channel(channelID) }
    }

    public var isInFlight: Bool {
        switch state {
        case .uploading, .sending: true
        default: false
        }
    }

    public var presentationState: SendState {
        switch state {
        case .queued: .queued
        case .uploading(let completed, let total): .uploading(completedFiles: completed, totalFiles: total)
        case .sending: .sending
        case .failed(let error): .failed(error)
        case .outcomeUnknown: .outcomeUnknown
        }
    }
}

/// Ordered pending sends for one session with a strict operation limit (enforced by
/// `UnsentWorkLedger`). Never evicts: items leave only through confirmation or an
/// explicit user discard.
public struct PendingSendQueue: Sendable {
    public private(set) var items: [PendingSend] = []
    private var lastIssuedMilliseconds: Int64 = 0

    public init() {}

    public var isEmpty: Bool { items.isEmpty }

    /// A `pending_post_id` unique within this process for `user` (bumps the ms value
    /// on collision, like the official client's `<user_id>:<Date.now()>` scheme).
    public mutating func makePendingID(user: UserID, now: MattermostTimestamp) -> PendingPostID {
        let ms = max(now.milliseconds, lastIssuedMilliseconds + 1)
        lastIssuedMilliseconds = ms
        return PendingPostID(user: user, milliseconds: ms)
    }

    public mutating func append(_ send: PendingSend) { items.append(send) }

    public func item(_ id: PendingPostID) -> PendingSend? { items.first { $0.pendingID == id } }

    public mutating func update(_ id: PendingPostID, _ body: (inout PendingSend) -> Void) {
        guard let index = items.firstIndex(where: { $0.pendingID == id }) else { return }
        body(&items[index])
        items[index].revision &+= 1
    }

    @discardableResult
    public mutating func remove(_ id: PendingPostID) -> PendingSend? {
        guard let index = items.firstIndex(where: { $0.pendingID == id }) else { return nil }
        return items.remove(at: index)
    }

    public func items(for target: TimelineTarget) -> [PendingSend] {
        items.filter { $0.target == target }
    }

    /// Next item that should start an attempt: queued, FIFO.
    public var nextQueued: PendingSend? { items.first { $0.state == .queued } }

    public var hasInFlight: Bool { items.contains(where: \.isInFlight) }

    public mutating func removeAll(channel: ChannelID) -> [PendingSend] {
        let removed = items.filter { $0.channelID == channel }
        items.removeAll { $0.channelID == channel }
        return removed
    }

    public mutating func removeAll() -> [PendingSend] {
        let removed = items
        items.removeAll()
        return removed
    }
}

/// Decides what to do after a POST attempt fails (pure; unit-tested).
public enum SendFailurePolicy {
    /// The server keeps `pending_post_id` in a dedup cache for 30 s (v10.11/v11.11
    /// source). Retrying with the same id inside this margin cannot create a duplicate.
    public static let deduplicationWindowMilliseconds: Int64 = 25_000
    public static let maximumAutomaticRetries = 3

    public enum Decision: Equatable, Sendable {
        /// Retry automatically with the same pending id after the delay.
        case retry(afterMilliseconds: Int64)
        /// Stop; keep the item as failed with this error (user may retry).
        case fail(UserFacingError)
        /// Stop; outcome unknown (user decides, retry may duplicate).
        case unknown
    }

    /// - Parameter serverDeduplicationTrusted: `false` when the server may be an HA
    ///   cluster (licensed `Cluster` feature): the default dedup cache is per node, so a
    ///   retry could land on another node and duplicate. Then the user decides.
    public static func decide(error: APIError, firstAttemptAt: MattermostTimestamp, now: MattermostTimestamp,
                              automaticRetriesUsed: Int, serverDeduplicationTrusted: Bool = true) -> Decision {
        let withinDedupWindow = serverDeduplicationTrusted
            && now.milliseconds - firstAttemptAt.milliseconds < deduplicationWindowMilliseconds
        let retriesLeft = automaticRetriesUsed < maximumAutomaticRetries
        switch error {
        case .outcomeUnknown:
            // Same pending id inside the window: the server returns the existing post
            // if the first attempt succeeded, otherwise creates it once.
            return withinDedupWindow && retriesLeft ? .retry(afterMilliseconds: 1_500) : .unknown
        case .server(let info) where info.id == ServerErrorID.deduplicatePending:
            // First attempt still being saved on the server.
            return withinDedupWindow && retriesLeft ? .retry(afterMilliseconds: 1_000) : .unknown
        case .notSent(let failure):
            return .fail(Self.userFacing(failure))
        case .rateLimited(let seconds):
            if retriesLeft, let seconds, seconds <= 30 { return .retry(afterMilliseconds: Int64(seconds) * 1_000) }
            return .fail(.rateLimited(retryAfterSeconds: seconds))
        case .server:
            // A 5xx after the request was processed may or may not have created the post.
            return withinDedupWindow && retriesLeft ? .retry(afterMilliseconds: 2_000) : .unknown
        case .unauthorized:
            return .fail(.authenticationRequired)
        case .forbidden:
            return .fail(.permissionDenied)
        case .notFound:
            return .fail(.notFoundOrInaccessible)
        case .badRequest(let info):
            if info.id == ServerErrorID.messageTooLong { return .fail(.messageTooLong(limitCharacters: 0)) }
            if info.id == ServerErrorID.deletedChannel { return .fail(.permissionDenied) }
            if info.id == ServerErrorID.rootIDInvalid { return .fail(.notFoundOrInaccessible) }
            return .fail(.serverError(status: 400))
        case .payloadTooLarge:
            return .fail(.payloadTooLarge(limitBytes: 0))
        case .cancelled:
            return .fail(.cancelled)
        case .responseTooLarge, .malformedResponse:
            // The server answered; a post may exist. Do not claim failure or success.
            return .unknown
        case .redirectRefused:
            return .fail(.serverUnreachable)
        case .overloaded:
            return retriesLeft ? .retry(afterMilliseconds: 500) : .fail(.serverUnreachable)
        case .notImplemented:
            return .fail(.unsupportedCapability("posting"))
        case .unexpectedStatus(let status):
            return .fail(.serverError(status: status))
        case .localFileUnavailable:
            return .fail(.fileUnavailable)
        }
    }

    public static func userFacing(_ failure: TransportFailure) -> UserFacingError {
        switch failure {
        case .offline: .offline
        case .timedOut: .timedOut
        case .tlsFailure: .tlsFailure
        case .cannotConnect, .dnsFailure, .connectionLost, .other: .serverUnreachable
        }
    }
}
