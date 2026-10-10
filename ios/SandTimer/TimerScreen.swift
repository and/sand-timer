import SwiftUI

/// The lengths offered at a tap, the Mac's menu among them: a 25-minute Pomodoro, and 6 and 12 for billing time.
private let lengths = [5, 6, 10, 12, 15, 25, 30, 45, 60]

/// The glass, drawn by `GlassRenderer` each frame it's asked for.
private final class GlassUIView: UIView {
    let renderer = GlassRenderer()
    var frameState: (progress: Double, angle: Double, running: Bool, sand: UIColor, minutes: Int, display: GlassDisplay, time: Double)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ rect: CGRect) {
        guard let s = frameState else { return }
        renderer.draw(in: bounds.insetBy(dx: 4, dy: 4), progress: s.progress, angle: s.angle, running: s.running, sand: s.sand,
                      minutes: s.minutes, display: s.display, time: s.time)
    }
}

private struct Glass: UIViewRepresentable {
    var progress: Double
    var angle: Double
    var running: Bool
    var sand: UIColor
    var minutes: Int
    var display: GlassDisplay
    var time: Double

    func makeUIView(context: Context) -> GlassUIView { GlassUIView() }

    func updateUIView(_ view: GlassUIView, context: Context) {
        view.frameState = (progress, angle, running, sand, minutes, display, time)
        view.setNeedsDisplay()
    }
}

struct TimerScreen: View {
    @EnvironmentObject private var store: Store
    @ObservedObject private var calm = Calm.shared
    /// Where the middle of the glass sits among the controls, on screen: the clean view moves it to the middle.
    @State private var glassMidY: CGFloat = 0
    /// When the glass last began to lie down or stand up, and which way: a pause lays it on its side, as on the Mac.
    @State private var tilt: (lying: Bool, since: Date)?
    /// When a flip began: the glass turns over before the sand starts to run.
    @State private var flipSince: Date?
    private static let flipTime = 0.65
    private static let tiltTime = 0.45

    var body: some View {
        // Every frame while the sand runs or the glass turns; once a second otherwise, for the clock.
        TimelineView(.animation(minimumInterval: animating ? nil : 1, paused: false)) { timeline in
            let now = timeline.date
            let session = store.timer.session
            let running = session.isRunning(at: now)
            let paused = session.isPaused(at: now)
            let project = store.projects.project(session.inSession(at: now) ? session.project : store.activeProject)
            let left = session.inSession(at: now) ? session.remaining(at: now) : Double(session.minutes) * 60
            let canSwitch = !store.oneThingAtATime || !session.inSession(at: now)

            VStack(spacing: 10) {
                VStack(spacing: 10) {
                    projectChips(enabled: canSwitch)
                    if !canSwitch {
                        Text("End the session to switch projects.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .opacity(calm.hidden ? 0 : 1)
                let flip = flipSince.map { ease(now.timeIntervalSince($0) / Self.flipTime) * 180 }
                Glass(
                    progress: flip != nil ? 1 : session.fallen(at: now),
                    angle: (flip ?? tiltAngle(now, paused: paused)) * .pi / 180,
                    running: running && flip == nil,
                    sand: UIColor(hex: project?.color ?? "#6C2ED6") ?? .systemPurple,
                    minutes: session.minutes,
                    display: GlassDisplay(time: clock(left), project: project?.name, goal: goal(now)),
                    time: now.timeIntervalSinceReferenceDate
                )
                .contentShape(Rectangle())
                .onTapGesture { press(now) }
                // In the clean view the glass glides to the middle of the screen, the bars and controls gone.
                .offset(y: calm.hidden ? Self.screenMidY - glassMidY : 0)
                // Measured outside the offset: where the glass rests, not where it has glided to.
                .background(GeometryReader { g in
                    Color.clear
                        .onAppear { glassMidY = g.frame(in: .global).midY }
                        .onChange(of: g.frame(in: .global).midY) { _, y in glassMidY = y }
                })
                .onChange(of: paused) { _, paused in tilt = (paused, Date()) }
                .onChange(of: running && session.remaining(at: now) < 0.05) { _, done in if done { store.settle() } }

                VStack(spacing: 10) {
                Text(running ? (project?.name ?? "Running") : paused ? "Paused · \(clock(left)) left" : "Tap the glass to start")
                    .foregroundStyle(.secondary)

                if session.inSession(at: now) {
                    HStack(spacing: 12) {
                        Button(running ? "Pause" : "Resume") { store.tap() }.buttonStyle(.borderedProminent)
                        Button("End Session") { store.end() }.buttonStyle(.bordered)
                    }
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(lengths, id: \.self) { m in
                                Button(m == 25 ? "25 🍅" : "\(m)") { store.setMinutes(m) }
                                    .buttonStyle(.bordered)
                                    .tint(session.minutes == m ? .amber : .gray)
                            }
                        }
                        .padding(.horizontal)
                    }
                }
                today(now).font(.footnote).foregroundStyle(.secondary).padding(.bottom, 8)
                }
                .opacity(calm.hidden ? 0 : 1)
            }
            .animation(.easeInOut(duration: calm.hidden ? 0.9 : 0.25), value: calm.hidden)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.ink)
            // Awake while the sand runs, if wanted: a glass you can't see is no use.
            .onChange(of: running && store.keepScreenOn, initial: true) { _, awake in
                UIApplication.shared.isIdleTimerDisabled = awake
            }
            .onChange(of: running && store.cleanView, initial: true) { _, on in calm.watch(on) }
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            calm.watch(false)
        }
    }

