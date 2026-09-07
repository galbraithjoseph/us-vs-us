import CoreData
import Foundation
import Observation

struct CloudSyncEvent: Codable, Equatable, Sendable {
    let identifier: UUID
    let kind: String
    let startedAt: Date
    let endedAt: Date?
    let succeeded: Bool
    let error: String?
}

@MainActor
protocol CloudSyncService {
    var events: [CloudSyncEvent] { get }
}

@MainActor @Observable
final class CloudSyncMonitor: CloudSyncService {
    private(set) var events: [CloudSyncEvent] = []
    private var subscription: CloudNotificationSubscription?
    init(container: NSPersistentCloudKitContainer) {
        subscription = CloudNotificationSubscription(name: NSPersistentCloudKitContainer.eventChangedNotification, object: container) { [weak self] notification in
            guard let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey] as? NSPersistentCloudKitContainer.Event else { return }
            let kind: String = switch event.type { case .setup: "setup"; case .import: "import"; case .export: "export"; @unknown default: "unknown" }
            let value = CloudSyncEvent(identifier: event.identifier, kind: kind, startedAt: event.startDate,
                                       endedAt: event.endDate, succeeded: event.succeeded, error: event.error.map(String.init(describing:)))
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.events.removeAll { $0.identifier == value.identifier }
                self.events.append(value)
                if self.events.count > 200 { self.events.removeFirst(self.events.count - 200) }
            }
        }
    }
}

/// Owns observer lifetime; callbacks extract sendable values before actor hops.
final class CloudNotificationSubscription: @unchecked Sendable {
    private let token: NSObjectProtocol
    init(name: Notification.Name, object: AnyObject? = nil, handler: @escaping @Sendable (Notification) -> Void) {
        token = NotificationCenter.default.addObserver(forName: name, object: object, queue: nil, using: handler)
    }
    deinit { NotificationCenter.default.removeObserver(token) }
}

final class CloudAccountGeneration: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    func value() -> UInt64 { lock.withLock { generation } }
    func invalidate() { lock.withLock { generation &+= 1 } }
}
