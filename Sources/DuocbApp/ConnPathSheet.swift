import SwiftUI

/// Point-in-time snapshot of the connection's paths (direct vs relay), fetched
/// on demand — the ● marker is the path iroh currently routes over.
struct ConnPathSheet: View {
    @Environment(SessionController.self) private var controller
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let paths = controller.connPaths, !paths.isEmpty {
                    ForEach(paths) { path in
                        HStack(spacing: 10) {
                            Text(path.selected ? "●" : "○")
                                .foregroundStyle(color(for: path.kind))
                            Text(path.display)
                                .font(.system(.footnote, design: .monospaced))
                        }
                    }
                } else {
                    Text("No path information yet")
                        .foregroundStyle(.secondary)
                        .font(.footnote)
                }
            }
            .navigationTitle("Connection path")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Refresh") { controller.queryConnPath() }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func color(for kind: String) -> Color {
        switch kind {
        case "direct": .green
        case "relay": .orange
        default: .secondary
        }
    }
}
