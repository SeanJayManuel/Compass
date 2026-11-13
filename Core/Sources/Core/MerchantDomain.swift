import Foundation

/// Seam 49: a merchant's website, so the app can show its logo (DoorDash
/// gets DoorDash's logo). Card-processor
/// prefixes ("SQ *", "TST*") and store numbers are dropped. Banks and brokers
/// match anywhere in a line, payments and trades included ("Chase Credit
/// Card", "You Bought Vanguard…"); an order through an app ("Taco Bell via
/// DoorDash") shows the shop, else the app. Known merchants map by name,
/// longest first; a brand written as one word with a capital inside
/// ("DoorDash", "YouTube") or as a ".com" is guessed. People, transfers, pay
/// and vague names give nothing, so they keep their initials and are never
/// looked up.
public enum MerchantDomain {
    public static func domain(for merchant: String) -> String? {
        let lower = merchant.lowercased()
        // "Taco Bell via DoorDash": the shop, else the app it came through.
        if let via = lower.range(of: " via ") {
            let shop = String(merchant[merchant.startIndex..<via.lowerBound])
            let app = String(merchant[via.upperBound...])
            return domain(for: shop) ?? domain(for: app)
        }
        let all = words(lower)
        guard !all.isEmpty else { return nil }
        let joined = " " + all.joined(separator: " ") + " "
        // A bank or broker anywhere: its own logo even on a payment or a trade.
        if let bank = banks.first(where: { joined.contains(" \($0.name) ") }) { return bank.domain }
        guard !all.contains(where: never.contains) else { return nil }

        // Processor prefixes come before the first "*", or as a leading word.
        var cleaned = lower
        if let star = cleaned.firstIndex(of: "*"), cleaned.distance(from: cleaned.startIndex, to: star) <= 8 {
            cleaned = String(cleaned[cleaned.index(after: star)...])
        }
        let kept = words(cleaned).filter { word in !isStoreNumber(word) && !processors.contains(word) }
        let name = kept.joined(separator: " ")
        guard !name.isEmpty else { return nil }

        if let known = known.first(where: { name == $0.name || name.hasPrefix($0.name + " ") }) {
            return known.domain
        }
        if let dotCom = all.firstIndex(of: "com"), dotCom > 0, lower.contains(".com") {
            return all[dotCom - 1] + ".com"
        }
        // One word with a capital inside, as brands write themselves.
        let original = merchant.trimmingCharacters(in: .whitespaces)
        if !original.contains(" "), original.allSatisfy(\.isLetter), original.count >= 4,
            original.dropFirst().contains(where: \.isUppercase), original.contains(where: \.isLowercase)
        {
            return original.lowercased() + ".com"
        }
        return nil
    }

