import CoreMotion
import SwiftUI

/// The clean view: while the sand runs, everything but the glass fades away after a few still seconds — the
/// controls, the tabs and the status bar — and comes back the moment the phone is picked up, moved or touched.
@MainActor
final class Calm: ObservableObject {
    static let shared = Calm()
    /// Everything but the glass is hidden.
    @Published private(set) var hidden = false
    private let motion = CMMotionManager()
    private var watching = false
    private var fade: DispatchWorkItem?
    private static let stillFor = 3.0

    /// Watches the phone while `on`: the sand running, with the clean view turned on and the timer showing.
    func watch(_ on: Bool) {
        guard on != watching else { return }
        watching = on
        if on {
            if motion.isDeviceMotionAvailable {
                motion.deviceMotionUpdateInterval = 1.0 / 15
                motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
                    // Movement, without gravity: a nudge of a thirtieth of g is enough.
                    guard let a = data?.userAcceleration, (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot() > 0.035 else { return }
                    MainActor.assumeIsolated { self?.wake() }
                }
            }
            wake()
        } else {
            motion.stopDeviceMotionUpdates()
            fade?.cancel()
            hidden = false
        }
    }

    /// The phone moved or was touched: show everything, and start counting the still seconds again.
    func wake() {
        if hidden { hidden = false }
        fade?.cancel()
        guard watching else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { if self?.watching == true { self?.hidden = true } }
        }
        fade = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.stillFor, execute: work)
    }
}
