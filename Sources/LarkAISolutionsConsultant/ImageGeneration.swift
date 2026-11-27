import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum ImageGenerationError: LocalizedError {
    case invalidEndpoint
    case missingAPIKey
    case emptyPrompt
    case httpStatus(Int)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return "Configure an HTTPS image-generation endpoint."
        case .missingAPIKey:
            return "Configure an image-generation API key."
        case .emptyPrompt:
            return "Describe the image you want to create."
        case .httpStatus(let status):
            return "Image generation failed (HTTP \(status)). Check the endpoint, model, and API key."
        case .invalidResponse:
            return "The image service did not return a valid base64 image."
        }
    }
}

public enum GeneratedImageSize: String, CaseIterable, Sendable {
    case portrait = "1024x1536"
    case square = "1024x1024"
    case landscape = "1536x1024"
}

public struct HTTPImageGenerator: Sendable {
    private let endpoint: URL
    private let apiKey: String
    private let model: String
    private let session: URLSession

    public init(endpoint: URL, apiKey: String, model: String, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.model = model
        self.session = session
    }

    public func generate(prompt: String, size: GeneratedImageSize = .portrait) async throws -> Data {
        guard endpoint.scheme?.lowercased() == "https", endpoint.host != nil else {
            throw ImageGenerationError.invalidEndpoint
        }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw ImageGenerationError.missingAPIKey }
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { throw ImageGenerationError.emptyPrompt }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(ImageRequest(model: model, prompt: prompt, size: size.rawValue))

        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw ImageGenerationError.invalidResponse
        }
        guard 200..<300 ~= response.statusCode else {
            throw ImageGenerationError.httpStatus(response.statusCode)
        }
        guard let decoded = try? JSONDecoder().decode(ImageResponse.self, from: data),
              let encoded = decoded.data.first?.base64,
              let image = Data(base64Encoded: encoded),
              !image.isEmpty else {
            throw ImageGenerationError.invalidResponse
        }
        return image
    }
}

private struct ImageRequest: Encodable {
    let model: String
    let prompt: String
    let size: String
    let quality = "high"
    let n = 1
}

private struct ImageResponse: Decodable {
    struct Image: Decodable {
        let base64: String

        enum CodingKeys: String, CodingKey {
            case base64 = "b64_json"
        }
    }
    let data: [Image]
}
