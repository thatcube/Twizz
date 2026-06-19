import Foundation

/// Reusable WebSocket transport plumbing shared by the app's live services
/// (`ChatService`, `HermesEventService`, `EventSubService`).
///
/// Each of those services is a `@MainActor @Observable` class that independently
/// re-implemented the same socket scaffolding: a single reused `URLSession`, an
/// optional `URLSessionWebSocketTask`, and an exponential-backoff counter for
/// silent auto-reconnect. This type owns exactly that transport state so the
/// services keep only their protocol-specific parsing, message handling and
/// reconnection *policy*.
///
/// It is intentionally transport-only and unopinionated about the receive loop:
/// callers capture `currentTask` and drive their own `receive()` exactly as
/// before, so message ordering, teardown/cancellation semantics and backoff
/// timing are byte-for-byte identical to the hand-rolled plumbing it replaces.
@MainActor
final class WebSocketConnection {
  /// One reusable session for this socket. Creating a fresh `URLSession` per
  /// (re)connect leaks the old one (it is never invalidated); reusing a single
  /// session avoids that accumulation over long viewing sessions.
  private let urlSession: URLSession
  private var task: URLSessionWebSocketTask?
  /// Consecutive failed reconnects, for exponential backoff. Reset on a healthy
  /// receive (and on a fresh connect).
  private var reconnectAttempts = 0

  init(urlSession: URLSession = URLSession(configuration: .default)) {
    self.urlSession = urlSession
  }

  /// The active socket task, or `nil` after teardown. Callers capture this at the
  /// top of their receive loop so a torn-down connection breaks the loop and a
  /// reconnect is observed on the *next* iteration — matching the prior
  /// `guard let currentSocket = socket else { break }` pattern.
  var currentTask: URLSessionWebSocketTask? { task }

  /// Whether a socket is currently open.
  var isOpen: Bool { task != nil }

  /// Open a new socket to `url` using the reused session, cancelling and
  /// replacing any existing one, then start it.
  @discardableResult
  func connect(to url: URL) -> URLSessionWebSocketTask {
    replace(with: urlSession.webSocketTask(with: url))
  }

  /// Replace the active socket with a caller-built task, cancelling the previous
  /// one (`.goingAway`) first, then start it. For protocol-level reconnects to a
  /// server-provided URL where the caller must construct the task itself.
  @discardableResult
  func replace(with newTask: URLSessionWebSocketTask) -> URLSessionWebSocketTask {
    task?.cancel(with: .goingAway, reason: nil)
    task = newTask
    newTask.resume()
    return newTask
  }

  /// Send a frame on the current socket. Fire-and-forget, ignoring the
  /// completion error, matching the prior `socket?.send(...) { _ in }` calls.
  func send(_ message: URLSessionWebSocketTask.Message) {
    task?.send(message) { _ in }
  }

  /// Cancel the socket (`.goingAway`) and drop it.
  func cancel() {
    task?.cancel(with: .goingAway, reason: nil)
    task = nil
  }

  // MARK: - Backoff

  /// Reset the exponential-backoff counter, after a healthy receive or a fresh
  /// connect.
  func resetBackoff() {
    reconnectAttempts = 0
  }

  /// The next reconnect delay in seconds — `min(3 * 2^attempts, 30)` — and
  /// advance the attempt counter. Identical schedule and increment point to the
  /// inline plumbing it replaces (3s, 6s, 12s, 24s, … capped at 30s).
  func nextBackoffDelay() -> Double {
    let delay = min(3.0 * pow(2.0, Double(reconnectAttempts)), 30.0)
    reconnectAttempts += 1
    return delay
  }
}
