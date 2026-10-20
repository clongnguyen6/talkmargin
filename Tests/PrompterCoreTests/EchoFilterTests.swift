import Testing
@testable import PrompterCore

struct EchoFilterTests {
    @Test func speakerBleedIsEcho() {
        let meeting = "How many times does the refund worker retry, and are we still on track for the release?"
        #expect(EchoFilter.isEcho("How many times does the refund worker retry and are we still on track for release", of: meeting))
    }

    @Test func ownWordsAreNotEcho() {
        let meeting = "How many times does the refund worker retry?"
        #expect(!EchoFilter.isEcho("Ý họ hỏi số lần retry, trả lời giúp tôi ngắn gọn", of: meeting))
        #expect(!EchoFilter.isEcho("Tell them three times with exponential backoff", of: meeting))
        #expect(!EchoFilter.isEcho("anything", of: ""))
    }
}
