import AppKit

@MainActor
enum ScreenViewTree {
    struct Node: Encodable {
        let className: String
        let frame: [String: CGFloat]
        let role: String?
        let label: String?
        let identifier: String?
        let hidden: Bool
        let children: [Node]

        @MainActor init(_ view: NSView) {
            className = String(describing: type(of: view))
            frame = ScreenViewTree.coordinates(view.convert(view.bounds, to: nil))
            role = view.accessibilityRole()?.rawValue
            label = view.accessibilityLabel()
            identifier = view.identifier?.rawValue ?? view.accessibilityIdentifier()
            hidden = view.isHiddenOrHasHiddenAncestor
            children = view.subviews.map { Node($0) }
        }

        enum CodingKeys: String, CodingKey {
            case className = "class"
            case frame, role, label, identifier, hidden, children
        }
    }

    private struct Capture: Encodable {
        let name: String
        let screen: String
        let windows: [Window]
    }

    private struct Window: Encodable {
        let frame: [String: CGFloat]
        let root: Node
    }

    static func regionArguments(frame: NSRect, screenTop: CGFloat, path: String) -> [String] {
        let region = NSRect(x: frame.minX, y: screenTop - frame.maxY, width: frame.width, height: frame.height).integral
        return ["-x", "-R\(Int(region.minX)),\(Int(region.minY)),\(Int(region.width)),\(Int(region.height))", path]
    }

    static func write(nextTo path: String, name: String, windows: [NSWindow]) -> Bool {
        guard let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--ararat-screen=") }) else { return true }
        let capture = Capture(name: name, screen: String(argument.dropFirst("--ararat-screen=".count)),
                              windows: windows.compactMap { window in
            guard let content = window.contentView else { return nil }
            return Window(frame: coordinates(window.frame), root: Node(content.superview ?? content))
        })
        let url = URL(fileURLWithPath: path).deletingPathExtension().appendingPathExtension("json")
        do {
            guard !capture.windows.isEmpty else { throw CocoaError(.fileWriteUnknown) }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(capture).write(to: url, options: .atomic)
            return true
        } catch {
            FileHandle.standardError.write(Data("ararat-trace: view tree \(url.path): \(error)\n".utf8))
            return false
        }
    }

    private static func coordinates(_ rect: NSRect) -> [String: CGFloat] {
        ["x": rect.minX, "y": rect.minY, "width": rect.width, "height": rect.height]
    }
}
