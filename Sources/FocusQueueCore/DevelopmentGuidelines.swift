import Foundation

/// Planning-phase guidelines (KAI-016): one format, generator prompt, self-check,
/// and owner checklist per Planning file. Bundled in `Config/development-guidelines/`
/// and compiled in. Experimental: a project opts in with `planningGuidelines` in
/// development.json; with it off, nothing here reaches the tab, briefs, or CLI.
public enum DevelopmentGuidelines {
    /// The bundled set, installed read-only under the support directory so the
    /// viewer and agents read one stable path.
    public static let directoryName = "development-guidelines"
    public static let readmeName = "README.md"

    /// Catalog artifact → its guideline file.
    public static let artifactGuidelines: [String: String] = [
        "concept.md": "concept-guideline.md",
        "research.md": "research-guideline.md",
        "design.md": "design-guideline.md",
        "prd.md": "prd-guideline.md",
        "technical-design.md": "technical-design-guideline.md",
        "devplan.md": "devplan-guideline.md",
    ]
    /// Module design files have no fixed name: `modules/<id>-<slug>.md`.
    public static let moduleGuideline = "module-guideline.md"
    public static let moduleFilePattern = "modules/<id>-<slug>.md"

    public static var fileNames: [String] { DevelopmentGuidelineFiles.texts.keys.sorted() }

    public static func text(_ name: String) -> String? { DevelopmentGuidelineFiles.texts[name] }

    /// The README's shared conventions, which fill `{{CONVENTIONS}}` in every prompt.
    public static var conventions: String {
        text(readmeName).flatMap { textBlock(in: $0, after: "## Shared conventions") } ?? ""
    }

    /// A guideline's prompt block with `{{CONVENTIONS}}` filled; the other
    /// placeholders stay for the caller, per the guideline's Inputs table.
    public static func prompt(_ name: String) -> String? {
        guard name != readmeName, let text = text(name), let block = textBlock(in: text, after: "## Prompt")
        else { return nil }
        return block.replacingOccurrences(of: "{{CONVENTIONS}}", with: conventions)
    }

    static func textBlock(in text: String, after heading: String) -> String? {
        guard let section = text.range(of: "\n" + heading + "\n"),
              let open = text.range(of: "```text\n", range: section.upperBound..<text.endIndex),
              let close = text.range(of: "\n```", range: open.upperBound..<text.endIndex) else { return nil }
        return String(text[open.upperBound..<close.lowerBound])
    }

