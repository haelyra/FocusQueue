import Foundation
import Testing
@testable import FocusQueueCore

private struct ModuleFolderFixture {
    let root: URL
    let project: ProjectDefinition
    let projectDirectory: URL
    let repository: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("module-files-\(UUID().uuidString)")
        repository = root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        project = ProjectDefinition(id: "demo", name: "Demo", taskPrefix: "DEM", repositoryPath: repository.path)
        let support = root.appendingPathComponent("support", isDirectory: true)
        projectDirectory = try ProjectContextStore(root: support).ensurePlan(for: project).deletingLastPathComponent()
    }

    var store: DevelopmentProcessStore {
        DevelopmentProcessStore(root: root.appendingPathComponent("support", isDirectory: true))
    }

    func write(_ text: String, to relative: String, in base: URL) throws {
        let url = base.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func discover() -> [DevelopmentModuleFile] {
        DevelopmentModuleFiles.discover(projectDirectory: projectDirectory, repositoryPath: repository.path)
    }
}

@Test("Module files in the repository's docs/modules show with no registration")
func moduleFilesFromRepository() throws {
    let fixture = try ModuleFolderFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try fixture.write("""
    # M10: Analytics and token usage

    **Status:** Phase 0 contract, draft.

    ## 1. Purpose
    **Status:** not this one.
    """, to: "docs/modules/m10-analytics.md", in: fixture.repository)
    try fixture.write("# M2: PTY host (`pty`)\n\n**One line:** Owns native terminals.\n", to: "docs/modules/m2-pty-host.md", in: fixture.repository)
    try fixture.write("# Amendment proposals\n", to: "docs/modules/amendments.md", in: fixture.repository)
    try fixture.write("", to: "docs/modules/.gitkeep", in: fixture.repository)

    let files = fixture.discover()
    // Modules by number (2 before 10), then shared files; dotfiles never show.
    #expect(files.map(\.fileName) == ["m2-pty-host.md", "m10-analytics.md", "amendments.md"])
    #expect(files.map(\.moduleID) == ["m2", "m10", nil])
    #expect(files.allSatisfy { $0.location == .repository })
    #expect(files[0].title == "PTY host (`pty`)")
    #expect(files[0].displayTitle == "M2 · PTY host (`pty`)")
    #expect(files[0].oneLine == "Owns native terminals.")
    #expect(files[1].status == "Phase 0 contract, draft.")
    #expect(files[2].displayTitle == "Amendment proposals")
    #expect(!files[2].isModule)
}

@Test("The repository copy wins over the project folder's copy of the same file")
func repositoryCopyWins() throws {
    let fixture = try ModuleFolderFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try fixture.write("# M1: Repository copy\n", to: "docs/modules/m1-core.md", in: fixture.repository)
    try fixture.write("# M1: Project copy\n", to: "modules/m1-core.md", in: fixture.projectDirectory)
    try fixture.write("# M3: Project only\n", to: "modules/m3-store.md", in: fixture.projectDirectory)

    let files = fixture.discover()
    #expect(files.map(\.fileName) == ["m1-core.md", "m3-store.md"])
    #expect(files[0].title == "Repository copy")
    #expect(files[0].location == .repository && files[0].hasOtherCopy)
    #expect(files[1].location == .project && !files[1].hasOtherCopy)
    #expect(DevelopmentModuleFiles.primaryFolder(projectDirectory: fixture.projectDirectory,
                                                  repositoryPath: fixture.repository.path).path
            == fixture.repository.appendingPathComponent("docs/modules").path)
}

@Test("A project with no repository uses its own modules folder, and empty folders yield nothing")
func projectFolderOnly() throws {
    let fixture = try ModuleFolderFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    #expect(fixture.discover().isEmpty)
    #expect(DevelopmentModuleFiles.primaryFolder(projectDirectory: fixture.projectDirectory, repositoryPath: "").path
            == fixture.projectDirectory.appendingPathComponent("modules").path)
    try fixture.write("# M4: Store\n", to: "modules/m4-store.md", in: fixture.projectDirectory)
    let files = DevelopmentModuleFiles.discover(projectDirectory: fixture.projectDirectory, repositoryPath: "")
    #expect(files.map(\.fileName) == ["m4-store.md"])
    #expect(files.first?.location == .project)
}

@Test("Symbolic links in a module folder never show")
func symbolicLinksAreSkipped() throws {
    let fixture = try ModuleFolderFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try fixture.write("# Secret\n", to: "outside.md", in: fixture.root)
    try FileManager.default.createDirectory(at: fixture.projectDirectory.appendingPathComponent("modules"),
                                            withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
        at: fixture.projectDirectory.appendingPathComponent("modules/m9-link.md"),
        withDestinationURL: fixture.root.appendingPathComponent("outside.md"))
    #expect(fixture.discover().isEmpty)
}

