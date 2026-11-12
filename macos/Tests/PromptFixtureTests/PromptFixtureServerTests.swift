import Foundation
import Testing
@testable import Ararat

@Test(.timeLimit(.minutes(1)))
func promptFixtureServesOnlyLoopbackPages() async throws {
    let server = try PromptFixtureServer()
    defer { server.stop() }
    let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
        server.start { result in continuation.resume(with: result) }
    }
    #expect(port > 0)

    let configuration = URLSessionConfiguration.ephemeral
    configuration.connectionProxyDictionary = [:]
    configuration.timeoutIntervalForRequest = 2
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }

    func response(_ path: String, host: String = "127.0.0.1") async throws -> (HTTPURLResponse, String) {
        let url = try #require(URL(string: "http://\(host):\(port)\(path)"))
        let (data, response) = try await session.data(from: url)
        return (try #require(response as? HTTPURLResponse), String(decoding: data, as: UTF8.self))
    }

    for (path, marker) in [
        ("/permissions", "requestNotifications"),
        ("/dialogs", "runAlert"),
        ("/protocol", "Protocol fixture"),
        ("/keyboard", "registerFixtureProtocol"),
        ("/search?q=example.com", "Search fixture"),
        ("/autofill", "address-submit"),
        ("/webauthn", "runCreate"),
    ] {
        let (http, body) = try await response(path)
        #expect(http.statusCode == 200)
        #expect(body.contains(marker))
    }

    let (query, queryBody) = try await response("/autofill?submitted=address")
    #expect(query.statusCode == 200)
    #expect(queryBody.contains("address-submit"))

    let (auth, authBody) = try await response("/auth")
    #expect(auth.statusCode == 401)
    #expect(auth.value(forHTTPHeaderField: "WWW-Authenticate") == "Basic realm=\"Ararat fixture\"")
    #expect(authBody.contains("401 body"))
    #expect(authBody.contains("dataset.auth = 'body'"))

    let (missing, _) = try await response("/missing")
    #expect(missing.statusCode == 404)
    await #expect(throws: (any Error).self) { try await response("/permissions", host: "127.0.0.2") }
}

@Test(.timeLimit(.minutes(1)))
func downloadsFixtureCompletesAndSupportsRangeResume() async throws {
    let server = try PromptFixtureServer()
    defer { server.stop() }
    let port: UInt16 = try await withCheckedThrowingContinuation { continuation in server.start { continuation.resume(with: $0) } }
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let complete = try #require(URL(string: "http://127.0.0.1:\(port)/complete-download"))
    let (data, response) = try await session.data(from: complete)
    #expect((response as? HTTPURLResponse)?.statusCode == 200)
    #expect(data.count == 8192)
    let resume = try #require(URL(string: "http://127.0.0.1:\(port)/resume-download"))
    await #expect(throws: (any Error).self) { try await session.data(from: resume) }
    var request = URLRequest(url: resume)
    request.setValue("bytes=32768-", forHTTPHeaderField: "Range")
    await #expect(throws: (any Error).self) { try await session.data(for: request) }
    await withCheckedContinuation { continuation in server.allowDownloadResume { continuation.resume() } }
    let (tail, rangeResponse) = try await session.data(for: request)
    let http = try #require(rangeResponse as? HTTPURLResponse)
    #expect(http.statusCode == 206)
    #expect(http.value(forHTTPHeaderField: "Content-Range") == "bytes 32768-262143/262144")
    #expect(tail.count == 262144 - 32768)
}
