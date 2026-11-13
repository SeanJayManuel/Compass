import Core
import SwiftData
import SwiftUI

/// Where am I? As the Workbench draft, card for card:
/// net worth with asset allocation beside it, the Accounts by class, then
/// three tiles: flexible left this month, goals, and what's waiting on them.
struct MoneyOverview: View {
    @Environment(NetWorthCache.self) private var cache
    @Query(sort: \GoalRecord.createdAt) private var goalRecords: [GoalRecord]
    @AppStorage("netWorth.range") private var range = TimeRange.oneYear
    @State private var today = Day(.now, in: .current)
    @State private var scrollActivity = ScrollActivity()
    @State private var position = ScrollPosition(edge: .top)
    /// Wide enough for allocation to sit beside net worth rather than under it.
    @State private var wide = true

    var body: some View {
        let breakdown = cache.breakdown
        let series = breakdown.map(\.netWorth)
        let visible = NetWorthSeries.trim(series, to: range, endingOn: cache.today)

        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                SyncMessages()

                let netWorth = ScrubbableNetWorth(
                    series: series, visible: visible, markers: markers(on: visible),
                    visibleBreakdown: trimmedBreakdown(breakdown),
                    accessible: breakdown.last?.accessible, today: cache.today, range: $range,
                    chartHeight: 200,
                    target: nextNetWorthGoal(above: series.last?.total)
                )
                .card(padding: Spacing.m)
                Group {
                    if wide {
                        HStack(alignment: .top, spacing: Spacing.m) {
                            netWorth
                            if let latest = breakdown.last {
                                AssetAllocation(latest: latest, fillsHeight: true)
                                    .frame(width: 300 * TextSize.current.scale)
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    } else {
                        netWorth
                        if let latest = breakdown.last { AssetAllocation(latest: latest) }
                    }
                }

                AccountsBreakdown(today: today)

                // Three tiles, side by side when there's room.
                if wide {
                    HStack(alignment: .top, spacing: Spacing.m) { tiles }
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    tiles
                }
            }
            .screenColumn()
            .environment(\.scrollActivity, scrollActivity)
            .onGeometryChange(for: Bool.self) {
                $0.size.width >= 900 * TextSize.current.scale
            } action: {
                wide = $0
            }
        }
        .onScrollPhaseChange { _, phase in
            scrollActivity.phaseChanged(to: phase)
        }
        .scrollPosition($position)
        #if DEBUG
            .task { await scrollTest() }
        #endif
        .background(Palette.canvas)
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            today = Day(.now, in: .current)
        }
    }

    @ViewBuilder private var tiles: some View {
        FlexibleGlance(today: today, tile: true)
        GoalsTile(today: cache.today)
        WaitingTile()
    }

    #if DEBUG
        /// `--scroll-test`: three seconds down, three back up, until quit.
        private func scrollTest() async {
            guard DebugSupport.scrollTest else { return }
            try? await Task.sleep(for: .seconds(3))
            while !Task.isCancelled {
                withAnimation(.linear(duration: 3)) { position.scrollTo(edge: .bottom) }
                try? await Task.sleep(for: .seconds(3.5))
                withAnimation(.linear(duration: 3)) { position.scrollTo(edge: .top) }
                try? await Task.sleep(for: .seconds(3.5))
            }
        }
    #endif

    /// The smallest active net worth goal still above today's total.
    private func nextNetWorthGoal(above total: Decimal?) -> (name: String, value: Decimal)? {
        guard let total else { return nil }
        return goalRecords.map(\.goal)
            .filter { goal in
                if case .netWorth = goal.kind, case .active = goal.status { return goal.target > total }
                return false
            }
            .min { $0.target < $1.target }
            .map { ($0.name, $0.target) }
    }

    private func trimmedBreakdown(_ breakdown: [DailyBreakdown]) -> [DailyBreakdown] {
        guard let start = range.start(endingOn: cache.today) else { return breakdown }
        return breakdown.filter { $0.day >= start }
    }

    /// Reached goals, as small marks on the net worth line.
    private func markers(on series: [DailyTotal]) -> [GoalMarker] {
        let byDay = Dictionary(series.map { ($0.day, $0.total) }, uniquingKeysWith: { first, _ in first })
        return goalRecords.compactMap { record in
            guard case .achieved(let day, _) = record.goal.status, let total = byDay[day] else { return nil }
            return GoalMarker(id: record.id, name: record.name, day: day, total: total)
        }
    }
}

/// A glance card's title and the way into its screen. Shared with the life overview.
struct GlanceHeader: View {
    let title: String
    let link: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            // The draft's card title: body size, semibold.
            Text(title).font(Typeface.body.weight(.semibold)).foregroundStyle(Palette.ink)
            Spacer(minLength: Spacing.s)
            Button(action: action) {
                HStack(spacing: Spacing.xs) {
                    Text(link)
                    Image(systemName: "chevron.right").font(AccountsSmallType.icon).accessibilityHidden(true)
                }
            }
            .linkButton().font(Typeface.detail)
        }
    }
}