    /// Lowercased words, apostrophes dropped ("trader joes"), "&" kept as a word.
    private static func words(_ text: String) -> [String] {
        text.replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "’", with: "")
            .replacingOccurrences(of: "&", with: " & ")
            .split { !$0.isLetter && !$0.isNumber && $0 != "&" }
            .map(String.init)
    }

    /// "#1234", "05521", "2k4": a store or reference number, not part of a name.
    /// A short number that starts a name ("7" in 7-Eleven) stays.
    private static func isStoreNumber(_ word: String) -> Bool {
        guard word.contains(where: \.isNumber) else { return false }
        return word.count > 1 || word.contains(where: \.isLetter)
    }

    /// Any of these words means a person, a transfer or pay: never looked up.
    private static let never: Set<String> = [
        "venmo", "zelle", "cash", "transfer", "payroll", "paycheck", "deposit", "payment", "autopay",
        "withdrawal", "atm", "interest", "dividend", "refund", "check", "fee", "to", "from"
    ]

    /// Words card processors and banks put before or around the name.
    private static let processors: Set<String> = [
        "sq", "tst", "pp", "paypal", "sp", "pos", "debit", "purchase", "card", "www", "mktp", "us", "inc", "llc",
        "whse", "com"
    ]

    /// Banks and brokers, matched as whole words anywhere in the line.
    private static let banks: [(name: String, domain: String)] = [
        ("chase", "chase.com"), ("capital one", "capitalone.com"), ("american express", "americanexpress.com"),
        ("amex", "americanexpress.com"), ("bank of america", "bankofamerica.com"), ("wells fargo", "wellsfargo.com"),
        ("citibank", "citi.com"), ("citi", "citi.com"), ("discover", "discover.com"), ("fidelity", "fidelity.com"),
        ("vanguard", "vanguard.com"), ("blackrock", "blackrock.com"), ("ishares", "ishares.com"),
        ("schwab", "schwab.com"), ("robinhood", "robinhood.com"), ("wealthfront", "wealthfront.com"),
        ("betterment", "betterment.com"), ("coinbase", "coinbase.com"), ("sofi", "sofi.com"), ("marcus", "marcus.com"),
        ("merrill", "ml.com"), ("e trade", "etrade.com"), ("etrade", "etrade.com"), ("us bank", "usbank.com"),
        ("navy federal", "navyfederal.org"), ("usaa", "usaa.com"), ("apple card", "apple.com")
    ].sorted { $0.name.count > $1.name.count }

    /// Longest names first, so "uber eats" wins over "uber".
    private static let known: [(name: String, domain: String)] = [
        // Shops and groceries
        ("the ups store", "theupsstore.com"), ("whole foods market", "wholefoodsmarket.com"),
        ("whole foods", "wholefoodsmarket.com"), ("trader joes", "traderjoes.com"), ("trader joe", "traderjoes.com"),
        ("home depot", "homedepot.com"), ("the home depot", "homedepot.com"), ("best buy", "bestbuy.com"),
        ("dollar tree", "dollartree.com"), ("dollar general", "dollargeneral.com"), ("buck mason", "buckmason.com"),
        ("old navy", "oldnavy.com"), ("bed bath", "bedbathandbeyond.com"), ("7 eleven", "7-eleven.com"),
        ("costco", "costco.com"), ("amazon", "amazon.com"), ("amzn", "amazon.com"),
        ("walmart", "walmart.com"), ("target", "target.com"), ("safeway", "safeway.com"), ("kroger", "kroger.com"),
        ("publix", "publix.com"), ("wegmans", "wegmans.com"), ("aldi", "aldi.us"), ("sprouts", "sprouts.com"),
        ("cvs", "cvs.com"), ("walgreens", "walgreens.com"), ("lowes", "lowes.com"), ("ikea", "ikea.com"),
        ("nike", "nike.com"), ("adidas", "adidas.com"), ("lululemon", "lululemon.com"), ("uniqlo", "uniqlo.com"),
        ("zara", "zara.com"), ("gap", "gap.com"), ("nordstrom", "nordstrom.com"), ("macys", "macys.com"),
        ("sephora", "sephora.com"), ("ulta", "ulta.com"), ("rei", "rei.com"), ("patagonia", "patagonia.com"),
        ("etsy", "etsy.com"), ("ebay", "ebay.com"), ("wayfair", "wayfair.com"), ("chewy", "chewy.com"),
        ("misen", "misen.com"), ("apple", "apple.com"), ("microsoft", "microsoft.com"),
        // Food and coffee
        ("blue bottle coffee", "bluebottlecoffee.com"), ("blue bottle", "bluebottlecoffee.com"),
        ("in n out", "in-n-out.com"), ("taco bell", "tacobell.com"), ("panda express", "pandaexpress.com"),
        ("jack in the box", "jackinthebox.com"), ("burger king", "bk.com"), ("five guys", "fiveguys.com"),
        ("shake shack", "shakeshack.com"), ("pizza hut", "pizzahut.com"), ("raising canes", "raisingcanes.com"),
        ("jersey mikes", "jerseymikes.com"), ("dutch bros", "dutchbros.com"), ("chick fil a", "chick-fil-a.com"),
        ("uber eats", "ubereats.com"), ("mcdonalds", "mcdonalds.com"), ("dunkin", "dunkindonuts.com"),
        ("starbucks", "starbucks.com"), ("peets", "peets.com"), ("philz", "philzcoffee.com"),
        ("chipotle", "chipotle.com"), ("sweetgreen", "sweetgreen.com"), ("cava", "cava.com"), ("wingstop", "wingstop.com"),
        ("sonic", "sonicdrivein.com"), ("wendys", "wendys.com"), ("popeyes", "popeyes.com"), ("kfc", "kfc.com"),
        ("panera", "panerabread.com"), ("dominos", "dominos.com"), ("subway", "subway.com"),
        ("doordash", "doordash.com"), ("grubhub", "grubhub.com"), ("instacart", "instacart.com"),
        ("seamless", "seamless.com"), ("postmates", "postmates.com"), ("gopuff", "gopuff.com"),
        // Getting around and travel
        ("air canada", "aircanada.com"), ("alaska air", "alaskaair.com"), ("american airlines", "aa.com"),
        ("united airlines", "united.com"), ("delta", "delta.com"), ("southwest", "southwest.com"),
        ("jetblue", "jetblue.com"), ("uber", "uber.com"), ("lyft", "lyft.com"), ("waymo", "waymo.com"),
        ("airbnb", "airbnb.com"), ("expedia", "expedia.com"), ("marriott", "marriott.com"), ("hilton", "hilton.com"),
        ("hyatt", "hyatt.com"), ("shell", "shell.com"), ("chevron", "chevron.com"), ("exxon", "exxon.com"),
        ("arco", "arco.com"), ("valero", "valero.com"), ("california department of motor vehicles", "dmv.ca.gov"),
        ("dmv", "dmv.ca.gov"), ("ups", "ups.com"), ("fedex", "fedex.com"), ("usps", "usps.com"),
        // Bills, health and services
        ("pacific gas and electric", "pge.com"), ("pacific gas & electric", "pge.com"), ("pg & e", "pge.com"),
        ("pge", "pge.com"), ("sutter health", "sutterhealth.org"), ("kaiser", "kp.org"),
        ("csc serviceworks", "cscsw.com"), ("powerhouse gym", "powerhousegym.com"), ("planet fitness", "planetfitness.com"),
        ("equinox", "equinox.com"), ("peloton", "onepeloton.com"), ("verizon", "verizon.com"), ("comcast", "xfinity.com"),
        ("xfinity", "xfinity.com"), ("at & t", "att.com"), ("tmobile", "t-mobile.com"), ("t mobile", "t-mobile.com"),
        ("geico", "geico.com"), ("progressive", "progressive.com"), ("state farm", "statefarm.com"),
        ("lemonade", "lemonade.com"), ("appfolio", "appfolio.com"),
        // Subscriptions and software
        ("prime video", "amazon.com"), ("netflix", "netflix.com"), ("hulu", "hulu.com"), ("disney", "disneyplus.com"),
        ("youtube", "youtube.com"), ("spotify", "spotify.com"), ("google", "google.com"), ("adobe", "adobe.com"),
        ("openai", "openai.com"), ("chatgpt", "openai.com"), ("anthropic", "anthropic.com"), ("claude ai", "anthropic.com"),
        ("github", "github.com"), ("cloudflare", "cloudflare.com"), ("linkedin", "linkedin.com"), ("notion", "notion.so"),
        ("figma", "figma.com"), ("dropbox", "dropbox.com"), ("duolingo", "duolingo.com"), ("pimsleur", "pimsleur.com"),
        ("cinemark", "cinemark.com"), ("amc", "amctheatres.com"), ("stubhub", "stubhub.com"),
        ("ticketmaster", "ticketmaster.com"), ("impark", "impark.com"), ("equator coffees", "equatorcoffees.com"),
        ("marufuku", "marufukuramen.com")
    ].sorted { $0.name.count > $1.name.count }
}
