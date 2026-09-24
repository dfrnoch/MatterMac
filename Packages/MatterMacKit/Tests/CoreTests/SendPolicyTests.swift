import Testing
@testable import MatterMacCore
import MatterMacModels
import MattermostAPI

@Suite("SendFailurePolicy")
struct SendFailurePolicyTests {
    let start = MattermostTimestamp(milliseconds: 1_000_000)

    func at(_ offset: Int64) -> MattermostTimestamp { MattermostTimestamp(milliseconds: start.milliseconds + offset) }

    @Test func lostResponseInsideDedupWindowRetriesWithSameID() {
        let decision = SendFailurePolicy.decide(error: .outcomeUnknown(.timedOut), firstAttemptAt: start, now: at(5_000),
                                                automaticRetriesUsed: 0)
        #expect(decision == .retry(afterMilliseconds: 1_500))
    }

    @Test func lostResponseOutsideDedupWindowIsUnknownNotFailedOrSent() {
        let decision = SendFailurePolicy.decide(error: .outcomeUnknown(.connectionLost), firstAttemptAt: start,
                                                now: at(40_000), automaticRetriesUsed: 0)
        #expect(decision == .unknown)
    }

    @Test func untrustedDedupNeverRetriesAutomatically() {
        let decision = SendFailurePolicy.decide(error: .outcomeUnknown(.timedOut), firstAttemptAt: start, now: at(1_000),
                                                automaticRetriesUsed: 0, serverDeduplicationTrusted: false)
        #expect(decision == .unknown)
    }

    @Test func retriesAreBounded() {
        let decision = SendFailurePolicy.decide(error: .outcomeUnknown(.timedOut), firstAttemptAt: start, now: at(1_000),
                                                automaticRetriesUsed: SendFailurePolicy.maximumAutomaticRetries)
        #expect(decision == .unknown)
    }

    @Test func dedupPendingResponseRetries() {
        let info = ServerErrorInfo(id: ServerErrorID.deduplicatePending, statusCode: 500, requestID: nil)
        #expect(SendFailurePolicy.decide(error: .server(info), firstAttemptAt: start, now: at(100), automaticRetriesUsed: 0)
            == .retry(afterMilliseconds: 1_000))
    }

    @Test func definiteFailuresAreFailuresNotUnknown() {
        let forbidden = ServerErrorInfo(id: ServerErrorID.permissions, statusCode: 403, requestID: nil)
        #expect(SendFailurePolicy.decide(error: .forbidden(forbidden), firstAttemptAt: start, now: at(1), automaticRetriesUsed: 0)
            == .fail(.permissionDenied))
        #expect(SendFailurePolicy.decide(error: .notSent(.offline), firstAttemptAt: start, now: at(1), automaticRetriesUsed: 0)
            == .fail(.offline))
        let tooLong = ServerErrorInfo(id: ServerErrorID.messageTooLong, statusCode: 400, requestID: nil)
        if case .fail(.messageTooLong) = SendFailurePolicy.decide(error: .badRequest(tooLong), firstAttemptAt: start, now: at(1),
                                                                  automaticRetriesUsed: 0) {} else {
            Issue.record("expected messageTooLong")
        }
    }

    @Test func malformedSuccessResponseIsUnknown() {
        #expect(SendFailurePolicy.decide(error: .malformedResponse, firstAttemptAt: start, now: at(1), automaticRetriesUsed: 0)
            == .unknown)
    }

    @Test func pendingIDsAreUniqueAndMonotonic() {
        var queue = PendingSendQueue()
        let user = UserID(unchecked: "u1")
        let a = queue.makePendingID(user: user, now: MattermostTimestamp(milliseconds: 5))
        let b = queue.makePendingID(user: user, now: MattermostTimestamp(milliseconds: 5))
        let c = queue.makePendingID(user: user, now: MattermostTimestamp(milliseconds: 3))
        #expect(a.rawValue == "u1:5")
        #expect(b.rawValue == "u1:6")
        #expect(c.rawValue == "u1:7")
    }
}
