import Charts
import Core
import SwiftData
import SwiftUI

/// A pill for picking a range or a view. Also used by Spending's view
/// switcher and the Accounts history ranges.
struct RangeButtonStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        RangePill(label: configuration.label, selected: selected, pressed: configuration.isPressed)
    }
}

/// The selected pill is a quiet ink tint, as the draft's segmented controls.
private struct RangePill: View {
    let label: ButtonStyleConfiguration.Label
    let selected: Bool
    let pressed: Bool

    var body: some View {
        label
            .font(Typeface.detail.weight(selected ? .semibold : .regular))
            .monospacedDigit()
            .padding(.horizontal, Spacing.s)
            .padding(.vertical, Spacing.xs)
            .foregroundStyle(selected ? Palette.ink : Palette.inkSecondary)
            .background(selected ? Palette.selectedFill : .clear, in: .capsule)
            .contentShape(.capsule)
            .opacity(pressed ? 0.7 : 1)
    }
}
