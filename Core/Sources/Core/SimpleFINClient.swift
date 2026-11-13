import Foundation

/// One account as SimpleFIN reports it.
public struct SimpleFINAccount: Hashable, Sendable {
    public var id: String
    public var name: String
    public var institution: String?
    public var balance: Decimal
    public var balanceDate: Date
    /// Posted transactions, when they were asked for.
    public var transactions: [SimpleFINTransaction]

    public init(
        id: String, name: String, institution: String?, balance: Decimal, balanceDate: Date,
        transactions: [SimpleFINTransaction] = []
    ) {
        self.id = id
        self.name = name
        self.institution = institution
        self.balance = balance
        self.balanceDate = balanceDate
        self.transactions = transactions
    }
}

public struct SimpleFINTransaction: Hashable, Sendable {
    public var id: String
    public var posted: Date
    /// Negative for money out.
    public var amount: Decimal
    /// The payee when the bank gives one, otherwise the description.
    public var payee: String
    public var description: String

    public init(id: String, posted: Date, amount: Decimal, payee: String, description: String) {
        self.id = id
        self.posted = posted
        self.amount = amount
        self.payee = payee
        self.description = description
    }
}

public struct SimpleFINAccountSet: Hashable, Sendable {
    public var accounts: [SimpleFINAccount]
    /// Messages the Bridge sends alongside the data, like a bank needing you to
    /// sign in again. Worth showing; not a failed sync.
    public var problems: [String]
}

/// Talks to a SimpleFIN Bridge (protocol v2): claims a setup token for an
/// access URL, then reads balances with it. https://www.simplefin.org/protocol.html
public struct SimpleFINClient: Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public enum Failure: LocalizedError, Equatable, Sendable {
        case badSetupToken
        case tokenAlreadyClaimed
        case badAccessURL
        case accessRevoked
        case paymentRequired
        case offline
        /// The request didn't complete for a reason other than being offline,
        /// such as a TLS failure. The Bridge never answered.
        case connectionFailed
        case http(Int)
        case unreadableResponse

