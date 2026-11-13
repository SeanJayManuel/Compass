import SwiftUI

/// A ring that fills toward a goal, with the share in its middle.
///
/// The stroke is centred on the frame's edge, so the room inside it is the
/// frame minus `lineWidth`. A ring about 40 pt across (at the default text
/// size) is small for the 13 pt label and takes the 11 pt one; either label
/// shrinks a little rather than touch the stroke.
struct ProgressRing: View {
    let fraction: Double
    let reached: Bool
    /// The stroke's width in points. A fixed size, so a caller using a small
    /// ring passes a thinner one, already multiplied by the text size.
    var lineWidth: CGFloat = 7

    var body: some View {
        GeometryReader { geometry in
            let diameter = min(geometry.size.width, geometry.size.height)
            let isSmall = diameter <= 44 * TextSize.current.scale
            ZStack {
                Circle().stroke(Palette.progressTrack, lineWidth: lineWidth)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(reached ? Palette.onPace : Palette.progress, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                // Rounded down, so 99.9% never reads as reached.
                Text((fraction * 100).rounded(.down) / 100, format: .percent.precision(.fractionLength(0)))
                    .font(isSmall ? Typeface.caption : Typeface.detail).monospacedDigit().foregroundStyle(Palette.ink)
                    .lineLimit(1).minimumScaleFactor(0.75)
                    // Inside the stroke's inner edge with air to spare: a round space is
                    // narrower than its diameter once the text has any height.
                    .frame(maxWidth: max((diameter - lineWidth) * 0.8, 0))
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}

/// A thin meter: a filled share and optional ticks (a range's minimum, a
/// target, an even pace). Fractions are 0...1 and clamped.
struct MeterBar: View {
    let fraction: Double
    var ticks: [Double] = []
    var tint: Color = Palette.progress
    var height: CGFloat = 8
    let label: String  // read by VoiceOver, e.g. "84 percent of $175,000"

    var body: some View {
        let h = height * TextSize.current.scale
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.progressTrack).frame(height: h)
                Capsule().fill(tint)
                    .frame(width: fraction > 0 ? max(width * clamp(fraction), h) : 0, height: h)
                ForEach(ticks.indices, id: \.self) { index in
                    PaceTick(height: h + 6)
                        .offset(x: width * clamp(ticks[index]) - PaceTick.width / 2)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: h + 6)
        .accessibilityElement()
        .accessibilityLabel(label)
    }

    private func clamp(_ value: Double) -> Double { min(max(value, 0), 1) }
}

/// A tick across a meter in ink, edged in the card's color so it still shows
/// where it crosses a fill as dark as itself (the Graphite accent).
struct PaceTick: View {
    static let width: CGFloat = 4
    let height: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: 1).fill(Palette.ink)
            .frame(width: 2, height: height)
            .padding(.horizontal, 1)
            .background(Palette.surface, in: .rect(cornerRadius: 1.5))
    }
}

/// What a status means, and so what color it takes. Green is on track, paid or
/// done; amber is behind or needs a look; red is over; ink is neutral.
enum StatusTone {
    case neutral, good, attention, over

    var color: Color {
        switch self {
        case .neutral: Palette.ink
        case .good: Palette.onPace
        case .attention: Palette.behind
        case .over: Palette.failure
        }
    }
}

/// A status in words, with an optional symbol, so color is never the only signal.
struct StatusLabel: View {
    let text: String
    var symbol: String? = nil
    let tone: StatusTone

    var body: some View {
        HStack(spacing: Spacing.xs) {
            if let symbol { Image(systemName: symbol).accessibilityHidden(true) }
            Text(text)
        }
        .font(Typeface.detail)
        .foregroundStyle(tone.color)
    }
}

/// A row's actions as a visible menu, mirroring its context menu, so
/// nothing needs a right-click to find.
struct RowActionsMenu<Items: View>: View {
    let label: String  // "Actions for $175K net worth"
    @ViewBuilder let items: () -> Items

    var body: some View {
        Menu {
            items()
        } label: {
            Image(systemName: "ellipsis.circle").font(Typeface.body)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .tint(Palette.inkSecondary)
        .help(label)
        .accessibilityLabel(label)
    }
}

extension View {
    /// A message on the canvas: a suggestion, things to tidy up. A plain card
    /// with less padding, since the accent marks only what's interactive; its
    /// buttons carry it.
    func banner() -> some View {
        card(padding: Spacing.m)
    }

