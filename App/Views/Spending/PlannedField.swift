import Core
import SwiftUI

/// A planned amount typed in place: small, right-aligned, saved on Return or
/// when focus moves on. Clearing it removes the plan; unreadable text, or a
/// change the sheet refuses, goes back to what was there.
struct PlannedField: View {
    let label: String
    let amount: Decimal?
    /// Returns whether the change was saved.
    let commit: (Decimal?) -> Bool
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(label, text: $text, prompt: Text("—"))
            .labelsHidden()
            .textFieldStyle(.plain)
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 6).fill(Palette.canvas))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(focused ? Palette.needle : Palette.rule, lineWidth: focused ? 1.5 : 0.5)
            )
            .focused($focused)
            .accessibilityLabel(label)
            .onAppear { text = Self.format(amount) }
            .onChange(of: amount) { text = Self.format(amount) }
            .onSubmit(save)
            .onChange(of: focused) { if !focused { save() } }
            .privateAmount()
    }

    private func save() {
        let typed = text.trimmingCharacters(in: .whitespaces)
        let value: Decimal?
        if typed.isEmpty {
            value = nil
        } else if let read = BudgetPlan.amount(from: typed) {
            value = read
        } else {
            text = Self.format(amount)
            return
        }
        // An unchanged amount, or one the sheet won't save, shows what's there.
        if value == amount || !commit(value) { text = Self.format(amount) }
    }

    static func format(_ amount: Decimal?) -> String {
        amount.map { $0.formatted(.currency(code: "USD").precision(.fractionLength(0...2))) } ?? ""
    }
}

/// A planned amount across months. A typed amount applies from this month
/// on; one that differs from last month is marked with a dot whose menu
/// keeps the change to this month or puts last month's amount back. (A
/// right-click on the field itself only ever gets the text field's menu.)
struct MonthPlanning {
    let schedule: BudgetSchedule
    let month: Month
    /// Returns whether the change was saved.
    let save: (BudgetSchedule) -> Bool

    func differs(_ amount: BudgetAmount) -> Bool { schedule.differsFromMonthBefore(amount, in: month) }

    /// Whether next month still follows this month's change, so it can be
    /// kept to this month.
    func carriesOn(_ amount: BudgetAmount) -> Bool {
        schedule.plan(for: month.adding(1))[amount] == schedule.plan(for: month)[amount]
    }

    /// Last month's amount, as said: "$70", or "nothing" when none was planned.
    func before(_ amount: BudgetAmount) -> String {
        schedule.plan(for: month.adding(-1))[amount].map { $0 > 0 ? $0.wholeDollars : "nothing" } ?? "nothing"
    }

    func keepToThisMonth(_ amount: BudgetAmount) { _ = save(schedule.keepingOnly(amount, in: month)) }

    func putBack(_ amount: BudgetAmount) {
        _ = save(schedule.setting(amount, to: schedule.plan(for: month.adding(-1))[amount], in: month, .onward))
    }

    var name: String { month.monthName }
    var previousName: String { month.adding(-1).monthName }
}

struct AcrossMonths: ViewModifier {
    let months: MonthPlanning
    let amount: BudgetAmount

    func body(content: Content) -> some View {
        if months.differs(amount) {
            content
                .overlay(alignment: .leading) {
                    Menu {
                        choices
                    } label: {
                        Circle().fill(Palette.needle).frame(width: 6, height: 6)
                            .padding(4).contentShape(Rectangle())
                    }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    // Inside the field's empty left side: amounts are right-aligned,
                    // and a narrow window puts a label just before the field.
                    .offset(x: 2)
                    .help("Changed in \(months.name): \(months.previousName) planned \(months.before(amount))")
                    .accessibilityLabel("Changed in \(months.name)")
                }
        } else {
            content
        }
    }

    @ViewBuilder private var choices: some View {
        if months.carriesOn(amount) {
            Button("Only \(months.name)") { months.keepToThisMonth(amount) }
        }
        Button("Same as \(months.previousName)") { months.putBack(amount) }
    }
}
