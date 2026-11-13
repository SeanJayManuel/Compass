import Core
import Foundation
import Testing

/// Seam 31 (full write coverage, Oct 31, 2026): the rest of what Claude may
/// keep up through chat, what's refused, and how undo restores.
@Suite struct ClaudeUpkeepTests {
    // Saturday Oct 31, 2026.
    let today = Day(year: 2026, month: 10, day: 31)
    func day(_ month: Int, _ day: Int) -> Day { Day(year: 2026, month: month, day: day) }

    func refusal(_ body: () throws -> Void) -> String? {
        do { try body(); return nil } catch let refusal as ClaudeRefusal { return refusal.message } catch { return "\(error)" }
    }

    // MARK: Events

    let event = ClaudeEvent(id: "e1", externalID: nil, title: "Dentist", start: .distantPast, end: .distantFuture, isAllDay: false, notes: nil)

    @Test func anEventsTitleAndNotesChangeButNotToNothing() throws {
        let renamed = try ClaudeRules.editEvent(event, title: "Dentist, Dr. Lee", notes: nil)
        #expect(renamed.title == "Dentist, Dr. Lee" && renamed.notes == nil && renamed.start == event.start)
        #expect(try ClaudeRules.editEvent(event, title: nil, notes: "Bring the form").notes == "Bring the form")
        // Empty notes clear them.
        let noted = ClaudeEvent(id: "e1", externalID: nil, title: "Dentist", start: .distantPast, end: .distantFuture, isAllDay: false, notes: "x")
        #expect(try ClaudeRules.editEvent(noted, title: nil, notes: "").notes == nil)
        #expect(refusal { _ = try ClaudeRules.editEvent(event, title: " ", notes: nil) } != nil)
        #expect(refusal { _ = try ClaudeRules.editEvent(event, title: "Dentist", notes: nil) }?.contains("nothing") == true)
    }

    // MARK: The Playbook

    @Test func aDeletedEntryComesBackUnlessItsTitleIsTakenInItsArea() {
        let tee = PlaybookEntry(area: "Clothes", kind: .pick, title: "Plain tee")
        #expect(ClaudeRules.canRestoreDeleted(tee, among: []))
        #expect(ClaudeRules.canRestoreDeleted(tee, among: [PlaybookEntry(area: "Gym", kind: .pick, title: "Plain tee")]))
        #expect(!ClaudeRules.canRestoreDeleted(tee, among: [PlaybookEntry(area: "clothes", kind: .note, title: "plain tee")]))
        #expect(!ClaudeRules.canRestoreDeleted(tee, among: [tee]))
    }

    @Test func aSizeIsRemovedByItsLabel() throws {
        let sizes = PlaybookSizes(rows: [PlaybookSize(label: "Suit", value: "38S"), PlaybookSize(label: "Jeans", value: "31 × 32")])
        #expect(try ClaudeRules.removeSize(sizes, label: "suit").rows.map(\.label) == ["Jeans"])
        #expect(refusal { _ = try ClaudeRules.removeSize(sizes, label: "Shoes") }?.contains("Suit, Jeans") == true)
    }

    // MARK: Habits

    let gym = Habit(title: "Gym", perWeek: 3, startedOn: Day(year: 2026, month: 9, day: 7), checkIns: [Day(year: 2026, month: 10, day: 26)])
    let linked = Habit(
        title: "French", perWeek: 7, startedOn: Day(year: 2026, month: 9, day: 7),
        reminder: HabitReminder(id: "r1", title: "French", listID: "l1", settled: []))

