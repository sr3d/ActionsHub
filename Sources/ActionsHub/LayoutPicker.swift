import SwiftUI

/// Button that opens a rows × cols grid: hover to size the layout, click to apply.
@MainActor struct LayoutPicker: View {
    @Environment(\.zoom) private var z
    @Environment(AppModel.self) private var model
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            Image(systemName: "square.grid.2x2")
                .frame(width: 30 * z, height: 30 * z)
                .background(RoundedRectangle(cornerRadius: 7 * z).fill(Color.primary.opacity(0.06)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Pane layout (\(model.layout.rows) × \(model.layout.cols))")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            LayoutGrid { rows, cols in
                model.setLayout(rows: rows, cols: cols)
                open = false
            }
            .environment(\.zoom, z)
            .environment(model)
        }
    }
}

@MainActor private struct LayoutGrid: View {
    @Environment(\.zoom) private var z
    @Environment(AppModel.self) private var model
    let apply: (Int, Int) -> Void
    @State private var hover: (r: Int, c: Int)?

    private var shown: (r: Int, c: Int) {
        hover ?? (model.layout.rows - 1, model.layout.cols - 1)
    }

    var body: some View {
        VStack(spacing: 8 * z) {
            VStack(spacing: 4 * z) {
                ForEach(0..<AppModel.maxGrid, id: \.self) { r in
                    HStack(spacing: 4 * z) {
                        ForEach(0..<AppModel.maxGrid, id: \.self) { c in
                            let on = r <= shown.r && c <= shown.c
                            RoundedRectangle(cornerRadius: 3 * z)
                                .fill(on ? Color.accentColor.opacity(hover == nil ? 0.45 : 0.8) : Color.primary.opacity(0.08))
                                .overlay(RoundedRectangle(cornerRadius: 3 * z).stroke(Color.primary.opacity(0.15)))
                                .frame(width: 30 * z, height: 22 * z)
                                .contentShape(Rectangle())
                                .onHover { inside in
                                    if inside { hover = (r, c) }
                                }
                                .onTapGesture { apply(r + 1, c + 1) }
                        }
                    }
                }
            }
            .onHover { inside in if !inside { hover = nil } }
            Text("\(shown.r + 1) × \(shown.c + 1)")
                .zFont(.callout, weight: .semibold)
                .monospacedDigit()
            Text(hover == nil ? "Current layout" : "Click to apply")
                .zFont(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12 * z)
    }
}
