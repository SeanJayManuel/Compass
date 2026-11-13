import Core
import Foundation
import Testing

@Suite struct ReminderAgendaTests {
    // Monday Oct 19, 2026 starts the week; today is Friday Oct 23.
    let today = Day(year: 2026, month: 10, day: 23)
    func day(_ month: Int, _ day: Int) -> Day { Day(year: 2026, month: month, day: day) }

    @Test func aDateOnlyDueIsThatDayAndATimedOneIsTheLocalDayAndMinute() {
        let dateOnly = DateComponents(year: 2026, month: 10, day: 25)
        #expect(ReminderDue(dateOnly, in: TimeZone(identifier: "Europe/London")!) == ReminderDue(day: day(10, 25)))

        // 11:30 pm Sunday in New York (EDT) is 8:30 pm in Los Angeles but 3:30 am Monday in London (GMT from Oct 25).
        var timed = DateComponents(year: 2026, month: 10, day: 25, hour: 23, minute: 30)
        timed.timeZone = TimeZone(identifier: "America/New_York")
        #expect(
            ReminderDue(timed, in: TimeZone(identifier: "America/Los_Angeles")!)
                == ReminderDue(day: day(10, 25), minute: 20 * 60 + 30))
        #expect(
            ReminderDue(timed, in: TimeZone(identifier: "Europe/London")!)
                == ReminderDue(day: day(10, 26), minute: 3 * 60 + 30))

        // With no zone of its own, a timed reminder floats: the same clock time wherever they are.
        let floating = DateComponents(year: 2026, month: 10, day: 25, hour: 9, minute: 0)
        #expect(ReminderDue(floating, in: TimeZone(identifier: "Asia/Tokyo")!) == ReminderDue(day: day(10, 25), minute: 9 * 60))
        #expect(ReminderDue(DateComponents(hour: 9), in: .current) == nil)

        // Midnight means a day was meant, not a time.
        var midnight = DateComponents(year: 2026, month: 10, day: 31, hour: 0, minute: 0)
        #expect(ReminderDue(midnight, in: TimeZone(identifier: "America/Los_Angeles")!) == ReminderDue(day: day(10, 31)))
        midnight.timeZone = TimeZone(identifier: "America/New_York")
        #expect(ReminderDue(midnight, in: TimeZone(identifier: "America/Los_Angeles")!) == ReminderDue(day: day(10, 31)))
    }

    let lists = [
        ReminderList(id: "admin", title: "Admin"), ReminderList(id: "week", title: "This Week"),
        ReminderList(id: "inbox", title: "Inbox"), ReminderList(id: "long", title: "Long Term"),
        ReminderList(id: "quarter", title: "This Quarter"), ReminderList(id: "living", title: "Living List"),
        ReminderList(id: "daily", title: "Repetitive Tasks"), ReminderList(id: "food", title: "Grocery")
    ]

    func reminder(
        _ title: String, _ list: String = "daily", due: Day? = nil, at minute: Int? = nil,
        daily: Bool = false
    ) -> Reminder {
        Reminder(
            id: title, title: title, listID: list, due: due.map { ReminderDue(day: $0, minute: minute) },
            repeatsDaily: daily)
    }

    @Test func theStandardListNamesSortRemindersAsBefore() {
        let agenda = ReminderAgenda(
            reminders: [reminder("Plan the hike", "week"), reminder("Renew the car", "admin"), reminder("Run a 10K", "quarter")],
            lists: lists, names: .standard, today: today)
        #expect(agenda.thisWeek.map(\.title) == ["Plan the hike"])
        #expect(agenda.admin.map(\.title) == ["Renew the car"])
        #expect(agenda.quarter.map(\.title) == ["Run a 10K"])
    }

    @Test func aRenamedListIsFoundByItsNewNameIgnoringCase() {
        var names = ReminderListNames.standard
        names.week = ["Now"]
        names.quarter = ["Next 90 days", "Q goals"]
        let mine = [
            ReminderList(id: "now", title: "NOW"), ReminderList(id: "q", title: "q goals"), ReminderList(id: "week", title: "This Week")
        ]
        let agenda = ReminderAgenda(
            reminders: [reminder("Plan the hike", "now"), reminder("Run a 10K", "q"), reminder("Old list item", "week")],
            lists: mine, names: names, today: today)
        #expect(agenda.thisWeek.map(\.title) == ["Plan the hike"])
        #expect(agenda.quarter.map(\.title) == ["Run a 10K"])
    }

    @Test func listNamesReadFromTextFallBackToTheStandardOnes() {
        #expect(ReminderListNames.parse("Now,  Soon ,", standard: ["This Week"]) == ["Now", "Soon"])
        #expect(ReminderListNames.parse("  ", standard: ["This Week"]) == ["This Week"])
        #expect(ReminderListNames.parse(nil, standard: ["Admin", "Errands"]) == ["Admin", "Errands"])
        #expect(ReminderListNames.standard.matches(.repeats, "repetitive tasks "))
        #expect(!ReminderListNames.standard.matches(.week, "Someday"))
    }

    @Test func thisWeekHoldsWhatsDueByTheEndOfTheWeekOverdueFirstAndNothingLater() {
        let agenda = ReminderAgenda(
            reminders: [
                reminder("Call grandparents", due: day(11, 1)),
                reminder("Pay card", due: day(10, 24)),
                reminder("Call dentist", due: day(10, 23), at: 15 * 60),
                reminder("Renew passport", due: day(10, 21)),
                reminder("Check in on a cousin", due: day(10, 25)),
                reminder("Water plants", due: day(10, 23)),
                reminder("Undated chore")
            ], lists: lists, today: today)
        #expect(agenda.thisWeek.map(\.title) == ["Renew passport", "Water plants", "Call dentist", "Pay card"])
        // A list with no place of its own shows only what's due this week.
        #expect(agenda.everyDay.isEmpty && agenda.admin.isEmpty && agenda.quarter.isEmpty)
    }

    @Test func dailyRepeatsStillToDoTodaySitApartAndOnesAlreadyDoneForTodayAreLeftOut() {
        let agenda = ReminderAgenda(
            reminders: [
                reminder("Take supplements", due: day(10, 22), daily: true),
                reminder("Practice French", due: day(10, 23), at: 8 * 60, daily: true),
                reminder("Stretch", due: day(10, 24), daily: true),
                reminder("Meal prep", due: day(10, 23))
            ], lists: lists, today: today)
        #expect(agenda.everyDay.map(\.title) == ["Take supplements", "Practice French"])
        #expect(agenda.thisWeek.map(\.title) == ["Meal prep"])
    }

    @Test func eachHorizonListHasItsOwnSection() {
        let agenda = ReminderAgenda(
            reminders: [
                reminder("Cancel subscription", "week"),
                reminder("Fix bike", "week", due: day(10, 24)),
                reminder("Plan next month", "week", due: day(11, 20)),
                reminder("Net worth goal", "quarter", due: day(12, 31)),
                reminder("Book trial class", "quarter", due: day(10, 20)),
                reminder("Write blogs", "quarter"),
                reminder("Shop around for a gift", "long"),
                reminder("Schedule an exam", "long", due: day(10, 24)),
                reminder("Card bonus", "long", due: day(12, 1)),
                reminder("Go scuba diving", "living"),
                reminder("Dance with a stranger", "living", due: day(10, 22)),
                reminder("Pay parking ticket", "admin"),
                reminder("Pick up dry cleaning", "admin", due: day(10, 21)),
                reminder("Renew licence", "admin", due: day(12, 1)),
                reminder("Something I jotted", "inbox"),
                reminder("Cut toenails", "inbox", due: day(10, 21))
            ], lists: lists, today: today)
        // This Week's own reminders are this week's whatever their date, after the dated ones due by Sunday.
        #expect(
            agenda.thisWeek.map(\.title) == [
                "Cut toenails", "Dance with a stranger", "Fix bike", "Schedule an exam",
                "Plan next month", "Cancel subscription"
            ])
        // The quarter's goals stay together, even in their deadline week.
        #expect(agenda.quarter.map(\.title) == ["Book trial class", "Net worth goal", "Write blogs"])
        #expect(agenda.comingUp.map(\.title) == ["Card bonus", "Shop around for a gift"])
        #expect(agenda.livingList.map(\.title) == ["Go scuba diving"])
        // Admin is all of a list named Admin, whatever their date.
        #expect(agenda.admin.map(\.title) == ["Pick up dry cleaning", "Renew licence", "Pay parking ticket"])
        #expect(agenda.inbox == 1)
    }

    @Test func aListCalledErrandsIsAdminToo() {
        let errands = [ReminderList(id: "e", title: " errands ")]
        let agenda = ReminderAgenda(reminders: [reminder("Return books", "e")], lists: errands, today: today)
        #expect(agenda.admin.map(\.title) == ["Return books"])
    }

    @Test func aRepeatJoinsThisWeekTheDayBeforeItsDue() {
        func repeating(_ title: String, _ list: String, due: Day) -> Reminder {
            Reminder(id: title, title: title, listID: list, due: ReminderDue(day: due), repeats: true)
        }
        // Today is Friday: Saturday's repeat shows, Sunday's waits, and an overdue one stays.
        let agenda = ReminderAgenda(
            reminders: [
                repeating("Water the plants", "daily", due: day(10, 24)),
                repeating("Pay credit card bills", "daily", due: day(10, 25)),
                repeating("Call grandparents", "week", due: day(10, 25)),
                repeating("Book a haircut", "daily", due: day(10, 20)),
                repeating("Renew the parking pass", "long", due: day(11, 20)),
                reminder("Schedule an exam", "long", due: day(10, 24))
            ], lists: lists, today: today)
        #expect(agenda.thisWeek.map(\.title) == ["Book a haircut", "Schedule an exam", "Water the plants"])
        // One in a list of its own keeps its place there.
        #expect(agenda.comingUp.map(\.title) == ["Renew the parking pass"])
    }

    @Test func aListCalledComingUpIsComingUpToo() {
        let lists = [ReminderList(id: "c", title: "Coming Up")]
        let agenda = ReminderAgenda(
            reminders: [reminder("Gift card before the credit expires", "c", due: day(12, 15))],
            lists: lists, today: today)
        #expect(agenda.comingUp.map(\.title) == ["Gift card before the credit expires"])
    }

    @Test func aTitleThatRepeatsItsListNameDropsIt() {
        #expect(ReminderAgenda.shortTitle("Living List: Learn French", list: "Living List") == "Learn French")
        #expect(ReminderAgenda.shortTitle("living list - Read a poetry book", list: "Living List") == "Read a poetry book")
        #expect(ReminderAgenda.shortTitle("Go scuba diving", list: "Living List") == "Go scuba diving")
        #expect(ReminderAgenda.shortTitle("Living List:", list: "Living List") == "Living List:")
        // Only the whole name, followed by a break, is the list's.
        #expect(ReminderAgenda.shortTitle("Long Termite treatment", list: "Long Term") == "Long Termite treatment")
        #expect(ReminderAgenda.shortTitle("- call mum", list: "") == "- call mum")
    }

    @Test func groceryListsAreHiddenUntilHeChoosesOtherwise() {
        let shopping = lists + [ReminderList(id: "shop", title: " groceries "), ReminderList(id: "shop2", title: "Shopping")]
        #expect(ReminderAgenda.hiddenByDefault(shopping) == ["food", "shop", "shop2"])

        let reminders = [
            reminder("Milk", "food", due: day(10, 23)), reminder("Renew passport", "admin"),
            reminder("Paint the shed", "long"), reminder("Read Dune", "long")
        ]
        let hidingGroceries = ReminderAgenda(reminders: reminders, lists: lists, hidden: ["food"], today: today)
        #expect(hidingGroceries.thisWeek.isEmpty)
        #expect(hidingGroceries.admin.map(\.title) == ["Renew passport"])
        #expect(hidingGroceries.comingUp.map(\.title) == ["Paint the shed", "Read Dune"])
        let hidingAdmin = ReminderAgenda(reminders: reminders, lists: lists, hidden: ["admin"], today: today)
        #expect(hidingAdmin.thisWeek.map(\.title) == ["Milk"])
        #expect(hidingAdmin.admin.isEmpty)
    }

    @Test func aMoneyLinkFindsItsReminderByIdentifierElseByTitle() {
        let goal = Reminder(id: "r1", title: "$50k net worth by year-end", listID: "quarter")
        let link = ReminderMeasure(reminderID: "r1", title: "$50k net worth by year-end", measure: .netWorth, target: 50_000)
        #expect(ReminderMeasure.link(for: goal, in: [link]) == link)
        // Reminders can hand back a new identifier after a sync: the title still finds it.
        let synced = Reminder(id: "r2", title: "$50k net worth by year-end", listID: "quarter")
        #expect(ReminderMeasure.link(for: synced, in: [link]) == link)
        #expect(ReminderMeasure.link(for: Reminder(id: "r3", title: "Write 4 blogs", listID: "quarter"), in: [link]) == nil)
    }

    /// Claude names a link even after its reminder is ticked off: by its
    /// reminder's identifier, else a title only one link has.
    @Test func aMoneyLinkIsNamedByIdentifierOrAnUnsharedTitle() {
        let link = ReminderMeasure(reminderID: "r1", title: "$50k net worth by year-end", measure: .netWorth, target: 50_000)
        let other = ReminderMeasure(reminderID: "r2", title: "$50K Net Worth by Year-End", measure: .netWorth, target: 85_000)
        #expect(ReminderMeasure.link(named: "r1", in: [link]) == link)
        #expect(ReminderMeasure.link(named: "$50K NET WORTH BY YEAR-END", in: [link]) == link)
        #expect(ReminderMeasure.link(named: "$50k net worth by year-end", in: [link, other]) == nil)
        #expect(ReminderMeasure.link(named: "r2", in: [link, other]) == other)
        #expect(ReminderMeasure.link(named: "Write 4 blogs", in: [link]) == nil)
    }

    @Test func aMoneyLinkReadsProgressAgainstItsTarget() {
        let link = ReminderMeasure(reminderID: "r1", title: "Net worth", measure: .netWorth, target: 50_000)
        #expect(link.fraction(values: [.netWorth: 37_500]) == Decimal(string: "0.75"))
        #expect(link.fraction(values: [.netWorth: 95_000]) == 1)
        #expect(link.fraction(values: [.netWorth: -5_000]) == 0)
        // Before the number is known there's no bar, not an empty one.
        #expect(link.fraction(values: [:]) == nil)
    }

    @Test func aTargetIsSuggestedFromTheAmountInTheTitle() {
        #expect(ReminderMeasure.suggestedTarget(in: "$50k net worth by year-end") == 50_000)
        #expect(ReminderMeasure.suggestedTarget(in: "Save $4,000 for the trip") == 4_000)
        #expect(ReminderMeasure.suggestedTarget(in: "Hit $1.2M invested") == 1_200_000)
        #expect(ReminderMeasure.suggestedTarget(in: "Emergency fund 15K") == nil)
        #expect(ReminderMeasure.suggestedTarget(in: "Gym 4x/week") == nil)
    }

    @Test func todayHoldsWhatsOverdueOrDueTodayFromEverySectionByWhenAndTheRestOfTheWeekIsCounted() {
        let agenda = ReminderAgenda(
            reminders: [
                reminder("Call the bank", "week", due: day(10, 23), at: 14 * 60),
                reminder("Renew passport", "admin", due: day(10, 20)),
                reminder("Book flights", "quarter", due: day(10, 23)),
                reminder("Take supplements", due: day(10, 23), daily: true),
                reminder("Water plants", "week", due: day(10, 24)),
                reminder("Clean the garage", "week"),
                reminder("Pay parking ticket", "admin"),
                reminder("Mail the forms", "admin", due: day(10, 24)),
                reminder("Plan the trip", "long", due: day(12, 1))
            ], lists: lists, today: today)

        #expect(agenda.today(today).map(\.title) == ["Renew passport", "Book flights", "Take supplements", "Call the bank"])
        // Later this week, dated or on This Week; not Admin's undated ones or what's due after Saturday.
        #expect(agenda.laterThisWeek(today) == 3)
    }
}
