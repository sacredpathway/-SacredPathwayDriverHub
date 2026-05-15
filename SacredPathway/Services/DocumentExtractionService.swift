import Foundation

// =============================================================================
// MARK: - DORMANT AI SERVICE (launch v1 ships without document scanning)
// =============================================================================
// This service is the bridge between iOS and the `extract-document` Edge
// Function. It is NOT invoked in the launch version of the app because
// `FeatureFlags.aiScanEnabled` is false in ScanUploadView.swift.
//
// All code below is preserved intact so that when the backend JWT path is
// stable and we want to reintroduce scanning:
//   1. Set `FeatureFlags.aiScanEnabled = true` in ScanUploadView.swift
//   2. Re-deploy the extract-document Edge Function
//   3. Re-add the AI disclosure text to the scan screen
//   4. Update privacy policy + App Store copy to disclose AI processing
//
// Future AI hookup:
// Any new AI backend should return a response that decodes into the same
// `ExtractedData` struct (see TruckDocument.swift). The rest of this file
// maps errors to the same five user-facing strings and needs no changes.
// =============================================================================

/// Talks to the Supabase `extract-document` Edge Function.
///
/// Contract with the backend:
///   Success: { "success": true, "document_id", "status", "extracted",
///              "raw_text", "model", "confidence", "parse_stage" }
///   Error:   { "success": false, "code": "ERROR_CODE",
///              "message": "User-friendly message",
///              "details": "<stage:hint — safe technical detail>" }
///
/// This service NEVER lets raw JSON, provider names, or stack traces reach
/// the UI's `message`. The five `ExtractionError` cases each have a fixed
/// user-facing string. A `details` field carries a short, stage-prefixed
/// hint the UI may expose under "Show details" for support/debug use.
enum DocumentExtractionService {

    private static let maxRetries = 3
    private static let baseBackoff: Double = 0.8
    private static let maxDetailLength = 200

    static func extract(documentId: UUID,
                        supabase: SupabaseService) async throws -> ExtractionResult {
        let body = ExtractRequest(documentId: documentId)
        var lastError: ExtractionError = .unknown(details: nil)

        for attempt in 0..<maxRetries {
            do {
                let response: ExtractResponse = try await supabase.invokeFunction(
                    name: Config.extractDocumentFunction,
                    body: body
                )

                // Happy path — includes the salvaged / fallback case where
                // the backend returns success=true with parse_stage=fallback.
                if response.success == true, let extracted = response.extracted {
                    return ExtractionResult(
                        structured: extracted,
                        rawText: response.rawText ?? "",
                        model: response.model ?? "unknown",
                        confidence: response.confidence ?? extracted.confidence ?? "medium",
                        parseStage: response.parseStage,
                        status: response.status
                    )
                }

                // Backend returned structured error.
                logDebug(prefix: "backend", code: response.code,
                         message: response.message, details: response.details)
                let mapped = Self.map(backendCode: response.code,
                                      details: response.details)

                if Self.isTransient(backendCode: response.code),
                   attempt < maxRetries - 1 {
                    lastError = mapped
                    try await Self.sleep(attempt: attempt)
                    continue
                }
                throw mapped

            } catch let error as EdgeFunctionError {
                logDebug(prefix: "edge", code: nil,
                         message: String(describing: error), details: nil)
                let mapped = Self.map(edgeError: error)

                if Self.isTransient(edgeError: error), attempt < maxRetries - 1 {
                    lastError = mapped
                    try await Self.sleep(attempt: attempt)
                    continue
                }
                throw mapped

            } catch let error as URLError {
                logDebug(prefix: "url", code: "\(error.code.rawValue)",
                         message: error.localizedDescription, details: nil)
                let mapped = Self.map(urlError: error)

                if Self.isTransient(urlError: error), attempt < maxRetries - 1 {
                    lastError = mapped
                    try await Self.sleep(attempt: attempt)
                    continue
                }
                throw mapped

            } catch let error as ExtractionError {
                throw error

            } catch {
                logDebug(prefix: "generic", code: nil,
                         message: error.localizedDescription, details: nil)
                throw ExtractionError.unknown(details: clip(error.localizedDescription))
            }
        }
        throw lastError
    }

    // MARK: - Mapping

    private static func map(backendCode: String?, details: String?) -> ExtractionError {
        let clipped = details.map { clip($0) }
        switch backendCode?.uppercased() {
        case "SCAN_TEMPORARILY_UNAVAILABLE": return .billing(details: clipped)
        case "RATE_LIMITED":                 return .rateLimited(details: clipped)
        case "TIMEOUT":                      return .timeout(details: clipped)
        case "AUTH_EXPIRED":                 return .authExpired(details: clipped)
        default:                             return .unknown(details: clipped)
        }
    }