/// The flexible amount left this month, as Spending leads with it.
struct FlexibleGlance: View {
    let today: Day
    /// After its link picks Spending: the menu bar panel opens the window.
    let opened: () -> Void
    /// The Money overview's tile: a small header and a smaller figure.
    var tile = false
    @Environment(Navigator.self) private var navigator
    @Query private var budgetRecords: [BudgetRecord]
    @Query private var payRecords: [PayProfileRecord]
    @Query private var kindRecords: [CategoryKindRecord]
    @Query private var records: [TransactionRecord]
    @Environment(\.modelContext) private var context
    @Environment(PayCache.self) private var pay
    /// The month's plan as Spending shows it (pay-planned income, flexible as
    /// what's left), read when the budget, pay settings or paychecks change,
    /// not on every draw. Nil until the paychecks are in.
    @State private var plan: BudgetPlan?

    init(today: Day, opened: @escaping () -> Void = {}, tile: Bool = false) {
        self.today = today
        self.opened = opened
        self.tile = tile
        let month = Month(today)
        // Last month too, so a transfer whose other side landed before the 1st still pairs.
        let first = month.adding(-1).firstDay.ordinal, last = month.adding(1).firstDay.ordinal
        var descriptor = FetchDescriptor<TransactionRecord>(predicate: #Predicate { $0.dayOrdinal >= first && $0.dayOrdinal < last })
        // Reading each stored field costs time; flexible spending and pairing
        // transfers need only these.
        // `withNotes` reads the rest; fetched here, not faulted in one by one.
        descriptor.propertiesToFetch = [
            \.id, \.accountID, \.dayOrdinal, \.amount, \.category, \.reimbursable, \.reimbursableAmount,
            \.paidFromGoal, \.paidFromGoalAmount, \.note, \.oneOff, \.splitsData
        ]
        _records = Query(descriptor)
    }

    var body: some View {
        let month = Month(today)
        let name = month.monthName
        VStack(alignment: .leading, spacing: Spacing.s) {
            if tile {
                TileHeader(symbol: "cart", title: "Flexible left in \(name)")
            } else {
                GlanceHeader(title: "Flexible spending", link: "Spending") {
                    navigator.screen = .spending; opened()
                }
            }
            if let plan, plan.flexibleBudget > 0 {
                let pace = FlexBudget.month(month, today: today, transactions: transactions, kinds: kinds, plan: plan)
                let left = pace.flexibleRemaining
                let figure = Text(
                    tile
                        ? (left >= 0 ? left.wholeDollars : "\((-left).wholeDollars) over")
                        : (left >= 0 ? "\(left.wholeDollars) left" : "\((-left).wholeDollars) over")
                )
                .font(tile ? Typeface.section : Typeface.figure).monospacedDigit()
                .foregroundStyle(left >= 0 ? Palette.ink : Palette.failure)
                let budget = Text(tile ? "of \(pace.flexibleBudget.wholeDollars)" : "of \(pace.flexibleBudget.wholeDollars) for \(name)")
                    .font(tile ? Typeface.detail : Typeface.body).foregroundStyle(Palette.inkSecondary)
                // The budget moves under the figure when the two don't fit on a line.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                        figure.fixedSize()
                        budget.fixedSize()
                    }
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        figure.fixedSize()
                        budget.fixedSize(horizontal: false, vertical: true)
                    }
                }
                .privateAmount()
                PaceMeter(
                    spent: pace.flexibleSpent, budget: pace.flexibleBudget, expected: pace.expectedSoFar,
                    tone: pace.standing.tone, showsPace: pace.daysLeft > 0, thickness: tile ? 6 : 12)
                Text(pace.paceInWords)
                    .font(Typeface.detail)
                    .foregroundStyle(pace.standing.tone == .neutral ? Palette.inkSecondary : pace.standing.tone.color)
            } else if plan == nil {
                // The paychecks aren't read yet (just after launch): say so, not "no budget".
                Text("Measuring…").font(tile ? Typeface.section : Typeface.figure).foregroundStyle(Palette.inkSecondary)
            } else {
                Text("No flexible budget yet. Set one up in Spending to see what's left each month.")
                    .font(Typeface.body).foregroundStyle(Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: tile ? .infinity : nil, alignment: .topLeading)
        .card(padding: tile ? Spacing.m : Spacing.l)
        .contentShape(.rect)
        .onTapGesture { if tile { navigator.screen = .spending } }
        .accessibilityAddTraits(tile ? .isButton : [])
        // A new paycheck moves planned income, and so the flexible budget.
        .task(
            id: PlanInputs(
                budget: budgetRecords.first?.planData, pay: payRecords.first?.profileData, paychecks: pay.version,
                kinds: kinds, month: Month(today))
        ) {
            guard let paychecks = pay.paychecks(forProfile: payRecords.first?.profileData) else { return }
            plan = (try? CompassStore(context: context).budgetPlan(for: Month(today), paychecks: paychecks)) ?? BudgetPlan(flexibleBudget: 0)
        }
    }

