import Foundation
import os
public import MatterMacCore

/// A scripted assistant: records every request and answers from `respond`.
public final class FakeAssistantProvider: AssistantProvider {
    public let maximumInputCharacters: Int
    private let state = OSAllocatedUnfairLock<[AssistantRequest]>(initialState: [])
    private let answer: @Sendable (AssistantRequest, Int) -> Result<String, AssistantError>

    /// `respond` gets the request and how many requests came before it.
    public init(maximumInputCharacters: Int = 100_000,
                respond: @escaping @Sendable (AssistantRequest, Int) -> Result<String, AssistantError> = { _, _ in .success("ok") }) {
        self.maximumInputCharacters = maximumInputCharacters
        self.answer = respond
    }

    public var requests: [AssistantRequest] { state.withLock { $0 } }

    public func respond(to request: AssistantRequest) async throws(AssistantError) -> String {
        let index = state.withLock { requests -> Int in
            requests.append(request)
            return requests.count - 1
        }
        return try answer(request, index).get()
    }
}
