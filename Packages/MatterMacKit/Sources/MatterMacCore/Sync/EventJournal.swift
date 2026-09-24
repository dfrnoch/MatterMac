public import MatterMacModels

/// A bounded journal of recently applied durable post events, used to close the
/// REST-snapshot/WebSocket race (SPEC §10): a history request records the journal
/// position when it starts; when its (possibly older) response is merged, every
/// journaled event after that position that touches a post in the response is
/// re-applied. If the journal wrapped past the request's start position, the caller
/// cannot prove the response is current and must mark the window stale instead.
public struct EventJournal: Sendable {
    public enum Record: Sendable {
        case upsert(Post)
        case deleted(PostID, rootOf: PostID?, at: MattermostTimestamp)
        case reaction(Reaction, added: Bool)

        public var postID: PostID {
            switch self {
            case .upsert(let post): post.id
            case .deleted(let id, _, _): id
            case .reaction(let reaction, _): reaction.postID
            }
        }
    }

    public let capacity: Int
    private var records: [(position: UInt64, record: Record)] = []
    private var head = 0
    /// Position of the most recently appended record (0 = none yet).
    public private(set) var position: UInt64 = 0

    public init(capacity: Int = 256) {
        precondition(capacity > 0)
        self.capacity = capacity
        records.reserveCapacity(capacity)
    }

    public mutating func append(_ record: Record) {
        position &+= 1
        if records.count < capacity {
            records.append((position, record))
        } else {
            records[head] = (position, record)
            head = (head + 1) % capacity
        }
    }

    /// Oldest position still retained (nil if empty).
    public var oldestPosition: UInt64? {
        guard !records.isEmpty else { return nil }
        return records.count < capacity ? records[0].position : records[head].position
    }

    /// Records strictly after `start`, oldest first; `nil` if some were already
    /// overwritten (the journal cannot vouch for the gap).
    public func records(after start: UInt64) -> [Record]? {
        guard start < position else { return [] }
        if let oldest = oldestPosition, oldest > start + 1 { return nil }
        let ordered: [(position: UInt64, record: Record)] = records.count < capacity
            ? records
            : Array(records[head...] + records[..<head])
        return ordered.filter { $0.position > start }.map(\.record)
    }

    public mutating func removeAll() {
        records.removeAll(keepingCapacity: true)
        head = 0
    }
}
