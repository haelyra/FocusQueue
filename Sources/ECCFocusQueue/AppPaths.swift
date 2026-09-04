import Foundation

struct AppPaths: Sendable {
    let supportDirectory: URL
    let configurationFile: URL
    let stateFile: URL
    let reviewsDirectory: URL
    let agentRegistrationsDirectory: URL

    var ingestionConfigurationFile: URL {
        supportDirectory.appendingPathComponent("ingestion.json")
    }

    var ingestionRuntimeDirectory: URL {
        supportDirectory.appendingPathComponent("ingestion", isDirectory: true)
    }

    var latestDailyReportFile: URL {
        ingestionRuntimeDirectory.appendingPathComponent("latest-report.json")
    }

    var dailyReportApprovalFile: URL {
        ingestionRuntimeDirectory.appendingPathComponent("pending-report-approval.json")
    }

    var dailyReportScript: URL {
        supportDirectory.appendingPathComponent("automation/Scripts/focus_queue_morning.py")
    }

    static func live(environment: [String: String] = ProcessInfo.processInfo.environment) -> Self {
        if let override = environment["FOCUS_QUEUE_SUPPORT_DIR"], !override.isEmpty {
            let directory = URL(fileURLWithPath: override, isDirectory: true)
            return Self(
                supportDirectory: directory,
                configurationFile: directory.appendingPathComponent("config.json"),
                stateFile: directory.appendingPathComponent("state.json"),
                reviewsDirectory: directory.appendingPathComponent("reviews", isDirectory: true),
                agentRegistrationsDirectory: directory.appendingPathComponent(
                    "agent-registrations", isDirectory: true)
            )
        }

        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ECC Focus Queue", isDirectory: true)
        return Self(
            supportDirectory: base,
            configurationFile: base.appendingPathComponent("config.json"),
            stateFile: base.appendingPathComponent("state.json"),
            reviewsDirectory: base.appendingPathComponent("reviews", isDirectory: true),
            agentRegistrationsDirectory: base.appendingPathComponent(
                "agent-registrations", isDirectory: true)
        )
    }
}
