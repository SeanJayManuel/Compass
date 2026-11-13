import AppKit
import SwiftData
import SwiftUI

/// The frame around every screen (Workbench, after Vult): a floating sidebar
/// panel, a top bar with the screen's name and its actions, then the screen.
/// The frame never changes between screens; a screen owns only what's under
/// the top bar. The window has no title bar, so the sidebar's top leaves room
/// for the window buttons and both it and the top bar drag the window.
struct AppFrame<Content: View>: View {
    @ViewBuilder let screen: Content
    /// Below this width the sidebar folds to icons on its own, as the
    /// system sidebar used to collapse, so the screen and top bar still fit.
    @State private var narrow = false

    var body: some View {
        HStack(spacing: 0) {
            Rail()
            VStack(spacing: 0) {
                TopBar()
                screen
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Palette.canvas)
        .ignoresSafeArea(.container, edges: .top)
        .overlay { SearchOverlay() }
        .environment(\.railForcedFolded, narrow)
        .onGeometryChange(for: Bool.self) {
            $0.size.width < 920 * TextSize.current.scale
        } action: {
            narrow = $0
        }
    }
}

/// The search panel while it's up, over the whole window.
private struct SearchOverlay: View {
    @Environment(Navigator.self) private var navigator

    var body: some View {
        ZStack {
            if navigator.isSearching { QuickSearchPanel() }
        }
        #if DEBUG
            // `--open-search` opens the panel once at launch, for snapshots.
            .task { if DebugSupport.openSearchText != nil { navigator.isSearching = true } }
        #endif
    }
}

// MARK: Sidebar

/// Whether the sidebar is folded to its icons (the top bar's button, or
/// View > Hide Sidebar, ⌃⌘S). Remembered between launches.
enum RailState {
    static let collapsedKey = "rail.collapsed"
}

/// One floating panel: Review, Life, Money, then Context and Settings pinned
/// to the bottom. Arrow keys move between screens, as in any Mac sidebar.
/// Folded, it shows each screen's icon alone, its name in a tooltip.
private struct Rail: View {
    @Environment(Navigator.self) private var navigator
    @AppStorage(RailState.collapsedKey) private var storedCollapsed = false
    @Environment(\.railForcedFolded) private var forced
    private var collapsed: Bool { storedCollapsed || forced }

    /// The panel's gap from the window's edges.
    static let inset: CGFloat = 8
    /// The window's buttons span about 54 pt; folded, the panel keeps 12 pt each side.
    static let foldedMinimum: CGFloat = 78

    var body: some View {
        let scale = TextSize.current.scale
        VStack(alignment: .leading, spacing: 0) {
            // Room for the window's close, minimize and zoom buttons, and
            // somewhere to drag the window by.
            Color.clear
                .frame(height: 36 * scale)
                .contentShape(.rect)
                .gesture(WindowDragGesture())
                .allowsWindowActivationEvents(true)
            ScrollView {
                VStack(alignment: .leading, spacing: 16 * scale) {
                    // What needs them comes first.
                    ReviewRailRow()
                    RailGroup(title: "Life") {
                        RailRow(screen: .life)
                        RailRow(screen: .habits)
                        RailRow(screen: .playbook)
                    }
                    RailGroup(title: "Money") {
                        RailRow(screen: .money)
                        RailRow(screen: .spending)
                        RailRow(screen: .transactions)
                        RailRow(screen: .goals)
                    }
                }
                .padding(.top, Spacing.xs)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.never)
            // What an assistant reads before advising. Named for what it is,
            // not for Claude, so it stays right whichever agent is connected.
            RailGroup(title: "Context") {
                RailRow(screen: .notes)
            }
            .padding(.vertical, Spacing.s)
            // Settings, as in the draft: the sliders, not a profile photo
            // Profile is Settings' first tab.
            RailRow(screen: .settings)
                .padding(.top, Spacing.xs)
                .overlay(alignment: .top) { Rule() }
        }
        .padding(.horizontal, 8 * scale)
        .padding(.bottom, 8 * scale)
        .animation(Motion.change, value: collapsed)
        // Wide enough for "Transactions" at every text size; folded, still
        // wide enough to hold the window's three buttons inside the panel.
        .frame(width: collapsed ? max(64 * scale, Self.foldedMinimum) : 216 * scale)
        .environment(\.railCollapsed, collapsed)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Palette.sidebar ?? Palette.surface, in: .rect(cornerRadius: Radius.card))
        .overlay(Hairline(cornerRadius: Radius.card))
        .padding([.top, .leading, .bottom], Self.inset)
        // The window's buttons sit inside the panel's top, centred on the
        // top bar's row, not across the panel's edge.
        .background(WindowButtonPlacement(left: Self.inset + 12, centerY: Self.inset + 18 * scale))
        .focusable()
        // The selected row already shows where they are; the system's focus
        // ring would outline the whole panel.
        .focusEffectDisabled()
        .onKeyPress(.downArrow) {
            navigator.step(1); return .handled
        }
        .onKeyPress(.upArrow) {
            navigator.step(-1); return .handled
        }
    }
}