    /// A text button that reads as a link: borderless, in the accent as text,
    /// and underlined when that accent is too close to the ink to tell apart
    /// (the Graphite accent).
    func linkButton() -> some View {
        buttonStyle(.borderless)
            .tint(Palette.needleText)
            .underline(Palette.linksNeedUnderline)
    }
}

/// Items left to right at their own widths, wrapping onto a new line when
/// the next one doesn't fit: a chart legend that reads as a sentence.
struct FlowRow: Layout {
    var spacing: CGFloat = 16  // Spacing.m; a literal, since a Layout is nonisolated
    var lineSpacing: CGFloat = 4  // Spacing.xs

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let available = proposal.width.flatMap { $0.isFinite ? $0 : nil }
        let rows = rows(width: available ?? .infinity, subviews: subviews)
        let width = rows.map { $0.last.map { $0.x + $0.size.width } ?? 0 }.max() ?? 0
        let height = rows.last.flatMap { row in row.map { $0.y + $0.size.height }.max() } ?? 0
        // The whole width it's offered, or its widest line when unbounded.
        return CGSize(width: available ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var index = 0
        for row in rows(width: bounds.width, subviews: subviews) {
            for item in row {
                subviews[index].place(
                    at: CGPoint(x: bounds.minX + item.x, y: bounds.minY + item.y),
                    anchor: .topLeading, proposal: ProposedViewSize(item.size))
                index += 1
            }
        }
    }

    private func rows(width: CGFloat, subviews: Subviews) -> [[(x: CGFloat, y: CGFloat, size: CGSize)]] {
        var rows: [[(x: CGFloat, y: CGFloat, size: CGSize)]] = [[]]
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        for subview in subviews {
            // An item longer than a whole line is offered the line, and truncates.
            var size = subview.sizeThatFits(.unspecified)
            if size.width > width { size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil)) }
            if x > 0, x + size.width > width {
                rows.append([])
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            rows[rows.count - 1].append((x, y, size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return rows
    }
}

/// A screen's search field: a magnifier, the prompt, a clear button, and Esc
/// to clear. A screen with a ⌘F shortcut brings it to the field itself.
struct SearchField: View {
    @Binding var text: String
    let prompt: String
    var focused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: Spacing.s) {
            Image(systemName: "magnifyingglass").foregroundStyle(Palette.inkSecondary)
                .accessibilityHidden(true)
                // The magnifier focuses the field too; the field and clear button take their own clicks.
                .onTapGesture { focused.wrappedValue = true }
            TextField("Search", text: $text, prompt: Text(prompt))
                .textFieldStyle(.plain)
                .focused(focused)
                .onExitCommand { text = "" }
            if !text.isEmpty {
                Button("Clear Search", systemImage: "xmark.circle.fill") {
                    text = ""
                    focused.wrappedValue = true
                }
                .labelStyle(.iconOnly).buttonStyle(.plain)
                .foregroundStyle(Palette.inkSecondary)
            }
        }
        .font(Typeface.body)
        .fieldChrome(focused: focused.wrappedValue)
    }
}

extension View {
    /// The screen's fields: a raised rounded box, ringed in the accent while
    /// typing in it.
    func fieldChrome(focused: Bool) -> some View {
        let scale = TextSize.current.scale
        return padding(.horizontal, 10 * scale)
            .padding(.vertical, 4 * scale)
            .background(Palette.surface, in: .rect(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(focused ? Palette.needle : Palette.rule, lineWidth: focused ? 1.5 : 0.5)
            }
            .contentShape(.rect)
    }
}

/// A rule between rows, one physical pixel on any display. A fixed 0.5 pt is
/// half a pixel at 100% scaling, so each line would round to a full pixel or
/// to nothing depending on where it landed.
struct Rule: View {
    @Environment(\.displayScale) private var displayScale

    var body: some View { Rectangle().fill(Palette.rule).frame(height: 1 / displayScale) }
}

/// A round mark at the start of a row, after Vult's: a merchant's or an
/// account's initials (or a symbol) on a quiet tint, or on its class color
/// when it has one. The row's name says the same, so VoiceOver skips it.
struct RowMark: View {
    let text: String
    var symbol: String?
    /// An account class's color; nil for the neutral tint.
    var tint: Color?
    /// A merchant: its logo when Compass has one (`MerchantLogos`).
    var merchant = false

    var body: some View {
        let size = 30 * TextSize.current.scale
        let logo = merchant ? MerchantLogos.shared.image(for: text) : nil
        ZStack {
            Circle().fill(tint.map { $0.opacity(0.16) } ?? Palette.selection)
            if let logo {
                // On white, so a dark logo reads in dark mode too.
                Circle().fill(.white)
                // Edge to edge: a logo.dev tile (Air Canada's black square,
                // Amazon's orange) becomes the circle itself, as app icons do,
                // rather than a black square around it.
                Image(nsImage: logo).resizable().interpolation(.high).scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(.circle)
            } else if let symbol {
                Image(systemName: symbol).font(.system(size: size * 0.42, weight: .medium))
            } else {
                Text(Self.initials(text)).font(.system(size: size * 0.36, weight: .semibold)).monospacedDigit()
            }
        }
        .foregroundStyle(tint ?? Palette.inkSecondary)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    /// The first letter of up to two words, skipping words without a letter
    /// first ("CHIPOTLE 0412" is C, "Trader Joe's" TJ).
    static func initials(_ name: String) -> String {
        let letters = name.split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == "/" })
            .compactMap { word in word.first(where: \.isLetter).flatMap { word.first == $0 ? $0 : nil } }
        let picked = letters.prefix(2).map { String($0).uppercased() }.joined()
        return picked.isEmpty ? "·" : picked
    }
}
