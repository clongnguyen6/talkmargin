import Foundation

/// Calls `onChange` whenever the file is written, including editors that
/// save atomically by replacing the file (rename/delete + create).
@MainActor
final class FileWatcher {
    private let url: URL
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    private var stopped = false

    init(url: URL, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange
        start()
    }

    func stop() {
        stopped = true
        pending?.cancel()
        source?.cancel()
        source = nil
    }

    /// `reload`: the file was missing when last tried (mid-replacement), so a reload
    /// may have shown an error; report a change once it is back.
    private func start(reload: Bool = false) {
        guard !stopped else { return }
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else {
            // The file may be mid-replacement; try again shortly.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                MainActor.assumeIsolated { self?.start(reload: true) }
            }
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.handle(source.data) }
        }
        source.setCancelHandler { close(fd) }
        self.source = source
        source.resume()
        if reload { scheduleChange() }
    }

    private func handle(_ events: DispatchSource.FileSystemEvent) {
        if events.contains(.delete) || events.contains(.rename) {
            source?.cancel()
            source = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                MainActor.assumeIsolated { self?.start() }
            }
        }
        scheduleChange()
    }

    private func scheduleChange() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.stopped else { return }
                self.onChange()
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }
}
