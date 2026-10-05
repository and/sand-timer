import AppKit
import ServiceManagement

/// The first thing a new install shows, once: how the timer is worked, and three choices — what you're working on,
/// what to hear while the sand runs, and whether it opens when you log in. Every one is optional, every one can be
/// changed later in Settings, and it ends by starting the first timer. "Getting Started…" in the menu brings it back.
final class WelcomePanel: NSPanel, NSWindowDelegate {
    private static var shared: WelcomePanel?
    /// The open window, if there is one. Tests look here.
    static var open: WelcomePanel? { shared?.isVisible == true ? shared : nil }
    /// Set once the welcome has been seen, so it isn't shown again by itself.
    static let seenKey = "welcomed"

    let welcome = WelcomeView()

    /// A new install sees the welcome; someone updating from a version without one does not. Every earlier version
    /// asked about Start at Login on its first launch, so that having been answered marks an existing install.
    static func shouldWelcome(_ defaults: UserDefaults = .standard) -> Bool {
        !defaults.bool(forKey: seenKey) && !defaults.bool(forKey: "loginItemConfigured")
    }

    static func show(for view: HourglassView) {
        let panel = shared ?? WelcomePanel()
        shared = panel
        panel.welcome.owner = view
        panel.welcome.reload()
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(nil)  // nothing typed into by accident
    }

    private init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 440, height: 480),
                   styleMask: [.titled, .closable], backing: .buffered, defer: false)
        title = "Welcome to Sand Timer"
        contentView = welcome
        setContentSize(welcome.fittingSize)
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isReleasedWhenClosed = false
        delegate = self
    }

    /// Closed with the red button: the same as Skip, so it doesn't come back by itself.
    func windowWillClose(_ notification: Notification) { welcome.markSeen() }
}

/// The welcome's contents.
final class WelcomeView: NSView {
    weak var owner: HourglassView?

    /// Up to three projects to begin with, by name — or, with some already made, up to three more.
    let projectFields = (1...3).map { _ in NSTextField() }
    /// The projects already made, each with a dot of its colour; hidden when there are none.
    let existingProjects = NSTextField(wrappingLabelWithString: "")
    private let projectsNote = WelcomeView.note("Time is counted for each project, and the sand takes its colour.")
    let soundPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    let loginCheck = NSButton(checkboxWithTitle: "Open Sand Timer when I log in", target: nil, action: nil)
    let startButton = NSButton(title: "Start a Timer", target: nil, action: nil)
    let skipButton = NSButton(title: "Skip", target: nil, action: nil)

    private static let width: CGFloat = 440
    private static let inset: CGFloat = 28

