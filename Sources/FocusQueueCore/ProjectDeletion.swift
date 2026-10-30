import Foundation

/// Removes registration and private queue storage, never a workspace or authored documents.
public struct ProjectDeletion: Sendable {
    public let supportDirectory: URL
    public let configurationURL: URL

    public init(supportDirectory: URL, configurationURL: URL) {
        self.supportDirectory = supportDirectory
        self.configurationURL = configurationURL
    }

    public func delete(projectID: String) throws -> AppConfiguration {
        guard projectID != ProjectCatalog.otherID else {
            throw TaskContextError.commandFailed("Other is the fallback project and cannot be deleted.")
        }
        // Discover the second lock target, then acquire both in the shared global order.
        // Re-read under those locks so a concurrent project edit cannot redirect deletion.
        let snapshot = try JSONDecoder().decode(AppConfiguration.self, from: Data(contentsOf: configurationURL))
        guard let candidate = snapshot.projects.first(where: { $0.id == projectID }) else {
            throw TaskContextError.commandFailed("The project no longer exists. Refresh and retry.")
        }
        let dashboard = URL(fileURLWithPath: candidate.dashboardPath).standardizedFileURL
        guard dashboard.resolvingSymlinksInPath() != configurationURL.resolvingSymlinksInPath() else {
            throw TaskContextError.commandFailed("The project dashboard points to the app configuration.")
        }
        return try FocusQueueFileLock.withLocks(for: [configurationURL, dashboard]) {
            let original = try Data(contentsOf: configurationURL)
            let current = try JSONDecoder().decode(AppConfiguration.self, from: original).validated()
            guard let project = current.projects.first(where: { $0.id == projectID }),
                  var raw = try JSONSerialization.jsonObject(with: original) as? [String: Any],
                  var projects = raw["focusQueueProjects"] as? [[String: Any]] else {
                throw TaskContextError.commandFailed("The project configuration changed. Refresh and retry.")
            }
            guard URL(fileURLWithPath: project.dashboardPath).standardizedFileURL == dashboard else {
                throw TaskContextError.commandFailed("The project changed during deletion. Refresh and retry.")
            }
            // A dashboard outside this project's private storage may be a repository file
            // or shared queue. Unregister it without touching its contents.
            let directory = try ProjectContextStore(root: supportDirectory)
                .planURL(projectID: projectID).deletingLastPathComponent()
            let privateDashboard = directory.appendingPathComponent("dashboard.json")
            let workspace = URL(fileURLWithPath: project.workspacePath).resolvingSymlinksInPath().path
            let repository = project.repositoryPath.isEmpty ? nil
                : URL(fileURLWithPath: project.repositoryPath).resolvingSymlinksInPath().path
            let resolved = dashboard.resolvingSymlinksInPath().path
            let ownsDashboard = dashboard == privateDashboard
                && resolved == privateDashboard.standardizedFileURL.path
                && resolved != workspace && !resolved.hasPrefix(workspace + "/")
                && repository.map { resolved != $0 && !resolved.hasPrefix($0 + "/") } != false
                && !current.projects.contains { $0.id != projectID
                    && URL(fileURLWithPath: $0.dashboardPath).resolvingSymlinksInPath().path == resolved }
            if FileManager.default.fileExists(atPath: dashboard.path) {
                let queue = try JSONDecoder().decode(DashboardDocument.self, from: Data(contentsOf: dashboard))
                guard !queue.tickets.contains(where: { $0.status.lowercased() == "in-progress" }) else {
                    throw TaskContextError.commandFailed("Finish active tasks before deleting this project, or archive it instead.")
                }
            }
            var next = current
            next.projects.removeAll { $0.id == projectID }
            if current.selectedProjectID == projectID {
                _ = next.selectProject(id: next.projects.first { $0.archivedAt == nil }?.id ?? ProjectCatalog.otherID)
            }
            _ = try next.validated()
            projects.removeAll { $0["id"] as? String == projectID }
            raw["focusQueueProjects"] = projects
            raw["focusQueueSelectedProjectID"] = next.selectedProjectID
            raw["dashboardPath"] = next.dashboardPath
            raw["workspacePath"] = next.workspacePath
            let updated = try JSONSerialization.data(withJSONObject: raw,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            // Keep the original queue in memory until configuration persistence succeeds.
            let savedDashboard = ownsDashboard && FileManager.default.fileExists(atPath: dashboard.path)
                ? try Data(contentsOf: dashboard) : nil
            if savedDashboard != nil { try FileManager.default.removeItem(at: dashboard) }
            do { try updated.write(to: configurationURL, options: .atomic) }
            catch {
                if let savedDashboard { try savedDashboard.write(to: dashboard, options: .atomic) }
                throw error
            }
            return try JSONDecoder().decode(AppConfiguration.self, from: updated).validated()
        }
    }
}
