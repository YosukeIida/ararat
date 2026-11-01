import Foundation

enum HarnessCommand {
    case archiveDelete(String), archiveSearch(String), createSpace(String), library(Bool), restore(String)
    case quit, space(Int), select(String), close(String), state, width, resetWidth, sidebar, toggleSidebar
    case invalid(String)

    static func parse(_ line: String) -> Self {
        let words = line.trimmingCharacters(in: .whitespacesAndNewlines).split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard let first = words.first else { return .invalid("error command: usage <command> [arguments]") }
        let verb = String(first)
        let argument = words.dropFirst().first.map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        let single = argument.flatMap { $0.isEmpty || $0.contains(where: \.isWhitespace) ? nil : $0 }
        func usage(_ syntax: String) -> Self { .invalid("error \(verb): usage \(syntax)") }
        func noArguments(_ command: Self) -> Self { argument == nil ? command : usage(verb) }
        switch verb {
        case "archive-delete":
            guard let single else { return usage("archive-delete <id>") }; return .archiveDelete(single)
        case "archive-search": return .archiveSearch(argument ?? "")
        case "create-space":
            guard let argument, !argument.isEmpty else { return usage("create-space <name>") }; return .createSpace(argument)
        case "library":
            if argument == nil { return .library(true) }
            guard argument == "close" else { return usage("library [close]") }; return .library(false)
        case "restore":
            guard let single else { return usage("restore <id>") }; return .restore(single)
        case "space":
            guard let single, single.utf8.allSatisfy({ (48...57).contains($0) }), let index = Int(single) else { return usage("space <index>") }; return .space(index)
        case "select":
            guard let single else { return usage("select <id>") }; return .select(single)
        case "close":
            guard let single else { return usage("close <id>") }; return .close(single)
        case "quit": return noArguments(.quit)
        case "state": return noArguments(.state)
        case "width": return noArguments(.width)
        case "reset-width": return noArguments(.resetWidth)
        case "sidebar": return noArguments(.sidebar)
        case "toggle-sidebar": return noArguments(.toggleSidebar)
        default: return .invalid("error unknown command")
        }
    }
}
