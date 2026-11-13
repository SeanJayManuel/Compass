import SwiftUI

/// How much room a screen's rows have. Below `Spacing.compactBelow` they
/// stack their columns instead of truncating names or clipping amounts.
/// Measured once per screen (in `screenColumn`), never per row, so lazy
/// lists stay cheap.
enum RowDensity: Equatable {
    case regular, compact

    init(width: CGFloat) { self = width < Spacing.compactBelow ? .compact : .regular }
}

extension EnvironmentValues {
    @Entry var rowDensity: RowDensity = .regular
    /// Whether the screen's scroll view is moving, so charts ignore the
    /// pointer then: content sliding under it would scrub them every frame.
    @Entry var scrollActivity: ScrollActivity?
}

/// An object, not a value, so a scroll starting or stopping re-renders only
/// the charts that read it, never the whole screen.
@Observable
final class ScrollActivity {
    private(set) var isScrolling = false
    @ObservationIgnored private var settling: Task<Void, Never>?

    /// A mouse wheel goes idle between ticks; waiting a moment before the
    /// charts take the pointer again keeps them from flipping with every tick.
    func phaseChanged(to phase: ScrollPhase) {
        settling?.cancel()
        if phase != .idle {
            if !isScrolling { isScrolling = true }
        } else {
            settling = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                if !Task.isCancelled { self?.isScrolling = false }
            }
        }
    }
}
