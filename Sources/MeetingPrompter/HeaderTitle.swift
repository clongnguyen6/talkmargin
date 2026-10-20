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
    /// Built again on every render, so a notice follows a language change while it shows.
    private var notice: (() -> String)?
    private var noticeEnd: DispatchWorkItem?

    init(_ label: NSTextField) {
        self.label = label
    }

    func showHint(_ text: String?) {
        hint = text
        render()
    }

    func showNotice(_ text: @autoclosure @escaping () -> String, seconds: Double) {
        notice = text
        render()
        noticeEnd?.cancel()
        let end = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.notice = nil
                self.render()
            }
        }
        noticeEnd = end
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: end)
    }

    /// After a language change: the notice is rebuilt; a hover hint is dropped until the pointer moves again.
    func relocalize() {
        hint = nil
        render()
    }

    private func render() {
        label.stringValue = notice?() ?? hint ?? base
    }
}
