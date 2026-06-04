import Foundation

/// Swappable notification backend. NSUserNotification is v1 (locked decision #1);
/// the protocol boundary keeps a later UNUserNotification swap contained to a
/// single file (PC1 escalation rule).
protocol NotificationBackend {
    /// Post the request and invoke `onActivate` when the user clicks the
    /// notification. The implementation is responsible for the keep-alive policy
    /// (stay alive until activated or dismissed; 600s safety cap). Must be called
    /// on the main thread under a running run loop so delegate callbacks deliver.
    func post(_ request: NotificationRequest, onActivate: @escaping () -> Void) throws
}
