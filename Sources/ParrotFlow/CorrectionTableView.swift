import SwiftUI

/// The teach-a-word panel: one editable mapping per row, with the sentence the
/// rule will be learned in when the app proposed the correction.
///
/// The fields, focus ring and actions are intentionally drawn here rather than
/// borrowed from the older translucent dialogs. This panel takes keyboard
/// focus and can stay open over a busy document; it needs the same opaque,
/// six-point Context surface as the pill without giving up native text fields.
struct CorrectionView: View {
    @EnvironmentObject private var model: CorrectionModel
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var focused: CorrectionModel.Cell?

    private var effectiveColorScheme: ColorScheme {
        model.theme.resolved(against: colorScheme)
    }

    private var theme: ContextTheme {
        ContextTheme(scheme: effectiveColorScheme, primaryHex: model.primaryColor)
    }

    private var showsContext: Bool { model.proposed && !model.sentence.isEmpty }

    var body: some View {
        surface
            .environment(\.colorScheme, effectiveColorScheme)
            .onAppear { focused = model.focus }
            // Clicks and Tab share one focus value. The panel catches Tab
            // before the native field editor consumes it; see CorrectionPanel.
            .onChange(of: focused) { _, now in model.focus = now }
            .onChange(of: model.focus) { _, now in
                if focused != now { focused = now }
            }
            .onExitCommand { model.onCancel?() }
    }

    private var surface: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            columns

            ScrollView {
                VStack(spacing: 0) {
                    ForEach($model.rows) { $row in self.row($row) }
                }
            }
            .scrollIndicators(.visible)
            .frame(height: CorrectionMetrics.rowsHeight(model.rows.count))

            addRow
            if showsContext { learnedIn }
            actions
        }
        .padding(CorrectionMetrics.contentPadding)
        .frame(
            width: CorrectionMetrics.surfaceWidth,
            height: CorrectionMetrics.height(
                forRows: model.rows.count, showsContext: showsContext
            ) - CorrectionMetrics.bleed * 2,
            alignment: .topLeading
        )
        .foregroundStyle(theme.foreground)
        .contextSurface(shape, border: theme.edge, theme: theme)
        .padding(CorrectionMetrics.bleed)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: ContextIdentity.radius, style: .continuous)
    }

    private var header: some View {
        HStack(spacing: 8) {
            ContextVoiceMark(color: theme.accent)
                .frame(width: 17, height: 17)
            Text("VOCABULARY")
                .foregroundStyle(theme.accent)
            Text(model.proposed ? "LEARN THIS WORD?" : "TEACH A WORD")
                .foregroundStyle(theme.muted)
            Spacer()
        }
        .font(.system(size: 10, weight: .semibold, design: .rounded))
        .kerning(0.9)
        .padding(.bottom, 14)
    }

    private var columns: some View {
        HStack(spacing: 10) {
            Text("HEARD AS")
                .frame(width: CorrectionMetrics.heardWidth, alignment: .leading)
            Color.clear.frame(width: CorrectionMetrics.arrowWidth)
            Text("SHOULD BE")
                .frame(width: CorrectionMetrics.correctedWidth, alignment: .leading)
            Spacer(minLength: 0)
        }
        .font(.system(size: 11, weight: .semibold, design: .rounded))
        .kerning(0.8)
        .foregroundStyle(theme.muted)
        .padding(.bottom, 7)
    }

    private func row(_ row: Binding<CorrectionRow>) -> some View {
        let id = row.wrappedValue.id
        return HStack(spacing: 10) {
            TextField("wrong word", text: row.heard)
                .textFieldStyle(.plain)
                .focused($focused, equals: cell(id, .heard))
                .onSubmit { model.onSubmit?() }
                .correctionField(theme: theme, focused: focused == cell(id, .heard))
                .frame(width: CorrectionMetrics.heardWidth)

            Image(systemName: "arrow.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(row.wrappedValue.corrected.isEmpty ? theme.muted : theme.accent)
                .frame(width: CorrectionMetrics.arrowWidth)

            TextField("blank to skip", text: row.corrected)
                .textFieldStyle(.plain)
                .focused($focused, equals: cell(id, .corrected))
                .onSubmit { model.onSubmit?() }
                .correctionField(theme: theme, focused: focused == cell(id, .corrected))
                .frame(width: CorrectionMetrics.correctedWidth)

            Button { model.remove(id) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(theme.muted)
                    .frame(width: 22, height: 26)
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
        Button { model.addRow() } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus").font(.system(size: 11, weight: .bold))
                Text("Add a word")
            }
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .foregroundStyle(theme.muted)
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(theme.controlFill, in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .padding(.top, 6)
    }

    /// The complete context stays visible up to three lines; beyond that the
    /// panel remains bounded and the tail truncates rather than growing over
    /// the document it is correcting.
    private var learnedIn: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("LEARNED IN")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .kerning(0.8)
                .foregroundStyle(theme.muted)
            Text("“\(model.sentence)”")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(theme.foreground.opacity(0.86))
                .lineLimit(3)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 12)
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 12)
            correctionButton(
                title: model.proposed ? "No" : "Cancel", key: "esc", primary: false,
                action: { model.onCancel?() }
            )
            .keyboardShortcut(.cancelAction)
            correctionButton(
                title: model.proposed ? "Yes" : "Save", key: "↩", primary: true,
                action: { model.onSubmit?() }
            )
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.top, 14)
    }

    private func correctionButton(
        title: String, key: String, primary: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Text(title).font(.system(size: 12, weight: .semibold, design: .rounded))
                Text(key)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        (primary ? theme.onAccent.opacity(0.17) : theme.controlFill),
                        in: RoundedRectangle(cornerRadius: 3)
                    )
            }
            .foregroundStyle(primary ? theme.onAccent : theme.foreground)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(
                primary ? theme.accent : theme.controlFill,
                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(primary ? theme.accent : theme.controlEdge, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }
}

private extension View {
    func correctionField(theme: ContextTheme, focused: Bool) -> some View {
        padding(.horizontal, 10)
            .padding(.vertical, 7)
            .foregroundStyle(theme.foreground)
            .background(
                theme.controlFill,
                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(
                        focused ? theme.accent : theme.controlEdge,
                        lineWidth: focused ? 1.25 : 1
                    )
            }
            .animation(.easeOut(duration: 0.12), value: focused)
    }
}
