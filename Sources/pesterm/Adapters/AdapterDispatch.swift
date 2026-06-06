import Foundation

/// PURE routing of the `--adapter <value>` flag to a flow, decoupled from main.swift so
/// it is unit-testable without spinning AppKit.
enum AdapterDispatch {
    /// The flow an `--adapter` value selects.
    enum Route: Equatable {
        /// The existing `claude` Notification adapter (info notification).
        case info
        /// The new `claude-permission` blocking PermissionRequest adapter.
        case permission
        /// Anything else — caller exits 2.
        case unknown
    }

    /// PURE: map an adapter value to its route.
    static func route(for adapter: String) -> Route {
        switch adapter {
        case "claude":
            return .info
        case "claude-permission":
            return .permission
        default:
            return .unknown
        }
    }
}
