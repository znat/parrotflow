import SwiftUI

/// The teach-a-word panel: one row per word, mapping what ParrotFlow wrote to
/// what it should have written, and what kind of thing that is.
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
    @FocusState private var focused: Focus?

    struct Focus: Hashable {
        let id: UUID
        let side: Bool  // true = the corrected side
    }

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
                status: summary,
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
        .onAppear {
            guard let target = model.focusTarget else { return }
            focused = Focus(id: target.id, side: target.side == .corrected)
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
            Text("TYPE")
            Spacer()
        }
        .font(.system(size: 9, weight: .semibold, design: .rounded))
        .kerning(0.9)
        .foregroundStyle(.quaternary)
        .padding(.bottom, 6)
    }

    private func row(_ row: Binding<CorrectionRow>) -> some View {
        let id = row.wrappedValue.id
        return HStack(spacing: 12) {
            TextField("wrong word", text: row.heard)
                .textFieldStyle(.plain)
                .focused($focused, equals: Focus(id: id, side: false))
                .onSubmit { model.onSubmit?() }
                .parrotField(focused: focused == Focus(id: id, side: false))
                .frame(width: CorrectionMetrics.heardWidth)

            Image(systemName: "arrow.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(
                    row.wrappedValue.corrected.isEmpty
                        ? AnyShapeStyle(.quaternary)
                        : AnyShapeStyle(Parrot.leaf)
                )
                .frame(width: CorrectionMetrics.arrowWidth)

            TextField("blank to skip", text: row.corrected)
                .textFieldStyle(.plain)
                .focused($focused, equals: Focus(id: id, side: true))
                .onSubmit { model.onSubmit?() }
                .parrotField(focused: focused == Focus(id: id, side: true))
                .frame(width: CorrectionMetrics.correctedWidth)

            kindPicker(row.kind)

            Button {
                model.remove(id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Leave this word alone")
        }
        .font(.system(size: 14, weight: .medium, design: .monospaced))
        .frame(height: CorrectionMetrics.rowHeight)
    }

    /// A menu rather than four segments. The proposal is right most of the time,
    /// so the common case is reading one word and moving on; four segments would
    /// spend the width of the panel on a control nobody touches.
    private func kindPicker(_ kind: Binding<WordKind>) -> some View {
        Menu {
            ForEach(WordKind.allCases, id: \.self) { option in
                Button(option.label) { kind.wrappedValue = option }
            }
        } label: {
            Text(kind.wrappedValue.label)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .frame(width: CorrectionMetrics.kindWidth, alignment: .leading)
    }

    private var addRow: some View {
        Button {
            model.addRow()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "plus").font(.system(size: 9, weight: .bold))
                Text("Add a word")
            }
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
        .padding(.top, 4)
        .padding(.bottom, 2)
    }

    private var summary: String {
        switch model.pendingRuleCount {
        case 0: return "Fill in a word to save a rule"
        case 1: return "1 rule to save"
        case let count: return "\(count) rules to save"
        }
    }
}
