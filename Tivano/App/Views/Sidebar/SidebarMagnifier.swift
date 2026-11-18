import Foundation
import SwiftUI

/// Per-row magnification levels for the sidebar's continuous hover, kept out of `@Observable`
/// so pointer moves never invalidate `SidebarView.body`. Only the leaf modifier on a row whose
/// level actually changed re-renders (at most six rows on a jump across the list).
@MainActor
final class SidebarMagnifier {
    private var cells: [UUID: ObservedValue<Int>] = [:]
    private var active: [UUID: Int] = [:]
    private(set) var hoveredID: UUID?
    private(set) var isDisabled = false

    func level(_ id: UUID) -> ObservedValue<Int> {
        if let cell = cells[id] { return cell }
        let cell = ObservedValue(active[id] ?? 0)
        cells[id] = cell
        return cell
    }

    func set(hovered: UUID?, neighbors: [UUID]) {
        var next: [UUID: Int] = [:]
        if let hovered {
            next[hovered] = 2
        }
        for id in neighbors where id != hovered && next[id] == nil {
            guard next.count < 3 else { break }
            next[id] = 1
        }
        hoveredID = hovered
        apply(next)
    }

    func reset() {
        hoveredID = nil
        guard !active.isEmpty else { return }
        apply([:])
    }

    func setDisabled(_ disabled: Bool) {
        isDisabled = disabled
        guard disabled, hoveredID != nil || !active.isEmpty else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            reset()
        }
    }

    private func apply(_ next: [UUID: Int]) {
        var candidates = Array(active.keys)
        for id in next.keys where active[id] == nil {
            candidates.append(id)
        }
        active = next
        var writes: [(ObservedValue<Int>, Int)] = []
        writes.reserveCapacity(min(candidates.count, 6))
        for id in candidates {
            let target = next[id] ?? 0
            if let cell = cells[id] {
                if cell.value != target, writes.count < 6 {
                    writes.append((cell, target))
                }
            } else if target != 0 {
                cells[id] = ObservedValue(target)
            }
        }
        for (cell, value) in writes {
            cell.value = value
        }
    }
}

/// Leaf magnification modifier: observes only this row's `ObservedValue<Int>` cell so neither
/// `SidebarView.body` nor the enclosing row's `Equatable` inputs depend on hover magnification.
struct SidebarMagnify: ViewModifier {
    let id: UUID
    let magnifier: SidebarMagnifier?

    func body(content: Content) -> some View {
        let level = magnifier?.level(id).value ?? 0
        content
            .scaleEffect(Self.scale(for: level), anchor: .leading)
            .offset(x: Self.offset(for: level))
            .animation(magnifier?.isDisabled == false ? .smooth(duration: 0.2) : nil, value: level)
    }

    private static func scale(for level: Int) -> CGFloat {
        switch level {
        case 2: 1.06
        case 1: 1.025
        default: 1
        }
    }

    private static func offset(for level: Int) -> CGFloat {
        switch level {
        case 2: 3
        case 1: 1
        default: 0
        }
    }
}
