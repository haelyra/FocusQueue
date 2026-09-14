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
