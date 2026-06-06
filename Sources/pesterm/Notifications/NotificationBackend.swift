import Foundation

/// Swappable notification backend. UNUserNotificationBackend is the implementation;
/// the protocol boundary keeps the posting mechanism contained to a single file
/// (e.g. a future presentation/style change stays here, not in core/adapter/reveal).
protocol NotificationBackend {
    /// Post the request and invoke `onActivate` when the user interacts with the
    /// notification. `actionIdentifier` is the tapped action's id, or nil /
    /// `UNNotificationDefaultActionIdentifier` for a body (default) click. The
    /// implementation is responsible for the keep-alive policy (stay alive until
    /// activated or dismissed; 600s safety cap). Must be called on the main thread
    /// under a running run loop so delegate callbacks deliver.
    func post(_ request: NotificationRequest,
              onActivate: @escaping (_ actionIdentifier: String?) -> Void) throws
}
