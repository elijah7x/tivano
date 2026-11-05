import SwiftUI

struct ChimeraCastingBadgeRow: View {
    let runtime: ThreadRuntime
    @Environment(AppModel.self) private var model
    @State private var isPresented = false
    @State private var picks: [UUID: ChimeraPick] = [:]
    @State private var skipped: Set<UUID> = []
    /// The rows already prefilled: a casting can gain rows from a later block.
    @State private var prepared: Set<UUID> = []

    var body: some View {
        if let casting = runtime.chimeraCasting {
            ChatBadge(
                title: Chrome.localized("Casting"),
                caption: String(format: Chrome.localized("%d roles waiting for a model"), casting.rows.count),
                needsAttention: true,
                isPresented: $isPresented,
                glyph: { ChimeraMarkImage().foregroundStyle(Chrome.accent) },
                detail: {
                    // The badge's popover hosts its content outside this view tree, so the
                    // app model the sheet and its model picker read must be passed in.
                    ChimeraCastingSheet(casting: casting, runtime: runtime, picks: $picks, skipped: $skipped)
                        .environment(model)
                }
            )
            .onAppear { prepare(casting) }
            .onChange(of: casting.rows.map(\.id)) { _, _ in prepare(casting) }
        }
    }

    private func prepare(_ casting: ChimeraCasting) {
        let ids = Set(casting.rows.map(\.id))
        guard ids != prepared else { return }
        picks = picks.filter { ids.contains($0.key) }
        skipped = skipped.intersection(ids)
        for row in casting.rows where !prepared.contains(row.id) {
            picks[row.id] = row.prefill
        }
        prepared = ids
    }
}

struct ChimeraCastingSheet: View {
    private static let maxHeight: CGFloat = 360
    private static let width: CGFloat = 520

    let casting: ChimeraCasting
    let runtime: ThreadRuntime
    @Binding var picks: [UUID: ChimeraPick]
    @Binding var skipped: Set<UUID>
    @Environment(\.closePopover) private var closePopover
    @Environment(AppModel.self) private var model

    private var isActive: Bool { runtime.chimeraCasting?.batchID == casting.batchID }
    private var liveRows: [ChimeraCastingRow] { runtime.chimeraCasting?.rows ?? casting.rows }
    private var isComplete: Bool {
        liveRows.allSatisfy { skipped.contains($0.id) || picks[$0.id].map(model.chimeraCanRun) == true }
    }
    private var sendCount: Int { liveRows.filter { !skipped.contains($0.id) }.count }

    // Like QuestionSheet, give the scroll view its measured height before the
    // badge popover measures its content; an unconstrained scroll view collapses.
    private var pageHeight: CGFloat {
        let probe = roles.frame(width: Self.width).environment(model)
        return min(NSHostingView(rootView: probe).fittingSize.height, Self.maxHeight)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Casting")
                    .font(.ui(.body, weight: .semibold))
                    .foregroundStyle(Chrome.primaryText)
                Text("Pick a model for each role. Nothing starts until you send.")
                    .font(.ui(.subheadline))
                    .foregroundStyle(Chrome.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            ScrollView(.vertical) {
                roles
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(width: Self.width, height: pageHeight)

            Divider()

            HStack(spacing: 8) {
                Spacer()
                Button("Send none") {
                    guard isActive else { return }
                    closePopover?()
                    runtime.cancelChimeraCasting()
                }
                .buttonStyle(.bordered)
                Button {
                    guard isActive, isComplete, sendCount > 0 else { return }
                    closePopover?()
                    runtime.confirmChimeraCasting(Dictionary(uniqueKeysWithValues: liveRows.compactMap { row in
                        guard !skipped.contains(row.id), let pick = picks[row.id] else { return nil }
                        return (row.id, pick)
                    }))
                } label: {
                    Text(verbatim: sendCount == 1 ? Chrome.localized("Send 1") : String(format: Chrome.localized("Send %d"), sendCount))
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(sendCount == 0 || !isComplete)
            }
            .controlSize(.regular)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(width: Self.width)
        .disabled(!isActive)
        .onChange(of: isActive) { _, active in if !active { closePopover?() } }
        .onChange(of: runtime.chimeraCasting?.rows.map(\.id)) { _, _ in closePopover?() }
    }

    private var roles: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(liveRows.enumerated()), id: \.element.id) { index, row in
                if index > 0 { ChromeRowDivider() }
                ChromeRow(title: row.role, detail: row.task, localizesDetail: false, localizesTitle: false, detailLineLimit: 2, titleLineLimit: 1) {
                    HStack(spacing: 8) {
                        ChimeraPickPicker(pick: Binding(
                            get: { picks[row.id] },
                            set: { if isActive { picks[row.id] = $0 } }
                        ), showsProvider: false)
                        .disabled(skipped.contains(row.id))
                        .opacity(skipped.contains(row.id) ? 0.5 : 1)
                        SettingsSwitch(isOn: Binding(
                            get: { !skipped.contains(row.id) },
                            set: { value in
                                guard isActive else { return }
                                if value { skipped.remove(row.id) } else { skipped.insert(row.id) }
                            }
                        ))
                        .accessibilityLabel(Text(verbatim: String(format: Chrome.localized("Send %@"), row.role)))
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
                }
                .help(Text(verbatim: row.task))
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
