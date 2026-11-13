import Core
import SwiftData
import SwiftUI

/// Every category in use: what kind it is, how it's budgeted and how many
/// transactions it holds. A category can be renamed, or merged into another.
struct CategoriesSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var kindRecords: [CategoryKindRecord]
    @Query private var budgetRecords: [BudgetRecord]
    /// Counted once on open and after a rename: kinds and roles don't move transactions.
    @State private var counts: [String?: Int] = [:]
    /// Categories kept alive by merchant rules or kinds alone, with no transactions.
    @State private var known: Set<String> = []
    @State private var renaming: String?
    @State private var newName = ""
    @State private var merging: Merge?
    @State private var transfersFiled: Int?
    @State private var problem: String?

    private struct Merge: Identifiable {
        let from: String
        let into: String
        var id: String { from + "\u{1F}" + into }
    }

    var body: some View {
        let kinds = Dictionary(
            kindRecords.compactMap { record in
                CategoryKind(rawValue: record.kindRaw).map { (record.category, $0) }
            }, uniquingKeysWith: { first, _ in first })
        let schedule = budgetRecords.first?.schedule ?? BudgetSchedule(BudgetPlan(flexibleBudget: 0))
        let plan = schedule.base
        let names = Set(counts.keys.compactMap { $0 }).union(known).union(schedule.categories)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }

        VStack(alignment: .leading, spacing: Spacing.m) {
            Text("Categories").font(Typeface.figure).foregroundStyle(Palette.ink)
            Text(
                "Spending counts toward your budget. Income is set against it. Transfers, like card payments, savings and buying stock, are neither. Fixed bills are planned one by one; everything flexible shares one budget."
            )
            .font(Typeface.detail).foregroundStyle(Palette.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(names, id: \.self) { name in
                        CategoryLine(
                            name: name, count: counts[name] ?? 0,
                            kind: Binding(
                                get: { kinds[name] ?? CategoryKind.guess(name) },
                                set: { try? CompassStore(context: context).setKind($0, for: name) }),
                            role: Binding(
                                get: { plan.role(of: name) },
                                set: { role in
                                    try? CompassStore(context: context).save(
                                        schedule.changing(Month(Day(.now, in: .current)), .onward) {
                                            $0.roles[name] = role
                                        })
                                }),
                            rename: {
                                newName = name; renaming = name
                            }
                        )
                        Rule()
                    }
                }
            }
            .frame(minHeight: 320)

            HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
                if let open = counts[nil], open > 0 {
                    Text(open == 1 ? "1 transaction has no category." : "\(open.formatted()) transactions have no category.")
                        .font(Typeface.detail).foregroundStyle(Palette.inkSecondary)
                }
                Spacer()
                Button("Find transfers") { findTransfers() }
                    .help("Files money moving between your own accounts, across all your history, under Transfer")
            }
        }
        .padding(Spacing.l)
        .frame(width: 760 * TextSize.current.scale, height: 620 * TextSize.current.scale)
        .background(Palette.canvas)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
        .task { reloadCounts() }
        .alert("Rename category", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Rename") { rename() }
        } message: {
            Text("Its transactions, merchant rules and budget move to the new name. Use a name that's already in use to merge the two.")
        }
        .alert(item: $merging) { merge in
            Alert(
                title: Text("Merge \(merge.from) into \(merge.into)?"),
                message: Text(mergeMessage(merge)),
                primaryButton: .default(Text("Merge")) { apply(merge) },
                secondaryButton: .cancel()
            )
        }
        .alert("Transfers", isPresented: Binding(get: { transfersFiled != nil }, set: { if !$0 { transfersFiled = nil } })) {
            Button("OK") { transfersFiled = nil }
        } message: {
            Text(TransferHint.result(transfersFiled ?? 0))
        }
        .alert("Couldn't change the category", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK") { problem = nil }
        } message: {
            Text(problem ?? "")
        }
    }

    private func reloadCounts() {
        counts = (try? CompassStore(context: context).categoryCounts()) ?? [:]
        known = (try? CompassStore(context: context).knownCategories()) ?? []
    }

    private func rename() {
        guard let old = renaming else { return }
        renaming = nil
        let new = CategoryRules.tidy(newName)
        guard !new.isEmpty, new != old else { return }
        // A name already in use, ignoring case and spacing, is a merge into
        // that one, asked first; only the case of its own name is a rename.
        let schedule = budgetRecords.first?.schedule ?? BudgetSchedule(BudgetPlan(flexibleBudget: 0))
        var others = Set(counts.keys.compactMap { $0 }).union(known).union(schedule.categories)
        others.remove(old)
        if let existing = CategoryRules.existing(new, among: others) {
            // After the rename alert has gone, or this one won't show.
            DispatchQueue.main.async { merging = Merge(from: old, into: existing) }
        } else {
            apply(Merge(from: old, into: new))
        }
    }

    private func mergeMessage(_ merge: Merge) -> String {
        let count = counts[merge.from] ?? 0
        let moving = count == 1 ? "Its 1 transaction" : "Its \(count.formatted()) transactions"
        let message = "\(moving), merchant rules and planned amounts move to \(merge.into). \(merge.into) keeps its own kind and budget role."
        // A bill folded into a category that isn't a bill has nowhere to show.
        let schedule = budgetRecords.first?.schedule ?? BudgetSchedule(BudgetPlan(flexibleBudget: 0))
        guard let dropped = schedule.billDropped(merging: merge.from, into: merge.into) else { return message }
        return message
            + " \(merge.into) isn't a fixed bill, so \(merge.from)'s planned \(dropped.wholeDollars) a month is dropped and its charges count as flexible spending."
    }

    private func apply(_ merge: Merge) {
        do {
            try CompassStore(context: context).renameCategory(merge.from, to: merge.into)
        } catch {
            problem = error.localizedDescription
        }
        reloadCounts()
    }

    private func findTransfers() {
        transfersFiled = (try? CompassStore(context: context).fileTransfers()) ?? 0
        reloadCounts()
    }
}

private struct CategoryLine: View {
    let name: String
    let count: Int
    @Binding var kind: CategoryKind
    @Binding var role: BudgetRole
    let rename: () -> Void

    var body: some View {
        HStack(spacing: Spacing.m) {
            CategoryGlyph(category: name).font(Typeface.body)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(Typeface.body).foregroundStyle(Palette.ink).lineLimit(1)
                Text(count == 1 ? "1 transaction" : "\(count.formatted()) transactions")
                    .font(Typeface.detail).foregroundStyle(Palette.inkSecondary)
            }
            Spacer(minLength: Spacing.m)
            Picker("Kind of \(name)", selection: $kind) {
                Text("Spending").tag(CategoryKind.spending)
                Text("Income").tag(CategoryKind.income)
                Text("Transfer").tag(CategoryKind.transfer)
            }
            .labelsHidden().pickerStyle(.segmented).frame(width: 250)
            Group {
                if kind == .spending {
                    Picker("Budget role of \(name)", selection: $role) {
                        Text("Fixed").tag(BudgetRole.fixed)
                        Text("Flexible").tag(BudgetRole.flexible)
                        Text("Irregular").tag(BudgetRole.irregular)
                    }
                    .labelsHidden().pickerStyle(.segmented)
                } else {
                    Text("Not budgeted").font(Typeface.detail).foregroundStyle(Palette.inkSecondary)
                }
            }
            .frame(width: 230, alignment: .leading)
            Button("Rename", action: rename).linkButton().font(Typeface.body)
        }
        .padding(.vertical, Spacing.s)
    }
}
