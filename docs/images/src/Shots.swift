import AppKit
import PrompterCore

// Harness for docs/images (built and run by render.sh, compiled with the app's sources in place of its main.swift):
// the overlay's real views with synthetic notes and chat, drawn offscreen into PNGs. Never shown on screen.
let arguments = CommandLine.arguments
guard arguments.count == 3 else { fatalError("usage: Shots <demo-notes.md> <out-dir>") }
let demoNotes = URL(fileURLWithPath: arguments[1])
let outDir = URL(fileURLWithPath: arguments[2], isDirectory: true)
let fm = FileManager.default

// Settings (UserDefaults.standard) and every file below must land in the scratch home.
let home = fm.homeDirectoryForCurrentUser.resolvingSymlinksInPath()
guard let fixed = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"],
      home.path == URL(fileURLWithPath: fixed).resolvingSymlinksInPath().path else {
    fatalError("run through render.sh (CFFIXED_USER_HOME must be the scratch home)")
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

// MARK: - Synthetic files

let meetings = home.appending(path: "Documents/Meetings")
try fm.createDirectory(at: meetings, withIntermediateDirectories: true)
let notesURL = meetings.appending(path: "kestrel-roadmap-review.md")
try fm.copyItem(at: demoNotes, to: notesURL)
let notesText = try String(contentsOf: notesURL, encoding: .utf8)
let others = ["customer-call-notes.md", "team-offsite-agenda.md", "interview-script.txt"].map { name in
    let url = meetings.appending(path: name)
    try? Data("# \(name)\n".utf8).write(to: url)
    return url.path
}

// MARK: - Settings

let settings = Settings()
settings.fontSize = 16
settings.opacity = 0.85
settings.blurBehind = false // the blur material cannot be drawn offscreen
settings.textBand = 0
settings.textOpacity = 1
settings.outlineVisible = false
settings.chatVisible = false
settings.expanded = false
settings.recentFiles = others
let screen = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
settings.setFrame(NSRect(x: screen.minX + 60, y: screen.maxY - 260, width: 640, height: 236), expanded: false)
settings.setFrame(NSRect(x: screen.minX + 60, y: screen.maxY - 600, width: 1120, height: 560), expanded: true)

// MARK: - Synthetic Claude conversation, rendered by the app's ClaudeChat

let session = ClaudeSession(id: "00000000-0000-4000-8000-000000000001", cwd: home.appending(path: "code/kestrel").path,
                            title: "Kestrel beta launch prep", modified: Date().addingTimeInterval(-2 * 3600))
let projects = [
    ClaudeProject(cwd: session.cwd, sessions: [
        session,
        ClaudeSession(id: "00000000-0000-4000-8000-000000000002", cwd: session.cwd, title: "Load test plan review",
                      modified: Date().addingTimeInterval(-26 * 3600)),
    ]),
    ClaudeProject(cwd: home.appending(path: "code/website").path, sessions: [
        ClaudeSession(id: "00000000-0000-4000-8000-000000000003", cwd: home.appending(path: "code/website").path,
                      title: "Pricing page copy", modified: Date().addingTimeInterval(-3 * 86400)),
    ]),
]
let question = "Others: What happens if the load test fails?\nTôi: trả lời ngắn gọn giúp tôi"
let answer = """
- Theo mục **Q&A** trong ghi chú: giữ waitlist đóng, mời theo từng đợt 200 người.
- Rollback chỉ là tắt một flag, không có migration dữ liệu.

**Có thể nói:**
> "If the load test fails, we keep the waitlist closed and invite people in batches of 200. Rolling back is a single flag, with no data migration."
"""
let store = ConversationStore(file: home.appending(path: "conversations.json"))
var conversation = Conversation(link: session)
conversation.forkID = "00000000-0000-4000-8000-000000000004"
conversation.turns = [Conversation.Turn(title: "❓ Others: What happens if the load test fails? · 10:42:15", quote: question,
                                        answer: answer, notes: NotesVersion(path: notesURL.path, markdown: notesText))]
store.save(conversation)
let chat = ClaudeChat(store: store) { (notesURL.path, notesText) }
chat.link(to: session)

// MARK: - Rendering

let overlay = OverlayController(settings: settings)
overlay.suggestedSession = { chat.suggestedSession(forDocument: $0) }
overlay.setClaudeProjects(projects)

@MainActor func settle() {
    for _ in 0..<6 { RunLoop.main.run(until: Date().addingTimeInterval(0.08)) }
    overlay.panel.contentView?.layoutSubtreeIfNeeded()
    hideSystemBackdrops(overlay.panel.contentView!)
    precondition(!overlay.panel.isVisible, "the overlay must never be on screen")
}

/// The panel's content at 2x, on a synthetic video-call backdrop, with rounded corners and a shadow.
@MainActor func shoot(_ name: String) throws {
    settle()
    let view = overlay.panel.contentView!
    let size = view.bounds.size
    let scale: CGFloat = 2
    let content = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    content.size = size
    view.cacheDisplay(in: view.bounds, to: content)

    let margin: CGFloat = 36
    let canvas = NSSize(width: size.width + 2 * margin, height: size.height + 2 * margin)
    let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas.width * scale), pixelsHigh: Int(canvas.height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    out.size = canvas
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
    drawMeetingBackdrop(in: NSRect(origin: .zero, size: canvas))
    let frame = NSRect(x: margin, y: margin, width: size.width, height: size.height)
    let shape = NSBezierPath(roundedRect: frame, xRadius: 12, yRadius: 12)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = .black.withAlphaComponent(0.55)
    shadow.shadowBlurRadius = 22
    shadow.shadowOffset = NSSize(width: 0, height: -6)
    shadow.set()
    // The backdrop layer of the overlay (a layer color, which cacheDisplay does not draw).
    NSColor.black.withAlphaComponent(0.9 * settings.opacity).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    content.draw(in: frame)
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.restoreGraphicsState()
    try out.representation(using: .png, properties: [:])!.write(to: outDir.appending(path: "\(name).png"))
    print("wrote docs/images/\(name).png (\(Int(canvas.width * scale)) x \(Int(canvas.height * scale)))")
}

/// macOS scroll-edge and backdrop views composite live with the screen behind; offscreen they draw opaque
/// over the text. They are system decoration, not the app's, so the snapshot leaves them out.
@MainActor func hideSystemBackdrops(_ view: NSView) {
    let name = String(describing: type(of: view))
    if ["Pocket", "BackdropView", "LuminanceAdjustment", "ContentBackgroundView"].contains(where: name.contains) {
        view.isHidden = true
        return
    }
    view.subviews.forEach(hideSystemBackdrops)
}

/// A plain, clearly synthetic meeting window: four participant tiles with initials.
@MainActor func drawMeetingBackdrop(in rect: NSRect) {
    NSColor(calibratedRed: 0.13, green: 0.14, blue: 0.17, alpha: 1).setFill()
    rect.fill()
    let colors: [NSColor] = [
        NSColor(calibratedRed: 0.30, green: 0.36, blue: 0.48, alpha: 1), NSColor(calibratedRed: 0.42, green: 0.34, blue: 0.40, alpha: 1),
        NSColor(calibratedRed: 0.30, green: 0.42, blue: 0.38, alpha: 1), NSColor(calibratedRed: 0.44, green: 0.40, blue: 0.30, alpha: 1),
    ]
    let gap: CGFloat = 10
    let tile = NSSize(width: (rect.width - 3 * gap) / 2, height: (rect.height - 3 * gap) / 2)
    for (index, initials) in ["A", "B", "C", "D"].enumerated() {
        let origin = NSPoint(x: rect.minX + gap + CGFloat(index % 2) * (tile.width + gap),
                             y: rect.minY + gap + CGFloat(index / 2) * (tile.height + gap))
        let box = NSRect(origin: origin, size: tile)
        colors[index].setFill()
        NSBezierPath(roundedRect: box, xRadius: 10, yRadius: 10).fill()
        let radius = min(tile.width, tile.height) * 0.16
        let circle = NSRect(x: box.midX - radius, y: box.midY - radius, width: 2 * radius, height: 2 * radius)
        NSColor.white.withAlphaComponent(0.22).setFill()
        NSBezierPath(ovalIn: circle).fill()
        let text = NSAttributedString(string: initials, attributes: [
            .font: NSFont.systemFont(ofSize: radius * 0.9, weight: .semibold), .foregroundColor: NSColor.white.withAlphaComponent(0.8)])
        let textSize = text.size()
        text.draw(at: NSPoint(x: circle.midX - textSize.width / 2, y: circle.midY - textSize.height / 2))
    }
}

// 1. Compact reading.
overlay.open(notesURL)
try shoot("overlay-compact")

// 2. Expanded: outline, a jump (with the way back in the header), and the Claude column.
overlay.setExpanded(true)
overlay.setOutlineVisible(true)
overlay.setAssistant(markdown: chat.markdown, title: chat.title, pin: chat.pinnedTitle)
overlay.setLinkedSession(chat.link)
overlay.setTerminalAvailable(chat.terminalSession != nil)
overlay.setClaudeContext(busy: false, documentPath: notesURL.path)
overlay.setChatVisible(true)
settle()
overlay.jumpToSection(3)
try shoot("overlay-expanded")

// 3. Document picker under the file name.
overlay.toggleDocumentPicker()
try shoot("document-picker")
overlay.closePickers()

// 4. Session picker under the chat title.
overlay.toggleSessionPicker()
try shoot("session-picker")
overlay.closePickers()
