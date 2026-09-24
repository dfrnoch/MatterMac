public import AppKit
public import AuthenticationServices
public import MatterMacCore
public import MatterMacModels

/// One scoped system-browser session. The callback scheme is used only inside
/// ASWebAuthenticationSession: no global URL handler or Info.plist claim is added.
@MainActor
public final class BrowserAuthentication: NSObject, ASWebAuthenticationPresentationContextProviding {
    private static weak var active: BrowserAuthentication?
    private let budget: ResourceBudget
    private var session: ASWebAuthenticationSession?
    private var anchor: NSWindow?
    private var attempt: BrowserLoginAttempt?
    private var continuation: CheckedContinuation<Result<URL, BrowserLoginError>, Never>?
    private var timeout: Task<Void, Never>?
    private var hasStarted = false

    public init(budget: ResourceBudget = .standard) { self.budget = budget }

    public func authenticate(_ attempt: BrowserLoginAttempt, anchor: NSWindow) async throws(BrowserLoginError) -> URL {
        guard Self.active == nil, !hasStarted else { throw .browserUnavailable }
        guard !Task.isCancelled else { throw .cancelled }
        hasStarted = true
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                self.attempt = attempt; self.anchor = anchor
                Self.active = self
                start(attempt)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
        return try result.get()
    }

    public func cancel() { finish(.failure(.cancelled)) }

    public func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchor ?? NSWindow()
    }

    private func start(_ attempt: BrowserLoginAttempt) {
        timeout = Task { [weak self, budget] in
            do { try await Task.sleep(for: .seconds(budget.authenticationTimeoutSeconds)) } catch { return }
            self?.finish(.failure(.timedOut))
        }
        let completion: ASWebAuthenticationSession.CompletionHandler = { [weak self] callback, error in
            Task { @MainActor in
                guard let self, self.continuation != nil else { return }
                if let callback { self.finish(.success(callback)) }
                else {
                    let cancelled = (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin
                    self.finish(.failure(cancelled ? .cancelled : .browserUnavailable))
                }
            }
        }
        let session: ASWebAuthenticationSession
        if #available(macOS 14.4, *) {
            session = ASWebAuthenticationSession(url: attempt.authorizationURL,
                callback: .customScheme(BrowserLoginAttempt.callbackScheme), completionHandler: completion)
        } else {
            session = ASWebAuthenticationSession(url: attempt.authorizationURL,
                callbackURLScheme: BrowserLoginAttempt.callbackScheme, completionHandler: completion)
        }
        self.session = session
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = true
        if !session.start() { finish(.failure(.browserUnavailable)) }
    }

    private func finish(_ result: Result<URL, BrowserLoginError>) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel(); timeout = nil
        if case .failure = result { attempt?.cancel() }
        attempt = nil
        session?.cancel(); session = nil
        anchor = nil
        if Self.active === self { Self.active = nil }
        continuation.resume(returning: result)
    }
}
