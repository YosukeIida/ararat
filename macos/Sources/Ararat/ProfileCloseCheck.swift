enum ProfileCloseCheck {
    static func restorationReady(selected: String?, active: String?,
                                 request: (command: String?, resolved: Bool, activated: Bool)?) -> Bool {
        guard selected != nil, selected == active else { return false }
        // Why not require a request: the transaction callback clears it after completion.
        return request.map { $0.resolved && $0.activated } ?? true
    }
}