    /// Writes the bundled files where they are missing or differ, read-only, and
    /// returns the folder. The bundled text is the baseline; edits are replaced,
    /// since owner overrides are not built yet.
    @discardableResult
    public static func install(root: URL) throws -> URL {
        let directory = root.appendingPathComponent(directoryName)
        if (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw TaskContextError.commandFailed("The planning guideline folder is redirected.")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        for (name, text) in DevelopmentGuidelineFiles.texts {
            let url = directory.appendingPathComponent(name)
            if (try? String(contentsOf: url, encoding: .utf8)) == text { continue }
            try? FileManager.default.removeItem(at: url)
            try Data(text.utf8).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        }
        return directory
    }

    public static func url(_ name: String, root: URL) throws -> URL {
        try install(root: root).appendingPathComponent(name)
    }

    /// Whether a file is one of the installed bundled guidelines.
    public static func isInstalledGuideline(_ url: URL, root: URL) -> Bool {
        url.deletingLastPathComponent().standardizedFileURL
            == root.appendingPathComponent(directoryName).standardizedFileURL
            && text(url.lastPathComponent) != nil
    }

    /// A module's default design file: `modules/<id>-<slug>.md`.
    public static func moduleFile(id: String, name: String) -> String {
        let slug = String(name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" })
            .split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        return "modules/\(id.lowercased())-\(slug.isEmpty ? "module" : slug).md"
    }
}

extension DevelopmentStep {
    /// The guideline files for this step, in artifact order: one per artifact,
    /// plus the step's own (the module guideline has no fixed artifact).
    public func guidelines(includingGuidelineArtifacts: Bool = true) -> [String] {
        let artifacts = self.artifacts + (includingGuidelineArtifacts ? guidelineArtifacts : [])
        var names = artifacts.compactMap { DevelopmentGuidelines.artifactGuidelines[$0] }
        if let guideline, !names.contains(guideline) { names.append(guideline) }
        return names
    }
}

extension DevelopmentProcess {
    public var usesPlanningGuidelines: Bool { planningGuidelines == true }

    /// The step's documents: guideline-only documents (technical-design.md) appear
    /// only while the project uses planning guidelines.
    public func artifacts(of step: DevelopmentStep) -> [String] {
        step.artifacts + (usesPlanningGuidelines ? step.guidelineArtifacts : [])
    }

    /// The project's own file for a catalog document. Projects with older names map
    /// them in `artifactNames`, which applies only while guidelines are on.
    public func fileName(forArtifact artifact: String) -> String {
        guard usesPlanningGuidelines, let mapped = artifactNames?[artifact], !mapped.isEmpty else { return artifact }
        return mapped
    }

    /// The catalog document a project file stands for, through `artifactNames`.
    public func catalogArtifact(forFile name: String) -> String? {
        if usesPlanningGuidelines, let mapped = artifactNames?.first(where: { $0.value == name })?.key {
            return mapped
        }
        // A catalog name that is mapped elsewhere no longer names this project's document.
        if usesPlanningGuidelines, let mapped = artifactNames?[name], mapped != name { return nil }
        return DevelopmentProcessCatalog.step(forArtifact: name, includingGuidelineArtifacts: usesPlanningGuidelines) != nil
            ? name : nil
    }

    /// What a step's guidelines produce, as (guideline, project file) pairs.
    public func guidelineTargets(of step: DevelopmentStep, moduleID: String? = nil) -> [(guideline: String, file: String)] {
        guard usesPlanningGuidelines else { return [] }
        var pairs = artifacts(of: step).compactMap { artifact in
            DevelopmentGuidelines.artifactGuidelines[artifact].map { ($0, fileName(forArtifact: artifact)) }
        }
        if step.guideline == DevelopmentGuidelines.moduleGuideline {
            let file = moduleID.flatMap { id in modules.first { $0.id == id }?.file } ?? DevelopmentGuidelines.moduleFilePattern
            pairs.append((DevelopmentGuidelines.moduleGuideline, file))
        }
        return pairs
    }
}

extension DevelopmentProcessStore {
    public func setPlanningGuidelines(_ enabled: Bool, projectID: String) throws -> DevelopmentProcess {
        try mutate(projectID: projectID) { $0.planningGuidelines = enabled ? true : nil }
    }

    /// Maps a catalog document to the project's own file name; nil restores the catalog name.
    public func setArtifactName(_ file: String?, artifact: String, projectID: String) throws -> DevelopmentProcess {
        guard DevelopmentProcessCatalog.step(forArtifact: artifact, includingGuidelineArtifacts: true) != nil,
              AgentContractRole(fileName: artifact) == nil else {
            let names = DevelopmentGuidelines.artifactGuidelines.keys.sorted().joined(separator: ", ")
            throw TaskContextError.commandFailed("\(artifact) is not a Planning document that can be renamed. Use one of: \(names).")
        }
        let trimmed = file?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty {
            guard !trimmed.hasPrefix("/"), !trimmed.split(separator: "/").contains(".."),
                  trimmed.lowercased().hasSuffix(".md") else {
                throw TaskContextError.commandFailed("Use a Markdown file name inside the project folder, such as architecture.md.")
            }
        }
        return try mutate(projectID: projectID) { process in
            var names = process.artifactNames ?? [:]
            names[artifact] = trimmed.isEmpty || trimmed == artifact ? nil : trimmed
            process.artifactNames = names.isEmpty ? nil : names
        }
    }

    /// Registers a module with a stable `m<N>` ID and, unless one is given, the
    /// default design file `modules/<id>-<slug>.md`.
    public func registerModule(name: String, file: String?, projectID: String) throws -> (DevelopmentProcess, DevelopmentModule) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DevelopmentProcessError.unknownModule(name) }
        var added: DevelopmentModule?
        let process = try mutate(projectID: projectID) { process in
            guard !process.modules.contains(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) else {
                throw TaskContextError.commandFailed("A module named \(trimmed) already exists.")
            }
            var number = process.modules.count + 1
            while process.modules.contains(where: { $0.id == "m\(number)" }) { number += 1 }
            let id = "m\(number)"
            let given = file?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !given.isEmpty, given.hasPrefix("/") || given.split(separator: "/").contains("..") {
                throw TaskContextError.commandFailed("Use a module file inside the project folder, such as \(DevelopmentGuidelines.moduleFile(id: id, name: trimmed)).")
            }
            let module = DevelopmentModule(id: id, name: trimmed,
                file: given.isEmpty ? DevelopmentGuidelines.moduleFile(id: id, name: trimmed) : given)
            process.modules.append(module)
            added = module
        }
        return (process, added!)
    }
}
