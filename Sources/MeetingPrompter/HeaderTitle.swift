import AppKit

/// One header label with three layers of text: the title itself (`base`), a hover
/// hint while the pointer rests on a control, and a timed notice (copy done, chat
/// busy). The label always shows the top layer, so a title update during a notice
/// is kept for when the notice ends, and layers never capture each other's text.
@MainActor
final class HeaderTitle {
    let label: NSTextField
    var base = "" {
        didSet { render() }
    }
    private var hint: String?
    private var notice: String?
    private var noticeEnd: DispatchWorkItem?

    init(_ label: NSTextField) {
        self.label = label
    }

    func showHint(_ text: String?) {
        hint = text
        render()
    }

    func showNotice(_ text: String, seconds: Double) {
        notice = text
        render()
        noticeEnd?.cancel()
        let end = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.notice == text else { return }
                self.notice = nil
                self.render()
            }
        }
        noticeEnd = end
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: end)
    }

    private func render() {
        label.stringValue = notice ?? hint ?? base
    }
}
