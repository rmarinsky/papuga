import XCTest
@testable import papuga

private final class OllamaURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
            )!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

final class AIOllamaClientTests: XCTestCase {
    private func runner() -> AIAnalysisRunner {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OllamaURLProtocol.self]
        return AIAnalysisRunner(session: URLSession(configuration: configuration))
    }

    func test_discoversInstalledModels() async throws {
        OllamaURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/tags")
            return (200, Data(#"{"models":[{"name":"qwen3:4b"},{"name":"gemma3:4b"}]}"#.utf8))
        }
        let models = try await runner().discoverOllamaModels()
        XCTAssertEqual(models, ["qwen3:4b", "gemma3:4b"])
    }

    func test_chatUsesNonStreamingDeterministicStructuredOutput() async throws {
        var calls = 0
        OllamaURLProtocol.handler = { request in
            calls += 1
            if request.url?.path == "/api/tags" {
                return (200, Data(#"{"models":[{"name":"qwen3:4b"}]}"#.utf8))
            }
            let body: Data
            if let direct = request.httpBody {
                body = direct
            } else {
                let stream = try XCTUnwrap(request.httpBodyStream)
                stream.open()
                defer { stream.close() }
                var collected = Data()
                let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
                defer { buffer.deallocate() }
                while stream.hasBytesAvailable {
                    let count = stream.read(buffer, maxLength: 4096)
                    if count <= 0 { break }
                    collected.append(buffer, count: count)
                }
                body = collected
            }
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json["stream"] as? Bool, false)
            XCTAssertEqual((json["options"] as? [String: Any])?["temperature"] as? Int, 0)
            XCTAssertNotNil(json["format"] as? [String: Any])
            return (200, Data(#"{"message":{"content":"{\"version\":2,\"predictions\":[]}"}}"#.utf8))
        }
        let response = try await runner().runOllama(model: "qwen3:4b", prompt: "rank")
        XCTAssertEqual(response, #"{"version":2,"predictions":[]}"#)
        XCTAssertEqual(calls, 2)
    }

    func test_missingModelAndUnavailableServerFailClosed() async throws {
        OllamaURLProtocol.handler = { _ in
            (200, Data(#"{"models":[{"name":"other"}]}"#.utf8))
        }
        do {
            _ = try await runner().runOllama(model: "missing", prompt: "rank")
            XCTFail("Expected missing model")
        } catch let error as AIAnalysisRunner.OllamaError {
            XCTAssertEqual(error, .missingModel("missing"))
        }

        OllamaURLProtocol.handler = { _ in throw URLError(.cannotConnectToHost) }
        do {
            _ = try await runner().discoverOllamaModels()
            XCTFail("Expected unavailable server")
        } catch {}
    }
}
