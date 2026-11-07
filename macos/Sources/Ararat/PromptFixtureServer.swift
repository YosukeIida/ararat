import Foundation
import Network

final class PromptFixtureServer {
  private let listener: NWListener
  private let queue = DispatchQueue(label: "ararat.prompt-fixture")

  init() throws {
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
    listener = try NWListener(using: parameters)
  }

  func start(ready: @escaping (Result<UInt16, Error>) -> Void) {
    listener.stateUpdateHandler = { [weak self] state in
      switch state {
      case .ready:
        if let port = self?.listener.port { ready(.success(port.rawValue)) }
      case .failed(let error): ready(.failure(error))
      default: break
      }
    }
    listener.newConnectionHandler = { [queue] connection in
      connection.start(queue: queue)
      Self.receive(connection, data: Data())
    }
    listener.start(queue: queue)
  }

  func stop() { listener.cancel() }

  private static func receive(_ connection: NWConnection, data: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { chunk, _, complete, error in
      var request = data
      if let chunk { request.append(chunk) }
      if request.range(of: Data("\r\n\r\n".utf8)) != nil {
        let line = String(decoding: request, as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
        let target = line.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        let path = String(target.split(separator: "?", maxSplits: 1).first ?? "")
        let (status, headers, body): (String, String, String)
        switch path {
        case "/permissions":
          status = "200 OK"; headers = ""; body = permissionsPage
        case "/dialogs":
          status = "200 OK"; headers = ""; body = dialogsPage
        case "/protocol":
          status = "200 OK"; headers = ""; body = "<!doctype html><title>Protocol fixture</title>"
        case "/autofill":
          status = "200 OK"; headers = ""; body = autofillPage
        case "/webauthn":
          status = "200 OK"; headers = ""; body = webauthnPage
        case "/auth":
          status = "401 Unauthorized"; headers = "WWW-Authenticate: Basic realm=\"Ararat fixture\"\r\n"; body = "<!doctype html><title>Unauthorized</title><p>401 body</p><script>document.documentElement.dataset.auth = 'body';</script>"
        default:
          status = "404 Not Found"; headers = ""; body = "Not found"
        }
        let bodyData = Data(body.utf8)
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\nConnection: close\r\n\(headers)Content-Length: \(bodyData.count)\r\n\r\n"
        connection.send(content: Data(response.utf8) + bodyData, completion: .contentProcessed { _ in connection.cancel() })
      } else if complete || error != nil || request.count >= 32768 {
        connection.cancel()
      } else {
        receive(connection, data: request)
      }
    }
  }

  private static let permissionsPage = """
    <!doctype html><title>Permissions fixture</title>
    <script>
    const result = document.documentElement.dataset;
    window.requestNotifications = async () => { result.notifications = await Notification.requestPermission(); };
    window.requestLocation = () => navigator.geolocation.getCurrentPosition(
      () => { result.location = 'granted'; }, error => { result.location = String(error.code); });
    window.requestMidi = async () => {
      try { await navigator.requestMIDIAccess({sysex: true}); result.midiResult = 'granted'; }
      catch (error) { result.midiResult = error.name; }
      result.midiState = (await navigator.permissions.query({name: 'midi', sysex: true})).state;
    };
    </script>
    """

  private static let dialogsPage = """
    <!doctype html><title>Dialogs fixture</title>
    <script>
    const result = document.documentElement.dataset;
    window.runAlert = () => { alert('Alert'); result.alert = 'done'; };
    window.runConfirm = key => { result[key] = String(confirm('Confirm')); };
    window.runPrompt = key => { const value = prompt('Prompt'); result[key] = value === null ? 'null' : value; };
    </script>
    """

  private static let autofillPage = """
    <!doctype html><title>Autofill fixture</title>
    <form id="address" action="/autofill" method="get">
      <input name="name" autocomplete="name">
      <input name="street" autocomplete="address-line1">
      <input name="city" autocomplete="address-level2">
      <input name="state" autocomplete="address-level1">
      <input name="zip" autocomplete="postal-code">
      <input name="country" autocomplete="country-name">
      <button id="address-submit" type="submit">Submit address</button>
    </form>
    <form id="card" action="/autofill" method="get">
      <input name="name" autocomplete="cc-name">
      <input name="number" autocomplete="cc-number">
      <input name="month" autocomplete="cc-exp-month">
      <input name="year" autocomplete="cc-exp-year">
      <button id="card-submit" type="submit">Submit card</button>
    </form>
    <script>
    window.fillAddress = () => {
      const form = document.getElementById('address');
      for (const [key, value] of Object.entries({name:'John Smith', street:'123 Testing St', city:'Mountain View', state:'CA', zip:'94043', country:'US'})) form.elements[key].value = value;
    };
    window.fillCard = () => {
      const form = document.getElementById('card');
      for (const [key, value] of Object.entries({name:'John Smith', number:'5454545454545454', month:'12', year:String(new Date().getFullYear()+2)})) form.elements[key].value = value;
    };
    </script>
    """

  private static let webauthnPage = """
    <!doctype html><title>WebAuthn fixture</title><script>
    const result = document.documentElement.dataset;
    window.runGet = async () => {
      try { await navigator.credentials.get({publicKey:{challenge:new Uint8Array(32), timeout:120000}}); result.get = 'success'; }
      catch (error) { result.get = error.name; }
    };
    window.runCreate = async () => {
      try { await navigator.credentials.create({publicKey:{challenge:new Uint8Array(32), rp:{name:'Ararat fixture'}, user:{id:new Uint8Array([1]), name:'test', displayName:'Test'}, pubKeyCredParams:[{type:'public-key',alg:-7}], timeout:120000}}); result.create = 'success'; }
      catch (error) { result.create = error.name; }
    };
    </script>
    """
}
