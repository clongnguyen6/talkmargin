/// Which conversation the chat shows when a session is chosen.
public enum ConversationChoice {
    /// Linking `chosen` shows that session's latest conversation only when nothing is
    /// shown yet (launch) or it is a different session. Re-picking the linked session
    /// keeps the conversation shown, e.g. a new empty one or a reopened older one.
    public static func linkShowsLatest(isShowing: Bool, linked: String?, chosen: String?) -> Bool {
        !isShowing || linked != chosen
    }
}
