import SwiftUI
import UserNotifications

@main
struct SandTimerApp: App {
    @Environment(\.scenePhase) private var phase
    private let presenter = NotificationPresenter()

    init() {
        UNUserNotificationCenter.current().delegate = presenter
        Notifier.requestPermission()
        let store = Store.shared
        LinkClient.start(store: store)  // only once linking is turned on in Settings does it touch Bluetooth
        store.linkChanged()
        NotificationCenter.default.addObserver(forName: LinkEngine.changed, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Store.shared.linkChanged() }
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(Store.shared)
                .preferredColorScheme(.dark)
        }
        .onChange(of: phase) { _, phase in
            guard phase == .active else { return }
            Store.shared.refresh()
            LinkClient.radio.wake()
        }
    }
}

/// Night-desk colours: the glass shows best on dark.
extension Color {
    static let ink = Color(red: 0.07, green: 0.086, blue: 0.11)
    static let panel = Color(red: 0.11, green: 0.133, blue: 0.17)
    static let amber = Color(red: 0.85, green: 0.64, blue: 0.25)
}

struct RootView: View {
    @ObservedObject private var calm = Calm.shared

    var body: some View {
        TabView {
            TimerScreen()
                .toolbar(calm.hidden ? .hidden : .visible, for: .tabBar)
                .tabItem { Label("Timer", systemImage: "hourglass") }
            StatsScreen().tabItem { Label("Statistics", systemImage: "chart.bar.fill") }
            SettingsScreen().tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
        .tint(.amber)
        .statusBarHidden(calm.hidden)
        .persistentSystemOverlays(calm.hidden ? .hidden : .automatic)
        // While everything is hidden, a touch anywhere only brings it back: nothing invisible gets pressed by mistake.
        .overlay {
            if calm.hidden {
                Color.black.opacity(0.001).ignoresSafeArea().onTapGesture { calm.wake() }
            }
        }
    }
}
