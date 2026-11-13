import Core
import PDFKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Their pay as they set it, about once a year: salary, paydays, the 401(k) and
/// its match, the stock plan, and the bonuses and vests they expect. Each
/// paycheck's figures are worked out from these, and the paychecks that sync
/// say what arrived. A paystub can fill the settings in; none is needed.
struct PaySettings: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \PaystubRecord.depositOrdinal, order: .reverse) private var stubRecords: [PaystubRecord]
    @Query(sort: \AccountRecord.createdAt) private var accountRecords: [AccountRecord]
    @State private var profile = PayProfile()
    @State private var loaded = false
    @State private var importing = false
    @State private var message: (text: String, failed: Bool)?
    /// Read when the tab opens and when what finds them changes, not on every keystroke.
    @State private var paychecks: [PaycheckDeposit] = []

    var body: some View {
        let stubs = stubRecords.compactMap(\.stub)
        let accounts = accountRecords.map(\.account).filter { $0.archivedOn == nil && $0.accountClass != .debt }
        Form {
            Section {
                LabeledContent("Base salary a year") {
                    TextField("Base salary a year", value: $profile.annualSalary, format: .currency(code: "USD"))
                        .labelsHidden().multilineTextAlignment(.trailing).frame(width: 130)
                }
                Picker("Paid", selection: $profile.everyDays) {
                    Text("Every week").tag(7)
                    Text("Every other week").tag(14)
                }
                LabeledContent("A payday") {
                    DatePicker(
                        "A payday",
                        selection: Binding(
                            get: { (profile.knownPayday ?? Day(.now, in: .current)).startDate(in: .current) },
                            set: { profile.knownPayday = Day($0, in: .current) }
                        ), displayedComponents: .date
                    )
                    .labelsHidden()
                }
                SettingsNote("A day a paycheck landed in your checking account; the rest count from it. Change these when your pay does, like after a raise.")
            } header: {
                SettingsHeader("Salary")
            }

            Section {
                percent("You put in", $profile.retirementPercent)
                Toggle("Before tax", isOn: $profile.retirementPreTax)
                percent("Match, of what you put in", $profile.matchPercent)
                percent("Matched on up to", $profile.matchUpToPercent)
                account("401(k) account", $profile.retirementAccountID, accounts)
            } header: {
                SettingsHeader("401(k)")
            }

            Section {
                money("You buy each check", $profile.stockPerCheck)
                money("Company adds each check", $profile.stockCompanyPerCheck)
                account("Stock plan account", $profile.stockAccountID, accounts)
            } header: {
                SettingsHeader("Stock purchase")
            }

            if let check = Pay.expected(profile) {
                Section {
                    LabeledContent("Gross a paycheck", value: check.regular.formatted(.currency(code: "USD"))).privateAmount()
                    LabeledContent(
                        "401(k) a paycheck",
                        value: "\(check.retirement.formatted(.currency(code: "USD"))) + \(check.match.formatted(.currency(code: "USD"))) match"
                    )
                    .privateAmount()
                    if let latest = Pay.latestNet(paychecks) {
                        LabeledContent(
                            "Latest paycheck",
                            value: "\(latest.net.formatted(.currency(code: "USD"))) on \(Self.long(latest.day))"
                        ).privateAmount()
                        LabeledContent(
                            "Take-home a month, on average",
                            value: Pay.monthlyTakeHome(net: latest.net, profile: profile).wholeDollars
                        ).privateAmount()
                    } else {
                        SettingsNote("No paycheck yet: deposits filed as \(profile.incomeCategory) near a payday count.")
                    }
                    let threes = Pay.threePaycheckMonths(from: Month(Day(.now, in: .current)), months: 12, profile: profile)
                    LabeledContent(
                        "Three-paycheck months",
                        value: threes.isEmpty
                            ? "None in the next year"
                            : threes.map {
                                $0.firstDay.startDate(in: .current).formatted(.dateTime.month(.abbreviated).year())
                            }.joined(separator: ", "))
                } header: {
                    SettingsHeader("Each paycheck")
                }
            }

            Section {
                Toggle("Plan paychecks in the budget", isOn: $profile.planIncomeFromPay)
                if profile.planIncomeFromPay {
                    TextField("Paycheck category", text: $profile.incomeCategory)
                    SettingsNote("Two paychecks a month at your latest deposit. A third payday, bonuses and the stock plan stay out of the budget.")
                }
            } header: {
                SettingsHeader("Budget")
            }

            Section {
                ForEach($profile.expected) { $item in
                    ExpectedPayRow(item: $item) { profile.expected.removeAll { $0.id == item.id } }
                }
                HStack {
                    Button("Add Bonus") { profile.expected.append(ExpectedPay(kind: .bonus, title: "Annual bonus", day: nil, gross: 0)) }
                    Button("Add Vest") { profile.expected.append(ExpectedPay(kind: .vest, title: "RSU vest", day: nil, gross: 0)) }
                }
                SettingsNote("Kept apart from the monthly budget. Leave the date off while it isn't known.")
            } header: {
                SettingsHeader("Bonuses and vests")
            }

            Section {
                Button("Fill In from a Paystub…") { importing = true }
                SettingsNote(
                    "Optional: reads a Statement of Earnings and Deductions (PDF) and fills in the salary, a payday, the 401(k) percent and the stock purchase. Compass keeps the figures it reads, never the file."
                )
                if let message { SettingsNote(message.text, color: message.failed ? Palette.failure : Palette.inkSecondary) }
                ForEach(stubs.sorted { $0.depositDate > $1.depositDate }) { stub in
                    HStack {
                        Text(Self.long(stub.depositDate))
                        Spacer()
                        Text("\(stub.grossPay.formatted(.currency(code: "USD"))) gross · \(stub.netPay.formatted(.currency(code: "USD"))) net")
                            .monospacedDigit().foregroundStyle(Palette.inkSecondary).privateAmount()
                        Button("Delete") { try? CompassStore(context: context).deletePaystub(depositedOn: stub.depositDate) }
                            .linkButton()
                    }
                }
            } header: {
                SettingsHeader("Paystubs")
            }
        }
        .settingsPane()
        .onAppear {
            guard !loaded else { return }
            profile = (try? CompassStore(context: context).payProfile()) ?? PayProfile()
            loaded = true
        }
        .task(id: [profile.knownPayday?.ordinal ?? 0, profile.everyDays, profile.incomeCategory.hashValue]) {
            paychecks = (try? CompassStore(context: context).paychecks(profile)) ?? []
        }
        .onChange(of: profile) { _, new in
            if loaded { try? CompassStore(context: context).save(new) }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            let (read, text, failed) = Self.importStubs(urls, into: CompassStore(context: context))
            // The latest stub fills in the settings.
            if let latest = read.max(by: { $0.depositDate < $1.depositDate }) { profile = profile.filled(from: latest) }
            message = (text, failed)
        }
    }

    private func percent(_ title: String, _ value: Binding<Decimal>) -> some View {
        LabeledContent(title) {
            HStack(spacing: 2) {
                TextField(title, value: value, format: .number).labelsHidden().multilineTextAlignment(.trailing).frame(width: 60)
                Text("%")
            }
        }
    }

    private func money(_ title: String, _ value: Binding<Decimal>) -> some View {
        LabeledContent(title) {
            TextField(title, value: value, format: .currency(code: "USD"))
                .labelsHidden().multilineTextAlignment(.trailing).frame(width: 110)
        }
    }

    private func account(_ title: String, _ id: Binding<UUID?>, _ accounts: [Account]) -> some View {
        Picker(title, selection: id) {
            Text("None").tag(UUID?.none)
            ForEach(accounts) { Text($0.name).tag(UUID?.some($0.id)) }
        }
    }

    /// Reads each PDF's text and saves the stubs that add up.
    private static func importStubs(_ urls: [URL], into store: CompassStore) -> ([Paystub], String, Bool) {
        var read: [Paystub] = [], failed: [String] = []
        for url in urls {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let text =
                PDFDocument(url: url).map { document in
                    (0..<document.pageCount).compactMap { document.page(at: $0)?.string }.joined(separator: "\n")
                } ?? ""
            do {
                let stub = try Paystub.parse(text)
                try store.save(stub)
                read.append(stub)
            } catch PaystubProblem.doesntAddUp {
                failed.append("\(url.lastPathComponent) doesn't add up (earnings less taxes and deductions isn't its net pay)")
            } catch {
                failed.append("\(url.lastPathComponent) doesn't read as a paystub")
            }
        }
        let done = read.isEmpty ? "" : "Filled in from the stub deposited \(read.map { long($0.depositDate) }.max() ?? ""). "
        return (read, done + failed.joined(separator: "; ") + (failed.isEmpty ? "" : "."), !failed.isEmpty)
    }

    static func long(_ day: Day) -> String { day.startDate(in: .current).formatted(date: .abbreviated, time: .omitted) }
}

