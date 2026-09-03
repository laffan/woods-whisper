import Foundation
import Combine
import Network

/// Whether the device has a network path right now — one question, asked in one place: *is there
/// any point starting something that needs the internet?*
///
/// Woods Whisper's premise is that the answer is usually no and nothing breaks. Recording,
/// transcription and transformation all run on-device; the network is one optional step (an online
/// Claude model for the rewrite) and a one-time model download. So the places that would otherwise
/// fire a request into a dead network ask this first and quietly don't — which is the difference
/// between a feature that isn't available right now and an error.
///
/// `NWPathMonitor` reports the **path**, not whether a particular host answers, so a "yes" here is
/// a reason to try rather than a promise. That asymmetry is deliberate: callers still have to
/// handle a request that fails anyway (a signal can go while a request is in flight, and a WiFi
/// network with no route out still counts as satisfied). This exists to stop the app *starting*
/// work it can be sure will fail, not to predict success.
///
/// It starts **optimistic**. The monitor's first update takes a moment to arrive, and something
/// skipped in that window would be skipped for no reason — better to try and fail than to refuse
/// while the answer simply isn't in yet.
public final class NetworkReachability: ObservableObject, @unchecked Sendable {

    /// One monitor for the app. Reachability is a property of the device rather than of any screen,
    /// and `NWPathMonitor` is a system resource worth having exactly one of.
    public static let shared = NetworkReachability()

    /// Whether there's a usable network path. Published, so a view can grey something out; read
    /// directly, so a background task can ask without observing.
    @Published public private(set) var isOnline = true

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.woodswhisper.reachability")

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            // The handler arrives on the monitor's own queue; published state changes on the main
            // one. Only when it has actually changed — a path update fires on every interface
            // change, most of which say the same thing twice.
            DispatchQueue.main.async {
                guard let self, self.isOnline != online else { return }
                self.isOnline = online
                wwLog("Network \(online ? "reachable" : "unreachable")", .general)
            }
        }
        monitor.start(queue: queue)
    }
}
