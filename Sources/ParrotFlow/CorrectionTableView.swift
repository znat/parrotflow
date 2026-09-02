import SwiftUI

/// The teach-a-word panel: one row per word, mapping what ParrotFlow wrote to
/// what it should have written.
///
/// The rows are proposed rather than enumerated. An earlier version put one row
/// per word of the selection, which is a wall of rows to read on a long
/// sentence; `VocabularySuggest` picks the words the dictionary does not know,
/// which is 0.4 rows per sentence on the archive.
///
/// Both sides are fields. The left one has to be editable because a name the
/// decoder split in two — "red crawl" for Redcrawl — arrives as two words and
/// no proposal can join them. Typing over the left field is how you widen a row
/// to the span you meant. That was the failure that retired this panel in #117,
/// and an editable field is the smaller answer to it.
///
/// Visually a sibling of the recording pill and the notice: same material, same
/// plumage rim, same footer as the preview panel. The words are set in
/// monospace — they are literal strings being mapped to other literal strings,
/// and each row is a line that lands in `vocabulary.yaml`.
struct CorrectionView: View {
    @EnvironmentObject private var model: CorrectionModel
    @FocusState private var focused: CorrectionModel.Cell?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader(title: "Vocabulary", note: "teach a word")
            columns

            ScrollView {
                VStack(spacing: 0) {
                    ForEach($model.rows) { $row in
                        self.row($row)
                    }
                }
            }
            .frame(height: CorrectionMetrics.rowsHeight(model.rows.count))

            addRow

            PanelActions(
                status: "",
                cancelTitle: "Cancel",
                confirmTitle: "Save",
                confirmKey: "↩",
                onCancel: { model.onCancel?() },
                onConfirm: { model.onSubmit?() }
            )
        }
        .padding(Parrot.panelPadding)
        .frame(width: CorrectionMetrics.width)
        .parrotSurface(
            RoundedRectangle(cornerRadius: Parrot.panelRadius, style: .continuous),
            solid: true
        )
        .onAppear { focused = model.focus }
        // Two ways in and one truth. The view moves focus when you click a
        // field; the panel moves it when you press Tab. Both write the model,
        // and the model writes back here.
        .onChange(of: focused) { _, now in model.focus = now }
        .onChange(of: model.focus) { _, now in
            if focused != now { focused = now }
        }
        .onExitCommand { model.onCancel?() }
    }

    private var columns: some View {
        HStack(spacing: 12) {
            Text("HEARD AS")
                .frame(width: CorrectionMetrics.heardWidth, alignment: .leading)
            // The arrow's column, so the two labels sit over their fields.
            Color.clear.frame(width: CorrectionMetrics.arrowWidth)
            Text("SHOULD BE")
                .frame(width: CorrectionMetrics.correctedWidth, alignment: .leading)
            Spacer()
        }
        .font(.system(size: 11, weight: .semibold, design: .rounded))
        .kerning(0.9)
        .foregroundStyle(.secondary)
        .padding(.bottom, 6)
    }

    private func row(_ row: Binding<CorrectionRow>) -> some View {
        let id = row.wrappedValue.id
        return HStack(spacing: 12) {
            TextField("wrong word", text: row.heard)
                .textFieldStyle(.plain)
                .focused($focused, equals: cell(id, .heard))
                .onSubmit { model.onSubmit?() }
                .parrotField(focused: focused == cell(id, .heard))
                .frame(width: CorrectionMetrics.heardWidth)

            Image(systemName: "arrow.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(
                    row.wrappedValue.corrected.isEmpty
                        ? AnyShapeStyle(.secondary)
                        : AnyShapeStyle(Parrot.leaf)
                )
                .frame(width: CorrectionMetrics.arrowWidth)

            TextField("blank to skip", text: row.corrected)
                .textFieldStyle(.plain)
                .focused($focused, equals: cell(id, .corrected))
                .onSubmit { model.onSubmit?() }
                .parrotField(focused: focused == cell(id, .corrected))
                .frame(width: CorrectionMetrics.correctedWidth)

            Button {
                model.remove(id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Leave this word alone")
        }
        .font(.system(size: 15, weight: .medium, design: .monospaced))
        .frame(height: CorrectionMetrics.rowHeight)
    }

    private func cell(_ id: UUID, _ column: CorrectionModel.Column) -> CorrectionModel.Cell {
        CorrectionModel.Cell(row: id, column: column)
    }

    private var addRow: some View {
        Button {
            model.addRow()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "plus").font(.system(size: 11, weight: .bold))
                Text("Add a word")
            }
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .padding(.top, 4)
        .padding(.bottom, 2)
    }

}
