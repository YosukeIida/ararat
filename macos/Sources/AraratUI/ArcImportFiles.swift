import Foundation

struct ArcImportFiles {
    let sidebar: String
    let windows: String?
    let keyBindings: String?
    let routing: String?
    let warning: String?

    init(directory: URL) throws {
        var warning: String?
        func read(_ name: String) throws -> String {
            let bytes = try Data(contentsOf: directory.appendingPathComponent(name))
            guard let json = String(data: bytes, encoding: .utf8) else {
                throw ReadError(message: "The file is not UTF-8.")
            }
            return json
        }
        func optional(_ name: String) -> String? {
            do {
                return try read(name)
            } catch {
                if !Self.isMissing(error), warning == nil {
                    warning = "\(name): \(error.localizedDescription)"
                }
                return nil
            }
        }
        let name = "StorableSidebar.json"
        do {
            sidebar = try read(name)
        } catch {
            let message = Self.isMissing(error) ? "\(name) was not found." : "\(name): \(error.localizedDescription)"
            throw ReadError(message: message)
        }
        windows = optional("StorableWindows.json")
        keyBindings = optional("StorableKeyBindings.json")
        routing = optional("StorableLinkRouting.json")
        self.warning = warning
    }

    private static func isMissing(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError
    }

    struct ReadError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}
