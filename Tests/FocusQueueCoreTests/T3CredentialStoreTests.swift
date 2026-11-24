import Foundation
import Testing
@testable import FocusQueueCore

@Suite("T3 credential store")
struct T3CredentialStoreTests {
    private let server = "http://127.0.0.1:3773"
    private let token = "secret-token-AbC123"

    @Test("In-memory store saves, loads, overwrites, deletes, and deletes a missing item")
    func inMemoryLifecycle() throws {
        let store = InMemoryT3CredentialStore()
        #expect(try store.load(server: server) == nil)

        let first = T3Credential(accessToken: token, expiresAt: Date(timeIntervalSince1970: 1_900_000_000))
        try store.save(first, server: server)
        #expect(try store.load(server: server) == first)

        let second = T3Credential(accessToken: "other", expiresAt: nil)
        try store.save(second, server: server)
        #expect(try store.load(server: server) == second)

        try store.delete(server: server)
        #expect(try store.load(server: server) == nil)
        try store.delete(server: server)
        #expect(store.isEmpty)
    }

    @Test("Accounts are lowercased with no trailing slash")
    func normalizedAccount() throws {
        #expect(T3CredentialAccount.normalized(" HTTP://127.0.0.1:3773/ ") == "http://127.0.0.1:3773")
        #expect(T3CredentialAccount.normalized("https://T3.Example.com//") == "https://t3.example.com")
        let store = InMemoryT3CredentialStore()
        try store.save(T3Credential(accessToken: token, expiresAt: nil), server: "HTTP://127.0.0.1:3773/")
        #expect(try store.load(server: server)?.accessToken == token)
    }

    @Test("Descriptions never contain the token")
    func redacted() {
        let credential = T3Credential(accessToken: token, expiresAt: Date(timeIntervalSince1970: 0))
        #expect(!String(describing: credential).contains(token))
        #expect(!String(reflecting: credential).contains(token))
        #expect(!"\(credential)".contains(token))
        var dumped = ""
        dump(credential, to: &dumped)
        #expect(!dumped.contains(token))
        #expect(String(describing: credential).contains("redacted"))
    }

    @Test("Expiry is checked against a given time")
    func expiry() {
        let credential = T3Credential(accessToken: token, expiresAt: Date(timeIntervalSince1970: 100))
        #expect(!credential.isExpired(at: Date(timeIntervalSince1970: 99)))
        #expect(credential.isExpired(at: Date(timeIntervalSince1970: 100)))
        #expect(!T3Credential(accessToken: token, expiresAt: nil).isExpired(at: .distantFuture))
    }

    @Test("Live Keychain saves, loads, and deletes, leaving nothing behind",
          .enabled(if: ProcessInfo.processInfo.environment["ECC_FOCUS_QUEUE_LIVE_T3_TESTS"] == "1"))
    func liveKeychain() throws {
        let store = KeychainT3CredentialStore()
        let account = "test://focusqueue"
        try store.delete(server: account)
        defer { try? store.delete(server: account) }

        let credential = T3Credential(accessToken: "live-test-\(UUID().uuidString)",
                                      expiresAt: Date(timeIntervalSince1970: 1_900_000_000))
        try store.save(credential, server: account)
        #expect(try store.load(server: account) == credential)

        let replaced = T3Credential(accessToken: "live-test-replaced", expiresAt: nil)
        try store.save(replaced, server: "TEST://FocusQueue/")
        #expect(try store.load(server: account) == replaced)

        try store.delete(server: account)
        #expect(try store.load(server: account) == nil)
        try store.delete(server: account)
    }
}
