import Core
import SwiftData
import SwiftUI

/// A budget from history, reviewed before saving: the first budget, or
/// "Fill in from my history…" later. Everything else is changed in place
/// on the budget sheet.
struct BudgetEditor: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var records: [TransactionRecord]
    @Query private var kindRecords: [CategoryKindRecord]
    @State private var plan: BudgetPlan
    private let schedule: BudgetSchedule
    @State private var flexibleText: String
    @State private var expectedText: [String: String]
    @State private var notSpending: Set<String> = []
    @State private var loaded = false
    let month: Month
    let fromHistory: Bool
    /// Income is planned, so the flexible budget is what's left after bills and savings.
    let flexibleIsRemainder: Bool

    enum Choice: String, CaseIterable {
        case fixed = "Fixed", flexible = "Flexible", irregular = "Irregular", notSpending = "Not spending"
    }

    /// Edits `month`'s plan; saving applies it from that month on. The last
    /// six full months suggest amounts.
    init(schedule: BudgetSchedule, month: Month, fromHistory: Bool = false, flexibleIsRemainder: Bool = false) {
        self.month = month
        self.flexibleIsRemainder = flexibleIsRemainder
        self.fromHistory = fromHistory
        self.schedule = schedule
        let plan = schedule.plan(for: month)
        _plan = State(initialValue: plan)
        _flexibleText = State(initialValue: plan.flexibleBudget > 0 ? "\(plan.flexibleBudget)" : "")
        _expectedText = State(initialValue: plan.expected.mapValues { "\($0)" })
        let first = Self.historyEnd(month).adding(-5).firstDay.ordinal
        let last = month.adding(1).firstDay.ordinal
        _records = Query(filter: #Predicate<TransactionRecord> { $0.dayOrdinal >= first && $0.dayOrdinal < last })
    }

    var body: some View {
        let transactions = records.map(\.transaction)
        let kinds = Dictionary(
            kindRecords.compactMap { record in
                CategoryKind(rawValue: record.kindRaw).map { (record.category, $0) }
            }, uniquingKeysWith: { first, _ in first })
        let grid = Spending.monthlyByCategory(endingIn: Self.historyEnd(month), transactions: transactions, kinds: kinds)
        let categories = Set(transactions.compactMap(\.category)).union(plan.expected.keys).sorted()

        Form {
            Section {
                Button("Fill in from my history") { applyTemplate(grid) }
                    .help("Steady monthly charges become fixed bills; the flexible budget starts at your recent average.")
                if flexibleIsRemainder {
                    LabeledContent("Flexible budget", value: "What's left")
                    Text("With income planned, the flexible budget is what's left after fixed and irregular bills and savings, every month.")
                        .font(Typeface.detail).foregroundStyle(Palette.inkSecondary)
                } else {
                    TextField("Flexible budget per month", text: $flexibleText, prompt: Text(suggestedFlexible(grid).map { "\($0)" } ?? "2,000"))
                }
                if !flexibleIsRemainder, !readable(flexibleText) {
                    Text(Self.unreadable).font(Typeface.detail).foregroundStyle(Palette.failure)
                }
                if !flexibleIsRemainder, let suggestion = suggestedFlexible(grid) {
                    Text("Your flexible spending averaged \(suggestion.wholeDollars) a month over the last 3 months.")
                        .font(Typeface.detail).foregroundStyle(Palette.inkSecondary)
                }
            }
            Section("Categories") {
                ForEach(categories, id: \.self) { category in
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        HStack {
                            Text(category)
                            Spacer()
                            // Income isn't budgeted: counting it as spending would offset real spending.
                            if (kinds[category] ?? CategoryKind.guess(category)) == .income {
                                Text("Income").foregroundStyle(Palette.inkSecondary)
                            } else {
                                Picker(category, selection: binding(for: category, kinds: kinds)) {
                                    ForEach(Choice.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                                }
                                .labelsHidden().pickerStyle(.segmented).frame(width: 340)
                            }
                        }
                        if choice(for: category, kinds: kinds) == .fixed {
                            TextField(
                                "Expected each month",
                                text: Binding(
                                    get: { expectedText[category] ?? "" },
                                    set: { expectedText[category] = $0 }
                                ), prompt: Text(averageMonth(category, grid).map { "\($0)" } ?? "0"))
                            if !readable(expectedText[category] ?? "") {
                                Text(Self.unreadable).font(Typeface.detail).foregroundStyle(Palette.failure)
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 620, height: 620)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save Budget") { save(grid: grid, kinds: kinds) }
                    // Only fields still on screen: a bill switched to flexible keeps its text but hides it.
                    .disabled(
                        !readable(flexibleText)
                            || expectedText.contains { category, text in
                                !notSpending.contains(category) && plan.role(of: category) == .fixed && !readable(text)
                            })
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            notSpending = Set(categories.filter { (kinds[$0] ?? CategoryKind.guess($0)) != .spending })
            if fromHistory { applyTemplate(grid) }
        }
    }

    static let unreadable = "Type an amount like 1,800, $1,800.50 or 1.8k."

    /// Empty (use the suggestion) or an amount BudgetPlan can read. The old
    /// money field read "2k" as $2 and "1.8k" as $1.80, so a typed budget
    /// could save as next to nothing.
    private func readable(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespaces).isEmpty || BudgetPlan.amount(from: text) != nil
    }

    private func choice(for category: String, kinds: [String: CategoryKind]) -> Choice {
        if notSpending.contains(category) { return .notSpending }
        switch plan.role(of: category) {
        case .fixed: return .fixed
        case .flexible: return .flexible
        case .irregular: return .irregular
        }
    }

    private func binding(for category: String, kinds: [String: CategoryKind]) -> Binding<Choice> {
        Binding(
            get: { choice(for: category, kinds: kinds) },
            set: { choice in
                switch choice {
                case .notSpending: notSpending.insert(category)
                case .fixed: notSpending.remove(category); plan.roles[category] = .fixed
                case .flexible: notSpending.remove(category); plan.roles[category] = .flexible
                case .irregular: notSpending.remove(category); plan.roles[category] = .irregular
                }
            }
        )
    }

    /// A starting plan from the last six full months (FlexBudget.template).
    private func applyTemplate(_ grid: [CategoryMonths]) {
        let template = FlexBudget.template(from: grid.filter { !notSpending.contains($0.category) })
        // Choices made by hand win over the template's guesses.
        let manual = plan.roles
        plan.roles = template.roles.merging(manual) { _, mine in mine }
        flexibleText = "\(template.flexibleBudget)"
        expectedText = [:]
        for row in grid where plan.role(of: row.category) == .fixed && !notSpending.contains(row.category) {
            if let amount = template.expected[row.category] ?? FlexBudget.usualMonth(row.category, in: grid) {
                expectedText[row.category] = "\(amount)"
            }
        }
    }

    private func averageMonth(_ category: String, _ grid: [CategoryMonths]) -> Decimal? {
        FlexBudget.usualMonth(category, in: grid)
    }

    /// The last full month before `month`, or before this month for one
    /// still to come, so suggestions never average in empty months.
    private static func historyEnd(_ month: Month) -> Month {
        min(month, Month(Day(.now, in: .current))).adding(-1)
    }

    private func suggestedFlexible(_ grid: [CategoryMonths]) -> Decimal? {
        FlexBudget.suggestedFlexibleBudget(from: grid, plan: plan, excluding: notSpending)
    }

    private func save(grid: [CategoryMonths], kinds: [String: CategoryKind]) {
        let store = CompassStore(context: context)
        let categories = Set(records.compactMap(\.category)).union(plan.expected.keys)
        var saved = plan
        saved.flexibleBudget = BudgetPlan.amount(from: flexibleText) ?? suggestedFlexible(grid) ?? 0
        // Every fixed category gets an amount: what was typed, else its recent
        // average. An irregular one keeps what's planned for it on the sheet.
        saved.expected = plan.expected.filter { saved.role(of: $0.key) == .irregular }
        for category in categories where !notSpending.contains(category) && saved.role(of: category) == .fixed {
            saved.expected[category] = BudgetPlan.amount(from: expectedText[category] ?? "") ?? averageMonth(category, grid) ?? 0
        }
        // Not spending: income stays income; anything else becomes a transfer.
        for category in categories {
            let current = kinds[category] ?? CategoryKind.guess(category)
            if current == .income { continue }
            if notSpending.contains(category), current == .spending { try? store.setKind(.transfer, for: category) }
            if !notSpending.contains(category), current != .spending { try? store.setKind(.spending, for: category) }
        }
        // A first budget is every month's; a later one starts this month.
        // A budget that didn't save keeps the editor open, with what was typed.
        let next: BudgetSchedule = schedule.isEmpty ? BudgetSchedule(saved) : schedule.applying(saved, from: month)
        let wasSaved: Bool = SaveFailures.shared.attempt { try store.save(next) }
        guard wasSaved else { return }
        dismiss()
    }
}
