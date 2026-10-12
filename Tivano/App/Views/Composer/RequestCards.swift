import SwiftUI

struct ApprovalCard: View {
    let request: ApprovalRequest
    let runtime: ThreadRuntime
    @AppStorage("performanceMode", store: CaptureRun.defaults ?? .standard) private var performanceMode = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: request.symbol)
                    .foregroundStyle(Chrome.warning)
                Text(verbatim: Chrome.localized(request.headline))
                    .font(.ui(.headline))
                Spacer()
            }
            switch request.kind {
            case .command:
                Text(request.title)
                    .font(.ui(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(8)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10, style: .continuous))
            case .plan:
                Text("Approve the plan above to let the agent start building.")
                    .font(.ui(.callout))
                    .foregroundStyle(Chrome.secondaryText)
            default:
                Text(request.title)
                    .font(.ui(.callout))
                    .textSelection(.enabled)
            }
            if let detail = request.detail, !detail.isEmpty {
                Text(detail)
                    .font(.ui(.caption))
                    .foregroundStyle(Chrome.secondaryText)
                    .lineLimit(3)
            }
            if let reason = request.reason, !reason.isEmpty {
                Text(reason)
                    .font(.ui(.callout))
                    .foregroundStyle(Chrome.secondaryText)
            }
            HStack(spacing: 8) {
                Spacer()
                // Only the card at the top of the stack answers to the chord: two cards both
                // claiming it left neither of them reliably approving.
                let ownsShortcut = request.id == runtime.approvals.first?.id
                ForEach(request.options.reversed()) { option in
                    if option.role == .approve {
                        if performanceMode {
                            Button(Chrome.localized(option.title)) { runtime.resolve(request, option: option) }
                                .buttonStyle(.borderedProminent)
                                .keyboardShortcut(ownsShortcut ? KeyboardShortcut(.return, modifiers: .command) : nil)
                        } else {
                            Button(Chrome.localized(option.title)) { runtime.resolve(request, option: option) }
                                .buttonStyle(.glassProminent)
                                .keyboardShortcut(ownsShortcut ? KeyboardShortcut(.return, modifiers: .command) : nil)
                        }
                    } else {
                        if performanceMode {
                            Button(Chrome.localized(option.title)) { runtime.resolve(request, option: option) }
                                .buttonStyle(.bordered)
                        } else {
                            Button(Chrome.localized(option.title)) { runtime.resolve(request, option: option) }
                                .buttonStyle(.glass)
                        }
                    }
                }
            }
        }
        .padding(16)
        .modifier(RequestCardSurface())
    }
}

private struct RequestCardSurface: ViewModifier {
    @AppStorage("performanceMode", store: CaptureRun.defaults ?? .standard) private var performanceMode = false
    @AppStorage("floatingGlassStyle", store: CaptureRun.defaults ?? .standard) private var floatingGlassStyle = "upstream"
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        if floatingGlassStyle == "upstream" {
            content.floatingGlass(shape, tint: Chrome.warning.opacity(0.1), rim: Chrome.warning.opacity(0.25))
        } else if !performanceMode {
            content
                .glassEffect(.regular.tint(Chrome.warning.opacity(0.1)), in: shape)
                .background {
                    shape
                        .fill(Color(nsColor: .controlBackgroundColor).opacity(0.92))
                        .background(shape.fill(Color(nsColor: .windowBackgroundColor)))
                }
                .clipShape(shape)
        } else {
            content
                .background(shape.fill(Color(nsColor: .controlBackgroundColor)))
                .clipShape(shape)
                .overlay {
                    shape.strokeBorder(Chrome.warning.opacity(0.25), lineWidth: 1)
                }
        }
    }
}
