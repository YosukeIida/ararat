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
