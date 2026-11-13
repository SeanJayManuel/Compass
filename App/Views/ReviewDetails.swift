import Core
import SwiftData
import SwiftUI

/// An open Review row: full bank wording, today's category evidence and the
/// existing budget treatment. This never changes the transaction.
struct ReviewDetails: View {
    let transaction: Core.Transaction
    let account: String
    let transferCandidate: Bool
    @Environment(\.modelContext) private var context
    @State private var reading: ReviewReading?
    @State private var problem: String?
    @State private var changes = 0

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(transaction.merchant).font(Typeface.body.weight(.semibold))
                Text(
                    [transaction.day.startDate(in: .current).formatted(date: .long, time: .omitted), account]
                        .filter { !$0.isEmpty }.joined(separator: " · ")
                )
                .font(Typeface.detail).foregroundStyle(Palette.inkSecondary)
                if !transaction.statement.isEmpty {
                    Text(transaction.statement).font(Typeface.body).textSelection(.enabled)
                }
                if !transaction.note.isEmpty {
                    Text(transaction.note).font(Typeface.body).textSelection(.enabled)
                }
                if transaction.oneOff {
                    Text("Marked as one-off; it still counts in its category.")
                        .font(Typeface.detail).foregroundStyle(Palette.inkSecondary)
                }
            }
            if let reading {
                section("Current category check") { Text(categoryCheck(reading)) }
                section("Budget for \(transaction.day.startDate(in: .current).formatted(.dateTime.month(.wide).year()))") {
                    budget(reading)
                    Text(
                        transferCandidate
                            ? "Filing as Transfer excludes it from income and spending. Not a transfer keeps its current category. Neither action moves money."
                            : transaction.category == nil
                                ? "This treatment applies while it is uncategorized. Choose a category before confirming."
                                : "This treatment already applies while the transaction waits in Review. Confirming keeps it; choosing another category can change it."
                    )
                }
            } else if let problem {
                Text("Couldn’t check the current category and budget: \(problem)")
                    .font(Typeface.detail).foregroundStyle(Palette.failure)
                Button("Try again") { changes += 1 }.linkButton().font(Typeface.detail)
            } else {
                Text("Checking the current rules and budget…")
                    .font(Typeface.detail).foregroundStyle(Palette.inkSecondary)
            }
        }
        .foregroundStyle(Palette.ink)
        .fixedSize(horizontal: false, vertical: true)
        .padding(Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.hover, in: .rect(cornerRadius: Radius.control))
        .task(id: Request(transaction: transaction, changes: changes)) { await load() }
        .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave).receive(on: DispatchQueue.main)) { _ in changes += 1 }
    }

    private struct Request: Equatable { let transaction: Core.Transaction; let changes: Int }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(title).font(Typeface.detail.weight(.semibold)).foregroundStyle(Palette.ink)
            content().font(Typeface.detail).foregroundStyle(Palette.inkSecondary)
        }
    }

    private func categoryCheck(_ reading: ReviewReading) -> String {
        if transaction.isSplit {
            return "Split across \(transaction.splits.count) categories. Confirming keeps every part; split charges do not teach merchant rules."
        }
        if transferCandidate {
            return "The bank’s wording suggests a move to or from an account Compass cannot see. Check the full description before filing it as a transfer."
        }
        guard let match = CategoryGuess.explanation(for: transaction, rules: reading.rules, categories: reading.categories) else {
            return transaction.category == nil
                ? "No current merchant rule or common-word match. Choose a category before confirming."
                : "No current merchant rule or common-word match explains this category. Keep it if it is right, or choose another."
        }
        let reason: String =
            switch match.evidence {
            case .merchantRule:
                "Your rule for this merchant’s money \(transaction.amount > 0 ? "in" : "out") suggests \(match.category)."
            case .knownMerchant(let phrase, let inStatement):
                "The \(inStatement ? "bank description" : "merchant name") contains “\(phrase)”, a known merchant filed as \(match.category)."
            case .commonWord(let word):
                "The merchant name or bank description contains “\(word)”, a common merchant word suggesting \(match.category)."
            }
        if transaction.category == nil { return reason + " Choose a category to apply it." }
        if let category = transaction.category, category != match.category {
            return "Currently filed as \(category). \(reason) Current rules can differ from the original filing; nothing changes until you choose a category."
        }
        return reason + " This checks today’s rules; the original reason was not saved."
    }

    @ViewBuilder private func budget(_ reading: ReviewReading) -> some View {
        if reading.matchedTransfer {
            Text("Matched movement between your accounts; already excluded from income and spending. Savings transfers can still count toward a savings line.")
        } else {
            ForEach(Array(transaction.parts.enumerated()), id: \.offset) { _, part in
                budgetPart(part, reading: reading)
            }
        }
        let isSpending = transaction.category.map { (reading.kinds[$0] ?? CategoryKind.guess($0)) == .spending } ?? (transaction.amount < 0)
        if !reading.matchedTransfer && isSpending {
            if transaction.owedBack > 0 { figure("Owed back, excluded from spending", transaction.owedBack) }
            if transaction.paidByGoal > 0 { figure("Paid from a goal, excluded from the budget", transaction.paidByGoal) }
        }
    }

    @ViewBuilder private func budgetPart(_ part: Core.Transaction, reading: ReviewReading) -> some View {
        let category = part.category ?? Spending.uncategorized
        let kind = part.category.map { reading.kinds[$0] ?? CategoryKind.guess($0) }
        if kind == .transfer {
            Text("\(category): excluded from income and spending. Savings transfers can still count toward a savings line.")
        } else if kind == .income {
            figure("\(category) · income", part.amount)
        } else if part.category == nil && part.amount > 0 {
            Text("Unfiled money in is kept apart from income until it has a category.")
        } else {
            let role: String =
                switch reading.plan.role(of: category) {
                case .fixed: "fixed bills"
                case .flexible: "flexible spending"
                case .irregular: "irregular spending"
                }
            if part.budgetAmount > 0 {
                figure("\(category) · refund", part.budgetAmount)
                Text("Offsets this category’s charges in \(role). Fixed-bill totals stop at zero.")
            } else {
                figure("\(category) · \(role)", -part.budgetAmount)
            }
        }
    }

    private func figure(_ label: String, _ amount: Decimal) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                Text(label).fixedSize()
                Text(amount.dollars).monospacedDigit().privateAmount().fixedSize()
            }
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(label)
                Text(amount.dollars).monospacedDigit().privateAmount()
            }
        }
    }

    private func load() async {
        reading = nil
        problem = nil
        let container = context.container, transaction = transaction
        do {
            let worker = Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                let context = ModelContext(container)
                let records = try context.fetch(FetchDescriptor<TransactionRecord>())
                let history = records.map(\.transaction)
                try Task.checkCancellation()
                let kinds = Dictionary(
                    try context.fetch(FetchDescriptor<CategoryKindRecord>()).compactMap { record in
                        CategoryKind(rawValue: record.kindRaw).map { (record.category, $0) }
                    }, uniquingKeysWith: { first, _ in first })
                let rules = CategoryRules(
                    Dictionary(
                        try context.fetch(FetchDescriptor<CategoryRuleRecord>()).map {
                            ($0.merchantKey, $0.category)
                        }, uniquingKeysWith: { first, _ in first }))
                let schedule = try context.fetch(FetchDescriptor<BudgetRecord>()).first?.schedule ?? BudgetSchedule(BudgetPlan(flexibleBudget: 0))
                let transferCategories = Set(history.compactMap(\.category).filter { (kinds[$0] ?? CategoryKind.guess($0)) == .transfer })
                // Pending guesses never explain themselves by teaching a rule.
                let confirmed = records.filter { $0.reviewPending != true }.map(\.transaction)
                let matched = TransferMatch.toFile(in: history, kinds: kinds).contains(transaction.id)
                try Task.checkCancellation()
                return ReviewReading(
                    rules: rules.filling(from: confirmed, skipping: transferCategories),
                    categories: Set(rules.all.values).union(kinds.keys).union(schedule.categories).union(history.compactMap(\.category)), kinds: kinds,
                    plan: schedule.plan(for: Month(transaction.day)),
                    matchedTransfer: matched)
            }
            let value = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled else { return }
            reading = value
        } catch {
            guard !Task.isCancelled else { return }
            problem = error.localizedDescription
        }
    }
}

private struct ReviewReading: Sendable {
    let rules: CategoryRules
    let categories: Set<String>
    let kinds: [String: CategoryKind]
    let plan: BudgetPlan
    let matchedTransfer: Bool
}
