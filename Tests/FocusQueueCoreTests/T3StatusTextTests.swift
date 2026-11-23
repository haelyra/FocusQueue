import Foundation
import Testing
@testable import FocusQueueCore

struct T3StatusTextTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 24 * 60 * 60

    private func state(label: String? = "Studio", expiresIn: TimeInterval? = nil) -> T3ConnectionState {
        T3ConnectionState(serverURL: "http://127.0.0.1:3773", environmentId: "env-1", environmentLabel: label,
                          serverVersion: "0.1.12", tokenExpiresAt: expiresIn.map { now.addingTimeInterval($0) })
    }

    private func text(_ status: T3ConnectionStatus, _ state: T3ConnectionState? = nil) -> String {
        T3StatusText.text(for: status, state: state, now: now)
    }

    @Test func disconnected() {
        #expect(text(.disconnected) == "Not connected")
    }

    @Test func signingIn() {
        #expect(text(.signingIn) == "Approve Focus Queue in T3 Code")
    }

    @Test func connectedUsesLabelAndStatusVersion() {
        let status = T3ConnectionStatus.connected(environmentId: "env-1", version: "0.1.13-nightly")
        #expect(text(status, state()) == "Connected to Studio, T3 Code 0.1.13-nightly")
    }

    @Test func connectedFallsBackWithoutLabel() {
        let status = T3ConnectionStatus.connected(environmentId: "env-1", version: "0.1.12")
        #expect(text(status, state(label: nil)) == "Connected to T3 Code server, T3 Code 0.1.12")
        #expect(text(status, nil) == "Connected to T3 Code server, T3 Code 0.1.12")
    }

    @Test func unreachable() {
        #expect(text(.unreachable) == "T3 Code is not running")
    }

    @Test func serverTooOld() {
        #expect(text(.serverTooOld("0.1.11"))
            == "T3 Code 0.1.11 is too old. Live updates need T3 Code 0.1.12 or later")
        #expect(text(.serverTooOld(nil)) == "T3 Code is too old. Live updates need T3 Code 0.1.12 or later")
    }

    @Test func accessTooLow() {
        #expect(text(.accessTooLow) == "Access too low: reconnect and choose Full access")
    }

    @Test func unauthorized() {
        #expect(text(.unauthorized) == "Access expired or revoked. Reconnect T3 Code")
    }

    @Test func otherServer() {
        #expect(text(.otherServer(expected: "env-1", actual: "env-2"))
            == "Connected to a different T3 Code server than your existing agents")
    }

    @Test func expiryNoteAtTwoDaysButNotTen() {
        let status = T3ConnectionStatus.connected(environmentId: "env-1", version: "0.1.12")
        #expect(text(status, state(expiresIn: 2 * day)) == "Connected to Studio, T3 Code 0.1.12 · Reconnect soon")
        #expect(text(status, state(expiresIn: 10 * day)) == "Connected to Studio, T3 Code 0.1.12")
        #expect(text(status, state(expiresIn: nil)) == "Connected to Studio, T3 Code 0.1.12")
    }

    @Test func expiryNoteOnlyWhenConnected() {
        #expect(text(.disconnected, state(expiresIn: 2 * day)) == "Not connected")
    }

    @Test(arguments: ["http://127.0.0.1:3773", "http://localhost:3773", "https://host.example",
                      "https://host.example:8443/mcp", "HTTP://LOCALHOST:3773", " http://127.0.0.1:3773 "])
    func acceptsLocalHTTPAndAnyHTTPS(_ url: String) {
        #expect(T3StatusText.isAcceptableServerURL(url))
    }

    @Test(arguments: ["http://192.168.1.5:3773", "http://host.example", "http://127.0.0.1.evil.example",
                      "ftp://127.0.0.1", "127.0.0.1:3773", "", "https://"])
    func rejectsRemoteHTTPAndJunk(_ url: String) {
        #expect(!T3StatusText.isAcceptableServerURL(url))
    }

    @Test func messages() {
        #expect(T3StatusText.insecureURLMessage == "Use https for servers that are not on this Mac")
        #expect(T3StatusText.fullAccessNote
            == "Focus Queue needs Full access. Choose Full access on T3 Code's approval page.")
    }
}