        public var errorDescription: String? {
            switch self {
            case .badSetupToken: "That doesn't look like a SimpleFIN setup token."
            case .tokenAlreadyClaimed: "This setup token was already used. Create a new one in SimpleFIN Bridge."
            case .badAccessURL: "The saved SimpleFIN access can't be used. Connect again with a new setup token."
            case .accessRevoked: "SimpleFIN refused the saved access. Connect again with a new setup token."
            case .paymentRequired: "SimpleFIN says the subscription needs payment."
            case .offline: "Can't reach SimpleFIN. Check your internet connection and try again."
            case .connectionFailed: "Couldn't complete a secure connection to SimpleFIN. Try again later."
            case .http(let status): "SimpleFIN answered with an error (HTTP \(status)). Try again later."
            case .unreadableResponse: "SimpleFIN's response couldn't be read."
            }
        }
    }

    private let transport: Transport

    /// A slow Bridge gets 20 seconds, then the usual "can't reach SimpleFIN".
    public static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 40
        return URLSession(configuration: configuration)
    }()

    public init(transport: @escaping Transport = { try await SimpleFINClient.session.data(for: $0) }) {
        self.transport = transport
    }

    /// Exchanges a one-time setup token for the long-lived access URL.
    public func claim(setupToken: String) async throws -> String {
        var request = URLRequest(url: try Self.claimURL(fromSetupToken: setupToken))
        request.httpMethod = "POST"
        request.setValue("0", forHTTPHeaderField: "Content-Length")

        let data = try await send(request, refused: .tokenAlreadyClaimed)
        let accessURL = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try Self.accountsRequest(accessURL: accessURL)
        return accessURL
    }

    /// Current balances for every account linked in SimpleFIN Bridge, plus
    /// posted transactions since `transactionsSince` when it's given.
    public func fetchAccounts(accessURL: String, transactionsSince: Date? = nil) async throws -> SimpleFINAccountSet {
        let request = try Self.accountsRequest(accessURL: accessURL, transactionsSince: transactionsSince)
        let data = try await send(request, refused: .accessRevoked)
        guard let decoded = try? JSONDecoder().decode(AccountSet.self, from: data) else {
            throw Failure.unreadableResponse
        }
        let institutions = Dictionary(
            (decoded.connections ?? []).map { ($0.conn_id, $0.name) },
            uniquingKeysWith: { first, _ in first }
        )
        var accounts: [SimpleFINAccount] = []
        for account in decoded.accounts {
            guard let balance = Decimal(string: account.balance, locale: Locale(identifier: "en_US_POSIX")) else {
                throw Failure.unreadableResponse
            }
            var transactions: [SimpleFINTransaction] = []
            for transaction in account.transactions ?? [] where transaction.pending != true && transaction.posted > 0 {
                guard let amount = Decimal(string: transaction.amount, locale: Locale(identifier: "en_US_POSIX")) else {
                    throw Failure.unreadableResponse
                }
                let description = transaction.description ?? ""
                let payee = transaction.payee.flatMap { $0.isEmpty ? nil : $0 } ?? description
                transactions.append(
                    SimpleFINTransaction(
                        id: transaction.id, posted: Date(timeIntervalSince1970: transaction.posted),
                        amount: amount, payee: payee, description: description
                    ))
            }
            accounts.append(
                SimpleFINAccount(
                    id: account.id,
                    name: account.name,
                    institution: account.conn_id.flatMap { institutions[$0] } ?? account.org?.name,
                    balance: balance,
                    balanceDate: Date(timeIntervalSince1970: account.balanceDate),
                    transactions: transactions
                ))
        }
        return SimpleFINAccountSet(accounts: accounts, problems: decoded.errlist?.map(\.msg) ?? decoded.errors ?? [])
    }

    /// Sends `request` and returns the body of a 200, mapping everything else
    /// to a `Failure`. A 403 means something different for each endpoint.
    private func send(_ request: URLRequest, refused: Failure) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport(request)
        } catch let error as URLError {
            throw Self.offlineCodes.contains(error.code) ? Failure.offline : Failure.connectionFailed
        }
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200: return data
        case 402: throw Failure.paymentRequired
        case 403: throw refused
        case let status: throw Failure.http(status)
        }
    }

    private static let offlineCodes: Set<URLError.Code> = [
        .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost,
        .cannotConnectToHost, .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed
    ]

    /// GET {access URL}/accounts, with the URL's embedded credentials moved
    /// into a Basic Authorization header. Balances only unless transactions
    /// since a date are asked for.
    static func accountsRequest(accessURL: String, transactionsSince: Date? = nil) throws -> URLRequest {
        guard var components = URLComponents(string: accessURL),
            components.scheme == "https", components.host != nil,
            let user = components.user, let password = components.password
        else { throw Failure.badAccessURL }

        let credentials = Data("\(user):\(password)".utf8).base64EncodedString()
        components.user = nil
        components.password = nil
        components.path += components.path.hasSuffix("/") ? "accounts" : "/accounts"
        components.queryItems = [
            URLQueryItem(name: "version", value: "2"),
            transactionsSince.map { URLQueryItem(name: "start-date", value: String(Int($0.timeIntervalSince1970))) }
                ?? URLQueryItem(name: "balances-only", value: "1")
        ]
        guard let url = components.url else { throw Failure.badAccessURL }

        var request = URLRequest(url: url)
        request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        return request
    }

    static func claimURL(fromSetupToken token: String) throws -> URL {
        var base64 = token.trimmingCharacters(in: .whitespacesAndNewlines)
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64),
            let text = String(data: data, encoding: .utf8),
            let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
            url.scheme == "https", url.host != nil
        else { throw Failure.badSetupToken }
        return url
    }
}

/// The v2 Account Set. Fields from v1 (`errors`, `org`) are read as a fallback.
private struct AccountSet: Decodable {
    struct Problem: Decodable {
        var msg: String
    }

    struct Connection: Decodable {
        var conn_id: String
        var name: String
    }

    struct Org: Decodable {
        var name: String?
    }

    struct Account: Decodable {
        var id: String
        var name: String
        var conn_id: String?
        var org: Org?
        var balance: String
        var balanceDate: TimeInterval
        var transactions: [Transaction]?

        enum CodingKeys: String, CodingKey {
            case id, name, conn_id, org, balance, transactions
            case balanceDate = "balance-date"
        }
    }

    struct Transaction: Decodable {
        var id: String
        var posted: TimeInterval
        var amount: String
        var description: String?
        var payee: String?
        var pending: Bool?
    }

    var errlist: [Problem]?
    var errors: [String]?
    var connections: [Connection]?
    var accounts: [Account]
}