    init() {
        super.init(frame: .zero)
        let inner = Self.width - 2 * Self.inset

        let title = NSTextField(labelWithString: "An hourglass for your desktop")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        let intro = Self.note("A few choices to begin with. All of them are optional, and all of them are in Settings later.", size: 12)

        // How it's worked: the one thing the timer can't show by looking at it.
        let tips = NSStackView(views: [
            Self.tip("cursorarrow.click", "Click to start. Click again to pause, once more to carry on."),
            Self.tip("hand.draw", "Drag it anywhere. It settles at the bottom of the screen."),
            Self.tip("contextualmenu.and.cursorarrow", "Right-click for everything else: length, colour, size and more."),
        ])
        tips.orientation = .vertical
        tips.alignment = .leading
        tips.spacing = 8

        let projectsTitle = Self.heading("What are you working on?")
        let fields = NSStackView(views: projectFields)
        fields.spacing = 8
        fields.distribution = .fillEqually

        let soundTitle = Self.heading("While the sand runs")
        soundPicker.addItems(withTitles: Background.allCases.map(\.title))
        soundPicker.target = self
        soundPicker.action = #selector(soundPicked)  // picking a noise plays a few seconds of it
        let soundNote = Self.note("Pick a noise to hear a few seconds of it.")

        startButton.bezelStyle = .rounded
        startButton.keyEquivalent = "\r"
        startButton.target = self
        startButton.action = #selector(startClicked)
        skipButton.bezelStyle = .rounded
        skipButton.target = self
        skipButton.action = #selector(skipClicked)
        let buttons = NSStackView(views: [skipButton, NSView(), startButton])

        let stack = NSStackView(views: [title, intro, tips, Self.divider(), projectsTitle, projectsNote, existingProjects, fields, Self.divider(),
                                        soundTitle, soundPicker, soundNote, Self.divider(), loginCheck, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(4, after: title)
        stack.setCustomSpacing(16, after: intro)
        stack.setCustomSpacing(4, after: projectsTitle)
        stack.setCustomSpacing(4, after: soundTitle)
        stack.setCustomSpacing(20, after: loginCheck)
        stack.edgeInsets = NSEdgeInsets(top: 24, left: Self.inset, bottom: 22, right: Self.inset)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        var constraints = [
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(equalToConstant: Self.width),
        ]
        for view in [intro, tips, projectsNote, existingProjects, fields, soundNote, buttons] {
            constraints.append(view.widthAnchor.constraint(equalToConstant: inner))
        }
        for divider in stack.arrangedSubviews where divider is NSBox {
            constraints.append(divider.widthAnchor.constraint(equalToConstant: inner))
        }
        NSLayoutConstraint.activate(constraints)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Shows what's set now: shown again from the menu, it starts from the current sound and login setting.
    func reload() {
        soundPicker.selectItem(at: Background.allCases.firstIndex(of: FocusNoise.shared.background) ?? 0)
        loginCheck.state = owner?.startsAtLogin == true ? .on : .off
        for field in projectFields { field.stringValue = "" }

        // Projects already made are listed, so the fields below can only add to them, never rename or repeat them.
        let made = owner?.projects.visible ?? []
        existingProjects.isHidden = made.isEmpty
        existingProjects.attributedStringValue = Self.list(made)
        projectsNote.stringValue = made.isEmpty
            ? "Time is counted for each project, and the sand takes its colour."
            : "Your projects so far. Add more here, or change them in Settings."
        for (index, field) in projectFields.enumerated() {
            field.placeholderString = made.isEmpty ? (index == 0 ? "e.g. Writing" : "Optional") : "Another project"
        }
        if let window {
            layoutSubtreeIfNeeded()
            window.setContentSize(fittingSize)
        }
    }

    /// "● DSA   ● AI   ● Job search", each dot in its project's colour.
    private static func list(_ projects: [Project]) -> NSAttributedString {
        let line = NSMutableAttributedString()
        let font = NSFont.systemFont(ofSize: 12)
        for (index, project) in projects.enumerated() {
            if index > 0 { line.append(NSAttributedString(string: "    ", attributes: [.font: font])) }
            line.append(NSAttributedString(string: "● ", attributes: [.font: font, .foregroundColor: NSColor(hex: project.color) ?? .secondaryLabelColor]))
            line.append(NSAttributedString(string: project.name, attributes: [.font: font, .foregroundColor: NSColor.labelColor]))
        }
        return line
    }

    @objc func soundPicked() {
        guard let background = Background.allCases[safe: soundPicker.indexOfSelectedItem] else { return }
        FocusNoise.shared.choose(background)
    }

    /// Takes the choices and starts the first timer.
    @objc func startClicked() {
        window?.makeFirstResponder(nil)  // a project name still being typed counts
        guard let owner else { return close() }
        // Projects: the names given, in colours of their own, the first one on.
        let names = projectFields.map { $0.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if !names.isEmpty {
            var list = owner.projects
            let palette = Theme.colors.map(\.sand.hexString) + ["#E8833A", "#3FA34D", "#D4B106"]
            var used = Set(list.visible.map(\.color))
            var made: [Project] = []
            for name in names {
                let color = palette.first { !used.contains($0) } ?? palette[made.count % palette.count]
                used.insert(color)
                made.append(Project(name: name, color: color))
            }
            let first = list.visible.isEmpty || owner.activeProjectID == nil
            list.all += made
            owner.updateProjects(list)
            // A first project goes on; added to ones already there, the project that's on stays on.
            if first { owner.switchProject(to: made[0].id) }
        }
        setStartAtLogin(loginCheck.state == .on, for: owner)
        close()
        owner.startSession(minutes: nil)  // the first timer, running by the time the welcome is gone
    }

    /// Leaves everything as it is. (A sound already picked stays picked: it was heard being chosen.)
    @objc func skipClicked() { close() }

    private func close() {
        markSeen()
        window?.close()
    }

    func markSeen() {
        UserDefaults.standard.set(true, forKey: WelcomePanel.seenKey)
        UserDefaults.standard.set(true, forKey: "loginItemConfigured")  // asked here, so never asked again elsewhere
    }

    /// Turns Start at Login on or off to match the box, only if that's a change.
    private func setStartAtLogin(_ on: Bool, for owner: HourglassView) {
        guard on != owner.startsAtLogin else { return }
        owner.loginToggled()
    }

    // MARK: Pieces

    private static func heading(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        return label
    }

    private static func note(_ text: String, size: CGFloat = 11) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: size)
        label.textColor = .secondaryLabelColor
        return label
    }

    private static func tip(_ symbol: String, _ text: String) -> NSView {
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        icon.widthAnchor.constraint(equalToConstant: 22).isActive = true
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 12)
        let row = NSStackView(views: [icon, label])
        row.spacing = 10
        row.alignment = .firstBaseline
        return row
    }

    private static func divider() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }
}
