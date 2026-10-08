import AppKit
import SwiftUI

@main
struct PersonalAIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            StatusMenu(runtime: delegate.runtime)
        } label: {
            Image(systemName: "brain")
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let runtime = Runtime()

    func applicationDidFinishLaunching(_ notification: Notification) {
        runtime.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        runtime.stop()
    }
}

struct StatusMenu: View {
    @ObservedObject var runtime: Runtime

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Personal AI").font(.headline)

            status

            Divider()

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                row("Mac", "\(runtime.hardware.chip), \(Int(runtime.hardware.ramGB)) GB")
                if let model = runtime.model {
                    row("Model", "\(model.name) (\(String(format: "%.1f", model.sizeGB)) GB)")
                }
                row("Address", Runtime.base.absoluteString)
            }
            .font(.callout)

            if runtime.adoptedExternal {
                Text("Using the Ollama that was already running on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Divider()

            Toggle("Open at login", isOn: Binding(
                get: { runtime.launchAtLogin },
                set: { runtime.setLaunchAtLogin($0) }
            ))

            HStack {
                Button("Show models folder") { NSWorkspace.shared.open(AppPaths.support) }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    @ViewBuilder private var status: some View {
        switch runtime.state {
        case .starting:
            Label("Starting", systemImage: "hourglass")
        case let .downloading(status, fraction):
            VStack(alignment: .leading, spacing: 4) {
                Label("Downloading the model", systemImage: "arrow.down.circle")
                if let fraction { ProgressView(value: fraction) } else { ProgressView().controlSize(.small) }
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
        case .ready:
            Label("Ready. Apps that use Ollama can connect now.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }
}
