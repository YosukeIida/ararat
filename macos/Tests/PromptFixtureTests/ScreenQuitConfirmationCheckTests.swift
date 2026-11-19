import Testing
@testable import Ararat

@Test func beforeUnloadClicksRequireTheMatchingQuitAttempt() {
    let canAnswer = ScreenQuitConfirmationCheck.canAnswerBeforeUnload
    #expect(!canAnswer(true, [true], [], false))
    #expect(!canAnswer(true, [true, true], [false], false))
    #expect(!canAnswer(true, [true], [true, true], true))
    #expect(!canAnswer(true, [true, true], [true], true))
    #expect(canAnswer(true, [true, true], [true, true], true))

    #expect(!canAnswer(false, [true, true], [true, true, false], false))
    #expect(!canAnswer(false, [true, true], [true, true, false, true, true], true))
    #expect(!canAnswer(false, [true, true, true], [true, true, false, true], true))
    #expect(canAnswer(false, [true, true, true], [true, true, false, true, true], true))
}
