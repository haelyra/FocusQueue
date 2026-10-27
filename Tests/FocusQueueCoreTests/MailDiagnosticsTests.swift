import Testing

@testable import FocusQueueCore

@Test("Mail failures distinguish helper approval from scope and sandbox denials")
func mailFailureDiagnosticCategories() {
    let cases = [
        ("mail_reader_busy: another request holds the lock", "Mail reader is busy with another request"),
        ("mail_permission_required: -1743", "ECC Focus Mail Reader > Mail"),
        ("Not authorized to send Apple events", "ECC Focus Mail Reader > Mail"),
        ("mailbox_not_configured: sent; Operation not permitted: /bin/ps", "outside the configured Mail scope"),
        ("mail_reader_timeout", "protected Mail reader timed out"),
        ("Operation not permitted: /bin/ps token=secret", "denied access to a local process or file"),
    ]
    for (failure, expected) in cases {
        let result = ProcessResult(exitCode: 1, standardOutput: failure, standardError: "", timedOut: false)
        let chat = CodexQueueAgent.safeFailureDetail(from: result, message: "Search my inbox", runTimeoutSeconds: 90)
        let report = DailyReportAutomation.presentation(for: result, hasMatchingReport: false).message
        #expect(chat.contains(expected))
        #expect(report.contains(expected))
        #expect(!chat.contains("token=secret"))
        #expect(!report.contains("token=secret"))
        if failure.contains("/bin/ps") {
            #expect(!chat.contains("Automation"))
            #expect(!report.contains("Automation"))
        }
    }
}

@Test("Daily report and Queue chat map worker failures through identical wording")
func workerFailureDiagnosticsAgreeAcrossSurfaces() {
    let cases = [
        (
            "Focus Queue morning reconciliation failed: mail_reader_timeout: Mail reader timed out after 90 seconds",
            "the protected Mail reader timed out. Confirm the configured mail provider is available, then retry"
        ),
        (
            "Focus Queue morning reconciliation failed: No-tools classification rejected codex-cli 0.153.4",
            "the message classifier failed its safety or compatibility check. Update Focus Queue or Codex, then retry"
        ),
        (
            "codex harness note: classification failed during collection; mail_reader_timeout while reading INBOX",
            "the protected Mail reader timed out. Confirm the configured mail provider is available, then retry"
        ),
        (
            "codex-cli 0.153.4 token usage: 12840 tokens",
            "the worker exited with code 1. See the private diagnostic log for details"
        ),
    ]
    for (stderr, expected) in cases {
        let result = ProcessResult(exitCode: 1, standardOutput: "", standardError: stderr, timedOut: false)
        let chat = CodexQueueAgent.safeFailureDetail(from: result, message: "Why is ECC-002 second?", runTimeoutSeconds: 90)
        let report = DailyReportAutomation.presentation(for: result, hasMatchingReport: true)
        #expect(chat == expected)
        #expect(report.message == "Daily report failed: \(chat). It will retry automatically.")
        #expect(report.isError)
    }
    let genericCodex = ProcessResult(
        exitCode: 1, standardOutput: "", standardError: "codex-cli 0.153.4 token usage: 12840 tokens", timedOut: false)
    let chatFallback = CodexQueueAgent.safeFailureDetail(from: genericCodex, message: "Why is ECC-002 second?", runTimeoutSeconds: 90)
    #expect(!chatFallback.contains("safety or compatibility check"))
    #expect(!chatFallback.contains("codex-cli 0.153.4"))
}

@Test("Partial daily reports append the mapped cause when stderr carries a known error")
func dailyReportPartialPresentationIncludesKnownCause() {
    let result = ProcessResult(
        exitCode: 2,
        standardOutput: "REPORT_ID: 11111111-2222-3333-4444-555555555555",
        standardError: "mail_reader_timeout: Mail reader timed out after 90 seconds",
        timedOut: false
    )

    let presentation = DailyReportAutomation.presentation(for: result, hasMatchingReport: true)

    #expect(presentation.isError)
    #expect(
        presentation.message
            == "Daily report completed with partial platform coverage: the protected Mail reader timed out. Confirm the configured mail provider is available, then retry. It will retry automatically."
    )
}

@Test("Queue chat reports a harness-enforced run budget as a timeout, not a bare exit code")
func queueChatHarnessRunBudgetIsTimeout() {
    for provider in ["Claude", "Codex", "Kimi"] {
        let result = ProcessResult(
            exitCode: 1, standardOutput: "",
            standardError: "\(provider) Queue harness failed: \(provider) exceeded the 120-second run budget",
            timedOut: false)
        let chat = CodexQueueAgent.safeFailureDetail(
            from: result, message: "Create a new project called Kairos", runTimeoutSeconds: 120)
        #expect(chat.hasPrefix("the request timed out after 120 seconds"))
        #expect(!chat.contains("exited with code"))
    }
    let mail = ProcessResult(
        exitCode: 1, standardOutput: "",
        standardError: "Claude Queue harness failed: Claude exceeded the 180-second run budget", timedOut: false)
    #expect(CodexQueueAgent.safeFailureDetail(from: mail, message: "Search my inbox", runTimeoutSeconds: 180)
        .hasPrefix("Mail check timed out after 180 seconds"))
}
