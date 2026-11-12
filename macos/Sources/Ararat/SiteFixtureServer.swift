import Foundation
import Network
import Security

/// The site-controls check's loopback fixtures: one plain-HTTP listener and one TLS listener on
/// 127.0.0.1. The TLS identity is a throwaway self-signed certificate for 127.0.0.1 that is
/// embedded here for the check only; the engine adds the matching
/// --ignore-certificate-errors-spki-list value so Chromium treats the page as secure without
/// touching the system trust store. Nothing in the product path loads it.
final class SiteFixtureServer {
    /// SHA-256 of the fixture leaf's SubjectPublicKeyInfo, base64. ararat_main.mm appends the
    /// matching --ignore-certificate-errors-spki-list switch for the site-controls checks.
    static let spkiHash = "41bhvYwNSFKJywXg6t2xbgeAoiBIlI83FdLJO/ILKZg="

    // openssl req -x509 -nodes -newkey rsa:2048 -days 3650 -subj /CN=127.0.0.1 \
    //   -addext subjectAltName=IP:127.0.0.1,DNS:localhost
    // openssl pkcs12 -export -passout pass:ararat (test-only identity)
    private static let identityBase64 = """
    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
    """

    private let plain: NWListener
    private let secure: NWListener
    private let queue = DispatchQueue(label: "ararat.site-fixture")
    let keychainPath: String

    struct Ports {
        var plain: UInt16
        var secure: UInt16
    }