/// A bonus or vest: what, when (if known) and how much before tax.
private struct ExpectedPayRow: View {
    @Binding var item: ExpectedPay
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                Picker("Kind", selection: $item.kind) {
                    Text("Bonus").tag(ExpectedPay.Kind.bonus)
                    Text("Vest").tag(ExpectedPay.Kind.vest)
                }
                .labelsHidden().fixedSize()
                TextField("What", text: $item.title)
                TextField("Gross", value: $item.gross, format: .currency(code: "USD"))
                    .multilineTextAlignment(.trailing).frame(width: 110)
                Button("Remove", action: remove).linkButton()
            }
            HStack {
                // A month Claude set becomes the first of it once the day is known.
                Toggle(
                    "Date known",
                    isOn: Binding(
                        get: { item.day != nil },
                        set: {
                            item.day = $0 ? item.month?.firstDay ?? Day(.now, in: .current) : nil
                            if $0 { item.month = nil }
                        }))
                if let day = item.day {
                    DatePicker(
                        "On",
                        selection: Binding(
                            get: { day.startDate(in: .current) },
                            set: { item.day = Day($0, in: .current) }),
                        displayedComponents: .date
                    )
                    .labelsHidden()
                } else if let month = item.month {
                    Text("In \(month.firstDay.startDate(in: .current).formatted(.dateTime.month(.wide).year()))")
                        .foregroundStyle(Palette.inkSecondary)
                }
                Spacer()
                Toggle("Estimate", isOn: $item.estimate).toggleStyle(.checkbox)
            }
        }
        .padding(.vertical, 2)
    }
}
