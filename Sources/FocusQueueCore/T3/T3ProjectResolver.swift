import Foundation

/// Maps a Focus Queue project to its T3 Code project on one server, registering it when needed.
public actor T3ProjectResolver {
    private let tools: any T3ToolCalling
    private let stateStore: T3ConnectionStateStore
    private let serverURL: String

    public init(tools: any T3ToolCalling, stateStore: T3ConnectionStateStore, serverURL: String) {
        self.tools = tools
        self.stateStore = stateStore
        self.serverURL = serverURL
    }

    /// The T3 project id for `project` on the server identified by `environmentId`:
    /// the saved mapping, else the project whose `workspaceRoot` is the repository, else a new project.
    public func projectId(for project: ProjectConfiguration, environmentId: String) async throws -> String {
        if let saved = try stateStore.load()?.projectMaps[environmentId]?[project.id] {
            return saved
        }
        let id: String
        if let match = try await matchingProjectId(repositoryPath: project.repositoryPath) {
            id = match
        } else {
            do {
                id = try await tools.createProject(path: project.repositoryPath, title: project.name).id
            } catch T3Error.projectAlreadyRegistered {
                guard let match = try await matchingProjectId(repositoryPath: project.repositoryPath) else {
                    throw T3Error.projectAlreadyRegistered
                }
                id = match
            }
        }
        try stateStore.update(serverURL: serverURL) { state in
            state.projectMaps[environmentId, default: [:]][project.id] = id
        }
        return id
    }

    private func matchingProjectId(repositoryPath: String) async throws -> String? {
        let target = T3Paths.canonical(repositoryPath)
        return try await tools.listProjects()
            .first { T3Paths.canonical($0.workspaceRoot) == target }?.id
    }
}