@Test("Module IDs come from the file name, else from an M<n>: heading")
func moduleIDParsing() throws {
    #expect(DevelopmentModuleFiles.moduleID(fileName: "m6-context-scoped-data.md") == "m6")
    #expect(DevelopmentModuleFiles.moduleID(fileName: "M13_desktop.md") == "m13")
    #expect(DevelopmentModuleFiles.moduleID(fileName: "m007-x.md") == "m7")
    #expect(DevelopmentModuleFiles.moduleID(fileName: "modules.md") == nil)
    #expect(DevelopmentModuleFiles.moduleID(fileName: "m6-diagram.png") == nil)
    #expect(DevelopmentModuleFiles.splitModuleHeading("M6: Context") == ("Context", "m6"))
    #expect(DevelopmentModuleFiles.splitModuleHeading("Migration plan") == ("Migration plan", nil))

    let fixture = try ModuleFolderFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try fixture.write("# M5: Scheduler\n", to: "modules/scheduler.md", in: fixture.projectDirectory)
    #expect(fixture.discover().first?.moduleID == "m5")
}

@Test("A registered module's file resolves to the repository copy, then the project folder")
func registeredModuleFileResolves() throws {
    let fixture = try ModuleFolderFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    func resolve(_ file: String?) -> String? {
        DevelopmentModuleFiles.resolve(file, projectDirectory: fixture.projectDirectory,
                                       repositoryPath: fixture.repository.path)?.path
    }
    #expect(resolve("modules/m1-core.md") == nil)
    try fixture.write("# M1: Project\n", to: "modules/m1-core.md", in: fixture.projectDirectory)
    #expect(resolve("modules/m1-core.md") == fixture.projectDirectory.appendingPathComponent("modules/m1-core.md").path)
    try fixture.write("# M1: Repository\n", to: "docs/modules/m1-core.md", in: fixture.repository)
    #expect(resolve("modules/m1-core.md") == fixture.repository.appendingPathComponent("docs/modules/m1-core.md").path)
    #expect(resolve("../m1-core.md") == nil)
    #expect(resolve("/etc/hosts") == nil)
    #expect(resolve(nil) == nil)
}

@Test("Tracking a module file keeps its ID, records modules/<file>, and is idempotent")
func trackModuleFile() throws {
    let fixture = try ModuleFolderFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try fixture.write("# M6: Context storage\n", to: "docs/modules/m6-context.md", in: fixture.repository)
    try fixture.write("# M2: PTY host\n", to: "docs/modules/m2-pty.md", in: fixture.repository)
    try fixture.write("# Review log\n", to: "docs/modules/review-log.md", in: fixture.repository)
    let files = fixture.discover()
    let store = fixture.store

    var process = try store.trackModuleFile(files[1], projectID: fixture.project.id)
    process = try store.trackModuleFile(files[0], projectID: fixture.project.id)
    // Tracked in click order, which sets the sequential review order.
    #expect(process.modules.map(\.id) == ["m6", "m2"])
    #expect(process.modules.map(\.name) == ["Context storage", "PTY host"])
    #expect(process.modules.map(\.file) == ["modules/m6-context.md", "modules/m2-pty.md"])
    let again = try store.trackModuleFile(files[1], projectID: fixture.project.id)
    #expect(again.modules.count == 2)
    #expect(DevelopmentModuleFiles.module(for: files[0], in: again.modules)?.id == "m2")
    #expect(throws: TaskContextError.self) { try store.trackModuleFile(files[2], projectID: fixture.project.id) }
    // A tracked file opens the repository copy.
    #expect(DevelopmentModuleFiles.resolve(again.modules[0].file, projectDirectory: fixture.projectDirectory,
                                           repositoryPath: fixture.repository.path)?.path
            == fixture.repository.appendingPathComponent("docs/modules/m6-context.md").path)
}

@Test("Tracking picks a free ID when the file's ID is taken by another module")
func trackModuleFileAvoidsIDCollision() throws {
    let fixture = try ModuleFolderFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let store = fixture.store
    _ = try store.mutate(projectID: fixture.project.id) {
        $0.modules = [DevelopmentModule(id: "m1", name: "Older", file: "modules/m1-older.md")]
    }
    try fixture.write("# M1: Newer\n", to: "modules/m1-newer.md", in: fixture.projectDirectory)
    let file = try #require(fixture.discover().first { $0.fileName == "m1-newer.md" })
    let process = try store.trackModuleFile(file, projectID: fixture.project.id)
    #expect(process.modules.map(\.id) == ["m1", "m2"])
    #expect(process.modules.last?.file == "modules/m1-newer.md")
}