    @Test func editingAHabitChecksItLikeTheEditor() throws {
        let edited = try ClaudeRules.editHabit(gym, title: "Lift", perWeek: 4, among: [gym])
        #expect(edited.title == "Lift" && edited.perWeek == 4 && edited.checkIns == gym.checkIns)
        #expect(refusal { _ = try ClaudeRules.editHabit(gym, title: nil, perWeek: 8, among: [gym]) } != nil)
        #expect(
            refusal { _ = try ClaudeRules.editHabit(gym, title: "Read", perWeek: nil, among: [gym, Habit(title: "read", perWeek: 2, startedOn: today)]) } != nil
        )
        #expect(refusal { _ = try ClaudeRules.editHabit(gym, title: "Gym", perWeek: 3, among: [gym]) }?.contains("nothing") == true)
        // A linked habit takes its reminder's title.
        #expect(refusal { _ = try ClaudeRules.editHabit(linked, title: "Spanish", perWeek: nil, among: [linked]) }?.contains("edit_reminder") == true)
        #expect(try ClaudeRules.editHabit(linked, title: nil, perWeek: 5, among: [linked]).perWeek == 5)
    }

    @Test func archivingStopsAHabitAndUnarchivingNeedsItsTitleFree() throws {
        #expect(try ClaudeRules.archiveHabit(gym, archived: true, among: [gym]).archived)
        #expect(refusal { _ = try ClaudeRules.archiveHabit(gym, archived: false, among: [gym]) }?.contains("nothing") == true)
        var old = gym
        old.archived = true
        #expect(try !ClaudeRules.archiveHabit(old, archived: false, among: [old]).archived)
        #expect(refusal { _ = try ClaudeRules.archiveHabit(old, archived: false, among: [old, Habit(title: "Gym", perWeek: 2, startedOn: today)]) } != nil)
        // An archived habit is unarchived before it's edited.
        #expect(refusal { _ = try ClaudeRules.editHabit(old, title: nil, perWeek: 2, among: [old]) }?.contains("archived") == true)
    }

    @Test func undoingAHabitEditKeepsCheckInsSince() {
        let after = try! ClaudeRules.editHabit(gym, title: "Lift", perWeek: 4, among: [gym])
        var current = after
        current.checkIns.append(day(10, 28))
        let restored = ClaudeRules.undoHabitEdit(current: current, before: gym, after: after)
        #expect(restored?.title == "Gym" && restored?.perWeek == 3 && restored?.checkIns.count == 2)
        current.perWeek = 5
        #expect(ClaudeRules.undoHabitEdit(current: current, before: gym, after: after) == nil)
    }

    @Test func aLinkedHabitIsArchivedNotDeleted() throws {
        try ClaudeRules.checkDelete(gym)
        #expect(refusal { try ClaudeRules.checkDelete(linked) }?.contains("archive") == true)
        // Back whole, unless its id or an active habit of its title is there by then.
        #expect(ClaudeRules.canRestoreDeleted(gym, among: []))
        #expect(!ClaudeRules.canRestoreDeleted(gym, among: [Habit(title: "gym", perWeek: 1, startedOn: today)]))
        var archived = Habit(title: "gym", perWeek: 1, startedOn: today)
        archived.archived = true
        #expect(ClaudeRules.canRestoreDeleted(gym, among: [archived]))
    }

    @Test func aCheckInIsRemovedOnlyWhenThere() throws {
        let removed = try ClaudeRules.removeCheckIn(gym, on: day(10, 26), today: today)
        #expect(removed?.checkIns.isEmpty == true)
        #expect(try ClaudeRules.removeCheckIn(gym, on: day(10, 27), today: today) == nil)
        // A linked habit's day stays settled as unticked.
        var ticked = linked
        ticked.checkIns = [day(10, 30)]
        let unticked = try ClaudeRules.removeCheckIn(ticked, on: day(10, 30), today: today)
        #expect(unticked?.checkIns.isEmpty == true && unticked?.reminder?.settled.contains(day(10, 30)) == true)
    }

    // MARK: Goals

    @Test func onlyAnActiveGoalIsRetired() throws {
        let goal = Goal(name: "Boat", kind: .netWorth, target: 50_000)
        #expect(try ClaudeRules.retireGoal(goal, reason: " Changed my mind ").status == .retired(reason: "Changed my mind"))
        #expect(refusal { _ = try ClaudeRules.retireGoal(goal, reason: "") } != nil)
        var reached = goal
        reached.status = .achieved(on: day(10, 1), value: 51_000)
        #expect(refusal { _ = try ClaudeRules.retireGoal(reached, reason: "Done") }?.contains("reached") == true)
        // Undo brings it back active while it's still retired as Claude left it.
        let retired = try ClaudeRules.retireGoal(goal, reason: "No")
        #expect(ClaudeRules.undoRetire(current: retired, before: goal, after: retired)?.status == .active)
        #expect(ClaudeRules.undoRetire(current: reached, before: goal, after: retired) == nil)
    }

    @Test func aRewardIsClaimedOnlyOnceTheGoalIsReached() throws {
        let invested = Goal(name: "$100K Invested", kind: .netWorth, target: 100_000)
        let planned = try ClaudeRules.setReward(invested, name: "Tudor BB54", cost: 4_300, claimedOn: nil, today: today)
        #expect(planned.reward == Reward(name: "Tudor BB54", cost: 4_300))
        #expect(refusal { _ = try ClaudeRules.setReward(invested, name: nil, cost: nil, claimedOn: day(10, 30), today: today) }?.contains("reached") == true)
        var reached = planned
        reached.status = .achieved(on: day(10, 2), value: 100_400)
        // The name and cost stay when only the claim is given.
        #expect(
            try ClaudeRules.setReward(reached, name: nil, cost: nil, claimedOn: day(10, 30), today: today).reward
                == Reward(name: "Tudor BB54", cost: 4_300, claimedOn: day(10, 30)))
        #expect(refusal { _ = try ClaudeRules.setReward(reached, name: nil, cost: nil, claimedOn: day(11, 2), today: today) } != nil)
        #expect(refusal { _ = try ClaudeRules.setReward(reached, name: nil, cost: nil, claimedOn: day(9, 30), today: today) }?.contains("before") == true)
        #expect(refusal { _ = try ClaudeRules.setReward(invested, name: nil, cost: 10, claimedOn: nil, today: today) }?.contains("name") == true)
        #expect(refusal { _ = try ClaudeRules.setReward(planned, name: "Tudor BB54", cost: 4_300, claimedOn: nil, today: today) }?.contains("nothing") == true)
        var retired = invested
        retired.status = .retired(reason: "x")
        #expect(refusal { _ = try ClaudeRules.setReward(retired, name: "Watch", cost: nil, claimedOn: nil, today: today) } != nil)
    }

    /// Nov 1, 2026: a This Quarter reminder with a target takes a reward the
    /// way a money goal does, claimed once its progress reaches 1.
    @Test func aQuarterGoalsRewardIsClaimedOnlyOnceItsProgressReachesOne() throws {
        let link = ReminderMeasure(reminderID: "r1", title: "$50k net worth", measure: .netWorth, target: 50_000)
        let planned = try ClaudeRules.setReward(link, name: "Weekend in Big Sur", cost: 900, claimedOn: nil, progress: 0.9, today: today)
        #expect(planned.reward == Reward(name: "Weekend in Big Sur", cost: 900))
        #expect(planned.target == 50_000 && planned.measure == .netWorth)
        #expect(
            refusal { _ = try ClaudeRules.setReward(planned, name: nil, cost: nil, claimedOn: day(10, 30), progress: 0.9, today: today) }?
                .contains("90%") == true)
        // A live fraction, full of digits, still reads as a whole percent.
        let live = Decimal(string: "148512.37")! / 150_000
        #expect(
            refusal { _ = try ClaudeRules.setReward(planned, name: nil, cost: nil, claimedOn: day(10, 30), progress: live, today: today) }?
                .contains("99%") == true)
        // Not known (no net worth yet) isn't reached either.
        #expect(refusal { _ = try ClaudeRules.setReward(planned, name: nil, cost: nil, claimedOn: day(10, 30), progress: nil, today: today) } != nil)
        // The name and cost stay when only the claim is given.
        #expect(
            try ClaudeRules.setReward(planned, name: nil, cost: nil, claimedOn: day(10, 30), progress: 1, today: today).reward
                == Reward(name: "Weekend in Big Sur", cost: 900, claimedOn: day(10, 30)))
        #expect(refusal { _ = try ClaudeRules.setReward(planned, name: nil, cost: nil, claimedOn: day(11, 2), progress: 1, today: today) } != nil)
        #expect(refusal { _ = try ClaudeRules.setReward(link, name: nil, cost: 10, claimedOn: nil, progress: 0.5, today: today) }?.contains("name") == true)
        #expect(refusal { _ = try ClaudeRules.setReward(link, name: "Watch", cost: -1, claimedOn: nil, progress: 0.5, today: today) } != nil)
        #expect(
            refusal { _ = try ClaudeRules.setReward(planned, name: "Weekend in Big Sur", cost: nil, claimedOn: nil, progress: 1, today: today) }?
                .contains("nothing") == true)
    }

    // MARK: Reminders

    @Test func aReminderMovesToAnotherList() throws {
        let week = ReminderList(id: "w", title: "This Week"), quarter = ReminderList(id: "q", title: "This Quarter")
        let reminder = Reminder(id: "r", title: "Passport", listID: "w")
        try ClaudeRules.checkMove(reminder, to: quarter)
        #expect(refusal { try ClaudeRules.checkMove(reminder, to: week) }?.contains("already") == true)
    }

    @Test func aRepeatIsDeletedInRemindersNotHere() throws {
        try ClaudeRules.checkDelete(Reminder(id: "r", title: "Passport", listID: "w"))
        #expect(refusal { try ClaudeRules.checkDelete(Reminder(id: "r", title: "Pay card", listID: "w", repeats: true)) } != nil)
    }

    @Test func undoingARepeatsTickFindsItsDoneCopy() {
        let done = [
            CompletedReminder(id: "c1", title: "Pay card", listID: "a", day: day(10, 30)),
            CompletedReminder(id: "c2", title: "Pay card", listID: "a", day: today),
            CompletedReminder(id: "c3", title: "Pay card", listID: "b", day: today)
        ]
        #expect(ClaudeRules.doneCopy(title: "pay card", listID: "a", on: today, among: done) == "c2")
        #expect(ClaudeRules.doneCopy(title: "Pay card", listID: "a", on: day(10, 29), among: done) == nil)
    }

    @Test func undoingAReminderEditLeavesNotesItDidntTouch() {
        let due = ReminderDue(day: day(11, 2))
        // An edit that changed only the title (notes nil: untouched).
        let before = ReminderEdit(title: "Passport", due: due), after = ReminderEdit(title: "Renew passport", due: due)
        let current = ReminderEdit(title: "Renew passport", due: due, notes: "Photo booth")
        #expect(ClaudeRules.undoReminderEdit(current: current, before: before, after: after) == ReminderEdit(title: "Passport", due: due))
        // One that changed the notes puts them back, and is refused once they changed again.
        let noted = ReminderEdit(title: "Passport", due: due, notes: "Bring photos")
        let wasBlank = ReminderEdit(title: "Passport", due: due, notes: "")
        #expect(ClaudeRules.undoReminderEdit(current: noted, before: wasBlank, after: noted) == wasBlank)
        #expect(ClaudeRules.undoReminderEdit(current: ReminderEdit(title: "Passport", due: due, notes: "x"), before: wasBlank, after: noted) == nil)
    }

    // MARK: Pay

    var profile: PayProfile {
        var profile = PayProfile()
        profile.annualSalary = 80_000
        profile.knownPayday = day(10, 9)
        return profile
    }

    @Test func paySettingsAreCheckedLikeSettings() throws {
        var edit = PayEdit()
        edit.annualSalary = 86_000
        edit.retirementPercent = 8
        let raised = try ClaudeRules.editPay(profile, edit)
        #expect(raised.annualSalary == 86_000 && raised.retirementPercent == 8 && raised.knownPayday == day(10, 9))
        for bad in [
            PayEdit(retirementPercent: 101), PayEdit(matchUpToPercent: -1), PayEdit(stockPerCheck: -5), PayEdit(everyDays: 10), PayEdit(annualSalary: 0)
        ] {
            #expect(refusal { _ = try ClaudeRules.editPay(profile, bad) } != nil)
        }
        #expect(refusal { _ = try ClaudeRules.editPay(profile, PayEdit(annualSalary: 80_000)) }?.contains("nothing") == true)
    }

    @Test func expectedPayTakesADayOrAMonth() throws {
        let bonus = try ClaudeRules.expectedPay(kind: .bonus, title: nil, gross: 9_000, on: .month(Month(year: 2027, month: 3)), estimate: true, note: "")
        #expect(bonus.title == "Bonus" && bonus.day == nil && bonus.month == Month(year: 2027, month: 3) && bonus.estimate)
        let vest = try ClaudeRules.expectedPay(kind: .vest, title: "RSU vest", gross: 2_000, on: .day(day(12, 15)), estimate: false, note: "")
        #expect(vest.day == day(12, 15) && vest.month == nil)
        #expect(refusal { _ = try ClaudeRules.expectedPay(kind: .bonus, title: nil, gross: 0, on: nil, estimate: false, note: "") } != nil)
        // Upcoming: from this month on, or not dated yet, soonest first.
        var pay = profile
        let past = ExpectedPay(kind: .bonus, title: "Old", month: Month(year: 2026, month: 9), gross: 1)
        let thisMonth = ExpectedPay(kind: .bonus, title: "Now", month: Month(year: 2026, month: 10), gross: 1)
        pay.expected = [bonus, vest, past, thisMonth]
        #expect(Pay.upcoming(pay, today: today).map(\.title) == ["Now", "RSU vest", "Bonus"])
    }

    @Test func expectedPaySavedBeforeMonthsReadsBack() throws {
        let old = #"{"id":"5A1F4E1C-6D5B-4C47-9E61-1B2D2B0C0A11","kind":"bonus","title":"Bonus","gross":5000,"note":""}"#
        let read = try JSONDecoder().decode(ExpectedPay.self, from: Data(old.utf8))
        #expect(read.month == nil && read.day == nil && !read.estimate)
    }

    @Test func undoingAPayChangeKeepsWhatChangedSince() throws {
        let bonus = ExpectedPay(kind: .bonus, title: "Bonus", month: Month(year: 2027, month: 3), gross: 9_000)
        // Claude raised the salary; the owner then added a bonus in Settings.
        let before = profile
        let after = try ClaudeRules.editPay(before, PayEdit(annualSalary: 86_000))
        var current = after
        current.expected = [bonus]
        let restored = ClaudeRules.undoPay(current: current, before: before, after: after)
        #expect(restored?.annualSalary == 80_000 && restored?.expected == [bonus])
        // Refused once the salary changed again.
        current.annualSalary = 90_000
        #expect(ClaudeRules.undoPay(current: current, before: before, after: after) == nil)
        // Claude added the bonus: undo takes it out while it's as Claude made it.
        var added = profile
        added.expected = [bonus]
        #expect(ClaudeRules.undoPay(current: added, before: profile, after: added)?.expected == [])
        var edited = added
        edited.expected[0].gross = 10_000
        #expect(ClaudeRules.undoPay(current: edited, before: profile, after: added) == nil)
        // Claude removed it: it comes back.
        #expect(ClaudeRules.undoPay(current: profile, before: added, after: profile)?.expected == [bonus])
    }

    // MARK: Accounts

    let car = Account(name: "Car", accountClass: .otherAssets, source: .manual)
    let chase = Account(name: "Chase Checking", accountClass: .cash, source: .simplefin)

    @Test func anAccountIsRenamedWithoutItsNumber() throws {
        #expect(try ClaudeRules.renameAccount(car, to: " 2019 Civic ", among: [car, chase]).name == "2019 Civic")
        #expect(refusal { _ = try ClaudeRules.renameAccount(chase, to: "Chase 4821", among: [car, chase]) }?.contains("number") == true)
        #expect(refusal { _ = try ClaudeRules.renameAccount(car, to: "chase checking", among: [car, chase]) } != nil)
        #expect(refusal { _ = try ClaudeRules.renameAccount(car, to: "", among: [car]) } != nil)
        #expect(refusal { _ = try ClaudeRules.renameAccount(car, to: "Car", among: [car]) }?.contains("nothing") == true)
    }

    @Test func archivingAnAccountDatesIt() throws {
        #expect(try ClaudeRules.archiveAccount(car, archived: true, today: today).archivedOn == today)
        #expect(refusal { _ = try ClaudeRules.archiveAccount(car, archived: false, today: today) } != nil)
    }

    @Test func aBalanceIsEnteredOnlyForAManualAccount() throws {
        let snapshot = try ClaudeRules.balance(18_500, for: car, on: today, today: today)
        #expect(snapshot == BalanceSnapshot(accountID: car.id, day: today, source: .manual, balance: 18_500))
        // Stored negative for a debt.
        let loan = Account(name: "Car loan", accountClass: .debt, source: .manual)
        #expect(try ClaudeRules.balance(9_000, for: loan, on: today, today: today).balance == -9_000)
        #expect(refusal { _ = try ClaudeRules.balance(1, for: chase, on: today, today: today) }?.contains("sync") == true)
        #expect(refusal { _ = try ClaudeRules.balance(1, for: car, on: day(11, 1), today: today) } != nil)
        var sold = car
        sold.archivedOn = day(10, 1)
        #expect(refusal { _ = try ClaudeRules.balance(1, for: sold, on: today, today: today) } != nil)
    }

    @Test func aDoneReminderIsFoundByIdOrItsLatestTitle() throws {
        let done = [
            CompletedReminder(id: "a", title: "Passport", listID: "admin", day: day(10, 20)),
            CompletedReminder(id: "b", title: "Passport", listID: "admin", day: day(10, 29)),
            CompletedReminder(id: "c", title: "Call mom", listID: "week", day: day(10, 29)),
            CompletedReminder(id: "d", title: "Call mom", listID: "admin", day: day(10, 29))
        ]
        #expect(try ClaudeRules.doneReminder("a", in: done).id == "a")
        #expect(try ClaudeRules.doneReminder("passport", in: done).id == "b")
        #expect(refusal { _ = try ClaudeRules.doneReminder("Call mom", in: done) }?.contains("id") == true)
        #expect(refusal { _ = try ClaudeRules.doneReminder("Gym", in: done) } != nil)
    }

    // MARK: Merchant rules and categories

    func charge(_ merchant: String, _ amount: Decimal, _ category: String?, on day: Day = Day(year: 2026, month: 10, day: 1)) -> Transaction {
        Transaction(
            accountID: UUID(), day: day, amount: amount, merchant: merchant, statement: merchant, category: category,
            externalID: UUID().uuidString)
    }

    @Test func aRuleIsSetPerMerchantAndDirection() throws {
        let rules = CategoryRules(["starbucks": "Coffee"])
        #expect(try ClaudeRules.ruleKey(merchant: "Blue Bottle", incoming: false, category: "Coffee", rules: rules) == "blue bottle")
        #expect(try ClaudeRules.ruleKey(merchant: "Costco", incoming: true, category: "Paychecks", rules: rules) == "+costco")
        #expect(refusal { _ = try ClaudeRules.ruleKey(merchant: "STARBUCKS", incoming: false, category: "Coffee", rules: rules) }?.contains("already") == true)
        #expect(refusal { _ = try ClaudeRules.ruleKey(merchant: " #1234 ", incoming: false, category: "Coffee", rules: rules) } != nil)
    }

    @Test func refilingPastTransactionsTakesTheMerchantsOnesInItsDirection() {
        let lunch = charge("Costco", -12, "Groceries"), pay = charge("Costco", 900, "Paychecks")
        let moved = charge("Costco", -50, "Transfer"), done = charge("Costco", -8, "Restaurants"), other = charge("Target", -9, "Groceries")
        let open = charge("COSTCO #1234", -3, nil)
        let refiled = ClaudeRules.refile([lunch, pay, moved, done, other, open], key: "costco", to: "Restaurants", transfers: ["Transfer"])
        #expect(Set(refiled.map(\.id)) == [lunch.id, open.id])
        #expect(refiled.first { $0.id == lunch.id }?.before == "Groceries" && refiled.first { $0.id == open.id }?.before == nil)
    }

    @Test func undoingARefilePutsBackOnlyWhatsStillAsMoved() {
        let a = UUID(), b = UUID(), c = UUID()
        let refiled = [Refiled(id: a, before: "Groceries"), Refiled(id: b, before: nil), Refiled(id: c, before: "Groceries")]
        // b was refiled by hand since; c is gone.
        let back = ClaudeRules.putBack(refiled, filedAs: "Restaurants", current: [a: "Restaurants", b: "Coffee"])
        #expect(back == [Refiled(id: a, before: "Groceries")])
    }

    @Test func aNewCategoryHasANameNoOtherHas() throws {
        #expect(try ClaudeRules.newCategory("  Pet   care ", among: ["Groceries"]) == "Pet care")
        #expect(refusal { _ = try ClaudeRules.newCategory("groceries", among: ["Groceries"]) }?.contains("already") == true)
        #expect(refusal { _ = try ClaudeRules.newCategory(" ", among: []) } != nil)
    }

    @Test func aRenameNeedsAFreeNameAndAMergeTwoCategories() throws {
        let names: Set<String> = ["Groceries", "Restaurants", "Coffee"]
        #expect(try ClaudeRules.rename("coffee", to: "Coffee shops", among: names) == ("Coffee", "Coffee shops"))
        // Only the case changing is a rename too.
        #expect(try ClaudeRules.rename("Coffee", to: "coffee", among: names) == ("Coffee", "coffee"))
        #expect(refusal { _ = try ClaudeRules.rename("Coffee", to: "restaurants", among: names) }?.contains("merge_category") == true)
        #expect(refusal { _ = try ClaudeRules.rename("Tea", to: "Drinks", among: names) } != nil)
        #expect(try ClaudeRules.merge("coffee", into: "RESTAURANTS", among: names) == ("Coffee", "Restaurants"))
        #expect(refusal { _ = try ClaudeRules.merge("Coffee", into: "Drinks", among: names) }?.contains("rename_category") == true)
        #expect(refusal { _ = try ClaudeRules.merge("Coffee", into: "coffee", among: names) } != nil)
    }

    // MARK: Adding a transaction

    @Test func aTransactionIsAddedOnlyToAManualAccount() throws {
        let cash = Account(name: "Cash", accountClass: .cash, source: .manual)
        let added = try ClaudeRules.newTransaction(
            account: cash, day: day(10, 30), amount: -14.50, merchant: " Farmers market ",
            category: "Groceries", note: " Eggs ", today: today)
        #expect(added.accountID == cash.id && added.amount == -14.50 && added.merchant == "Farmers market" && added.statement == "Farmers market")
        #expect(added.category == "Groceries" && added.note == "Eggs" && added.externalID.hasPrefix(ClaudeRules.addedPrefix))
        #expect(
            refusal { _ = try ClaudeRules.newTransaction(account: chase, day: today, amount: -5, merchant: "Deli", category: nil, note: "", today: today) }?
                .contains("sync") == true)
        #expect(
            refusal { _ = try ClaudeRules.newTransaction(account: cash, day: day(11, 1), amount: -5, merchant: "Deli", category: nil, note: "", today: today) }
                != nil)
        #expect(
            refusal { _ = try ClaudeRules.newTransaction(account: cash, day: today, amount: 0, merchant: "Deli", category: nil, note: "", today: today) } != nil
        )
        #expect(
            refusal { _ = try ClaudeRules.newTransaction(account: cash, day: today, amount: -5, merchant: " ", category: nil, note: "", today: today) } != nil)
        var closed = cash
        closed.archivedOn = day(10, 1)
        #expect(
            refusal { _ = try ClaudeRules.newTransaction(account: closed, day: today, amount: -5, merchant: "Deli", category: nil, note: "", today: today) }
                != nil)
    }

    @Test func aManualAccountIsCreatedWithItsOpeningBalance() throws {
        let (cash, opening) = try ClaudeRules.newAccount(name: " Cash ", accountClass: .cash, balance: 120, on: today, among: [car])
        #expect(cash.name == "Cash" && cash.source == .manual && cash.accountClass == .cash)
        #expect(opening == BalanceSnapshot(accountID: cash.id, day: today, source: .manual, balance: 120))
        #expect(try ClaudeRules.newAccount(name: "Venmo debt", accountClass: .debt, balance: 50, on: today, among: []).1.balance == -50)
        #expect(refusal { _ = try ClaudeRules.newAccount(name: "car", accountClass: .cash, balance: 0, on: today, among: [car]) } != nil)
        #expect(
            refusal { _ = try ClaudeRules.newAccount(name: "Cash 4821", accountClass: .cash, balance: 0, on: today, among: []) }?.contains("number") == true)
    }
}
