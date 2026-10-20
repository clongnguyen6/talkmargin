import Foundation

/// Everything the app itself writes into what reaches Claude: the system prompt, the
/// answer-language instruction, the fork name and the push-to-talk speaker labels.
/// Deliberately independent of the interface language (`UIText`); `ClaudeTextTests`
/// pins it. Changing it changes Claude's behaviour, not a translation.
public enum ClaudeText {
    public static let systemPrompt = """
    You are the user's assistant during a live English-language meeting, shown in a small overlay only the \
    user can see. Questions may quote what was just said in the meeting ("Others: …" is other participants, \
    captured by speech recognition, so expect misheard words and infer the intended meaning) followed by the \
    user's own words ("Tôi: …", often Vietnamese). Messages may include the user's prepared notes in \
    <meeting_notes>, edits to them, or notices that the user switched documents. Answer from the notes the user \
    is reading now (the latest ones); earlier notes and answers stay useful background.

    Rules:
    - Write explanations in Vietnamese. Write anything the user might say out loud in the meeting in natural English.
    - Be brief and scannable: short bullets, no preamble, no closing remarks. The user reads this mid-conversation.
    - When a quoted question is directed at the user, give 1-3 short English lines they could say.
    - Only look at files in the working directory when it is needed to answer accurately, and prefer a few targeted reads. Never change anything.
    - If you are unsure, say so in one line instead of guessing.
    """

    /// Appended to every question.
    public static let answerLanguage = "Viết câu trả lời bằng tiếng Việt. Chỉ những câu gợi ý để tôi nói ra trong cuộc họp mới viết bằng tiếng Anh."

    /// The question, preceded by what Claude needs to know about the notes.
    public static func prompt(_ question: String, notes: String?) -> String {
        [notes, question, answerLanguage].compactMap { $0 }.joined(separator: "\n\n")
    }

    /// Name prefix of the read-only forks the chat creates, as `claude --resume` lists them.
    public static let meetingForkPrefix = "🎙 Meeting · "

    /// Name of the fork in `claude --resume`, so it is not mistaken for the original.
    public static func forkName(sessionTitle: String) -> String {
        meetingForkPrefix + sessionTitle
    }

    /// Title the session catalog gives a session with none; part of the fork name, so the
    /// interface shows `UIText.Key.sessionUntitled` for it instead.
    public static let untitledSession = "Session không tên"

    /// Push-to-talk text for the question box: the meeting audio and the user's microphone.
    public static func transcript(others: String, mine: String) -> String {
        switch (others.isEmpty, mine.isEmpty) {
        case (false, false): "Others: \(others)\nTôi: \(mine)"
        case (false, true): "Others: \(others)"
        default: mine
        }
    }
}
