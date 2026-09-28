import AppKit

/// The settings that aren't a quick change to the timer itself: a daily target to aim for, and the switches that
/// used to crowd the right-click menu. One window, reused: asking for it again brings the same one back to the front.
final class SettingsPanel: NSPanel, NSWindowDelegate {
    private static var shared: SettingsPanel?
    /// The open window, if there is one. Tests look here.
    static var open: SettingsPanel? { shared?.isVisible == true ? shared : nil }

    let settings = SettingsView()

    static func show(for view: HourglassView) {
        let panel = shared ?? SettingsPanel()
        shared = panel
        panel.settings.owner = view
        panel.settings.reload()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 400, height: 240),
                   styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        title = "Sand Timer Settings"
        contentView = settings
        setContentSize(settings.fittingSize)
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isReleasedWhenClosed = false
        delegate = self
        setFrameAutosaveName("settings")  // reopens where it was last left
        if frameAutosaveName.isEmpty || frame.origin == .zero { center() }
    }

    /// A number still being typed counts when the window is closed, not just when Return is pressed.
    func windowWillClose(_ notification: Notification) { makeFirstResponder(nil) }
}

/// The contents of the settings window: the daily target, then the on/off switches.
final class SettingsView: NSView {
    weak var owner: HourglassView?

    let targetCheck = NSButton(checkboxWithTitle: "Daily target", target: nil, action: nil)
    let targetField = NSTextField()
    let unitPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    let saveButton = NSButton(title: "Save", target: nil, action: nil)
    /// The switches, by what they are called.
    private(set) var switches: [String: NSButton] = [:]

    private static let units = ["minutes", "hours"]

    private enum Switch: Int, CaseIterable {
        case login, float, control, updates

        var title: String {
            ["Start at Login", "Float Anywhere", "Control from Claude & Shortcuts", "Check for Updates"][rawValue]
        }
        var hint: String {
            ["Opens the timer when you log in to your Mac",
             "Keeps the timer wherever you let go of it, instead of dropping it to the bottom of the screen",
             "Lets sandtimer:// links start, pause, resume and restart the timer",
             "Asks GitHub once a day whether a newer Sand Timer has been released"][rawValue]
        }
    }

    init() {
        super.init(frame: .zero)

        targetCheck.target = self
        targetCheck.action = #selector(targetToggled)
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimum = 0
        formatter.maximum = NSNumber(value: HourglassView.longestDailyTarget)
        formatter.maximumFractionDigits = 2
        targetField.formatter = formatter
        targetField.alignment = .right
        targetField.target = self
        targetField.action = #selector(targetEdited)
        targetField.widthAnchor.constraint(equalToConstant: 64).isActive = true
        unitPicker.addItems(withTitles: Self.units)
        unitPicker.target = self
        unitPicker.action = #selector(targetEdited)
        let targetRow = NSStackView(views: [targetCheck, targetField, unitPicker])
        targetRow.spacing = 8

        let targetHint = Self.note("A line along the timer's base fills as the sand runs through the day, and is full at the target. Hover over the base to read it off, like 21:18/60:00.")

        let divider = NSBox.separator()
        var rows: [NSView] = [targetRow, targetHint, divider]
        for entry in Switch.allCases {
            let box = NSButton(checkboxWithTitle: entry.title, target: self, action: #selector(switchToggled(_:)))
            box.tag = entry.rawValue
            box.toolTip = entry.hint
            switches[entry.title] = box
            rows.append(box)
        }

        // Everything already applies as it is changed; Save is for the number still being typed, and closes the window.
        saveButton.target = self
        saveButton.action = #selector(saveClicked)
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"  // the default button: Return saves
        let saveRow = NSStackView(views: [NSView(), saveButton])
        saveRow.distribution = .fill
        rows.append(saveRow)

        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.setCustomSpacing(6, after: targetRow)
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 22, bottom: 20, right: 22)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(equalToConstant: 400),
            targetHint.widthAnchor.constraint(equalToConstant: 400 - 44),
            divider.widthAnchor.constraint(equalToConstant: 400 - 44),
            saveRow.widthAnchor.constraint(equalToConstant: 400 - 44),
        ])
        reload()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private static func note(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        return label
    }

    /// Shows what the timer is set to now.
    func reload() {
        guard let owner else { return }
        let minutes = owner.dailyTargetMinutes
        targetCheck.state = minutes > 0 ? .on : .off
        if minutes > 0 {
            let inHours = minutes % 60 == 0
            targetField.doubleValue = inHours ? Double(minutes / 60) : Double(minutes)
            unitPicker.selectItem(at: inHours ? 1 : 0)
        } else if targetField.stringValue.isEmpty {
            targetField.doubleValue = 1  // what switching it on starts from: an hour
            unitPicker.selectItem(at: 1)
        }
        targetField.isEnabled = minutes > 0
        unitPicker.isEnabled = minutes > 0

        switches[Switch.login.title]?.state = owner.startsAtLogin ? .on : .off
        switches[Switch.float.title]?.state = owner.floats ? .on : .off
        switches[Switch.control.title]?.state = owner.allowsControl ? .on : .off
        switches[Switch.updates.title]?.state = UpdateChecker.shared.isEnabled ? .on : .off
    }

    /// The target as the fields read now, in minutes.
    private var enteredMinutes: Int {
        let value = targetField.doubleValue
        return Int((unitPicker.indexOfSelectedItem == 1 ? value * 60 : value).rounded())
    }

    @objc private func targetToggled() {
        // Switching it on with nothing sensible typed in starts from an hour.
        if targetCheck.state == .on, enteredMinutes < 1 {
            targetField.doubleValue = 1
            unitPicker.selectItem(at: 1)
        }
        owner?.setDailyTarget(minutes: targetCheck.state == .on ? enteredMinutes : 0)
        reload()
    }

    @objc private func targetEdited() {
        guard targetCheck.state == .on else { return }
        owner?.setDailyTarget(minutes: enteredMinutes)
        reload()  // a target that came out as nothing switches itself off; one too large is brought back to a day
    }

    /// Takes whatever is in the number field, even if Return was never pressed in it, and closes the window.
    @objc func saveClicked() {
        window?.makeFirstResponder(nil)
        targetEdited()
        window?.close()
    }

    @objc private func switchToggled(_ sender: NSButton) {
        switch Switch(rawValue: sender.tag) {
        case .login: owner?.loginToggled()
        case .float: owner?.floatToggled()
        case .control: owner?.controlToggled()
        case .updates: owner?.updateChecksToggled()
        case nil: break
        }
        reload()  // a change macOS refused, like Start at Login, shouldn't stay ticked
    }
}

private extension NSBox {
    static func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }
}
