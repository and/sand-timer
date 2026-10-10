import AppKit

/// The settings that aren't a quick change to the timer itself: a daily target to aim for, the projects time is counted
/// against, and the switches that used to crowd the right-click menu. One window, reused: asking for it again brings the same one back to the front.
final class SettingsPanel: NSPanel, NSWindowDelegate {
    private static var shared: SettingsPanel?
    /// The open window, if there is one. Tests look here.
    static var open: SettingsPanel? { shared?.isVisible == true ? shared : nil }

    let settings = SettingsView()

    /// Opens the window, on a given page if asked (0 General, 1 Projects, 2 Sound, 3 Phone & Focus).
    static func show(for view: HourglassView, page: Int? = nil) {
        let panel = shared ?? SettingsPanel()
        shared = panel
        panel.settings.owner = view
        panel.settings.reload()
        if let page { panel.settings.show(page: page) }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(nil)  // opens with nothing selected, so a stray key can't overwrite a project's name
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
        settings.show(page: settings.tabs.selectedSegment)  // the size of the page showing, not the size it was saved at
    }

    /// A number still being typed counts when the window is closed, not just when Return is pressed.
    func windowWillClose(_ notification: Notification) { makeFirstResponder(nil) }
}

/// The contents of the settings window: the daily target, the projects, then the on/off switches.
final class SettingsView: NSView {
    weak var owner: HourglassView?

    /// One line of the project list: its colour, its name, whether shaking reaches it, and a way to remove it.
    struct ProjectRow {
        let color: NSColorWell
        let name: NSTextField
        let shake: NSButton
        let remove: NSButton
    }
    /// The project list's lines, by project id. Tests look here.
    private(set) var projectRows: [String: ProjectRow] = [:]
    /// Each row's line in the list, by project id, so a row can be added or taken away without rebuilding the others.
    private var projectLines: [String: NSView] = [:]
    let addProjectButton = NSButton(title: "Add Project", target: nil, action: nil)
    private let projectStack = NSStackView()
    private let projectScroll = NSScrollView()
    private var projectScrollHeight: NSLayoutConstraint?
    /// The ids the list was last built for; it is only rebuilt when they change, so typing in a name isn't interrupted.
    private var shownProjects: [String] = []
    private static let projectRowHeight: CGFloat = 26
    /// How many lines show before the list scrolls.
    private static let projectRowsShown = 6

    let targetCheck = NSButton(checkboxWithTitle: "Daily target", target: nil, action: nil)
    let targetField = NSTextField()
    let unitPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    let saveButton = NSButton(title: "Save", target: nil, action: nil)
    /// The tabs along the top, and the page each one shows.
    let tabs = NSSegmentedControl()
    private var pages: [NSStackView] = []
    private static let tabTitles = ["General", "Projects", "Sound", "Phone & Focus"]
    private static let tabKey = "settingsTab"
    private static let width: CGFloat = 420
    /// The switches, by what they are called.
    private(set) var switches: [String: NSButton] = [:]

    private static let units = ["minutes", "hours"]
    /// Sound: what plays while the sand runs, how loud, how soft; and the short sounds, each on or off.
    let noisePicker = NSPopUpButton(frame: .zero, pullsDown: false)
    let effectsCheck = NSButton(checkboxWithTitle: "Flip, Fall & Finish", target: nil, action: nil)
    let chimesCheck = NSButton(checkboxWithTitle: "Minute Chimes", target: nil, action: nil)
    let noiseVolume = NSSlider(value: FocusNoise.defaultVolume, minValue: 0, maxValue: 1, target: nil, action: nil)
    let noiseSoftness = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let noiseVolumeLabel = NSTextField(labelWithString: "")
    private let noiseSoftnessLabel = NSTextField(labelWithString: "")
    /// Linking a phone: what is linked, and the buttons to link one or unlink them all.
    let focusSwitch = NSButton(checkboxWithTitle: "Do Not Disturb while the sand runs", target: nil, action: nil)
    let focusStatus = NSTextField(wrappingLabelWithString: "")
    let focusButton = NSButton(title: "Open Shortcuts", target: nil, action: nil)
    let linkSwitch = NSButton(checkboxWithTitle: "Link with a phone", target: nil, action: nil)
    let linkButton = NSButton(title: "Link a Phone…", target: nil, action: nil)
    let unlinkButton = NSButton(title: "Unlink All", target: nil, action: nil)
    let linkStatus = NSTextField(wrappingLabelWithString: "")
    /// The line under One Thing at a Time saying what it does.
    private var oneThingNote: NSTextField?

