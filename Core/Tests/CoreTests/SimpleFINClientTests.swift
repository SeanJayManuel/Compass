import Core
import Foundation
import Testing

@Suite struct SimpleFINClientTests {
    /// base64 of "https://bridge.example/simplefin/claim/demo-token"
    let setupToken = "aHR0cHM6Ly9icmlkZ2UuZXhhbXBsZS9zaW1wbGVmaW4vY2xhaW0vZGVtby10b2tlbg=="
    let accessURL = "https://user:secret@bridge.example/simplefin"

    @Test func claimingASetupTokenReturnsTheAccessURL() async throws {
        let bridge = FakeBridge(status: 200, body: Data("\(accessURL)\n".utf8))
        let client = SimpleFINClient(transport: bridge.transport)

        let claimed = try await client.claim(setupToken: setupToken)

        #expect(claimed == accessURL)
        #expect(bridge.requests.first?.httpMethod == "POST")
        #expect(bridge.requests.first?.url?.absoluteString == "https://bridge.example/simplefin/claim/demo-token")
    }

    @Test func fetchingAccountsSendsTheAccessURLCredentialsAsBasicAuth() async throws {
        let bridge = FakeBridge(status: 200, body: try FakeBridge.fixture("accounts-v2"))
        let client = SimpleFINClient(transport: bridge.transport)

        _ = try await client.fetchAccounts(accessURL: accessURL)

        let request = try #require(bridge.requests.first)
        #expect(request.url?.absoluteString == "https://bridge.example/simplefin/accounts?version=2&balances-only=1")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Basic dXNlcjpzZWNyZXQ=")
    }

    @Test func fetchedAccountsCarryExactBalancesInstitutionsAndProblems() async throws {
        let bridge = FakeBridge(status: 200, body: try FakeBridge.fixture("accounts-v2"))
        let client = SimpleFINClient(transport: bridge.transport)

        let set = try await client.fetchAccounts(accessURL: accessURL)

        #expect(
            set.accounts == [
                SimpleFINAccount(
                    id: "ACT-checking", name: "Everyday Checking", institution: "Example Bank",
                    balance: Decimal(string: "1234.56")!, balanceDate: Date(timeIntervalSince1970: 1_792_900_800)
                ),
                SimpleFINAccount(
                    id: "ACT-card", name: "Rewards Card", institution: "Example Credit Union",
                    balance: Decimal(string: "-321.09")!, balanceDate: Date(timeIntervalSince1970: 1_792_900_800)
                )
            ])
        #expect(set.problems == ["Example Credit Union needs you to sign in again."])
    }

    @Test func aTokenThatIsNotBase64URLIsRejectedBeforeAnyRequest() async {
        let bridge = FakeBridge(status: 200)
        let client = SimpleFINClient(transport: bridge.transport)

        await #expect(throws: SimpleFINClient.Failure.badSetupToken) {
            try await client.claim(setupToken: "not a token")
        }
        #expect(bridge.requests.isEmpty)
    }

    @Test func aSecondClaimOfTheSameTokenSaysItWasUsed() async {
        let client = SimpleFINClient(transport: FakeBridge(status: 403).transport)
        await #expect(throws: SimpleFINClient.Failure.tokenAlreadyClaimed) {
            try await client.claim(setupToken: setupToken)
        }
    }

    @Test(arguments: [
        (403, SimpleFINClient.Failure.accessRevoked),
        (402, .paymentRequired),
        (500, .http(500))
    ])
    func bridgeRefusalsBecomeNamedFailures(status: Int, expected: SimpleFINClient.Failure) async {
        let client = SimpleFINClient(transport: FakeBridge(status: status).transport)
        await #expect(throws: expected) {
            try await client.fetchAccounts(accessURL: accessURL)
        }
    }

    @Test func noInternetIsAClearFailureNotACrash() async {
        let client = SimpleFINClient(transport: FakeBridge(failingWith: URLError(.notConnectedToInternet)).transport)
        do {
            _ = try await client.fetchAccounts(accessURL: accessURL)
            Issue.record("Expected a failure")
        } catch {
            #expect(error as? SimpleFINClient.Failure == .offline)
            #expect(error.localizedDescription == "Can't reach SimpleFIN. Check your internet connection and try again.")
        }
    }

    @Test func otherConnectionErrorsAreNotReportedAsHTTPStatuses() async {
        let client = SimpleFINClient(transport: FakeBridge(failingWith: URLError(.serverCertificateUntrusted)).transport)
        await #expect(throws: SimpleFINClient.Failure.connectionFailed) {
            try await client.fetchAccounts(accessURL: accessURL)
        }
    }

    @Test func aResponseThatIsNotAnAccountSetIsAFailure() async {
        let client = SimpleFINClient(transport: FakeBridge(status: 200, body: Data("<html>".utf8)).transport)
        await #expect(throws: SimpleFINClient.Failure.unreadableResponse) {
            try await client.fetchAccounts(accessURL: accessURL)
        }
    }

    @Test func anAccessURLWithoutCredentialsIsRejected() async {
        let client = SimpleFINClient(transport: FakeBridge(status: 200).transport)
        await #expect(throws: SimpleFINClient.Failure.badAccessURL) {
            try await client.fetchAccounts(accessURL: "https://bridge.example/simplefin")
        }
    }
}

/// Stands in for the SimpleFIN Bridge. Tests never call the real one.
final class FakeBridge: @unchecked Sendable {
    private(set) var requests: [URLRequest] = []
    private let respond: @Sendable (URLRequest) throws -> (Int, Data)

    init(status: Int, body: Data = Data()) {
        respond = { _ in (status, body) }
    }

    init(failingWith error: Error) {
        respond = { _ in throw error }
    }

    var transport: SimpleFINClient.Transport {
        { request in
            self.requests.append(request)
            let (status, body) = try self.respond(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (body, response)
        }
    }

    static func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }
}
