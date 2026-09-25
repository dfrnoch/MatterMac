/// Central resource policy (SPEC §15). Injected into every session and worker; no
/// component invents its own limit. Values are initial engineering budgets, adjustable
/// only with measured evidence (docs/progress.md).
///
/// Byte figures are *estimated* retained cost used for deterministic eviction. They do
/// not replace whole-process physical-footprint measurement.
public struct ResourceBudget: Sendable, Hashable {
    public struct CountAndBytes: Sendable, Hashable {
        public var count: Int
        public var bytes: Int
        public init(count: Int, bytes: Int) {
            self.count = count
            self.bytes = bytes
        }
    }

    /// Active timeline window: ~300 posts, additionally capped by estimated content.
    public var activeTimeline = CountAndBytes(count: 300, bytes: 8 * .mebibyte)
    /// All retained post content across windows, threads, and search, all servers.
    public var retainedPosts = CountAndBytes(count: 2_000, bytes: 16 * .mebibyte)
    /// Compact per-channel window bookkeeping (IDs, gap markers) across all windows.
    public var windowBookkeepingEntries = 20_000
    public var decodedImageEntries = 1_024
    public var imageFailureEntries = 256
    /// Largest single decoded image: a 2048 × 2048 four-byte bitmap (16 MiB) plus the
    /// pipeline's rounding and row-alignment allowance. Only the explicitly opened
    /// image viewer asks for that size; timeline thumbnails use at most 720 px.
    public var maximumDecodedImageBytes = 17 * .mebibyte
    /// Longest decoded edge in pixels (image viewer); callers request less.
    public var maximumImagePixelDimension = 2_048
    public var decodedImageBytes = 32 * .mebibyte
    public var compressedImageBytes = 8 * .mebibyte
    public var compressedImagePerObjectBytes = 2 * .mebibyte
    /// Largest source image (pixels) we are willing to hand to Image I/O at all.
    public var maximumSourceImagePixels = 50_000_000
    public var layoutCache = CountAndBytes(count: 2_000, bytes: 8 * .mebibyte)
    /// Combined draft and pending-send count/text. Never silently LRU-evicted.
    public var unsentText = CountAndBytes(count: 100, bytes: 4 * .mebibyte)
    public var pastedImageBytes = 8 * .mebibyte
    public var directoryDetails = CountAndBytes(count: 5_000, bytes: 8 * .mebibyte)
    /// Saved (`flagged_post` preference) post ids tracked per session. Saves beyond this
    /// are still on the server but show as unsaved here.
    public var savedPostIDs = 5_000
    /// Channel summaries shown in the sidebar, per session.
    public var sidebarChannelsPerSession = 5_000
    public var requestsPerServer = 6
    public var requestsGlobal = 10
    /// Slots of `requestsPerServer` reserved for interactive (user-initiated) requests.
    public var interactiveReservedPerServer = 2
    /// Maximum requests waiting for a slot before new background work is refused.
    public var requestWaitersPerServer = 64
    public var attachmentTransfersGlobal = 2
    public var attachmentsPerPost = 10
    public var attachmentPathBytes = 4 * .kibibyte
    public var imageDecodesGlobal = 2
    public var outstandingImageRequests = 16
    public var webSocketMessageBytes = 2 * .mebibyte
    public var realtimeMailbox = CountAndBytes(count: 512, bytes: 2 * .mebibyte)
    public var diagnosticRingBytes = 256 * .kibibyte
    public var connectedSessions = 3
    public var rememberedAccountBytes = 32 * .kibibyte
    /// One system browser login at a time, with bounded callback size and lifetime.
    public var authenticationProviderLabelBytes = 256
    public var authenticationCallbackBytes = 8 * .kibibyte
    public var authenticationTimeoutSeconds = 180
    /// Default bound for a normal JSON API response body.
    public var apiResponseBytes = 8 * .mebibyte
    /// Bound for small metadata responses (ping, config, me).
    public var smallResponseBytes = 1 * .mebibyte
    /// Search results retained per query.
    public var searchResults = CountAndBytes(count: 200, bytes: 2 * .mebibyte)
    /// Posts retained for one open thread (part of `retainedPosts`).
    public var threadWindow = CountAndBytes(count: 200, bytes: 4 * .mebibyte)
    /// Text the composer accepts from one paste before refusing with an explanation.
    public var maximumPasteBytes = 512 * .kibibyte
    /// Composer undo levels.
    public var composerUndoLevels = 64
    /// Messages longer than this render collapsed with an explicit expand action.
    public var collapsedMessageCharacters = 4_000
    /// Hard ceiling on characters parsed for one message's rich rendering.
    public var maximumRenderedCharacters = 70_000
    public static let maximumRenderedTableRows = 50
    public static let maximumRenderedTableColumns = 10
    public static let maximumRenderedTableCellCharacters = 300

    public init() {}

    public static let standard = ResourceBudget()
}

extension Int {
    public static let kibibyte = 1_024
    public static let mebibyte = 1_048_576
}