    private var kinds: [String: CategoryKind] {
        Dictionary(
            kindRecords.compactMap { record in CategoryKind(rawValue: record.kindRaw).map { (record.category, $0) } },
            uniquingKeysWith: { first, _ in first })
    }

    /// Built field by field: `record.transaction` would read every field back
    /// in. Matched transfers read as filed, as on Spending's budget.
    private var transactions: [Core.Transaction] {
        TransferMatch.asFiled(
            records.map { record in
                record.withNotes(
                    Core.Transaction(
                        id: record.id, accountID: record.accountID, day: Day(ordinal: record.dayOrdinal),
                        amount: record.amount, merchant: "", category: record.category, externalID: ""))
            }, kinds: kinds)
    }
}

/// A tile's header: a small icon and what the tile is, as the draft.
struct TileHeader: View {
    let symbol: String
    let title: String

    var body: some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: symbol).foregroundStyle(Palette.inkSecondary).accessibilityHidden(true)
            Text(title).foregroundStyle(Palette.inkSecondary)
        }
        .font(Typeface.detail)
        .accessibilityAddTraits(.isHeader)
    }
}

/// How the goals stand in a line: how many are on pace, and the first one
/// that needs a look. Opens Goals, on that goal when there is one.
private struct GoalsTile: View {
    let today: Day
    @Environment(Navigator.self) private var navigator
    @Environment(NetWorthCache.self) private var cache
    @Query(sort: \GoalRecord.createdAt) private var goalRecords: [GoalRecord]

    var body: some View {
        let active = GoalAttention.order(goalRecords.map(\.goal), progress: cache.goalProgress)
        let readings = active.compactMap { goal in cache.goalProgress[goal.id].map { GoalReading(goal: goal, progress: $0, today: today) } }
        let needsLook = readings.filter { $0.status.tone == .attention || $0.status.tone == .over }
        let onPace = readings.count - needsLook.count
        VStack(alignment: .leading, spacing: Spacing.s) {
            TileHeader(symbol: "scope", title: "Goals")
            if active.isEmpty {
                Text("No goals yet").font(Typeface.section).foregroundStyle(Palette.ink)
            } else if readings.isEmpty {
                // Progress isn't in yet (just after launch): say so, not "all on pace".
                Text("Measuring…").font(Typeface.section).foregroundStyle(Palette.inkSecondary)
            } else {
                Text("\(onPace) on pace").font(Typeface.section).foregroundStyle(Palette.ink)
                if let first = needsLook.first {
                    (Text(first.goal.name).foregroundStyle(Palette.attention)
                        + Text(needsLook.count > 1 ? " and \(needsLook.count - 1) more need a look" : " needs a look")
                        .foregroundStyle(Palette.inkSecondary))
                        .font(Typeface.detail)
                } else {
                    Text(readings.count < active.count ? "Measuring the rest" : "All on pace")
                        .font(Typeface.detail).foregroundStyle(Palette.inkSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card(padding: Spacing.m)
        .contentShape(.rect)
        .onTapGesture {
            if let first = needsLook.first { navigator.open(goal: first.goal.id) } else { navigator.screen = .goals }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens Goals")
    }
}

/// What's waiting on them in Review. Opens it.
private struct WaitingTile: View {
    @Environment(Navigator.self) private var navigator
    @Query(filter: #Predicate<TransactionRecord> { $0.reviewPending == true || $0.category == nil })
    private var waiting: [TransactionRecord]

    var body: some View {
        let unfiled = waiting.filter { $0.category == nil }.count
        VStack(alignment: .leading, spacing: Spacing.s) {
            TileHeader(symbol: "tray", title: "Waiting on you")
            Text(waiting.isEmpty ? "All caught up" : "\(waiting.count) to review")
                .font(Typeface.section).foregroundStyle(Palette.ink)
            if !waiting.isEmpty {
                Text(unfiled == 0 ? "New transactions to confirm" : "\(unfiled) without a category")
                    .font(Typeface.detail).foregroundStyle(Palette.inkSecondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card(padding: Spacing.m)
        .contentShape(.rect)
        .onTapGesture { navigator.screen = .review }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens Review")
    }
}

/// What the overview's plan is read from: the budget, pay settings and this month's transactions.
private struct PlanInputs: Hashable {
    var budget: Data?
    var pay: Data?
    var paychecks: Int
    var kinds: [String: CategoryKind]
    var month: Month
}
