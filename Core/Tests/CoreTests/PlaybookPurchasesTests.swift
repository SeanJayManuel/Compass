import Core
import Foundation
import Testing

/// Seam 37: a pick's purchases at the shop it's from, for restocking.
@Suite struct PlaybookPurchasesTests {
    // Friday Oct 30, 2026.
    let today = Day(year: 2026, month: 10, day: 30)
    let card = UUID()
    func day(_ year: Int, _ month: Int, _ day: Int) -> Day { Day(year: year, month: month, day: day) }

    func pick(from source: String) -> PlaybookEntry {
        PlaybookEntry(area: "Clothes", kind: .pick, title: "Plain tee", source: source, size: "M")
    }

    @Test func theShopIsWhereItsFromWithoutTheWebAddress() {
        #expect(PlaybookPurchases.shop(pick(from: "uniqlo.com")) == "uniqlo")
        #expect(PlaybookPurchases.shop(pick(from: "https://www.bombas.com/products/ankle")) == "bombas")
        #expect(PlaybookPurchases.shop(pick(from: "Uniqlo, SoHo store")) == "Uniqlo")
        #expect(PlaybookPurchases.shop(pick(from: "amazon.co.uk")) == "amazon")
        #expect(PlaybookPurchases.shop(pick(from: "shop.everlane.com")) == "everlane")
        #expect(PlaybookPurchases.shop(pick(from: "Trader Joe's")) == "Trader Joe's")
        #expect(PlaybookPurchases.shop(pick(from: "  ")) == nil)
    }

    @Test func onlyAPickHasAShop() {
        var routine = pick(from: "uniqlo.com")
        routine.kind = .routine
        #expect(PlaybookPurchases.shop(routine) == nil)
    }

    func charge(_ day: Day, _ amount: String, _ merchant: String = "Uniqlo", category: String? = "Clothing") -> Transaction {
        Transaction(
            accountID: card, day: day, amount: Decimal(string: amount)!, merchant: merchant, statement: merchant.uppercased() + " USA 0123",
            category: category, externalID: UUID().uuidString)
    }

    var history: [Transaction] {
        [
            charge(day(2024, 11, 1), "-25"), charge(day(2025, 5, 10), "-30"), charge(day(2025, 11, 20), "-20"),
            // Two charges on one day are one purchase.
            charge(day(2026, 4, 2), "-39.80"), charge(day(2026, 4, 2), "-19.90"),
            // A refund, a payment to the shop's card and another shop aren't purchases.
            charge(day(2026, 4, 10), "19.90"), charge(day(2026, 6, 1), "-100", category: "Credit Card Payment"),
            charge(day(2026, 9, 1), "-12", "Muji")
        ]
    }

    @Test func purchasesSayWhenItWasLastBoughtAndHowOften() throws {
        let summary = try #require(PlaybookPurchases.summary(pick(from: "uniqlo.com"), transactions: history, today: today))
        #expect(summary.shop == "uniqlo")
        #expect(summary.lastBought == day(2026, 4, 2))
        #expect(summary.lastSpent == Decimal(string: "59.70"))
        // Nov 20, 2025 and Apr 2, 2026 fall in the past year.
        #expect(summary.timesPastYear == 2)
        // Gaps of 190, 194 and 133 days.
        #expect(summary.usualGapDays == 190)
        // 211 days since Apr 2.
        #expect(summary.restockDue)
    }

    @Test func notTimeToRestockWithinTheUsualGap() throws {
        let summary = try #require(PlaybookPurchases.summary(pick(from: "uniqlo.com"), transactions: history, today: day(2026, 9, 1)))
        #expect(!summary.restockDue)
    }

    @Test func fewerThanThreePurchasesCantSayHowOften() throws {
        let two = [charge(day(2025, 11, 20), "-20"), charge(day(2026, 4, 2), "-59.70")]
        let summary = try #require(PlaybookPurchases.summary(pick(from: "Uniqlo"), transactions: two, today: today))
        #expect(summary.usualGapDays == nil)
        #expect(!summary.restockDue)
    }

    @Test func aMatchedTransferIsntAPurchase() throws {
        let paired = charge(day(2026, 4, 2), "-59.70", category: nil)
        let summary = PlaybookPurchases.summary(pick(from: "Uniqlo"), transactions: [paired], transfers: [paired.id], today: today)
        #expect(summary == nil)
    }

    @Test func noShopOrNoPurchasesIsNothing() {
        #expect(PlaybookPurchases.summary(pick(from: ""), transactions: history, today: today) == nil)
        #expect(PlaybookPurchases.summary(pick(from: "everlane.com"), transactions: history, today: today) == nil)
    }
}
