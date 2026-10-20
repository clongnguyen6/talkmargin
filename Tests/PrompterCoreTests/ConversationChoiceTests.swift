import Testing
@testable import PrompterCore

struct ConversationChoiceTests {
    @Test func launchRestoresLatestEvenWithoutASession() {
        #expect(ConversationChoice.linkShowsLatest(isShowing: false, linked: nil, chosen: "s1"))
        #expect(ConversationChoice.linkShowsLatest(isShowing: false, linked: nil, chosen: nil))
    }

    @Test func repickingTheLinkedSessionKeepsTheShownConversation() {
        // "Cuộc trò chuyện mới" or a reopened older conversation, then ⌥S ⌥↩ on the highlighted session.
        #expect(!ConversationChoice.linkShowsLatest(isShowing: true, linked: "s1", chosen: "s1"))
        #expect(!ConversationChoice.linkShowsLatest(isShowing: true, linked: nil, chosen: nil))
    }

    @Test func choosingAnotherSessionShowsItsLatest() {
        #expect(ConversationChoice.linkShowsLatest(isShowing: true, linked: "s1", chosen: "s2"))
        #expect(ConversationChoice.linkShowsLatest(isShowing: true, linked: "s1", chosen: nil))
        #expect(ConversationChoice.linkShowsLatest(isShowing: true, linked: nil, chosen: "s1"))
    }
}
