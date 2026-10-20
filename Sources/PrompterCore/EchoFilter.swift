import Foundation

/// Without headphones the microphone also hears the meeting from the speakers.
public enum EchoFilter {
    /// True when most words of `microphone` also appear in `meeting`, i.e. the
    /// mic picked up the speakers rather than the user speaking.
    public static func isEcho(_ microphone: String, of meeting: String) -> Bool {
        let micWords = words(microphone)
        guard !micWords.isEmpty else { return false }
        let meetingWords = Set(words(meeting))
        let shared = micWords.filter(meetingWords.contains).count
        return Double(shared) / Double(micWords.count) >= 0.6
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}
