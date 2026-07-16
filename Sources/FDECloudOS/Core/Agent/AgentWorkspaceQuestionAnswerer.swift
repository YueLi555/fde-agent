import Foundation

struct AgentWorkspaceQuestionEvidence: Hashable, Sendable {
    var toolName: String
    var targetPath: String
    var actualResult: String
    var success: Bool
    var error: String?
}

struct AgentWorkspaceQuestionAnswer: Hashable, Sendable {
    var content: String
    var evidence: [AgentWorkspaceQuestionEvidence]
}

protocol AgentWorkspaceQuestionAnswering: Sendable {
    func answer(input: String, intent: MissionIntent, workspace: Workspace) async -> AgentWorkspaceQuestionAnswer
}

struct LocalWorkspaceQuestionAnswerer: AgentWorkspaceQuestionAnswering {
    func answer(input: String, intent: MissionIntent, workspace: Workspace) async -> AgentWorkspaceQuestionAnswer {
        let roots = workspaceRoots(for: workspace)
        let usesChinese = intent.detectedLanguage == "zh" || containsCJK(input)
        guard !roots.isEmpty else {
            return AgentWorkspaceQuestionAnswer(
                content: usesChinese
                    ? "我还没有连接到项目目录。请选择工作区项目后，我可以读取真实文件再回答。"
                    : "No project directory is connected yet. Choose a workspace project and I can answer from real files.",
                evidence: [
                    AgentWorkspaceQuestionEvidence(
                        toolName: "workspace.scope",
                        targetPath: "",
                        actualResult: "No local project root is configured.",
                        success: false,
                        error: "missing_project_root"
                    )
                ]
            )
        }

        var evidence: [AgentWorkspaceQuestionEvidence] = []
        var models: [(label: String, root: String, model: CodebaseModel)] = []
        for root in roots {
            do {
                let model = try CodebaseIntelligence(maxFiles: 5_000).discover(rootPath: root.path)
                models.append((root.label, root.path, model))
                evidence.append(
                    AgentWorkspaceQuestionEvidence(
                        toolName: "CodebaseIntelligence.discover",
                        targetPath: root.path,
                        actualResult: model.evidence.result,
                        success: true,
                        error: nil
                    )
                )
            } catch {
                evidence.append(
                    AgentWorkspaceQuestionEvidence(
                        toolName: "CodebaseIntelligence.discover",
                        targetPath: root.path,
                        actualResult: "",
                        success: false,
                        error: error.localizedDescription
                    )
                )
            }
        }

        let normalized = input.lowercased()
        if asksForTestFiles(normalized) {
            return testFilesAnswer(models: models, evidence: evidence, usesChinese: usesChinese)
        }

        if let targetPath = explicitPath(in: input),
           let fileAnswer = readFileAnswer(
               targetPath: targetPath,
               models: models,
               evidence: &evidence,
               usesChinese: usesChinese
           ) {
            return fileAnswer
        }

        if asksWhyTestsFailed(normalized) {
            return testFailureQuestionAnswer(models: models, evidence: evidence, usesChinese: usesChinese)
        }

        return projectSummaryAnswer(models: models, evidence: evidence, usesChinese: usesChinese)
    }