    private static var screenMidY: CGFloat {
        (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen.bounds.midY ?? 0
    }

    private var animating: Bool {
        let now = Date()
        return store.timer.session.isRunning(at: now) || flipSince != nil
            || tilt.map { now.timeIntervalSince($0.since) < Self.tiltTime + 0.1 } == true
    }

    private func ease(_ t: Double) -> Double {
        let t = min(1, max(0, t))
        return t * t * (3 - 2 * t)
    }

    /// 90 lying down, 0 standing, and on the way between for a moment after a pause or a resume.
    private func tiltAngle(_ now: Date, paused: Bool) -> Double {
        guard let tilt, tilt.lying == paused else { return paused ? 90 : 0 }
        let t = ease(now.timeIntervalSince(tilt.since) / Self.tiltTime)
        return tilt.lying ? 90 * t : 90 * (1 - t)
    }

    /// Flip it over when it's waiting (the glass turns, then the sand runs); otherwise pause or carry on.
    private func press(_ now: Date) {
        guard flipSince == nil else { return }
        guard !store.timer.session.inSession(at: now) else { return store.tap() }
        flipSince = Date()
        Task {
            try? await Task.sleep(for: .seconds(Self.flipTime))
            store.start()
            flipSince = nil
        }
    }

    private func projectChips(enabled: Bool) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach([nil] + store.projects.visible.map(\.id), id: \.self) { (id: String?) in
                    let p = store.projects.project(id)
                    let on = store.activeProject == id
                    Button { store.setActiveProject(id) } label: {
                        HStack(spacing: 6) {
                            Circle().fill(p.flatMap { Color(uiColor: UIColor(hex: $0.color) ?? .gray) } ?? .gray).frame(width: 9, height: 9)
                            Text(p?.name ?? ProjectList.untitled)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(on ? Color.panel : .clear, in: Capsule())
                        .overlay(Capsule().stroke(.white.opacity(on ? 0 : 0.2)))
                    }
                    .foregroundStyle(.primary)
                    .disabled(!enabled && !on)
                    .opacity(!enabled && !on ? 0.4 : 1)
                }
            }
            .padding(.horizontal)
        }
        .padding(.top, 8)
    }

    /// The stretch running now, counted on screen as it goes; the record itself is written at each pause and end.
    private func counting(_ now: Date) -> TimeInterval {
        let s = store.timer.session
        guard let from = s.countedFrom else { return 0 }
        return max(0, min(now, s.runningUntil ?? now).timeIntervalSince(from))
    }

    private func goal(_ now: Date) -> Double? {
        guard store.targetMinutes > 0 else { return nil }
        return (store.wholeLog.seconds(on: now) + counting(now)) / Double(store.targetMinutes * 60)
    }

    private func today(_ now: Date) -> Text {
        let day = store.wholeLog.days[SandLog.dayKey(now)] ?? SandLog.Day()
        let seconds = day.seconds + counting(now)
        if store.targetMinutes > 0 {
            return Text("\(SandLog.durationLabel(seconds)) of \(SandLog.durationLabel(Double(store.targetMinutes * 60))) today")
        }
        return Text("\(SandLog.durationLabel(seconds)) today · \(SandLog.timersLabel(day.finished)) finished")
    }

    private func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.up))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
