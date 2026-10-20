import AppKit

/// Live display controls: backdrop, blur, text band, text opacity, font size.
/// Shown in a dropdown inside the overlay, so every control takes the first click.
@MainActor
final class DisplaySettingsController: NSViewController {
    enum Change {
        case appearance
        case fontSize(Double)
        case reset
    }

    private let settings: Settings
    private let onChange: (Change) -> Void

    private let backdropSlider = FirstClickSlider(0...100)
    private let blurSwitch = HeaderButton.checkbox("Làm mờ app phía sau")
    private let bandSlider = FirstClickSlider(0...100)
    private let textSlider = FirstClickSlider(40...100)
    private let backdropValue = NSTextField(labelWithString: "")
    private let bandValue = NSTextField(labelWithString: "")
    private let textValue = NSTextField(labelWithString: "")
    private let fontValue = NSTextField(labelWithString: "")

    init(settings: Settings, onChange: @escaping (Change) -> Void) {
        self.settings = settings
        self.onChange = onChange
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func loadView() {
        for slider in [backdropSlider, bandSlider, textSlider] {
            slider.isContinuous = true
            slider.target = self
            slider.action = #selector(slid)
            slider.widthAnchor.constraint(equalToConstant: 150).isActive = true
        }
        blurSwitch.target = self
        blurSwitch.action = #selector(toggledBlur)
        for label in [backdropValue, bandValue, textValue, fontValue] {
            label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            label.textColor = .secondaryLabelColor
            label.alignment = .right
            label.widthAnchor.constraint(equalToConstant: 38).isActive = true
        }

        let smaller = HeaderButton.push("−", target: self, action: #selector(smallerFont))
        let bigger = HeaderButton.push("+", target: self, action: #selector(biggerFont))
        for button in [smaller, bigger] {
            button.bezelStyle = .rounded
            button.controlSize = .small
        }
        let fontControls = NSStackView(views: [smaller, bigger])
        fontControls.spacing = 4

        let grid = NSGridView(views: [
            [Self.name("Nền"), backdropSlider, backdropValue],
            [NSGridCell.emptyContentView, blurSwitch, NSGridCell.emptyContentView],
            [Self.name("Nền sau chữ"), bandSlider, bandValue],
            [Self.name("Độ đậm chữ"), textSlider, textValue],
            [Self.name("Cỡ chữ"), fontControls, fontValue],
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.cell(for: blurSwitch)?.row?.topPadding = -4

        let hint = NSTextField(wrappingLabelWithString: "Tắt làm mờ để nhìn xuyên (ví dụ màn hình đang share); tăng \"Nền sau chữ\" để chữ vẫn rõ trên nền sáng.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor

        let reset = HeaderButton.push("Mặc định", target: self, action: #selector(resetAll))
        reset.bezelStyle = .rounded
        reset.controlSize = .small

        let title = NSTextField(labelWithString: "Hiển thị")
        title.font = .systemFont(ofSize: 13, weight: .semibold)

        let stack = NSStackView(views: [title, grid, hint, reset])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        view = stack
        // The hint wraps to the controls' width, and the popover sizes to fit both.
        let gridWidth = grid.fittingSize.width
        hint.preferredMaxLayoutWidth = gridWidth
        hint.widthAnchor.constraint(equalToConstant: gridWidth).isActive = true
        stack.widthAnchor.constraint(equalToConstant: gridWidth + stack.edgeInsets.left + stack.edgeInsets.right).isActive = true
        stack.frame.size = stack.fittingSize
        preferredContentSize = stack.frame.size
        refresh()
    }

    private static func name(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12)
        return label
    }

    /// Shows the current settings (they can also change from shortcuts).
    func refresh() {
        guard isViewLoaded else { return }
        backdropSlider.doubleValue = settings.opacity * 100
        blurSwitch.state = settings.blurBehind ? .on : .off
        bandSlider.doubleValue = settings.textBand * 100
        textSlider.doubleValue = settings.textOpacity * 100
        updateLabels()
    }

    private func updateLabels() {
        backdropValue.stringValue = "\(Int(backdropSlider.doubleValue.rounded()))%"
        bandValue.stringValue = bandSlider.doubleValue < 1 ? "Tắt" : "\(Int(bandSlider.doubleValue.rounded()))%"
        textValue.stringValue = "\(Int(textSlider.doubleValue.rounded()))%"
        fontValue.stringValue = "\(Int(settings.fontSize))pt"
    }

    @objc private func slid() {
        settings.opacity = backdropSlider.doubleValue / 100
        settings.textBand = bandSlider.doubleValue / 100
        settings.textOpacity = textSlider.doubleValue / 100
        updateLabels()
        onChange(.appearance)
    }

    @objc private func toggledBlur() {
        settings.blurBehind = blurSwitch.state == .on
        onChange(.appearance)
    }

    @objc private func smallerFont() {
        onChange(.fontSize(-1))
        updateLabels()
    }

    @objc private func biggerFont() {
        onChange(.fontSize(1))
        updateLabels()
    }

    @objc private func resetAll() {
        settings.resetDisplay()
        refresh()
        onChange(.reset)
    }
}

private final class FirstClickSlider: NSSlider {
    convenience init(_ range: ClosedRange<Double>) {
        self.init(value: range.lowerBound, minValue: range.lowerBound, maxValue: range.upperBound, target: nil, action: nil)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private extension HeaderButton {
    static func checkbox(_ title: String) -> HeaderButton {
        let button = HeaderButton()
        button.setButtonType(.switch)
        button.title = title
        return button
    }

    static func push(_ title: String, target: AnyObject, action: Selector) -> HeaderButton {
        let button = HeaderButton()
        button.title = title
        button.bezelStyle = .rounded
        button.target = target
        button.action = action
        return button
    }
}