    private static func map(edgeError: EdgeFunctionError) -> ExtractionError {
        switch edgeError {
        case .invalidResponse:
            return .unknown(details: "edge: invalidResponse")
        case .httpError(let code, let body):
            // Try to decode the clean error envelope FIRST (our backend).
            if let data = body.data(using: .utf8),
               let payload = try? JSONDecoder().decode(BackendErrorBody.self, from: data),
               let c = payload.code {
                // Prefer our `details` field. If that's missing (e.g. because
                // the response came from the Supabase gateway, not our own
                // function), fall back to the payload's `message` so the UI
                // can at least surface the underlying reason.
                let fallbackDetails = payload.details ?? payload.message
                return Self.map(backendCode: c, details: clip(fallbackDetails ?? "http_\(code)"))
            }
            // Fallback by HTTP code only — never surface the full `body` text.
            let trimmedBody = clip(body)
            switch code {
            case 401, 403: return .authExpired(details: "http_\(code) \(trimmedBody)")
            case 408, 504: return .timeout(details: "http_\(code) \(trimmedBody)")
            case 429:      return .rateLimited(details: "http_\(code) \(trimmedBody)")
            case 402, 503: return .billing(details: "http_\(code) \(trimmedBody)")
            default:       return .unknown(details: "http_\(code) \(trimmedBody)")
            }
        }
    }

    private static func map(urlError: URLError) -> ExtractionError {
        switch urlError.code {
        case .timedOut:
            return .timeout(details: "url_\(urlError.code.rawValue)")
        case .userAuthenticationRequired:
            return .authExpired(details: "url_\(urlError.code.rawValue)")
        default:
            return .unknown(details: "url_\(urlError.code.rawValue)")
        }
    }

    // MARK: - Retry predicates

    private static func isTransient(backendCode: String?) -> Bool {
        switch backendCode?.uppercased() {
        case "RATE_LIMITED", "TIMEOUT", "UNKNOWN_SCAN_ERROR": return true
        default: return false
        }
    }

    private static func isTransient(edgeError: EdgeFunctionError) -> Bool {
        switch edgeError {
        case .invalidResponse: return true
        case .httpError(let code, _):
            return code == 408 || code == 425 || code == 429 || (500...599).contains(code)
        }
    }

    private static func isTransient(urlError: URLError) -> Bool {
        switch urlError.code {
        case .timedOut, .cannotConnectToHost, .networkConnectionLost,
             .notConnectedToInternet, .dnsLookupFailed:
            return true
        default:
            return false
        }
    }

    // MARK: - Utilities

    private static func sleep(attempt: Int) async throws {
        let jitter = Double.random(in: 0.8...1.2)
        let nanos = UInt64(baseBackoff * pow(2.0, Double(attempt)) * jitter * 1_000_000_000)
        try await Task.sleep(nanoseconds: nanos)
    }

    private static func logDebug(prefix: String,
                                 code: String?,
                                 message: String?,
                                 details: String?) {
        #if DEBUG
        let safeMessage = (message ?? "").prefix(1000)
        let safeDetails = (details ?? "").prefix(200)
        print("[DocumentExtraction][\(prefix)] code=\(code ?? "nil") details=\(safeDetails) message=\(safeMessage)")
        #endif
    }

    static func clip(_ s: String, max: Int = maxDetailLength) -> String {
        guard s.count > max else { return s }
        let idx = s.index(s.startIndex, offsetBy: max)
        return String(s[..<idx])
    }
}

// MARK: - Wire types

struct ExtractRequest: Encodable {
    let documentId: UUID
    enum CodingKeys: String, CodingKey { case documentId = "document_id" }
}

struct ExtractResponse: Decodable {
    let success: Bool?
    let documentId: String?
    let status: String?
    let extracted: ExtractedData?
    let rawText: String?
    let model: String?
    let confidence: String?
    let code: String?
    let message: String?
    let details: String?
    let parseStage: String?
}

private struct BackendErrorBody: Decodable {
    let success: Bool?
    let code: String?
    let message: String?
    let details: String?
}

// MARK: - Result

struct ExtractionResult {
    let structured: ExtractedData
    let rawText: String
    let model: String
    let confidence: String
    let parseStage: String?
    let status: String?

    /// True if the backend salvaged the extraction — fields may be sparse
    /// and the user should review carefully.
    var needsManualReview: Bool {
        status == "pending_manual_review" || parseStage == "fallback"
    }
}

// MARK: - Error (only these five cases ever reach the UI — each carries an
// optional `details` string for collapsible "Show details" diagnostics)

enum ExtractionError: LocalizedError, Equatable {
    case billing(details: String?)
    case rateLimited(details: String?)
    case timeout(details: String?)
    case authExpired(details: String?)
    case unknown(details: String?)

    var errorDescription: String? {
        switch self {
        case .billing:
            return "Document scanning is temporarily unavailable. Tap Enter Manually to add this one by hand."
        case .rateLimited:
            return "Too many scans at once. Wait a few seconds and tap Try Again."
        case .timeout:
            return "That took too long. Tap Try Again, or enter manually."
        case .authExpired:
            return "Your session expired. Sign out and sign back in."
        case .unknown:
            return "Something went wrong while scanning. Tap Try Again, or enter it manually."
        }
    }

    /// Safe technical hint for collapsible display. Never contains raw JSON
    /// or provider names.
    var technicalDetails: String? {
        switch self {
        case .billing(let d), .rateLimited(let d), .timeout(let d),
             .authExpired(let d), .unknown(let d):
            return d
        }
    }

    /// Short code suitable for a support badge ("UNKNOWN_SCAN_ERROR" etc.).
    var code: String {
        switch self {
        case .billing:     return "SCAN_TEMPORARILY_UNAVAILABLE"
        case .rateLimited: return "RATE_LIMITED"
        case .timeout:     return "TIMEOUT"
        case .authExpired: return "AUTH_EXPIRED"
        case .unknown:     return "UNKNOWN_SCAN_ERROR"
        }
    }
}
