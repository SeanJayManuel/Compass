import Core
import Testing

/// Seam 49: a merchant's website, for fetching its logo.
@Suite struct MerchantDomainTests {
    @Test func knownMerchantsMapToTheirSites() {
        #expect(MerchantDomain.domain(for: "DoorDash") == "doordash.com")
        #expect(MerchantDomain.domain(for: "Costco") == "costco.com")
        #expect(MerchantDomain.domain(for: "Trader Joe's") == "traderjoes.com")
        #expect(MerchantDomain.domain(for: "Whole Foods Market") == "wholefoodsmarket.com")
        #expect(MerchantDomain.domain(for: "UPS") == "ups.com")
        #expect(MerchantDomain.domain(for: "The UPS Store") == "theupsstore.com")
    }

    @Test func storeNumbersAndBankWordingAreDropped() {
        #expect(MerchantDomain.domain(for: "COSTCO WHSE #1234") == "costco.com")
        #expect(MerchantDomain.domain(for: "AMZN Mktp US*2K4") == "amazon.com")
        #expect(MerchantDomain.domain(for: "STARBUCKS STORE 05521") == "starbucks.com")
    }

    @Test func cardProcessorPrefixesAreDropped() {
        #expect(MerchantDomain.domain(for: "SQ *BLUE BOTTLE COFFEE") == "bluebottlecoffee.com")
        #expect(MerchantDomain.domain(for: "TST* Sweetgreen") == "sweetgreen.com")
        #expect(MerchantDomain.domain(for: "PAYPAL *SPOTIFY") == "spotify.com")
    }

    @Test func theLongerNameWins() {
        #expect(MerchantDomain.domain(for: "Uber Eats") == "ubereats.com")
        #expect(MerchantDomain.domain(for: "Uber Trip") == "uber.com")
    }

    @Test func aBrandWrittenAsOneCapitalisedWordOrADotComIsGuessed() {
        #expect(MerchantDomain.domain(for: "YouTube") == "youtube.com")
        #expect(MerchantDomain.domain(for: "HULU.COM") == "hulu.com")
    }

    @Test func peopleTransfersAndPayAreNeverLookedUp() {
        #expect(MerchantDomain.domain(for: "Venmo · J. Alvarez") == nil)
        #expect(MerchantDomain.domain(for: "Zelle to Nora") == nil)
        #expect(MerchantDomain.domain(for: "Transfer to Savings") == nil)
        #expect(MerchantDomain.domain(for: "Payroll · Acme") == nil)
        #expect(MerchantDomain.domain(for: "Payment Thank You") == nil)
        #expect(MerchantDomain.domain(for: "Rewards Card Autopay") == nil)
    }

    @Test func banksAndBrokersShowEvenOnPaymentsAndTrades() {
        #expect(MerchantDomain.domain(for: "Chase Credit Card") == "chase.com")
        #expect(MerchantDomain.domain(for: "Payment to Chase") == "chase.com")
        #expect(MerchantDomain.domain(for: "Capital One") == "capitalone.com")
        #expect(MerchantDomain.domain(for: "You Bought Vanguard Total International Stock I... (Vxus) (Cash)") == "vanguard.com")
        #expect(MerchantDomain.domain(for: "Purchase Into Core Account Fidelity Government Money Market (Spaxx) (Cash)") == "fidelity.com")
        #expect(MerchantDomain.domain(for: "Blackrock Russell 2000 Indx") == "blackrock.com")
    }

    @Test func anOrderPlacedThroughAnAppShowsTheShop() {
        #expect(MerchantDomain.domain(for: "Taco Bell via DoorDash") == "tacobell.com")
        #expect(MerchantDomain.domain(for: "Corner Bistro via DoorDash") == "doordash.com")
    }

    @Test func namesWithNumbersAndHyphensMatch() {
        #expect(MerchantDomain.domain(for: "In-N-Out Burger") == "in-n-out.com")
        #expect(MerchantDomain.domain(for: "7-Eleven") == "7-eleven.com")
        #expect(MerchantDomain.domain(for: "Pacific Gas & Electric") == "pge.com")
        #expect(MerchantDomain.domain(for: "Delta Airlines") == "delta.com")
    }

    @Test func vagueNamesKeepTheirInitials() {
        #expect(MerchantDomain.domain(for: "Laundromat") == nil)
        #expect(MerchantDomain.domain(for: "Corner Bistro") == nil)
        #expect(MerchantDomain.domain(for: "Hardware Co") == nil)
        #expect(MerchantDomain.domain(for: "") == nil)
    }
}
