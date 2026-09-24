public import Foundation

/// The injectable network boundary used by `MattermostHTTPClient` and
/// `MattermostDiscoveryClient` (SPEC §9). The production implementation is
/// `URLSessionTransport`; TestSupport provides `FakeHTTPTransport`.
///
/// Contract for every method:
/// - Non-2xx responses are returned (with a body of at most
///   `limits.maximumErrorBodyBytes`), never thrown.
/// - Thrown errors are transport-level only: `.notSent`, `.outcomeUnknown`,
///   `.cancelled`, `.responseTooLarge`, `.redirectRefused`, `.localFileUnavailable`.
/// - Task cancellation cancels the network operation and throws `.cancelled`.
/// - Bodies are bounded *while* they are received: a response whose declared or
///   actual (decompressed) size exceeds `limits.maximumBodyBytes` is cancelled and
///   fails with `.responseTooLarge`.
public protocol HTTPTransport: Sendable {
    /// Sends a request whose response body is buffered in memory (bounded).
    func send(_ request: HTTPRequest, limits: ResponseLimits) async throws(APIError) -> HTTPResponse

    /// Streams `file` as the raw request body (no copy, no staging, no full read into
    /// memory). `Content-Length` is `file.expectedLength`. The file is monitored for
    /// changes while it is sent; any change fails the upload with
    /// `.localFileUnavailable`.
    func upload(_ request: HTTPRequest, file: UploadFile, limits: ResponseLimits,
                progress: @escaping @Sendable (TransferProgress) -> Void) async throws(APIError) -> HTTPResponse

    /// Streams a 2xx response body into `handle` in chunks of at most
    /// `URLSessionTransport.maximumWriteChunkBytes`. Nothing is written for non-2xx
    /// responses. The returned response has an empty body on success. The caller
    /// owns `handle` (and removes partial output on failure).
    func download(_ request: HTTPRequest, to handle: FileHandle, limits: ResponseLimits,
                  progress: @escaping @Sendable (TransferProgress) -> Void) async throws(APIError) -> HTTPResponse

    /// Cancels outstanding work and releases network resources. Subsequent calls
    /// fail with `.cancelled`. Idempotent.
    func shutdown() async
}
