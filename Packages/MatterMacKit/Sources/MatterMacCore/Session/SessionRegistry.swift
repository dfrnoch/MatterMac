public import MatterMacModels
public import MattermostAPI

/// Main-actor registry of connected server sessions (SPEC §3: at most three by
/// default, one account per slot, explicit connect/disconnect). All state is in
/// memory; saved credentials are managed separately by the app.
@MainActor
public final class SessionRegistry {
    public struct Slot: Identifiable, Sendable {
        public let id: ServerSlotID
        public let endpoint: ServerEndpoint
        public let session: ServerSession
        public let user: User
        public let siteName: String
    }

    public enum AddError: Error, Sendable, Hashable {
        case limitReached(Int)
        case alreadyConnected
    }

    public private(set) var slots: [Slot] = []
    public private(set) var activeSlot: ServerSlotID?
    public let dependencies: SessionDependencies
    public let factory: any MattermostServiceFactory
    private var nextSlot: UInt64 = 1
    /// Called whenever slots or the active slot change.
    public var onChange: (() -> Void)?

    public init(dependencies: SessionDependencies, factory: any MattermostServiceFactory) {
        self.dependencies = dependencies
        self.factory = factory
    }

    public var activeSession: ServerSession? { slots.first { $0.id == activeSlot }?.session }
    public var active: Slot? { slots.first { $0.id == activeSlot } }
    public var canAddSession: Bool { slots.count < dependencies.budget.connectedSessions }

    /// Creates and starts a session for an authenticated account and makes it active.
    @discardableResult
    public func add(endpoint: ServerEndpoint, login: LoginResult, capabilities: ServerCapabilities)
        throws(AddError) -> Slot
    {
        guard canAddSession else { throw .limitReached(dependencies.budget.connectedSessions) }
        if slots.contains(where: { $0.endpoint == endpoint && $0.user.id == login.user.id }) { throw .alreadyConnected }
        let slotID = ServerSlotID(nextSlot)
        nextSlot += 1
        let scope = AccountScope(server: slotID, user: login.user.id)
        let service = factory.service(for: endpoint, credential: login.credential)
        let session = ServerSession(scope: scope, endpoint: endpoint, me: login.user, credential: login.credential,
                                    capabilities: capabilities, service: service, dependencies: dependencies)
        let slot = Slot(id: slotID, endpoint: endpoint, session: session, user: login.user,
                        siteName: capabilities.siteName)
        slots.append(slot)
        activate(slotID)
        Task { await session.start() }
        return slot
    }

    public func activate(_ slot: ServerSlotID) {
        guard slots.contains(where: { $0.id == slot }) else { return }
        activeSlot = slot
        dependencies.retention.setActive(slot)
        onChange?()
    }

    /// Disconnects and discards a session. Callers confirm with the user first when
    /// it has unsent work. Returns the honest sign-out outcome.
    public func remove(_ slot: ServerSlotID, revokeServerSession: Bool) async -> SignOutOutcome? {
        guard let index = slots.firstIndex(where: { $0.id == slot }) else { return nil }
        let removed = slots.remove(at: index)
        if activeSlot == slot {
            activeSlot = slots.first?.id
            dependencies.retention.setActive(activeSlot)
        }
        onChange?()
        return await removed.session.shutdown(revokeServerSession: revokeServerSession)
    }

    /// Shuts down every session; normal app termination preserves saved sign-ins.
    public func removeAll(revokeServerSessions: Bool = true) async {
        let all = slots
        slots.removeAll()
        activeSlot = nil
        dependencies.retention.setActive(nil)
        onChange?()
        let sessions = all.map(\.session)
        await withTaskGroup(of: Void.self) { group in
            for session in sessions {
                group.addTask { _ = await session.shutdown(revokeServerSession: revokeServerSessions) }
            }
        }
    }
}
