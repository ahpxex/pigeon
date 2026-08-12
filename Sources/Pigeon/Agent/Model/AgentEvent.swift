import Foundation

/// Typed events emitted by the agent runtime. Consumers (terminal stream,
/// future UI) fold these into whatever presentation they need — the
/// runtime never touches UI directly. Modeled on Pi's harness events.
enum AgentEvent {
    /// Incremental assistant text.
    case textDelta(String)
    /// A tool is about to run (already permission-checked).
    case toolStart(name: String, summary: String)
    /// A tool finished; summary is short and human-readable.
    case toolEnd(name: String, ok: Bool, summary: String)
    /// The whole run finished. For .error, `message` explains why.
    case finished(StopReason, message: String?)
}
