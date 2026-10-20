import AppKit
import PrompterCore

/// Live display controls: backdrop, blur, text band, text opacity, font size, and the interface language.
/// Shown in a dropdown inside the overlay, so every control takes the first click.
@MainActor
final class DisplaySettingsController: NSViewController {
    enum Change {
        case appearance
        case fontSize(Double)
        case reset
        case language(UILanguage)
    }

    private let settings: Settings
    private let onChange: (Change) -> Void

    private let backdropSlider = FirstClickSlider(0...100)
    private let blurSwitch = HeaderButton.checkbox("")
    private let bandSlider = FirstClickSlider(0...100)
    private let textSlider = FirstClickSlider(40...100)
    private let backdropValue = NSTextField(labelWithString: "")
    private let bandValue = NSTextField(labelWithString: "")
    private let textValue = NSTextField(labelWithString: "")
    private let fontValue = NSTextField(labelWithString: "")
    private let languageControl = FirstClickSegmentedControl(labels: UILanguage.allCases.map(\.code), trackingMode: .selectOne,
                                                             target: nil, action: nil)
    private let backdropName = name()
    private let bandName = name()
    private let textName = name()
    private let fontName = name()
    private let languageName = name()
    private let titleLabel = NSTextField(labelWithString: "")
    private let hint = NSTextField(wrappingLabelWithString: "")
    private let reset = HeaderButton()
    private let grid = NSGridView()
    private var hintWidth: NSLayoutConstraint?
    private var stackWidth: NSLayoutConstraint?

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
        languageControl.target = self
        languageControl.action = #selector(choseLanguage)
        languageControl.controlSize = .small
        // Clicking it must not move the keyboard focus (e.g. away from the question box).
        languageControl.refusesFirstResponder = true

        for row in [
            [backdropName, backdropSlider, backdropValue],
            [NSGridCell.emptyContentView, blurSwitch, NSGridCell.emptyContentView],
            [bandName, bandSlider, bandValue],
            [textName, textSlider, textValue],
            [fontName, fontControls, fontValue],
            [languageName, languageControl, NSGridCell.emptyContentView],
        ] { grid.addRow(with: row) }
        grid.rowSpacing = 10
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.cell(for: blurSwitch)?.row?.topPadding = -4

        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor

        reset.target = self
        reset.action = #selector(resetAll)
        reset.bezelStyle = .rounded
        reset.controlSize = .small

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)

        let stack = NSStackView(views: [titleLabel, grid, hint, reset])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        view = stack
        hintWidth = hint.widthAnchor.constraint(equalToConstant: 0)
        stackWidth = stack.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([hintWidth!, stackWidth!])
        localize()
    }

    /// Labels in the current language; the box is sized again since the label column changes width.
    func localize() {
        guard isViewLoaded, let stack = view as? NSStackView else { return }
        titleLabel.stringValue = tr(.displayTitle)
        backdropName.stringValue = tr(.displayBackdrop)
        blurSwitch.title = tr(.displayBlur)
        bandName.stringValue = tr(.displayTextBand)
        textName.stringValue = tr(.displayTextOpacity)
        fontName.stringValue = tr(.displayFontSize)
        languageName.stringValue = tr(.displayLanguage)
        hint.stringValue = tr(.displayHint, tr(.displayTextBand))
        reset.title = tr(.displayDefaults)
        // The hint wraps to the controls' width, and the dropdown sizes to fit both.
        let gridWidth = grid.fittingSize.width
        hint.preferredMaxLayoutWidth = gridWidth
        hintWidth?.constant = gridWidth
        stackWidth?.constant = gridWidth + stack.edgeInsets.left + stack.edgeInsets.right
        stack.frame.size = stack.fittingSize
        preferredContentSize = stack.frame.size
        refresh()
    }

    private static func name() -> NSTextField {
        let label = NSTextField(labelWithString: "")
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
        languageControl.selectedSegment = UILanguage.allCases.firstIndex(of: settings.language) ?? 0
        updateLabels()
    }

    private func updateLabels() {
        backdropValue.stringValue = "\(Int(backdropSlider.doubleValue.rounded()))%"
        bandValue.stringValue = bandSlider.doubleValue < 1 ? tr(.displayOff) : "\(Int(bandSlider.doubleValue.rounded()))%"
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

    @objc private func choseLanguage() {
        guard UILanguage.allCases.indices.contains(languageControl.selectedSegment) else { return }
        onChange(.language(UILanguage.allCases[languageControl.selectedSegment]))
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

private final class FirstClickSegmentedControl: NSSegmentedControl {
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
