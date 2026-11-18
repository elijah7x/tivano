import Dispatch
import Foundation

extension Notification.Name {
    static let memoryPressure = Notification.Name("TivanoMemoryPressure")
}

@MainActor
enum MemoryPressureMonitor {
    private static var source: DispatchSourceMemoryPressure?

    static func start() {
        guard source == nil else { return }
        let monitor = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        monitor.setEventHandler {
            MainActor.assumeIsolated {
                let critical = Self.source?.data.contains(.critical) ?? false
                NotificationCenter.default.post(
                    name: .memoryPressure,
                    object: nil,
                    userInfo: ["critical": critical]
                )
            }
        }
        source = monitor
        monitor.resume()
    }
}
