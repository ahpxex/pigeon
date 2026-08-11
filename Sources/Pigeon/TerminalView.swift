import SwiftUI
import GhosttyKit

/// Root view of a terminal window.
struct TerminalView: View {
    @EnvironmentObject private var ghostty: Ghostty.App

    var body: some View {
        switch ghostty.readiness {
        case .loading:
            ProgressView()
                .frame(minWidth: 400, minHeight: 300)
        case .error(let message):
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                Text("libghostty failed to start")
                    .font(.headline)
                Text(message)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 400, minHeight: 300)
            .padding()
        case .ready:
            TerminalSurface(app: ghostty.app!)
                .frame(minWidth: 200, minHeight: 100)
        }
    }
}

/// Bridges a Ghostty.SurfaceView into SwiftUI. The surface (and the shell
/// process behind it) lives exactly as long as the coordinator.
struct TerminalSurface: NSViewRepresentable {
    let app: ghostty_app_t

    final class Coordinator {
        let surfaceView: Ghostty.SurfaceView

        init(app: ghostty_app_t) {
            surfaceView = Ghostty.SurfaceView(app: app)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(app: app)
    }

    func makeNSView(context: Context) -> Ghostty.SurfaceView {
        context.coordinator.surfaceView
    }

    func updateNSView(_ nsView: Ghostty.SurfaceView, context: Context) {}
}