    private enum Switch: Int, CaseIterable {
        case login, float, control, updates, oneThing

        var title: String {
            ["Start at Login", "Float Anywhere", "Control from Claude & Shortcuts", "Check for Updates", "One Thing at a Time"][rawValue]
        }
        var hint: String {
            ["Opens the timer when you log in to your Mac",
             "Keeps the timer wherever you let go of it, instead of dropping it to the bottom of the screen",
             "Lets sandtimer:// links start, pause, resume and restart the timer",
             "Asks GitHub once a day whether a newer Sand Timer has been released",
             "End the session to switch projects."][rawValue]
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

        let targetHint = Self.note("Fills a line on the base through the day. Hover to see it.")

        // Projects: made here, switched between from the menu or by shaking the timer.
        let projectsTitle = NSTextField(labelWithString: "Projects")
        projectsTitle.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        let projectsHint = Self.note("Time counts toward the active project. Shake to switch.")
        projectStack.orientation = .vertical
        projectStack.alignment = .leading
        projectStack.spacing = 4
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        projectStack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(projectStack)
        projectScroll.documentView = document
        projectScroll.drawsBackground = false
        projectScroll.hasVerticalScroller = true
        projectScroll.autohidesScrollers = true
        projectScroll.translatesAutoresizingMaskIntoConstraints = false
        let scrollHeight = projectScroll.heightAnchor.constraint(equalToConstant: 0)
        projectScrollHeight = scrollHeight
        NSLayoutConstraint.activate([
            projectStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            projectStack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            projectStack.topAnchor.constraint(equalTo: document.topAnchor),
            projectStack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.widthAnchor.constraint(equalTo: projectScroll.contentView.widthAnchor),
            scrollHeight,
        ])
        addProjectButton.target = self
        addProjectButton.action = #selector(addProjectClicked)
        addProjectButton.bezelStyle = .rounded
        addProjectButton.controlSize = .small

        // Sound: one thing playing while the sand runs, and the short sounds of things happening.
        let noiseTitle = NSTextField(labelWithString: "Sound")
        noiseTitle.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        let noiseHint = Self.note("What plays while the sand runs.")
        noisePicker.addItems(withTitles: Background.allCases.map(\.title))
        effectsCheck.target = self
        effectsCheck.action = #selector(effectsToggled)
        chimesCheck.target = self
        chimesCheck.action = #selector(chimesToggled)
        let effectsRow = NSStackView(views: [effectsCheck, chimesCheck])
        effectsRow.spacing = 18
        noisePicker.target = self
        noisePicker.action = #selector(noisePicked)
        for (slider, action) in [(noiseVolume, #selector(noiseVolumeChanged)), (noiseSoftness, #selector(noiseSoftnessChanged))] {
            slider.target = self
            slider.action = action
            slider.isContinuous = true
            slider.widthAnchor.constraint(equalToConstant: 200).isActive = true
        }
        for label in [noiseVolumeLabel, noiseSoftnessLabel] {
            label.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            label.textColor = .secondaryLabelColor
            label.widthAnchor.constraint(equalToConstant: 40).isActive = true
        }
        func row(_ name: String, _ slider: NSSlider, _ label: NSTextField) -> NSStackView {
            let title = NSTextField(labelWithString: name)
            title.widthAnchor.constraint(equalToConstant: 70).isActive = true
            let line = NSStackView(views: [title, slider, label])
            line.spacing = 8
            return line
        }
        let noiseVolumeRow = row("Volume", noiseVolume, noiseVolumeLabel)
        let noiseSoftnessRow = row("Softness", noiseSoftness, noiseSoftnessLabel)

        // Linking a phone: its projects and time shared with this Mac's.
        let linkTitle = NSTextField(labelWithString: "Phone")
        linkTitle.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        let linkHint = Self.note("Optional: link Sand Timer on your iPhone or Android phone to share one timer, your projects "
                                 + "and statistics. The two talk over Bluetooth, encrypted, whenever they're near each other.")
        linkStatus.font = .systemFont(ofSize: 11)
        linkStatus.textColor = .secondaryLabelColor
        for (button, action) in [(linkButton, #selector(linkClicked)), (unlinkButton, #selector(unlinkClicked))] {
            button.target = self
            button.action = action
            button.bezelStyle = .rounded
            button.controlSize = .small
        }
        linkSwitch.target = self
        linkSwitch.action = #selector(linkToggled)
        let linkRow = NSStackView(views: [linkButton, unlinkButton])
        linkRow.spacing = 8

        // Do Not Disturb, by way of two shortcuts: macOS has no switch for Focus that an app may use.
        let focusTitle = NSTextField(labelWithString: "Focus")
        focusTitle.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        let focusHint = Self.note("Runs two shortcuts you make once in the Shortcuts app: “\(FocusShortcuts.onName)”, "
                                  + "with Set Focus turning Do Not Disturb on, and “\(FocusShortcuts.offName)” turning it off. "
                                  + "With Share Across Devices on in Focus settings, your iPhone follows.")
        focusSwitch.target = self
        focusSwitch.action = #selector(focusToggled)
        focusStatus.font = .systemFont(ofSize: 11)
        focusStatus.textColor = .secondaryLabelColor
        focusButton.target = self
        focusButton.action = #selector(openShortcuts)
        focusButton.bezelStyle = .rounded
        focusButton.controlSize = .small
        let focusDivider = NSBox.separator()

        let divider = NSBox.separator()
        var general: [NSView] = [targetRow, targetHint, divider]
        var projectsPage: [NSView] = [projectsTitle, projectsHint, projectScroll, addProjectButton]
        for entry in Switch.allCases {
            let box = NSButton(checkboxWithTitle: entry.title, target: self, action: #selector(switchToggled(_:)))
            box.tag = entry.rawValue
            box.toolTip = entry.hint
            switches[entry.title] = box
            // One Thing at a Time is about projects, so it sits with them, its reason spelled out beneath it.
            if entry == .oneThing {
                let reason = Self.note(entry.hint)
                reason.widthAnchor.constraint(equalToConstant: Self.width - 44).isActive = true
                projectsPage += [box, reason]
                oneThingNote = reason
            } else {
                general.append(box)
            }
        }
        let sound: [NSView] = [noiseTitle, noiseHint, noisePicker, noiseVolumeRow, noiseSoftnessRow, effectsRow]
        let phone: [NSView] = [linkTitle, linkHint, linkSwitch, linkStatus, linkRow, focusDivider,
                               focusTitle, focusHint, focusSwitch, focusStatus, focusButton]

        // Everything already applies as it is changed; Save is for the number still being typed, and closes the window.
        saveButton.target = self
        saveButton.action = #selector(saveClicked)
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"  // the default button: Return saves
        let saveRow = NSStackView(views: [NSView(), saveButton])
        saveRow.distribution = .fill

        // A page for each kind of setting, so the window stays short enough to see whole.
        pages = [general, projectsPage, sound, phone].map { views in
            let page = NSStackView(views: views)
            page.orientation = .vertical
            page.alignment = .leading
            page.spacing = 12
            return page
        }
        func space(_ points: CGFloat, after view: NSView) {
            pages.first { $0.arrangedSubviews.contains(view) }?.setCustomSpacing(points, after: view)
        }
        space(6, after: targetRow)
        space(4, after: projectsTitle)
        space(8, after: projectsHint)
        space(8, after: projectScroll)
        space(4, after: noiseTitle)
        space(4, after: linkTitle)
        space(6, after: linkHint)
        space(6, after: linkSwitch)
        space(8, after: linkStatus)
        space(4, after: focusTitle)
        space(6, after: focusHint)
        space(6, after: focusSwitch)
        space(6, after: focusStatus)
        if let box = switches[Switch.oneThing.title] { space(4, after: box) }

        tabs.segmentCount = Self.tabTitles.count
        for (i, title) in Self.tabTitles.enumerated() { tabs.setLabel(title, forSegment: i) }
        tabs.trackingMode = .selectOne
        tabs.target = self
        tabs.action = #selector(tabPicked)
        let tabsRow = NSStackView(views: [tabs])
        tabsRow.alignment = .centerX

        let stack = NSStackView(views: [tabsRow] + pages + [saveRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 22, bottom: 20, right: 22)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let inner = Self.width - 44
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(equalToConstant: Self.width),
            tabsRow.widthAnchor.constraint(equalToConstant: inner),
            targetHint.widthAnchor.constraint(equalToConstant: inner),
            divider.widthAnchor.constraint(equalToConstant: inner),
            focusDivider.widthAnchor.constraint(equalToConstant: inner),
            linkHint.widthAnchor.constraint(equalToConstant: inner),
            linkStatus.widthAnchor.constraint(equalToConstant: inner),
            focusHint.widthAnchor.constraint(equalToConstant: inner),
            focusStatus.widthAnchor.constraint(equalToConstant: inner),
            projectsHint.widthAnchor.constraint(equalToConstant: inner),
            projectScroll.widthAnchor.constraint(equalToConstant: inner),
            saveRow.widthAnchor.constraint(equalToConstant: inner),
        ] + pages.map { $0.widthAnchor.constraint(equalToConstant: inner) })
        show(page: min(max(0, UserDefaults.standard.integer(forKey: Self.tabKey)), pages.count - 1))
        reload()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Shows one page, the window fitting it with its top edge kept where it was.
    func show(page index: Int) {
        tabs.selectedSegment = index
        for (i, page) in pages.enumerated() { page.isHidden = i != index }
        UserDefaults.standard.set(index, forKey: Self.tabKey)
        guard let window else { return }
        layoutSubtreeIfNeeded()
        let top = window.frame.maxY
        window.setContentSize(fittingSize)
        window.setFrameTopLeftPoint(NSPoint(x: window.frame.minX, y: top))
    }

    @objc private func tabPicked() { show(page: tabs.selectedSegment) }

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
        switches[Switch.oneThing.title]?.state = owner.oneThingAtATime ? .on : .off
        reloadProjects()
        reloadNoise()
        reloadLink()
        reloadFocus()
    }

    // MARK: Focus

    private func reloadFocus() {
        let focus = FocusShortcuts.shared
        focusSwitch.state = focus.isEnabled ? .on : .off
        focusStatus.isHidden = !focus.isEnabled
        guard focus.isEnabled else { return }
        focus.missing { [weak self] missing in
            self?.focusStatus.stringValue = missing.isEmpty
                ? "Both shortcuts are ready."
                : "Not found in Shortcuts yet: " + missing.map { "“\($0)”" }.joined(separator: " and ") + "."
        }
    }

    @objc func focusToggled() {
        FocusShortcuts.shared.setEnabled(focusSwitch.state == .on)
        reload()
    }

    @objc func openShortcuts() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Shortcuts.app"))
    }

    // MARK: Phone

    private func reloadLink() {
        let link = Link.engine
        linkSwitch.state = link.isEnabled ? .on : .off
        linkButton.isHidden = !link.isEnabled
        unlinkButton.isHidden = !link.isLinked
        linkStatus.isHidden = !link.isEnabled
        guard link.isLinked else {
            linkStatus.stringValue = "No phone linked."
            return
        }
        let ago = RelativeDateTimeFormatter()
        ago.unitsStyle = .full
        let here = link.connected
        var lines = link.devices.map { device in
            here.contains(device.id) ? "\(device.name) · connected"
                : "\(device.name) · last seen \(ago.localizedString(for: device.seen, relativeTo: Date()))"
        }
        if lines.isEmpty { lines = ["Waiting for a phone to scan the code."] }
        if let problem = Link.radio.problem { lines.append(problem) }
        linkStatus.stringValue = lines.joined(separator: "\n")
    }

    @objc func linkClicked() { LinkPanel.show() }

    /// On: Bluetooth may be used, and macOS asks the first time. Off: none at all, the link kept for next time.
    @objc func linkToggled() {
        Link.engine.setEnabled(linkSwitch.state == .on)
        reload()
    }

    /// Unlinks every phone, after saying what that means.
    @objc func unlinkClicked() {
        let alert = NSAlert()
        alert.messageText = "Unlink all phones?"
        alert.informativeText = "Your phones stop sharing the timer, projects and time with this Mac, and their time leaves "
            + "this Mac's statistics. Each phone keeps its own record. You can link again at any time."
        alert.addButton(withTitle: "Unlink")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Link.engine.unlink()
    }

    // MARK: Focus Sound

    private func reloadNoise() {
        let noise = FocusNoise.shared
        noisePicker.selectItem(at: Background.allCases.firstIndex(of: noise.background) ?? 0)
        noiseVolume.doubleValue = noise.volume
        noiseSoftness.doubleValue = noise.softness
        noiseVolumeLabel.stringValue = "\(Int((noise.volume * 100).rounded()))%"
        noiseSoftnessLabel.stringValue = noise.softness < 0.005 ? "Off" : "\(Int((noise.softness * 100).rounded()))%"
        noiseVolume.isEnabled = noise.background != .silence
        noiseSoftness.isEnabled = noise.kind != nil  // softness is for the noises; the sand sounds as sand does
        effectsCheck.state = owner?.soundOn == true ? .on : .off
        chimesCheck.state = owner?.minuteChimesOn == true ? .on : .off
    }

    @objc func noisePicked() {
        guard let background = Background.allCases[safe: noisePicker.indexOfSelectedItem] else { return }
        FocusNoise.shared.choose(background)
        reloadNoise()
    }

    @objc func effectsToggled() {
        owner?.soundToggled()
        reloadNoise()
    }

    @objc func chimesToggled() {
        owner?.minuteChimesToggled()
        reloadNoise()
    }

    @objc func noiseVolumeChanged() {
        FocusNoise.shared.setVolume(noiseVolume.doubleValue)
        reloadNoise()
    }

    @objc func noiseSoftnessChanged() {
        FocusNoise.shared.setSoftness(noiseSoftness.doubleValue)
        reloadNoise()
    }

    // MARK: Projects

    private func reloadProjects() {
        guard let owner else { return }
        let visible = owner.projects.visible
        if visible.map(\.id) != shownProjects {
            // Only the rows that came or went change: the others, and anything typed in them, are left as they are.
            let ids = Set(visible.map(\.id))
            for gone in shownProjects where !ids.contains(gone) {
                projectLines[gone]?.removeFromSuperview()
                projectLines[gone] = nil
                projectRows[gone] = nil
            }
            for project in visible where projectLines[project.id] == nil {
                let row = makeRow(for: project)
                projectRows[project.id] = row
                let line = NSStackView(views: [row.color, row.name, row.shake, row.remove])
                line.spacing = 8
                line.heightAnchor.constraint(equalToConstant: Self.projectRowHeight).isActive = true
                projectLines[project.id] = line
            }
            for (index, project) in visible.enumerated() {
                guard let line = projectLines[project.id] else { continue }
                let at = projectStack.arrangedSubviews.firstIndex(of: line)
                guard at != index else { continue }
                if at != nil { projectStack.removeArrangedSubview(line) }
                projectStack.insertArrangedSubview(line, at: min(index, projectStack.arrangedSubviews.count))
            }
            shownProjects = visible.map(\.id)
            let lines = CGFloat(min(visible.count, Self.projectRowsShown))
            projectScrollHeight?.constant = lines == 0 ? 0 : lines * Self.projectRowHeight + (lines - 1) * projectStack.spacing
            projectScroll.isHidden = visible.isEmpty
            fitWindow()
        }
        // Refresh what's shown without disturbing a name being typed.
        for project in visible {
            guard let row = projectRows[project.id] else { continue }
            if let color = NSColor(hex: project.color), row.color.color.hexString != project.color { row.color.color = color }
            if row.name.currentEditor() == nil { row.name.stringValue = project.name }
            row.shake.state = project.shakes ? .on : .off
        }
    }

    private func makeRow(for project: Project) -> ProjectRow {
        let well = NSColorWell(style: .minimal)
        well.color = NSColor(hex: project.color) ?? .systemPurple
        well.target = self
        well.action = #selector(projectColorChanged(_:))
        well.identifier = NSUserInterfaceItemIdentifier(project.id)
        well.widthAnchor.constraint(equalToConstant: 38).isActive = true
        let name = NSTextField(string: project.name)
        name.placeholderString = "Project name"
        name.target = self
        name.action = #selector(projectRenamed(_:))
        name.cell?.sendsActionOnEndEditing = true  // leaving the field renames, not just pressing Return
        name.identifier = NSUserInterfaceItemIdentifier(project.id)
        name.widthAnchor.constraint(equalToConstant: 190).isActive = true
        let shake = NSButton(checkboxWithTitle: "Shake", target: self, action: #selector(projectShakeToggled(_:)))
        shake.state = project.shakes ? .on : .off
        shake.toolTip = "Shaking the timer moves between the projects ticked here"
        shake.identifier = NSUserInterfaceItemIdentifier(project.id)
        let remove = NSButton(image: NSImage(systemSymbolName: "minus.circle", accessibilityDescription: "Remove") ?? NSImage(),
                              target: self, action: #selector(projectRemoved(_:)))
        remove.isBordered = false
        remove.toolTip = "Remove this project. The time already counted against it stays in Statistics."
        remove.identifier = NSUserInterfaceItemIdentifier(project.id)
        return ProjectRow(color: well, name: name, shake: shake, remove: remove)
    }

    /// Makes one change to the project whose row `control` is in, and hands the new list to the timer.
    private func change(_ control: NSView, _ edit: (inout Project) -> Void) {
        guard let owner, let id = control.identifier?.rawValue,
              let index = owner.projects.all.firstIndex(where: { $0.id == id }) else { return }
        var list = owner.projects
        edit(&list.all[index])
        owner.updateProjects(list)
        reloadProjects()
    }

    @objc func projectColorChanged(_ sender: NSColorWell) { change(sender) { $0.color = sender.color.hexString } }

    @objc func projectRenamed(_ sender: NSTextField) {
        let name = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { reloadProjects(); return }  // a project always has a name
        change(sender) { $0.name = name }
    }

    @objc func projectShakeToggled(_ sender: NSButton) { change(sender) { $0.shakes = sender.state == .on } }

    /// Removed from the menus and from shaking, but kept, so the time counted against it keeps its name and colour.
    @objc func projectRemoved(_ sender: NSButton) {
        commitEditing()
        change(sender) { $0.archived = true }
    }

    /// Takes a name still being typed before the list changes: a button click doesn't end the typing by itself.
    private func commitEditing() {
        guard let window, window.firstResponder is NSText else { return }
        window.makeFirstResponder(nil)
    }

    /// A new project, in a colour not already in use where possible, with its name ready to be typed over.
    @objc func addProjectClicked() {
        commitEditing()
        guard let owner else { return }
        var list = owner.projects
        let used = Set(list.visible.map(\.color))
        let palette = Theme.colors.map(\.sand.hexString) + ["#E8833A", "#3FA34D", "#D4B106", "#8E5A3C"]
        let color = palette.first { !used.contains($0) } ?? palette[list.all.count % palette.count]
        let project = Project(name: "Project \(list.visible.count + 1)", color: color)
        list.all.append(project)
        owner.updateProjects(list)
        reloadProjects()
        if let field = projectRows[project.id]?.name {
            window?.makeFirstResponder(field)
            field.currentEditor()?.selectAll(nil)
        }
        projectScroll.documentView?.scroll(NSPoint(x: 0, y: projectStack.fittingSize.height))
    }

    /// Grows or shrinks the window with the project list, keeping its top edge where it is.
    private func fitWindow() {
        guard let window else { return }
        layoutSubtreeIfNeeded()
        let size = fittingSize
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        window.setFrame(frame, display: true)
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
        window?.makeFirstResponder(nil)  // a project name still being typed is taken too
        targetEdited()
        window?.close()
    }

    @objc private func switchToggled(_ sender: NSButton) {
        switch Switch(rawValue: sender.tag) {
        case .login: owner?.loginToggled()
        case .float: owner?.floatToggled()
        case .control: owner?.controlToggled()
        case .updates: owner?.updateChecksToggled()
        case .oneThing: owner?.oneThingToggled()
        case nil: break
        }
        reload()  // a change macOS refused, like Start at Login, shouldn't stay ticked
    }
}

/// Lays the project list out from the top down, as a list is read.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

private extension NSBox {
    static func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }
}
