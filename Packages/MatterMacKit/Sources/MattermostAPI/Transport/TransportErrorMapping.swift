import Foundation

/// Classifies Foundation loading errors into `APIError` (SPEC §6, §11).
///
/// `.notSent` means the request provably never reached the server (resolution,
/// connection, TLS, offline): a write may be retried without creating a duplicate.
/// `.outcomeUnknown` means the request may have been transmitted; a write's result
/// is unknown and must not be retried blindly.
public enum TransportErrorMapping {
    /// - Parameter requestTransmitted: whether task metrics show that URLSession began
    ///   transmitting the request (`requestStartDate != nil`). `nil` when unknown,
    ///   which is treated as "may have been sent".
    public static func map(_ error: any Error, requestTransmitted: Bool?) -> APIError {
        if let apiError = error as? APIError { return apiError }
        if error is CancellationError { return .cancelled }
        guard let urlError = error as? URLError else {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain {
                return map(URLError(URLError.Code(rawValue: nsError.code)), requestTransmitted: requestTransmitted)
            }
            return requestTransmitted == false ? .notSent(.other(code: nsError.code)) : .outcomeUnknown(.other(code: nsError.code))
        }
        let neverSent = requestTransmitted == false
        switch urlError.code {
        case .cancelled:
            return .cancelled
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff, .callIsActive:
            return .notSent(.offline)
        case .cannotFindHost, .dnsLookupFailed:
            return .notSent(.dnsFailure)
        case .cannotConnectToHost:
            return .notSent(.cannotConnect)
        case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected,
             .clientCertificateRequired, .appTransportSecurityRequiresSecureConnection:
            return .notSent(.tlsFailure)
        case .unsupportedURL, .badURL:
            return .notSent(.other(code: urlError.code.rawValue))
        case .fileDoesNotExist, .noPermissionsToReadFile, .fileIsDirectory, .cannotOpenFile:
            return .localFileUnavailable
        case .dataLengthExceedsMaximum:
            return .responseTooLarge(limitBytes: 0)
        case .httpTooManyRedirects, .redirectToNonExistentLocation:
            return .redirectRefused
        case .timedOut:
            return neverSent ? .notSent(.timedOut) : .outcomeUnknown(.timedOut)
        case .networkConnectionLost:
            return neverSent ? .notSent(.connectionLost) : .outcomeUnknown(.connectionLost)
        default:
            let code = urlError.code.rawValue
            return neverSent ? .notSent(.other(code: code)) : .outcomeUnknown(.other(code: code))
        }
    }
}
