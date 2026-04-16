import Foundation
import UIKit

/// Sends document images to Claude AI for intelligent data extraction.
/// Claude reads rate confirmations, fuel receipts, lumper fees, tolls, repair bills,
/// and returns structured data ready to create Loads or Expenses.
class ClaudeAIService {

    static let shared = ClaudeAIService()

    private let apiURL = URL(string: "https://api.anthropic.com/v1/messages")!

    /// The system prompt that tells Claude how to parse trucking documents
    private let systemPrompt = """
    You are an AI assistant for a trucking company. You extract data from scanned documents.

    Given an image of a trucking document (rate confirmation, fuel receipt, lumper fee, toll receipt, repair bill, BOL, or invoice), extract ALL relevant data and return it as JSON.

    Determine the document type first, then extract fields accordingly:

    For RATE CONFIRMATIONS / LOAD SHEETS:
    - document_type: "rate_confirmation"
    - broker_name, broker_mc_number
    - load_number
    - pickup_date (YYYY-MM-DD), delivery_date (YYYY-MM-DD)
    - origin (city, state), destination (city, state)
    - total_miles
    - line_haul_rate, fuel_surcharge, accessorial_charges, total_revenue

    For FUEL RECEIPTS:
    - document_type: "fuel_receipt"
    - vendor_name
    - expense_amount (total cost)
    - gallons, price_per_gallon
    - expense_category: "fuel"

    For LUMPER FEES:
    - document_type: "lumper_fee"
    - vendor_name
    - expense_amount
    - expense_category: "lumper"

    For TOLL RECEIPTS:
    - document_type: "toll"
    - vendor_name (toll authority)
    - expense_amount
    - expense_category: "toll"

    For REPAIR / MAINTENANCE BILLS:
    - document_type: "repair"
    - vendor_name
    - expense_amount
    - expense_category: "maintenance"
    - notes (description of work)

    For any OTHER document:
    - document_type: "other"
    - Extract whatever fields seem relevant

    Always include a "confidence" field: "high", "medium", or "low" based on image quality and how sure you are about the extracted values.

    If a field is not visible or unclear, omit it rather than guessing.

    Return ONLY valid JSON, no markdown, no explanation. Just the JSON object.
    """

    /// Extract data from a document image using Claude Vision
    func extractData(from image: UIImage) async throws -> ExtractedData {
        // Compress and encode the image
        guard let imageData = image.jpegData(compressionQuality: 0.7) else {
            throw AIError.imageEncodingFailed
        }
        let base64Image = imageData.base64EncodedString()

        // Check API key
        guard Config.anthropicAPIKey != "YOUR_ANTHROPIC_API_KEY_HERE" else {
            throw AIError.noAPIKey
        }

        // Build the request
        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Config.anthropicAPIKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 30

        let body: [String: Any] = [
            "model": "claude-sonnet-4-20250514",
            "max_tokens": 1024,
            "system": systemPrompt,
            "messages": [
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "image",
                            "source": [
                                "type": "base64",
                                "media_type": "image/jpeg",
                                "data": base64Image
                            ]
                        ],
                        [
                            "type": "text",
                            "text": "Extract all data from this trucking document. Return only JSON."
                        ]
                    ]
                ]
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        // Make the API call
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            print("🔴 Claude API error (\(httpResponse.statusCode)): \(errorBody)")
            throw AIError.apiError(statusCode: httpResponse.statusCode, message: errorBody)
        }

        // Parse Claude's response
        let claudeResponse = try JSONDecoder().decode(ClaudeResponse.self, from: data)

        guard let textContent = claudeResponse.content.first(where: { $0.type == "text" }),
              let jsonString = textContent.text else {
            throw AIError.noTextInResponse
        }

        // Parse the JSON string into ExtractedData
        guard let jsonData = jsonString.data(using: .utf8) else {
            throw AIError.jsonParsingFailed
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let extracted = try decoder.decode(ExtractedData.self, from: jsonData)

        return extracted
    }

    /// Generate a text response from Claude (used for AI summaries, insights, etc.)
    static func generateText(prompt: String) async throws -> String {
        guard Config.anthropicAPIKey != "YOUR_ANTHROPIC_API_KEY_HERE" else {
            throw AIError.noAPIKey
        }

        let apiURL = URL(string: "https://api.anthropic.com/v1/messages")!
        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Config.anthropicAPIKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 30

        let body: [String: Any] = [
            "model": "claude-sonnet-4-20250514",
            "max_tokens": 512,
            "messages": [
                [
                    "role": "user",
                    "content": prompt
                ]
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw AIError.apiError(statusCode: httpResponse.statusCode, message: errorBody)
        }

        let claudeResponse = try JSONDecoder().decode(ClaudeTextResponse.self, from: data)

        guard let text = claudeResponse.content.first?.text else {
            throw AIError.noTextInResponse
        }

        return text
    }
}

private struct ClaudeTextResponse: Codable {
    let content: [TextBlock]
    struct TextBlock: Codable {
        let type: String
        let text: String?
    }
}

// MARK: - Claude API Response Models

private struct ClaudeResponse: Codable {
    let content: [ContentBlock]
}

private struct ContentBlock: Codable {
    let type: String
    let text: String?
}

// MARK: - Error Types

enum AIError: LocalizedError {
    case imageEncodingFailed
    case noAPIKey
    case invalidResponse
    case apiError(statusCode: Int, message: String)
    case noTextInResponse
    case jsonParsingFailed

    var errorDescription: String? {
        switch self {
        case .imageEncodingFailed:
            return "Failed to encode the image"
        case .noAPIKey:
            return "No API key configured. Go to Config.swift and add your Anthropic API key."
        case .invalidResponse:
            return "Invalid response from AI service"
        case .apiError(let code, let message):
            return "AI service error (\(code)): \(message)"
        case .noTextInResponse:
            return "AI returned an empty response"
        case .jsonParsingFailed:
            return "Failed to parse AI response"
        }
    }
}
