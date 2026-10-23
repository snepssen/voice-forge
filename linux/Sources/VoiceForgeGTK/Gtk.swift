import CGtk
import Foundation

// The few conversions GTK's C API needs from Swift. Constructors hand back
// `GtkWidget *`; functions on a final type take an opaque pointer, and on a
// derivable one a typed pointer. Both are the same address.

typealias Widget = UnsafeMutablePointer<GtkWidget>

/// A widget as an opaque pointer, for final types (GtkLabel, AdwSpinRow, ...).
func op(_ widget: Widget) -> OpaquePointer { OpaquePointer(widget) }

/// A widget as a typed pointer, for derivable types (GtkWindow, ...).
func typed<T>(_ widget: Widget) -> UnsafeMutablePointer<T> { UnsafeMutablePointer<T>(OpaquePointer(widget)) }

/// A C callback for a signal that passes only the emitter.
typealias Handler = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void

/// `g_signal_connect`, which is a macro Swift cannot see.
func connect(_ instance: UnsafeMutableRawPointer?, _ signal: String, _ handler: Handler) {
    g_signal_connect_data(instance, signal, unsafeBitCast(handler, to: GCallback.self), nil, nil, GConnectFlags(rawValue: 0))
}

func connect(_ widget: Widget, _ signal: String, _ handler: Handler) {
    connect(UnsafeMutableRawPointer(widget), signal, handler)
}

// MARK: - Back to the main loop

/// Work finished elsewhere comes back here: GLib runs its loop, not Dispatch's
/// main queue, so `DispatchQueue.main` would never run.
private let pendingLock = NSLock()
nonisolated(unsafe) private var pending: [() -> Void] = []

func onMain(_ work: @escaping () -> Void) {
    pendingLock.lock()
    pending.append(work)
    pendingLock.unlock()
    g_idle_add({ _ in
        pendingLock.lock()
        let due = pending
        pending = []
        pendingLock.unlock()
        due.forEach { $0() }
        return 0  // G_SOURCE_REMOVE
    }, nil)
}
