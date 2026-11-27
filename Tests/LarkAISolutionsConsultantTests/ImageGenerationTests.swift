import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import LarkAISolutionsConsultant

private final class ImageFixtureURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let expectedSize = switch url.path {
        case "/square": "1024x1024"
        case "/landscape": "1536x1024"
        default: "1024x1536"
        }
        let validRequest = request.httpMethod == "POST"
            && request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key"
            && body?["prompt"] as? String == "a detailed portrait"
            && body?["model"] as? String == "gpt-image-1.5"
            && body?["quality"] as? String == "high"
            && body?["size"] as? String == expectedSize
            && body?["n"] as? Int == 1
        let status = url.path == "/failure" || !validRequest ? 400 : 200
        let json = url.path == "/invalid"
            ? #"{"data":[{"b64_json":"not-base64!"}]}"#
            : #"{"data":[{"b64_json":"AQID"}]}"#
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

struct ImageGenerationTests {
    private func generator(path: String) -> HTTPImageGenerator {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ImageFixtureURLProtocol.self]
        return HTTPImageGenerator(
            endpoint: URL(string: "https://example.test/\(path)")!,
            apiKey: "test-key",
            model: "gpt-image-1.5",
            session: URLSession(configuration: configuration)
        )
    }

    @Test
    func generatesHighQualityPortraitFromPrompt() async throws {
        let image = try await generator(path: "success").generate(prompt: " a detailed portrait ")
        #expect(image == Data([1, 2, 3]))
    }

    @Test
    func sendsSelectedImageSize() async throws {
        for (path, size) in [("square", GeneratedImageSize.square), ("landscape", .landscape)] {
            let image = try await generator(path: path).generate(prompt: "a detailed portrait", size: size)
            #expect(image == Data([1, 2, 3]))
        }
    }

    @Test
    func rejectsFailedAndInvalidResponses() async throws {
        for path in ["failure", "invalid"] {
            do {
                _ = try await generator(path: path).generate(prompt: "a detailed portrait")
                Issue.record("Expected image generation to fail for \(path)")
            } catch ImageGenerationError.httpStatus(400) where path == "failure" {
            } catch ImageGenerationError.invalidResponse where path == "invalid" {
            } catch {
                Issue.record("Unexpected error for \(path): \(error)")
            }
        }
    }

    @Test
    func rejectsEmptyPromptAndInsecureEndpoint() async throws {
        do {
            _ = try await generator(path: "success").generate(prompt: "  ")
            Issue.record("Expected an empty prompt error")
        } catch ImageGenerationError.emptyPrompt {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let insecure = HTTPImageGenerator(
            endpoint: URL(string: "http://example.test/generate")!,
            apiKey: "test-key",
            model: "gpt-image-1.5"
        )
        do {
            _ = try await insecure.generate(prompt: "a detailed portrait")
            Issue.record("Expected an insecure endpoint error")
        } catch ImageGenerationError.invalidEndpoint {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
