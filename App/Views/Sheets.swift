import Core
import SwiftData
import SwiftUI

struct AddAccountSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var accountClass = AccountClass.cash
    @State private var balanceText = ""
    @State private var error: String?

    var body: some View {
        Form {
            TextField("Name", text: $name)
            Picker("Type", selection: $accountClass) {
                ForEach(AccountClass.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            TextField("Balance", text: $balanceText)
            if accountClass == .debt {
                Text("Enter the amount owed. It counts against net worth.")
                    .font(Typeface.detail).foregroundStyle(.secondary)
            }
            if let error { Text(error).foregroundStyle(Palette.failure) }
        }
        .formStyle(.grouped)
        .font(Typeface.body)
        .frame(width: 360 * TextSize.current.scale)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") {
                    guard let balance = MoneyInput.parse(balanceText) else { return }
                    do {
                        try CompassStore(context: context).addManualAccount(
                            name: name.trimmingCharacters(in: .whitespaces),
                            accountClass: accountClass, balance: balance, on: Day(.now, in: .current)
                        )
                        dismiss()
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || MoneyInput.parse(balanceText) == nil)
            }
        }
    }
}

struct LogBalanceSheet: View {
    let account: Account
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var balanceText = ""
    @State private var error: String?

    var body: some View {
        Form {
            LabeledContent("Account", value: account.name)
            TextField("Balance today", text: $balanceText)
            if account.source == .simplefin {
                Text("This pins today's balance. A sync with a newer balance takes over, and one within 1% clears the pin.")
                    .font(Typeface.detail).foregroundStyle(.secondary)
            }
            if let error { Text(error).foregroundStyle(Palette.failure) }
        }
        .formStyle(.grouped)
        .font(Typeface.body)
        .frame(width: 360 * TextSize.current.scale)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    guard let balance = MoneyInput.parse(balanceText) else { return }
                    do {
                        try CompassStore(context: context).logBalance(balance, for: account, on: Day(.now, in: .current))
                        dismiss()
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
                .disabled(MoneyInput.parse(balanceText) == nil)
            }
        }
    }
}

struct ConnectSheet: View {
    @Environment(SyncService.self) private var sync
    @Environment(\.dismiss) private var dismiss
    @State private var token = ""

    var body: some View {
        Form {
            Text("Paste a setup token from SimpleFIN Bridge. Each token works once.")
                .foregroundStyle(.secondary)
            TextField("Setup token", text: $token, axis: .vertical)
                .lineLimit(3...6)
        }
        .formStyle(.grouped)
        .font(Typeface.body)
        .frame(width: 420 * TextSize.current.scale)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Connect") {
                    let token = token
                    dismiss()
                    Task { await sync.connect(setupToken: token) }
                }
                .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}

extension AccountClass {
    var label: String {
        switch self {
        case .cash: "Cash"
        case .taxable: "Taxable investments"
        case .retirement: "Retirement"
        case .equity: "Equity"
        case .otherAssets: "Other assets"
        case .debt: "Debt"
        }
    }
}

/// Reads a dollar amount as typed: "1000", "1,000.50", "$1,000" or "-25".
enum MoneyInput {
    static func parse(_ text: String) -> Decimal? {
        let cleaned = text.filter { !"$, ".contains($0) }
        guard !cleaned.isEmpty else { return nil }
        return Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX"))
    }
}
