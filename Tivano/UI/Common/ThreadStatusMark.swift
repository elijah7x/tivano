import SwiftUI

extension Chrome {
    /// Opaque, muted status tokens: darker on light surfaces, lighter on dark ones.
    /// Kept separate from theme accents so a neon theme cannot turn these into neon dots.
    static func threadStatusColor(_ status: ThreadActivityStatus, isDark: Bool) -> Color {
        let hex: String = switch status {
        case .completed: isDark ? "94AD9D" : "617F6D"
        case .approval: isDark ? "C1AC80" : "927747"
        case .question: isDark ? "AAA0BD" : "80718F"
        case .failed: isDark ? "C29489" : "A06D61"
        case .interrupted: isDark ? "9AA5AC" : "727F87"
        case .idle, .running: isDark ? "9AA5AC" : "727F87"
        }
        return Color(hex: hex)
    }
}

struct ThreadStatusMark: View {
    @Environment(\.colorScheme) private var colorScheme
    let status: ThreadActivityStatus
    var isStill = false
    var runningHelp: String? = nil

    var body: some View {
        Group {
            switch status {
            case .idle:
                Color.clear.accessibilityHidden(true)
            case .running:
                MiniSpinner(cellSize: 2.4, isStill: isStill)
                    .help(Text(verbatim: runningHelp ?? Chrome.localized(status.title)))
                    .accessibilityLabel(Text(verbatim: Chrome.localized(status.title)))
            default:
                Group {
                    if status == .interrupted {
                        Circle().strokeBorder(Chrome.threadStatusColor(status, isDark: colorScheme == .dark), lineWidth: 1.2)
                    } else {
                        Circle().fill(Chrome.threadStatusColor(status, isDark: colorScheme == .dark))
                    }
                }
                .frame(width: 6, height: 6)
                .help(Text(verbatim: Chrome.localized(status.title)))
                .accessibilityLabel(Text(verbatim: Chrome.localized(status.title)))
            }
        }
        .frame(width: Chrome.iconSize, height: Chrome.iconSize)
    }
}
