import Core
import SwiftData
import SwiftUI

struct GoalEditor: View {
    let accounts: [Account]
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var goal: Goal
    @State private var kindChoice: KindChoice
    @State private var chosenAccounts: Set<UUID>
    @State private var targetText: String
    @State private var minimumText: String
    @State private var spendingText: String
    @State private var multiplierText: String
    @State private var hasDate: Bool
    @State private var date: Date
    @State private var rewardName: String
    @State private var rewardCostText: String
    @State private var error: String?

    enum KindChoice: String, CaseIterable {
        case netWorth = "Net worth"
        case accountTotal = "Account total"
        case fire = "Financial independence"
    }

    init(goal: Goal, accounts: [Account]) {
        self.accounts = accounts
        _goal = State(initialValue: goal)
        func text(_ value: Decimal?) -> String { value.map { $0 == 0 ? "" : "\($0)" } ?? "" }
        switch goal.kind {
        case .netWorth:
            _kindChoice = State(initialValue: .netWorth)
            _chosenAccounts = State(initialValue: [])
            _spendingText = State(initialValue: "")
            _multiplierText = State(initialValue: "25")
        case .accountTotal(let ids):
            _kindChoice = State(initialValue: .accountTotal)
            _chosenAccounts = State(initialValue: ids)
            _spendingText = State(initialValue: "")
            _multiplierText = State(initialValue: "25")
        case .fire(let spending, let multiplier):
            _kindChoice = State(initialValue: .fire)
            _chosenAccounts = State(initialValue: [])
            _spendingText = State(initialValue: text(spending))
            _multiplierText = State(initialValue: text(multiplier))
        }
        _targetText = State(initialValue: text(goal.target))
        _minimumText = State(initialValue: text(goal.targetMin))
        _hasDate = State(initialValue: goal.targetDate != nil)
        _date = State(initialValue: goal.targetDate?.startDate(in: .current) ?? Calendar.current.date(byAdding: .year, value: 1, to: .now)!)
        _rewardName = State(initialValue: goal.reward?.name ?? "")
        _rewardCostText = State(initialValue: text(goal.reward?.cost))
    }

    var body: some View {
        Form {
            TextField("Name", text: $goal.name, prompt: Text("$150K net worth"))
            Picker("Measures", selection: $kindChoice) {
                ForEach(KindChoice.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            switch kindChoice {
            case .netWorth:
                TextField("Target", text: $targetText, prompt: Text("150,000"))
            case .accountTotal:
                TextField("Target", text: $targetText, prompt: Text("100,000"))
                Section("Accounts") {
                    ForEach(accounts.filter { $0.archivedOn == nil }) { account in
                        Toggle(
                            account.name,
                            isOn: Binding(
                                get: { chosenAccounts.contains(account.id) },
                                set: { if $0 { chosenAccounts.insert(account.id) } else { chosenAccounts.remove(account.id) } }
                            ))
                    }
                }
            case .fire:
                TextField("Annual spending", text: $spendingText, prompt: Text("40,000"))
                TextField("Multiplier", text: $multiplierText)
                Text("Counts taxable, retirement and equity accounts against spending times the multiplier.")
                    .font(Typeface.detail).foregroundStyle(Palette.inkSecondary)
            }
            if kindChoice != .fire {
                TextField("Minimum (optional)", text: $minimumText, prompt: Text("For a range, like 22,000 to 25,000"))
            }
            Toggle("Target date", isOn: $hasDate)
            if hasDate { DatePicker("By", selection: $date, displayedComponents: .date) }
            TextField("Why (optional)", text: $goal.note, prompt: Text("By my 30th birthday"), axis: .vertical)
                .lineLimit(1...3)
            Section("Reward (optional)") {
                TextField("Reward", text: $rewardName, prompt: Text("Tudor Black Bay 54"))
                TextField("Cost", text: $rewardCostText)
                Text("A reward is spending. It never counts toward net worth.")
                    .font(Typeface.detail).foregroundStyle(Palette.inkSecondary)
            }
            if let error { Text(error).foregroundStyle(Palette.failure) }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 560)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save Goal") { save() }
                    .disabled(goal.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func save() {
        var saved = goal
        switch kindChoice {
        case .netWorth:
            saved.kind = .netWorth
        case .accountTotal:
            saved.kind = .accountTotal(chosenAccounts)
        case .fire:
            saved.kind = .fire(annualSpending: MoneyInput.parse(spendingText) ?? 0, multiplier: MoneyInput.parse(multiplierText) ?? 25)
            saved.targetMin = nil
        }
        if kindChoice != .fire {
            saved.target = MoneyInput.parse(targetText) ?? 0
            saved.targetMin = MoneyInput.parse(minimumText)
        }
        // The same checks Claude's goal tools make (Goal.problem, in Core).
        switch saved.problem {
        case .noAccounts: error = "Choose at least one account."; return
        case .noSpending: error = "Enter your annual spending."; return
        case .noTarget: error = "Enter a target amount."; return
        case .minimumNotBelowTarget: error = "The minimum must be below the target."; return
        case nil: break
        }
        saved.targetDate = hasDate ? Day(date, in: .current) : nil
        saved.note = saved.note.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = rewardName.trimmingCharacters(in: .whitespaces)
        saved.reward = name.isEmpty ? nil : Reward(name: name, cost: MoneyInput.parse(rewardCostText), claimedOn: goal.reward?.claimedOn)
        do {
            let store = CompassStore(context: context)
            try store.save(saved)
            try store.refreshGoals(today: Day(.now, in: .current))
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
