import ApplicationServices
import AppKit
func attr(_ e: AXUIElement, _ n: String) -> AnyObject? { var v: AnyObject?; return AXUIElementCopyAttributeValue(e, n as CFString, &v) == .success ? v : nil }
let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "dev.serafim.fast").first!.processIdentifier
let app = AXUIElementCreateApplication(pid)
let win = (attr(app, kAXWindowsAttribute) as! [AXUIElement]).first { (attr($0, kAXIdentifierAttribute) as? String) != "browser" }!
func walk(_ e: AXUIElement, _ f: (AXUIElement) -> Void) { f(e); for k in attr(e, kAXChildrenAttribute) as? [AXUIElement] ?? [] { walk(k, f) } }
func label(_ e: AXUIElement) -> String {
    [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute].compactMap { attr(e, $0) as? String }.first { !$0.isEmpty } ?? ""
}
var rows: [(String, AXUIElement)] = []
walk(win) { e in
    if (attr(e, kAXRoleAttribute) as? String) == kAXRowRole, let t = Optional(label(e)) {
        var name = t
        if name.isEmpty { walk(e) { c in if name.isEmpty, (attr(c, kAXRoleAttribute) as? String) == kAXStaticTextRole { name = label(c) } } }
        rows.append((name, e))
    }
}
let wanted = CommandLine.arguments.dropFirst()
for (name, row) in rows where wanted.isEmpty || wanted.contains(name) {
    AXUIElementSetAttributeValue(row, kAXSelectedAttribute as CFString, kCFBooleanTrue)
    usleep(700_000)
    print("## \(name)")
    var seen = Set<String>()
    walk(win) { e in
        let role = attr(e, kAXRoleAttribute) as? String ?? ""
        guard [kAXStaticTextRole, kAXCheckBoxRole, kAXPopUpButtonRole, kAXRadioButtonRole, kAXButtonRole, kAXSliderRole, kAXTextFieldRole].contains(role) else { return }
        var inList = false; var p = attr(e, kAXParentAttribute)
        while let q = p { if (attr(q as! AXUIElement, kAXRoleAttribute) as? String) == kAXRowRole { inList = true; break }; p = attr(q as! AXUIElement, kAXParentAttribute) }
        if inList { return }
        let l = label(e); let key = role + l
        if !l.isEmpty, !seen.contains(key) { seen.insert(key); print("  \(role.replacingOccurrences(of: "AX", with: "")): \(l)") }
    }
}
if wanted.isEmpty { print("rows:", rows.map { $0.0 }) }