/// A quiet label over its rows: Life, Money, Context.
private struct RailGroup<Rows: View>: View {
    let title: String
    @ViewBuilder let rows: Rows
    @Environment(\.railCollapsed) private var collapsed

    var body: some View {
        let scale = TextSize.current.scale
        VStack(alignment: .leading, spacing: 2 * scale) {
            if collapsed {
                Rule().padding(.horizontal, 8 * scale).padding(.vertical, 6 * scale)
            } else {
                groupTitle
            }
            rows
        }
    }

    private var groupTitle: some View {
        let scale = TextSize.current.scale
        return Text(title)
            .font(Typeface.detail)
            .foregroundStyle(Palette.inkSecondary)
            .padding(.horizontal, 10 * scale)
            .padding(.bottom, 2 * scale)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Review's row, with how many new transactions wait on them.
private struct ReviewRailRow: View {
    @Query(filter: #Predicate<TransactionRecord> { $0.reviewPending == true || $0.category == nil })
    private var waiting: [TransactionRecord]

    var body: some View { RailRow(screen: .review, count: waiting.count) }
}

private struct RailRow: View {
    let screen: Screen
    /// A count at the row's end (on the icon's corner when folded); nil for none.
    var count: Int?
    @Environment(Navigator.self) private var navigator
    @Environment(\.railCollapsed) private var collapsed
    @State private var hovering = false

    var body: some View {
        let selected = navigator.screen == screen
        let scale = TextSize.current.scale
        Button {
            navigator.screen = screen
        } label: {
            HStack(spacing: 10 * scale) {
                Image(systemName: screen.symbol)
                    .font(Typeface.sidebar.weight(.medium))
                    // Only the selected row's icon takes the accent, so it marks where you are.
                    .foregroundStyle(selected ? Palette.needle : Palette.inkSecondary)
                    .frame(width: 20 * scale)
                    .overlay(alignment: .topTrailing) {
                        if collapsed, let count, count > 0 {
                            Circle().fill(Palette.attention).frame(width: 7 * scale, height: 7 * scale).offset(x: 3, y: -2)
                        }
                    }
                if !collapsed {
                    Text(screen.rowTitle)
                        .font(selected ? Typeface.sidebar.weight(.medium) : Typeface.sidebar)
                        .foregroundStyle(selected ? Palette.ink : Palette.ink.opacity(0.82))
                        .lineLimit(1)
                    if let count, count > 0 {
                        Spacer(minLength: Spacing.xs)
                        Text(count.formatted())
                            .font(Typeface.caption.weight(.semibold))
                            .monospacedDigit()
                            // Amber: something waits on them, not a selection.
                            .foregroundStyle(Palette.label(light: StatusHue.behind.light, dark: StatusHue.behind.dark))
                            .padding(.horizontal, 6 * scale)
                            .frame(minWidth: 20 * scale, minHeight: 18 * scale)
                            .background(Palette.attention, in: .capsule)
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 32 * scale, alignment: collapsed ? .center : .leading)
            .padding(.horizontal, collapsed ? 0 : 10 * scale)
            .background(
                selected ? Palette.selection : hovering ? Palette.hover : .clear,
                in: .rect(cornerRadius: 8 * scale)
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(collapsed ? screen.title : "")
        // Both sections have an Overview, so VoiceOver hears which.
        .accessibilityLabel(count.map { $0 > 0 ? "\(screen.title), \($0) waiting" : screen.title } ?? screen.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: Top bar

/// The same 52 pt bar on every screen: where you are (the section, a slanted
/// divider, then the screen's icon and name), and the screen's actions at the
/// end. Dragging the bar moves the window.
private struct TopBar: View {
    @Environment(Navigator.self) private var navigator
    @AppStorage(RailState.collapsedKey) private var collapsed = false
    @Environment(\.railForcedFolded) private var forced

    var body: some View {
        let scale = TextSize.current.scale
        let screen = navigator.screen ?? .money
        HStack(spacing: 10 * scale) {
            // A narrow window keeps the sidebar folded, so there's nothing to toggle.
            if !forced {
                TopBarButton(title: collapsed ? "Show Sidebar" : "Hide Sidebar", symbol: "sidebar.left") {
                    withAnimation(Motion.change) { collapsed.toggle() }
                }
                .padding(.leading, -8 * scale)
            }
            Text(screen.section)
                .lineLimit(1)
                .font(Typeface.detail)
                .foregroundStyle(Palette.inkSecondary)
            Rectangle()
                .fill(Palette.rule)
                .frame(width: 1, height: 16 * scale)
                .rotationEffect(.degrees(20))
                .accessibilityHidden(true)
            Label {
                Text(screen.rowTitle)
            } icon: {
                Image(systemName: screen.symbol)
                    .foregroundStyle(Palette.inkSecondary)
            }
            .font(Typeface.detail.weight(.medium))
            .foregroundStyle(Palette.ink)
            .lineLimit(1)
            .layoutPriority(-1)
            Spacer(minLength: Spacing.m)
            if forced {
                TopBarButton(title: "Search (⌘K)", symbol: "magnifyingglass") { navigator.isSearching = true }
            } else {
                TopBarSearch()
            }
            // Compact search and grouped money actions leave room for the screen name.
            // The actions still keep their size if a custom typeface needs more room.
            TopBarActions(screen: screen)
                .fixedSize()
        }
        .accessibilityElement(children: .contain)
        .padding(.horizontal, 20 * scale)
        .frame(height: 52 * scale)
        .background {
            Color.clear
                .contentShape(.rect)
                .gesture(WindowDragGesture())
                .allowsWindowActivationEvents(true)
        }
    }
}

/// An icon button in the top bar: quiet until hovered, its name in a tooltip
/// and for VoiceOver.
struct TopBarButton: View {
    let title: String
    let symbol: String
    var spinning = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let scale = TextSize.current.scale
        Button(action: action) {
            Image(systemName: symbol)
                .font(Typeface.body)
                .symbolEffect(.rotate, options: .repeat(.continuous), isActive: spinning && !Motion.reduced)
                .foregroundStyle(hovering ? Palette.ink : Palette.inkSecondary)
                .frame(width: 30 * scale, height: 30 * scale)
                .background(hovering ? Palette.hover : .clear, in: .rect(cornerRadius: 8 * scale))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(title)
        .accessibilityLabel(title)
    }
}

extension EnvironmentValues {
    /// Whether the sidebar is folded to icons, for its rows and groups.
    @Entry var railCollapsed = false
    /// Whether the window is too narrow for the open sidebar.
    @Entry var railForcedFolded = false
}

/// View > Hide Sidebar (⌃⌘S), as the system split view had.
struct RailCommands: Commands {
    @AppStorage(RailState.collapsedKey) private var collapsed = false

    var body: some Commands {
        CommandGroup(replacing: .sidebar) {
            Button(collapsed ? "Show Sidebar" : "Hide Sidebar") {
                withAnimation(Motion.change) { collapsed.toggle() }
            }
            .keyboardShortcut("s", modifiers: [.control, .command])
        }
    }
}

/// Puts the window's close, minimize and zoom buttons at a spot inside the
/// sidebar panel. With no title bar AppKit draws them at the window's corner,
/// right across the panel's rounded edge. AppKit lays them out again on a
/// resize, on full screen and when the window becomes key, so they're placed
/// again after each.
private struct WindowButtonPlacement: NSViewRepresentable {
    /// The first button's left edge, from the window's left.
    let left: CGFloat
    /// The buttons' vertical centre, from the window's top.
    let centerY: CGFloat

    func makeNSView(context: Context) -> Placer { Placer() }

    func updateNSView(_ view: Placer, context: Context) {
        view.left = left
        view.centerY = centerY
        view.place()
    }

    final class Placer: NSView {
        var left: CGFloat = 20
        var centerY: CGFloat = 26
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Leaving the window (closing it) drops the observers too.
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            let names: [Notification.Name] = [
                NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
                NSWindow.didExitFullScreenNotification, NSWindow.didBecomeKeyNotification,
                NSWindow.didResignKeyNotification
            ]
            observers = names.map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.place() }
                }
            }
            DispatchQueue.main.async { [weak self] in self?.place() }
        }

        func place() {
            guard let window, !window.styleMask.contains(.fullScreen),
                let close = window.standardWindowButton(.closeButton),
                let minimize = window.standardWindowButton(.miniaturizeButton),
                let zoom = window.standardWindowButton(.zoomButton),
                let titlebar = close.superview, let container = titlebar.superview
            else { return }
            // The title bar's own view is only as tall as a title bar; grow it
            // from the top so buttons set lower aren't clipped.
            let height = centerY * 2
            container.frame = NSRect(x: 0, y: window.frame.height - height, width: window.frame.width, height: height)
            titlebar.frame = container.bounds
            let gap = minimize.frame.minX - close.frame.minX
            let step = gap > 0 ? gap : 20
            for (index, button) in [close, minimize, zoom].enumerated() {
                let size = button.frame.size
                // AppKit's coordinates run up from the bottom of the title bar view.
                button.setFrameOrigin(NSPoint(x: left + CGFloat(index) * step, y: height - centerY - size.height / 2))
            }
        }
    }
}
