enum ScreenQuitConfirmationCheck {
    static let firstQuit = [true, true]
    static let afterStay = firstQuit + [false]
    static let retryQuit = afterStay + firstQuit

    static func canAnswerBeforeUnload(stay: Bool, panels: [Bool], closing: [Bool], tryingToQuit: Bool) -> Bool {
        guard tryingToQuit else { return false }
        if stay { return panels == [true, true] && closing == firstQuit }
        return panels == [true, true, true] && closing == retryQuit
    }
}
