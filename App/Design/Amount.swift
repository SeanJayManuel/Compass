import SwiftUI

/// Hide amounts (⌘⇧H): blurs every dollar figure without locking, for screen
/// sharing. Charts keep their shape.
enum HideAmounts {
    static let key = "hideAmounts"
}

extension Decimal {
    /// "$1,240.00", or "−$1,240.00" with a true minus, never a hyphen.
    var dollars: String { withMinus(unsigned.formatted(.currency(code: "USD"))) }

    /// "$1,240", or "−$1,240" with a true minus, never a hyphen.
    var wholeDollars: String { withMinus(unsigned.formatted(.currency(code: "USD").precision(.fractionLength(0)))) }

    private var unsigned: Decimal { self < 0 ? -self : self }

    /// A minus only when something nonzero is shown, so −$0.40 in whole dollars reads "$0".
    private func withMinus(_ text: String) -> String {
        self < 0 && text.contains(where: { $0.isNumber && $0 != "0" }) ? "−" + text : text
    }

    /// "+$2,140" or "−$310", for changes.
    var signedWholeDollars: String {
        let magnitude = (self < 0 ? -self : self).wholeDollars
        return self < 0 ? "−\(magnitude)" : "+\(magnitude)"
    }
}

struct PrivateAmount: ViewModifier {
    @AppStorage(HideAmounts.key) private var hidden = false

    func body(content: Content) -> some View {
        // The blur only while hidden: even at radius 0 it renders every figure
        // offscreen and blurs it again on each frame of a scroll, which made the
        // money overview stutter. Hiding and showing cross-fade instead.
        Group {
            if hidden {
                content.blur(radius: 9)
            } else {
                content
            }
        }
        .accessibilityHidden(hidden)
        .animation(Motion.change, value: hidden)
    }
}

extension View {
    func privateAmount() -> some View { modifier(PrivateAmount()) }
}