    private func workspaceRoots(for workspace: Workspace) -> [(label: String, path: String)] {
        var seen = Set<String>()
        return [
            ("Legacy project", workspace.localProjectRoot),
            ("Agent project", workspace.localAgentProjectRoot)
        ].compactMap { item -> (String, String)? in
            let label = item.0
            let path = item.1
            guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
                return nil
            }
            let normalized = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
            guard seen.insert(normalized).inserted else { return nil }
            return (label, normalized)
        }
    }

    private func testFilesAnswer(
        models: [(label: String, root: String, model: CodebaseModel)],
        evidence: [AgentWorkspaceQuestionEvidence],
        usesChinese: Bool
    ) -> AgentWorkspaceQuestionAnswer {
        let files = models.flatMap { item in
            item.model.files
                .filter(isTestFile)
                .map { file in
                    models.count == 1 ? file.path : "\(item.label): \(file.path)"
                }
        }
        let uniqueFiles = unique(files)

        let content: String
        if uniqueFiles.isEmpty {
            content = usesChinese
                ? "我已读取当前项目文件索引，没有发现测试文件。"
                : "I inspected the current project file index and did not find test files."
        } else {
            let lines = uniqueFiles.map { "- \($0)" }.joined(separator: "\n")
            content = usesChinese
                ? "我已读取当前项目文件索引，发现这些测试文件：\n\(lines)"
                : "I inspected the current project file index and found these test files:\n\(lines)"
        }

        return AgentWorkspaceQuestionAnswer(content: content, evidence: evidence)
    }

    private func readFileAnswer(
        targetPath: String,
        models: [(label: String, root: String, model: CodebaseModel)],
        evidence: inout [AgentWorkspaceQuestionEvidence],
        usesChinese: Bool
    ) -> AgentWorkspaceQuestionAnswer? {
        guard let match = resolveFile(targetPath, in: models) else {
            evidence.append(
                AgentWorkspaceQuestionEvidence(
                    toolName: "CodebaseIntelligence.search",
                    targetPath: targetPath,
                    actualResult: "No repository-relative path or unique basename matched \(targetPath).",
                    success: false,
                    error: "file_not_found"
                )
            )
            return AgentWorkspaceQuestionAnswer(
                content: usesChinese
                    ? "我搜索了已连接项目，但没有找到与 `\(targetPath)` 匹配的文件。请提供更完整的相对路径。"
                    : "I searched the connected projects but could not find a file matching `\(targetPath)`. Please provide a more complete relative path.",
                evidence: evidence
            )
        }

        evidence.append(
            AgentWorkspaceQuestionEvidence(
                toolName: "CodebaseIntelligence.search",
                targetPath: targetPath,
                actualResult: "Resolved \(targetPath) to \(match.file.path).",
                success: true,
                error: nil
            )
        )

        let rootURL = URL(fileURLWithPath: match.root, isDirectory: true).standardizedFileURL
        let fileURL = rootURL.appendingPathComponent(match.file.path).standardizedFileURL
        guard fileURL.path == rootURL.path || fileURL.path.hasPrefix(rootURL.path + "/") else {
            evidence.append(
                AgentWorkspaceQuestionEvidence(
                    toolName: "FileManager.readFile",
                    targetPath: match.file.path,
                    actualResult: "",
                    success: false,
                    error: "Path is outside workspace root."
                )
            )
            return AgentWorkspaceQuestionAnswer(
                content: usesChinese
                    ? "我找到了 `\(match.file.path)`，但它解析到了工作区范围之外，因此没有读取。"
                    : "I found `\(match.file.path)`, but it resolved outside the workspace boundary, so I did not read it.",
                evidence: evidence
            )
        }

        do {
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            let declarations = declarationNames(in: content)
            evidence.append(
                AgentWorkspaceQuestionEvidence(
                    toolName: "FileManager.readFile",
                    targetPath: fileURL.path,
                    actualResult: readEvidenceSummary(
                        path: match.file.path,
                        characterCount: content.count,
                        declarations: declarations
                    ),
                    success: true,
                    error: nil
                )
            )
            return AgentWorkspaceQuestionAnswer(
                content: responsibilityAnswer(
                    path: match.file.path,
                    content: content,
                    declarations: declarations,
                    usesChinese: usesChinese
                ),
                evidence: evidence
            )
        } catch {
            evidence.append(
                AgentWorkspaceQuestionEvidence(
                    toolName: "FileManager.readFile",
                    targetPath: fileURL.path,
                    actualResult: "",
                    success: false,
                    error: error.localizedDescription
                )
            )
            return AgentWorkspaceQuestionAnswer(
                content: usesChinese
                    ? "我找到了 `\(match.file.path)`，但读取失败：\(error.localizedDescription)"
                    : "I found `\(match.file.path)`, but reading it failed: \(error.localizedDescription)",
                evidence: evidence
            )
        }
    }

    private func resolveFile(
        _ requestedPath: String,
        in models: [(label: String, root: String, model: CodebaseModel)]
    ) -> (label: String, root: String, file: CodebaseFile)? {
        let requested = requestedPath
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
        guard !requested.isEmpty else { return nil }

        let candidates: [(label: String, root: String, file: CodebaseFile, rank: Int)] = models.flatMap { item in
            item.model.files.compactMap { file in
                let path = file.path.replacingOccurrences(of: "\\", with: "/").lowercased()
                let basename = URL(fileURLWithPath: path).lastPathComponent
                let rank: Int
                if path == requested {
                    rank = 0
                } else if path.hasSuffix("/" + requested) {
                    rank = 1
                } else if basename == requested {
                    rank = 2
                } else {
                    return nil
                }
                return (item.label, item.root, file, rank)
            }
        }
        return candidates
            .sorted { lhs, rhs in
                if lhs.rank == rhs.rank {
                    return lhs.file.path.count < rhs.file.path.count
                }
                return lhs.rank < rhs.rank
            }
            .first
            .map { ($0.label, $0.root, $0.file) }
    }

    private func declarationNames(in content: String) -> [String] {
        guard let expression = try? NSRegularExpression(
            pattern: #"\b(?:struct|class|enum|protocol|actor)\s+([A-Za-z_][A-Za-z0-9_]*)"#
        ) else {
            return []
        }
        let range = NSRange(content.startIndex..<content.endIndex, in: content)
        return unique(
            expression.matches(in: content, range: range).compactMap { match in
                guard let nameRange = Range(match.range(at: 1), in: content) else { return nil }
                return String(content[nameRange])
            }
        )
    }

    private func readEvidenceSummary(
        path: String,
        characterCount: Int,
        declarations: [String]
    ) -> String {
        let declarationSummary = declarations.isEmpty
            ? "No type declarations were detected."
            : "Declarations: \(declarations.prefix(8).joined(separator: ", "))."
        return "Read \(characterCount) characters from \(path). \(declarationSummary)"
    }

    private func responsibilityAnswer(
        path: String,
        content: String,
        declarations: [String],
        usesChinese: Bool
    ) -> String {
        if content.contains("struct AgentConversationView: View") {
            var responsibilities: [String] = []
            responsibilities.append(
                usesChinese
                    ? "定义对话区的 SwiftUI 根视图，并按时间顺序呈现用户消息和 Agent 回复。"
                    : "Defines the root SwiftUI view for the conversation area and renders user and agent turns in order."
            )
            if content.contains("AgentConversationWorkUnitAdapter.displayItems") {
                responsibilities.append(
                    usesChinese
                        ? "把保存的对话消息与真实运行事件交给 `AgentConversationWorkUnitAdapter`，生成可展示的消息或流式回复。"
                        : "Projects stored conversation messages and real runtime events through `AgentConversationWorkUnitAdapter` into display messages or streaming responses."
                )
            }
            if content.contains("AgentConversationWorkUnitAdapter.workStatusCards") {
                responsibilities.append(
                    usesChinese
                        ? "根据同一批运行事件生成 Work Status 卡片；它只负责展示投影结果，不执行任务。"
                        : "Builds the Work Status cards from the same runtime events; it presents projected state but does not execute the task."
                )
            }
            if content.contains("AgentConversationApprovalView") || content.contains("onApprove") {
                responsibilities.append(
                    usesChinese
                        ? "展示待审批动作，并把批准、拒绝和选项选择回传给上层控制器。"
                        : "Surfaces pending approvals and forwards approve, reject, and option-selection actions to the parent controller."
                )
            }
            let bullets = responsibilities.map { "- \($0)" }.joined(separator: "\n")
            let evidenceLine = declarations.isEmpty
                ? ""
                : (usesChinese
                    ? "\n\n文件中识别到的主要类型包括：`\(declarations.prefix(8).joined(separator: "`、`"))`。"
                    : "\n\nThe main declarations I found include `\(declarations.prefix(8).joined(separator: "`, `"))`.")
            return usesChinese
                ? "我实际读取了 `\(path)`。它的主要职责是：\n\(bullets)\(evidenceLine)"
                : "I read `\(path)`. Its main responsibilities are:\n\(bullets)\(evidenceLine)"
        }

        let isSwiftUIView = content.contains("import SwiftUI")
            && (content.contains(": View") || content.contains("var body: some View"))
        let declarationText = declarations.isEmpty
            ? (usesChinese ? "没有识别到顶层类型声明" : "no top-level type declarations were detected")
            : (usesChinese
                ? "主要声明：`\(declarations.prefix(8).joined(separator: "`、`"))`"
                : "main declarations: `\(declarations.prefix(8).joined(separator: "`, `"))`")
        if usesChinese {
            let role = isSwiftUIView
                ? "这是一个 SwiftUI 展示文件，负责组合视图状态、内容和用户交互。"
                : "这个文件主要定义并组织其中的类型与相关逻辑。"
            return "我实际读取了 `\(path)`。\(role)从文件内容提取到的依据是：\(declarationText)。"
        }
        let role = isSwiftUIView
            ? "It is a SwiftUI presentation file that composes view state, content, and user interactions."
            : "It primarily defines and organizes the types and logic declared in the file."
        return "I read `\(path)`. \(role) Evidence from the file: \(declarationText)."
    }

    private func testFailureQuestionAnswer(
        models: [(label: String, root: String, model: CodebaseModel)],
        evidence: [AgentWorkspaceQuestionEvidence],
        usesChinese: Bool
    ) -> AgentWorkspaceQuestionAnswer {
        let tests = models.flatMap { item in
            item.model.files.filter(isTestFile).prefix(12).map { file in
                models.count == 1 ? file.path : "\(item.label): \(file.path)"
            }
        }
        let testList = tests.isEmpty
            ? (usesChinese ? "我没有发现测试文件。" : "I did not find test files.")
            : unique(tests).map { "- \($0)" }.joined(separator: "\n")
        let content = usesChinese
            ? "我已检查项目文件，但当前对话里没有真实测试输出，所以不能断言失败原因。相关测试文件包括：\n\(testList)\n\n如果你要我判断失败原因，请明确要求运行测试。"
            : "I inspected the project files, but this conversation does not include real test output, so I cannot state a failure cause yet. Relevant test files include:\n\(testList)\n\nAsk me to run the tests if you want execution-backed failure analysis."
        return AgentWorkspaceQuestionAnswer(content: content, evidence: evidence)
    }

    private func projectSummaryAnswer(
        models: [(label: String, root: String, model: CodebaseModel)],
        evidence: [AgentWorkspaceQuestionEvidence],
        usesChinese: Bool
    ) -> AgentWorkspaceQuestionAnswer {
        let summaries = models.map { item in
            let testCount = item.model.files.filter(isTestFile).count
            let sourceCount = item.model.files.count - testCount
            if usesChinese {
                return "\(item.label)：\(item.model.repositoryKind.rawValue)，\(item.model.files.count) 个文件，\(sourceCount) 个非测试文件，\(testCount) 个测试文件。"
            }
            return "\(item.label): \(item.model.repositoryKind.rawValue), \(item.model.files.count) files, \(sourceCount) non-test files, \(testCount) test files."
        }
        let content = summaries.isEmpty
            ? (usesChinese ? "我没有读到可用的项目文件。" : "I did not read any usable project files.")
            : summaries.joined(separator: "\n")
        return AgentWorkspaceQuestionAnswer(content: content, evidence: evidence)
    }

    private func asksForTestFiles(_ normalized: String) -> Bool {
        let asksForFiles = normalized.contains("test file")
            || normalized.contains("tests file")
            || normalized.contains("测试文件")
            || normalized.contains("有哪些测试")
            || normalized.contains("list tests")
            || normalized.contains("list test")
        let asksToRun = normalized.contains("run test")
            || normalized.contains("运行测试")
            || normalized.contains("跑测试")
        return asksForFiles && !asksToRun
    }

    private func asksWhyTestsFailed(_ normalized: String) -> Bool {
        (normalized.contains("why") || normalized.contains("为什么"))
            && (normalized.contains("test") || normalized.contains("测试"))
            && (normalized.contains("fail") || normalized.contains("失败"))
    }

    private func isTestFile(_ file: CodebaseFile) -> Bool {
        if file.isTest { return true }
        let path = file.path.lowercased()
        return path.contains("/tests/")
            || path.hasPrefix("tests/")
            || path.contains("test.")
            || path.contains("tests.")
            || path.contains("spec.")
            || path.hasSuffix("test.swift")
            || path.hasSuffix("tests.swift")
            || path.hasSuffix("spec.ts")
            || path.hasSuffix("spec.js")
    }

    private func explicitPath(in input: String) -> String? {
        let delimiters = CharacterSet.whitespacesAndNewlines.union(.init(charactersIn: "`'\"，。！？,;:()[]{}<>"))
        return input.components(separatedBy: delimiters)
            .map { $0.trimmingCharacters(in: delimiters) }
            .first { token in
                token.contains("/")
                    || token.hasSuffix(".swift")
                    || token.hasSuffix(".ts")
                    || token.hasSuffix(".tsx")
                    || token.hasSuffix(".js")
                    || token.hasSuffix(".jsx")
                    || token.hasSuffix(".py")
                    || token.hasSuffix(".md")
                    || token.hasSuffix(".json")
            }
    }

    private func containsCJK(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(Int(scalar.value))
        }
    }

    private func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}