    init() throws {
        keychainPath = Self.scratchKeychainPath()
        Self.trackForExit(keychainPath)
        let plainParameters = NWParameters.tcp
        plainParameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        plain = try NWListener(using: plainParameters)

        do {
            let identity = try Self.decodeIdentity(keychainPath: keychainPath)
            let tls = NWProtocolTLS.Options()
            guard let secIdentity = sec_identity_create(identity) else {
                throw NSError(domain: "Ararat.siteFixture", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "sec_identity_create failed"])
            }
            sec_protocol_options_set_local_identity(tls.securityProtocolOptions, secIdentity)
            let secureParameters = NWParameters(tls: tls)
            secureParameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            secure = try NWListener(using: secureParameters)
        } catch {
            Self.removeKeychain(at: keychainPath)
            throw error
        }
    }

    deinit { Self.removeKeychain(at: keychainPath) }

    func start(ready: @escaping (Result<Ports, Error>) -> Void) {
        var plainPort: UInt16?
        var securePort: UInt16?
        var reported = false
        func report() {
            guard !reported, let plainPort, let securePort else { return }
            reported = true
            ready(.success(Ports(plain: plainPort, secure: securePort)))
        }
        plain.stateUpdateHandler = { state in
            switch state {
            case .ready: plainPort = self.plain.port?.rawValue; report()
            case .failed(let error): ready(.failure(error))
            default: break
            }
        }
        secure.stateUpdateHandler = { state in
            switch state {
            case .ready: securePort = self.secure.port?.rawValue; report()
            case .failed(let error): ready(.failure(error))
            default: break
            }
        }
        for listener in [plain, secure] {
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                connection.start(queue: self.queue)
                self.receive(connection, data: Data())
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        plain.cancel()
        secure.cancel()
        Self.removeKeychain(at: keychainPath)
    }

    private func receive(_ connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { chunk, _, complete, error in
            var request = data
            if let chunk { request.append(chunk) }
            if request.range(of: Data("\r\n\r\n".utf8)) != nil {
                let line = String(decoding: request, as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
                let target = line.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                let path = String(target.split(separator: "?", maxSplits: 1).first ?? "")
                let (status, body): (String, String)
                switch path {
                case "/site": status = "200 OK"; body = Self.sitePage
                case "/clean": status = "200 OK"; body = Self.cleanPage
                case "/capture": status = "200 OK"; body = Self.capturePage
                default: status = "404 Not Found"; body = "Not found"
                }
                let bodyData = Data(body.utf8)
                let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: \(bodyData.count)\r\n\r\n"
                connection.send(content: Data(response.utf8) + bodyData, completion: .contentProcessed { _ in connection.cancel() })
            } else if complete || error != nil || request.count >= 32768 {
                connection.cancel()
            } else {
                self.receive(connection, data: request)
            }
        }
    }

    private static let sitePage = """
    <!doctype html><title>Site controls fixture</title>
    <p id="fixture">site controls fixture</p>
    <script>
    const result = document.documentElement.dataset;
    window.requestLocation = () => navigator.geolocation.getCurrentPosition(
      () => { result.location = 'granted'; }, error => { result.location = String(error.code); });
    window.requestNotifications = async () => { result.notifications = await Notification.requestPermission(); };
    </script>
    """

    private static let cleanPage = """
    <!doctype html><title>Clean site fixture</title>
    <p>nothing to ask for</p>
    """

    private static let capturePage = """
    <!doctype html><title>Capture fixture</title>
    <style>html,body{margin:0;padding:0}.band{height:200px}</style>
    <script>
    for (let index = 0; index < 12; index += 1) {
      const band = document.createElement('div');
      band.className = 'band';
      band.style.background = `hsl(${index * 30} 70% 50%)`;
      band.textContent = `band ${index}`;
      document.body.appendChild(band);
    }
    </script>
    """

    static func scratchKeychainPath() -> String {
        NSTemporaryDirectory() + "ararat-site-fixture-\(UUID().uuidString).keychain"
    }

    /// Deletes the scratch keychain and its file. Safe when the file is already gone.
    @discardableResult
    static func removeKeychain(at path: String) -> Bool {
        var keychain: SecKeychain?
        if SecKeychainOpen(path, &keychain) == errSecSuccess, let keychain {
            SecKeychainDelete(keychain)
        }
        try? FileManager.default.removeItem(atPath: path)
        if path == exitPath { exitPath = "" }
        return !FileManager.default.fileExists(atPath: path)
    }

    // A check that times out can exit before the runtime tears its fixture down, so the one
    // scratch keychain of this process is also removed by an atexit handler.
    nonisolated(unsafe) private static var exitPath = ""
    nonisolated(unsafe) private static var exitRegistered = false

    private static func trackForExit(_ path: String) {
        exitPath = path
        guard !exitRegistered else { return }
        exitRegistered = true
        atexit {
            let pending = SiteFixtureServer.exitPath
            if !pending.isEmpty { SiteFixtureServer.removeKeychain(at: pending) }
        }
    }

    /// Imports the embedded throwaway PKCS#12 into a scratch keychain. The keychain is passed
    /// with kSecImportExportKeychain, so the user's default keychain and search list are never
    /// read or changed; the caller deletes the scratch keychain when done.
    static func decodeIdentity(keychainPath: String) throws -> SecIdentity {
        var keychain: SecKeychain?
        let password = "ararat"
        SecKeychainSetUserInteractionAllowed(false)
        defer { SecKeychainSetUserInteractionAllowed(true) }
        var status = SecKeychainCreate(keychainPath, UInt32(password.utf8.count), password, false, nil, &keychain)
        if status == errSecDuplicateItem { status = SecKeychainOpen(keychainPath, &keychain) }
        guard status == errSecSuccess, let keychain else {
            removeKeychain(at: keychainPath)
            throw NSError(domain: "Ararat.siteFixture", code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "scratch keychain error \(status)"])
        }
        // Why .ignoreUnknownCharacters: the identity is a wrapped multi-line literal.
        guard let data = Data(base64Encoded: identityBase64, options: .ignoreUnknownCharacters) else {
            removeKeychain(at: keychainPath)
            throw NSError(domain: "Ararat.siteFixture", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "identity base64 does not decode"])
        }
        var items: CFArray?
        let options: [String: Any] = [
            kSecImportExportPassphrase as String: password,
            kSecImportExportKeychain as String: keychain,
        ]
        let imported = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
        guard imported == errSecSuccess, let list = items as? [[String: Any]],
              let item = list.first, let identity = item[kSecImportItemIdentity as String] else {
            removeKeychain(at: keychainPath)
            throw NSError(domain: "Ararat.siteFixture", code: imported == errSecSuccess ? 3 : Int(imported),
                          userInfo: [NSLocalizedDescriptionKey: "pkcs12 import error \(imported)"])
        }
        return identity as! SecIdentity
    }
}
