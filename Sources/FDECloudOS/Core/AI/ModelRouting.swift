import Foundation
import OSLog

enum LLMNarrationDebugLog {
    private static let logger = Logger(subsystem: "FDECloudOS", category: "LLMNarration")

    static func write(_ message: @autoclosure () -> String) {
        let value = message()
        logger.debug("\(value, privacy: .public)")
    }
}

enum ModelProviderKind: String, Codable, Sendable {
    case openAI = "OpenAI"
    case claude = "Claude"
    case local = "Local"
}

enum ModelReasoningRole: String, Codable, Sendable {
    case planning = "planning"
    case execution = "execution"
    case recovery = "recovery"
    case policy = "policy"
}

struct ModelProviderState: Codable, Hashable, Sendable {
    var provider: String
    var liveProvider: Bool
    var enabled: Bool
    var reason: String
}

struct ModelProviderDiagnostics: Codable, Hashable, Sendable {
    var activeProvider: String
    var fallbackReason: String
    var lastValidationResult: String
    var lastLatencyMilliseconds: Double?
    var liveProviderStates: [ModelProviderState]
    var updatedAt: Date

    static func initial(providers: [any ModelProvider]) -> ModelProviderDiagnostics {
        ModelProviderDiagnostics(
            activeProvider: "Local",
            fallbackReason: "No routing attempt yet",
            lastValidationResult: "not run",
            lastLatencyMilliseconds: nil,
            liveProviderStates: providers.map { provider in
                ModelProviderState(
                    provider: provider.kind.rawValue,
                    liveProvider: provider.isLiveProvider,
                    enabled: provider.isAvailable,
                    reason: provider.disabledReason ?? "enabled"
                )
            },
            updatedAt: Date()
        )
    }
}

actor ModelProviderDiagnosticsStore {
    private var current: ModelProviderDiagnostics

    init(initial: ModelProviderDiagnostics = ModelProviderDiagnostics(
        activeProvider: "Local",
        fallbackReason: "No routing attempt yet",
        lastValidationResult: "not run",
        lastLatencyMilliseconds: nil,
        liveProviderStates: [],
        updatedAt: Date()
    )) {
        self.current = initial
    }

    func update(_ diagnostics: ModelProviderDiagnostics) {
        current = diagnostics
    }

    func snapshot() -> ModelProviderDiagnostics {
        current
    }
}

protocol ModelProvider: Sendable {
    var kind: ModelProviderKind { get }
    var isAvailable: Bool { get }
    var isLiveProvider: Bool { get }
    var disabledReason: String? { get }
    func generateDecision(prompt: CompiledPrompt, context: ExecutionContext) async throws -> StructuredAgentOutput
    func generateReadOnlyNextAction(prompt: CompiledPrompt, context: ExecutionContext) async throws -> ReadOnlyNextAction
    func generatePlan(for input: String, context: ExecutionContext) async throws -> StructuredAgentOutput
    func reasonAboutExecution(for input: String, context: ExecutionContext) async throws -> StructuredAgentOutput
    func reasonAboutRecovery(for input: String, context: ExecutionContext) async throws -> StructuredAgentOutput
    func reasonAboutPolicy(for input: String, context: ExecutionContext) async throws -> StructuredAgentOutput
}

protocol AgentNarrationProviding: Sendable {
    var kind: ModelProviderKind { get }
    var isAvailable: Bool { get }
    var disabledReason: String? { get }
    func generateNarration(for request: AgentNarrationRequest) async throws -> AgentNarration
}

extension ModelProvider {
    var isLiveProvider: Bool {
        kind != .local
    }

    var disabledReason: String? {
        isAvailable ? nil : "\(kind.rawValue) provider is not configured"
    }

    func generateDecision(prompt: CompiledPrompt, context: ExecutionContext) async throws -> StructuredAgentOutput {
        try await generatePlan(for: prompt.userPrompt, context: context)
    }

    func generateReadOnlyNextAction(prompt: CompiledPrompt, context: ExecutionContext) async throws -> ReadOnlyNextAction {
        ReadOnlyNextAction(legacyOutput: try await generateDecision(prompt: prompt, context: context))
    }

    func reasonAboutExecution(for input: String, context: ExecutionContext) async throws -> StructuredAgentOutput {
        try await generatePlan(for: input, context: context)
    }

    func reasonAboutRecovery(for input: String, context: ExecutionContext) async throws -> StructuredAgentOutput {
        try await generatePlan(for: input, context: context)
    }

    func reasonAboutPolicy(for input: String, context: ExecutionContext) async throws -> StructuredAgentOutput {
        try await generatePlan(for: input, context: context)
    }
}

protocol ModelRouting: Sendable {
    func generatePlan(for input: String, context: ExecutionContext) async throws -> StructuredAgentOutput
    func generateDecision(prompt: CompiledPrompt, context: ExecutionContext) async throws -> StructuredAgentOutput
    func generateReadOnlyNextAction(prompt: CompiledPrompt, context: ExecutionContext) async throws -> ReadOnlyNextAction
}

extension ModelRouting {
    func generateDecision(prompt: CompiledPrompt, context: ExecutionContext) async throws -> StructuredAgentOutput {
        try await generatePlan(for: prompt.userPrompt, context: context)
    }

    func generateReadOnlyNextAction(prompt: CompiledPrompt, context: ExecutionContext) async throws -> ReadOnlyNextAction {
        ReadOnlyNextAction(legacyOutput: try await generateDecision(prompt: prompt, context: context))
    }
}

enum ModelRoutingError: LocalizedError, Equatable, Sendable {
    case providerUnavailable(String)
    case providerRequestFailed(String)
    case providerOutputInvalid(String)

    var diagnosticReason: String {
        switch self {
        case .providerUnavailable: "provider_unavailable"
        case .providerRequestFailed: "provider_request_failed"
        case .providerOutputInvalid: "provider_output_invalid"
        }
    }

    static func classified(_ error: Error) -> ModelRoutingError {
        if let providerFailure = error as? ModelProviderFailure {
            return providerFailure.routingError
        }
        if let routing = error as? ModelRoutingError { return routing }
        if error is StructuredOutputSchemaError || error is DecodingError {
            return .providerOutputInvalid(error.localizedDescription)
        }
        return .providerRequestFailed(error.localizedDescription)
    }

    var errorDescription: String? {
        switch self {
        case .providerUnavailable(let detail):
            return "No model provider is available: \(detail)"
        case .providerRequestFailed(let detail):
            return "Model provider request failed: \(detail)"
        case .providerOutputInvalid(let detail):
            return "Model provider output was invalid: \(detail)"
        }
    }
}

struct ModelProviderFailure: LocalizedError, Equatable, Sendable {
    var routingError: ModelRoutingError
    var provider: ModelProviderKind
    var model: String
    var failurePhase: String
    var httpStatus: Int?
    var safeErrorCode: String
    var safeErrorType: String
    var durationMilliseconds: Int
    var requestPayloadBytes: Int
    var responsePayloadBytes: Int
    var responseDecodeFailed: Bool
    var responseSchemaValidationFailed: Bool
    var retryable: Bool
    var attempts: Int = 1

    var errorDescription: String? { routingError.localizedDescription }

    var auditPayload: [String: String] {
        [
            "provider": provider.rawValue,
            "model": model,
            "provider_failure_phase": failurePhase,
            "http_status": httpStatus.map(String.init) ?? "",
            "provider_error_code": safeErrorCode,
            "provider_error_type": safeErrorType,
            "provider_duration_ms": String(durationMilliseconds),
            "provider_request_bytes": String(requestPayloadBytes),
            "provider_response_bytes": String(responsePayloadBytes),
            "response_decode_failed": responseDecodeFailed ? "true" : "false",
            "response_schema_validation_failed": responseSchemaValidationFailed ? "true" : "false",
            "retryable": retryable ? "true" : "false",
            "provider_attempts": String(attempts)
        ]
    }

    static func transport(
        _ error: Error,
        provider: ModelProviderKind,
        model: String,
        startedAt: Date,
        requestPayloadBytes: Int
    ) -> ModelProviderFailure {
        let nsError = error as NSError
        let urlError = error as? URLError
        let code: String
        let retryable: Bool
        if let urlError {
            code = "url_error_\(safeURLCode(urlError.code))"
            retryable = retryableURLCodes.contains(urlError.code)
        } else {
            code = nsError.domain == NSURLErrorDomain
                ? "url_error_\(nsError.code)"
                : "transport_error"
            retryable = false
        }
        return ModelProviderFailure(
            routingError: .providerRequestFailed(safeTransportDetail(error)),
            provider: provider,
            model: model,
            failurePhase: urlError?.code == .timedOut ? "timeout" : "transport",
            httpStatus: nil,
            safeErrorCode: code,
            safeErrorType: urlError?.code == .timedOut ? "timeout" : "transport",
            durationMilliseconds: elapsedMilliseconds(since: startedAt),
            requestPayloadBytes: requestPayloadBytes,
            responsePayloadBytes: 0,
            responseDecodeFailed: false,
            responseSchemaValidationFailed: false,
            retryable: retryable
        )
    }

    static func http(
        _ error: Error,
        provider: ModelProviderKind,
        model: String,
        response: HTTPURLResponse,
        startedAt: Date,
        requestPayloadBytes: Int,
        responsePayloadBytes: Int
    ) -> ModelProviderFailure {
        let retryable = response.statusCode == 408
            || response.statusCode == 429
            || (500..<600).contains(response.statusCode)
        return ModelProviderFailure(
            routingError: ModelRoutingError.classified(error),
            provider: provider,
            model: model,
            failurePhase: "http",
            httpStatus: response.statusCode,
            safeErrorCode: "http_\(response.statusCode)",
            safeErrorType: "http_error",
            durationMilliseconds: elapsedMilliseconds(since: startedAt),
            requestPayloadBytes: requestPayloadBytes,
            responsePayloadBytes: responsePayloadBytes,
            responseDecodeFailed: false,
            responseSchemaValidationFailed: false,
            retryable: retryable
        )
    }

    static func response(
        _ error: Error,
        provider: ModelProviderKind,
        model: String,
        response: HTTPURLResponse,
        startedAt: Date,
        requestPayloadBytes: Int,
        responsePayloadBytes: Int
    ) -> ModelProviderFailure {
        let schemaFailure = error is StructuredOutputSchemaError
            || error is StructuredOutputError
            || error is DecodingError
        return ModelProviderFailure(
            routingError: .providerOutputInvalid(error.localizedDescription),
            provider: provider,
            model: model,
            failurePhase: schemaFailure ? "response_schema_validation" : "response_decode",
            httpStatus: response.statusCode,
            safeErrorCode: schemaFailure ? "response_schema_invalid" : "response_decode_failed",
            safeErrorType: schemaFailure ? "schema_validation" : "response_decode",
            durationMilliseconds: elapsedMilliseconds(since: startedAt),
            requestPayloadBytes: requestPayloadBytes,
            responsePayloadBytes: responsePayloadBytes,
            responseDecodeFailed: !schemaFailure,
            responseSchemaValidationFailed: schemaFailure,
            retryable: false
        )
    }

    private static let retryableURLCodes: Set<URLError.Code> = [
        .timedOut,
        .cannotFindHost,
        .cannotConnectToHost,
        .networkConnectionLost,
        .dnsLookupFailed,
        .notConnectedToInternet,
        .resourceUnavailable
    ]

    private static func safeURLCode(_ code: URLError.Code) -> String {
        switch code {
        case .timedOut: "timed_out"
        case .cannotFindHost: "cannot_find_host"
        case .cannotConnectToHost: "cannot_connect_to_host"
        case .networkConnectionLost: "network_connection_lost"
        case .dnsLookupFailed: "dns_lookup_failed"
        case .notConnectedToInternet: "not_connected_to_internet"
        case .resourceUnavailable: "resource_unavailable"
        case .cancelled: "cancelled"
        default: String(code.rawValue)
        }
    }

    private static func safeTransportDetail(_ error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .networkConnectionLost:
                return "The provider connection was lost before an HTTP response was received."
            case .timedOut:
                return "The provider request timed out before a response was received."
            case .notConnectedToInternet:
                return "The provider request could not start because the network is unavailable."
            default:
                return "The provider transport failed before an HTTP response was received."
            }
        }
        return "The provider transport failed before an HTTP response was received."
    }

    private static func elapsedMilliseconds(since date: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(date) * 1_000))
    }
}

struct ModelRouter: ModelRouting {
    private let providers: [any ModelProvider]
    private let validator: any StructuredOutputValidating
    private let diagnosticsStore: ModelProviderDiagnosticsStore?
    private let contextDiagnosticsStore: ContextCompilerDiagnosticsStore?
    private static let logger = Logger(subsystem: "FDECloudOS", category: "ModelRouting")

    init(
        providers: [any ModelProvider],
        validator: any StructuredOutputValidating = StructuredOutputValidator(),
        diagnosticsStore: ModelProviderDiagnosticsStore? = nil,
        contextDiagnosticsStore: ContextCompilerDiagnosticsStore? = nil
    ) {
        self.providers = providers
        self.validator = validator
        self.diagnosticsStore = diagnosticsStore
        self.contextDiagnosticsStore = contextDiagnosticsStore
    }

    func generatePlan(for input: String, context: ExecutionContext) async throws -> StructuredAgentOutput {
        try await route(role: .planning, input: input, context: context)
    }

    func generateDecision(prompt: CompiledPrompt, context: ExecutionContext) async throws -> StructuredAgentOutput {
        try await route(prompt: prompt, context: context)
    }

    func generateReadOnlyNextAction(prompt: CompiledPrompt, context: ExecutionContext) async throws -> ReadOnlyNextAction {
        try await routeReadOnlyNextAction(prompt: prompt, context: context)
    }

    private func routeReadOnlyNextAction(
        prompt: CompiledPrompt,
        context: ExecutionContext
    ) async throws -> ReadOnlyNextAction {
        var failures: [String] = []
        var failureReasons: [String] = []
        var providerFailures: [ModelProviderFailure] = []
        var skipped: [String] = []
        for provider in providers {
            guard provider.isAvailable else {
                skipped.append("\(provider.kind.rawValue) disabled: \(provider.disabledReason ?? "not configured")")
                continue
            }
            let startedAt = Date()
            do {
                let action = try await provider.generateReadOnlyNextAction(prompt: prompt, context: context)
                await updateDiagnostics(
                    activeProvider: provider.kind.rawValue,
                    fallbackReason: (failures + skipped).isEmpty ? "none" : (failures + skipped).joined(separator: " | "),
                    validationResult: "decoded read-only next action from \(provider.kind.rawValue)",
                    latency: Date().timeIntervalSince(startedAt)
                )
                return action
            } catch {
                if let providerFailure = error as? ModelProviderFailure {
                    providerFailures.append(providerFailure)
                }
                failureReasons.append(ModelRoutingError.classified(error).diagnosticReason)
                failures.append("\(provider.kind.rawValue) OBSERVE failed: \(error.localizedDescription)")
            }
        }
        await updateDiagnostics(
            activeProvider: "none",
            fallbackReason: (failures + skipped).joined(separator: " | "),
            validationResult: "no provider produced a decodable read-only next action",
            latency: nil
        )
        if let providerFailure = providerFailures.last { throw providerFailure }
        throw routedFailure(reasons: failureReasons, detail: failures.joined(separator: "; "))
    }

    private func route(role: ModelReasoningRole, input: String, context: ExecutionContext) async throws -> StructuredAgentOutput {
        var failures: [String] = []
        var failureReasons: [String] = []
        var providerFailures: [ModelProviderFailure] = []
        var skipped: [String] = []
        if role == .planning, let contextBundle = context.contextBundle {
            let bundleSize = (try? JSONCoding.encode(contextBundle).utf8.count) ?? 0
            await contextDiagnosticsStore?.markPassedToPlanner(bundleSizeBytes: bundleSize)
        }

        for provider in providers {
            guard provider.isAvailable else {
                skipped.append("\(provider.kind.rawValue) disabled: \(provider.disabledReason ?? "not configured")")
                Self.logger.debug(
                    "Model provider skipped role=\(role.rawValue, privacy: .public) provider=\(provider.kind.rawValue, privacy: .public) reason=\(provider.disabledReason ?? "not configured", privacy: .public)"
                )
                LLMNarrationDebugLog.write(
                    "router_provider_skipped role=\(role.rawValue) provider=\(provider.kind.rawValue) reason=\(provider.disabledReason ?? "not_configured")"
                )
                continue
            }

            Self.logger.debug(
                "Model provider selected for attempt role=\(role.rawValue, privacy: .public) provider=\(provider.kind.rawValue, privacy: .public)"
            )
            LLMNarrationDebugLog.write("router_provider_attempt role=\(role.rawValue) provider=\(provider.kind.rawValue)")
            let startedAt = Date()
            do {
                let output = try await generate(role: role, provider: provider, input: input, context: context)
                try validator.validate(output)
                LLMNarrationDebugLog.write(
                    "router_provider_success role=\(role.rawValue) provider=\(provider.kind.rawValue) latency_ms=\(Int(Date().timeIntervalSince(startedAt) * 1000))"
                )
                await updateDiagnostics(
                    activeProvider: provider.kind.rawValue,
                    fallbackReason: (failures + skipped).isEmpty ? "none" : (failures + skipped).joined(separator: " | "),
                    validationResult: "valid structured output from \(provider.kind.rawValue)",
                    latency: Date().timeIntervalSince(startedAt)
                )
                return output
            } catch {
                if let providerFailure = error as? ModelProviderFailure {
                    providerFailures.append(providerFailure)
                }
                failureReasons.append(ModelRoutingError.classified(error).diagnosticReason)
                failures.append("\(provider.kind.rawValue) \(role.rawValue) failed: \(error.localizedDescription)")
                LLMNarrationDebugLog.write(
                    "router_provider_failed role=\(role.rawValue) provider=\(provider.kind.rawValue) reason=\(error.localizedDescription)"
                )
            }
        }

        await updateDiagnostics(
            activeProvider: "none",
            fallbackReason: (failures + skipped).joined(separator: " | "),
            validationResult: "no provider produced schema-valid output",
            latency: nil
        )
        LLMNarrationDebugLog.write(
            "router_provider_unavailable role=\(role.rawValue) fallback_reason=\((failures + skipped).joined(separator: " | "))"
        )
        if let providerFailure = providerFailures.last {
            throw providerFailure
        }
        throw routedFailure(reasons: failureReasons, detail: failures.joined(separator: "; "))
    }

    private func route(prompt: CompiledPrompt, context: ExecutionContext) async throws -> StructuredAgentOutput {
        var failures: [String] = []
        var failureReasons: [String] = []
        var providerFailures: [ModelProviderFailure] = []
        var skipped: [String] = []
        let role = prompt.missionState.rawValue

        for provider in providers {
            guard provider.isAvailable else {
                skipped.append("\(provider.kind.rawValue) disabled: \(provider.disabledReason ?? "not configured")")
                Self.logger.debug(
                    "Model provider skipped role=\(role, privacy: .public) provider=\(provider.kind.rawValue, privacy: .public) reason=\(provider.disabledReason ?? "not configured", privacy: .public)"
                )
                LLMNarrationDebugLog.write(
                    "router_provider_skipped role=\(role) provider=\(provider.kind.rawValue) reason=\(provider.disabledReason ?? "not_configured")"
                )
                continue
            }

            Self.logger.debug(
                "Model provider selected for attempt role=\(role, privacy: .public) provider=\(provider.kind.rawValue, privacy: .public)"
            )
            LLMNarrationDebugLog.write("router_provider_attempt role=\(role) provider=\(provider.kind.rawValue)")
            let startedAt = Date()
            do {
                let output = try await provider.generateDecision(prompt: prompt, context: context)
                try validator.validate(output)
                LLMNarrationDebugLog.write(
                    "router_provider_success role=\(role) provider=\(provider.kind.rawValue) latency_ms=\(Int(Date().timeIntervalSince(startedAt) * 1000))"
                )
                await updateDiagnostics(
                    activeProvider: provider.kind.rawValue,
                    fallbackReason: (failures + skipped).isEmpty ? "none" : (failures + skipped).joined(separator: " | "),
                    validationResult: "valid structured output from \(provider.kind.rawValue)",
                    latency: Date().timeIntervalSince(startedAt)
                )
                return output
            } catch {
                if let providerFailure = error as? ModelProviderFailure {
                    providerFailures.append(providerFailure)
                }
                failureReasons.append(ModelRoutingError.classified(error).diagnosticReason)
                failures.append("\(provider.kind.rawValue) \(role) failed: \(error.localizedDescription)")
                LLMNarrationDebugLog.write(
                    "router_provider_failed role=\(role) provider=\(provider.kind.rawValue) reason=\(error.localizedDescription)"
                )
            }
        }

        await updateDiagnostics(
            activeProvider: "none",
            fallbackReason: (failures + skipped).joined(separator: " | "),
            validationResult: "no provider produced schema-valid output",
            latency: nil
        )
        LLMNarrationDebugLog.write(
            "router_provider_unavailable role=\(role) fallback_reason=\((failures + skipped).joined(separator: " | "))"
        )
        if let providerFailure = providerFailures.last {
            throw providerFailure
        }
        throw routedFailure(reasons: failureReasons, detail: failures.joined(separator: "; "))
    }

    private func routedFailure(reasons: [String], detail: String) -> ModelRoutingError {
        if reasons.contains("provider_output_invalid") {
            return .providerOutputInvalid(detail)
        }
        if reasons.contains("provider_request_failed") {
            return .providerRequestFailed(detail)
        }
        return .providerUnavailable(detail)
    }

    private func generate(
        role: ModelReasoningRole,
        provider: any ModelProvider,
        input: String,
        context: ExecutionContext
    ) async throws -> StructuredAgentOutput {
        switch role {
        case .planning:
            return try await provider.generatePlan(for: input, context: context)
        case .execution:
            return try await provider.reasonAboutExecution(for: input, context: context)
        case .recovery:
            return try await provider.reasonAboutRecovery(for: input, context: context)
        case .policy:
            return try await provider.reasonAboutPolicy(for: input, context: context)
        }
    }

    private func updateDiagnostics(
        activeProvider: String,
        fallbackReason: String,
        validationResult: String,
        latency: TimeInterval?
    ) async {
        guard let diagnosticsStore else { return }
        await diagnosticsStore.update(
            ModelProviderDiagnostics(
                activeProvider: activeProvider,
                fallbackReason: fallbackReason,
                lastValidationResult: validationResult,
                lastLatencyMilliseconds: latency.map { $0 * 1000 },
                liveProviderStates: providers.map { provider in
                    ModelProviderState(
                        provider: provider.kind.rawValue,
                        liveProvider: provider.isLiveProvider,
                        enabled: provider.isAvailable,
                        reason: provider.disabledReason ?? "enabled"
                    )
                },
                updatedAt: Date()
            )
        )
    }
}

struct ModelProviderConfiguration: Sendable {
    var preferredProvider: ModelProviderKind?
    var openAIAPIKey: String?
    var anthropicAPIKey: String?
    var openAIModel: String
    var claudeModel: String

    static func environment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment,
        secureStore: (any SecureValueStoring)? = nil
    ) -> ModelProviderConfiguration {
        let preferredProvider: ModelProviderKind?
        switch environment["FDE_MODEL_PROVIDER"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "openai":
            preferredProvider = .openAI
        case "claude", "anthropic":
            preferredProvider = .claude
        case "local":
            preferredProvider = .local
        default:
            preferredProvider = nil
        }

        return ModelProviderConfiguration(
            preferredProvider: preferredProvider,
            openAIAPIKey: sanitizedKey(environment["OPENAI_API_KEY"])
                ?? storedProviderToken(["OpenAI", "openai"], secureStore: secureStore),
            anthropicAPIKey: sanitizedKey(environment["ANTHROPIC_API_KEY"])
                ?? storedProviderToken(["Anthropic", "Claude", "anthropic", "claude"], secureStore: secureStore),
            openAIModel: environment["OPENAI_MODEL"]?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "gpt-4.1-mini",
            claudeModel: environment["ANTHROPIC_MODEL"]?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "claude-3-5-sonnet-latest"
        )
    }

    private static func sanitizedKey(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
    }

    private static func storedProviderToken(
        _ providerNames: [String],
        secureStore: (any SecureValueStoring)?
    ) -> String? {
        guard let secureStore else { return nil }
        for provider in providerNames {
            let value = try? secureStore.load(for: .providerToken(provider: provider, workspaceID: nil))
            if let sanitized = sanitizedKey(value) {
                return sanitized
            }
        }
        return nil
    }
}

enum ModelProviderFactory {
    private static let logger = Logger(subsystem: "FDECloudOS", category: "ModelRouting")

    static func providers(configuration: ModelProviderConfiguration) -> [any ModelProvider] {
        let local = LocalDeterministicModelProvider()
        let openAI = OpenAIProvider(apiKey: configuration.openAIAPIKey, model: configuration.openAIModel)
        let claude = ClaudeProvider(apiKey: configuration.anthropicAPIKey, model: configuration.claudeModel)

        switch configuration.preferredProvider {
        case .openAI:
            logger.debug("Model provider order selected: OpenAI then Local fallback")
            LLMNarrationDebugLog.write("router_provider_order selected=OpenAI fallback=Local openai_key_present=\(configuration.openAIAPIKey != nil)")
            return [openAI, local]
        case .claude:
            logger.debug("Model provider order selected: Claude then Local fallback")
            LLMNarrationDebugLog.write("router_provider_order selected=Claude fallback=Local openai_key_present=\(configuration.openAIAPIKey != nil)")
            return [claude, local]
        case .local:
            logger.debug("Model provider order selected: Local deterministic only")
            LLMNarrationDebugLog.write("router_provider_order selected=Local reason=explicit_local openai_key_present=\(configuration.openAIAPIKey != nil)")
            return [local]
        case nil:
            if configuration.openAIAPIKey != nil {
                logger.debug("Model provider order selected: OpenAI then Local fallback by API key auto-detection")
                LLMNarrationDebugLog.write("router_provider_order selected=OpenAI fallback=Local reason=OPENAI_API_KEY_present")
                return [openAI, local]
            }
            if configuration.anthropicAPIKey != nil {
                logger.debug("Model provider order selected: Claude then Local fallback by API key auto-detection")
                LLMNarrationDebugLog.write("router_provider_order selected=Claude fallback=Local reason=ANTHROPIC_API_KEY_present")
                return [claude, local]
            }
            logger.debug("Model provider order selected: Local deterministic only")
            LLMNarrationDebugLog.write("router_provider_order selected=Local reason=no_live_provider_key")
            return [local]
        }
    }

    static func productionProviders(configuration: ModelProviderConfiguration) -> [any ModelProvider] {
        let openAI = OpenAIProvider(apiKey: configuration.openAIAPIKey, model: configuration.openAIModel)
        let claude = ClaudeProvider(apiKey: configuration.anthropicAPIKey, model: configuration.claudeModel)

        switch configuration.preferredProvider {
        case .openAI:
            logger.debug("Production model provider order selected: OpenAI only")
            LLMNarrationDebugLog.write("router_provider_order selected=OpenAI fallback=none production=true openai_key_present=\(configuration.openAIAPIKey != nil)")
            return [openAI]
        case .claude:
            logger.debug("Production model provider order selected: Claude only")
            LLMNarrationDebugLog.write("router_provider_order selected=Claude fallback=none production=true")
            return [claude]
        case .local:
            logger.debug("Production model provider order selected: none because local deterministic provider is not used in production")
            LLMNarrationDebugLog.write("router_provider_order selected=none reason=explicit_local_disabled_in_production")
            return []
        case nil:
            if configuration.openAIAPIKey != nil {
                logger.debug("Production model provider order selected: OpenAI only by API key auto-detection")
                LLMNarrationDebugLog.write("router_provider_order selected=OpenAI fallback=none production=true reason=OPENAI_API_KEY_present")
                return [openAI]
            }
            if configuration.anthropicAPIKey != nil {
                logger.debug("Production model provider order selected: Claude only by API key auto-detection")
                LLMNarrationDebugLog.write("router_provider_order selected=Claude fallback=none production=true reason=ANTHROPIC_API_KEY_present")
                return [claude]
            }
            logger.debug("Production model provider order selected: none; no live provider configured")
            LLMNarrationDebugLog.write("router_provider_order selected=none production=true reason=no_live_provider_key")
            return []
        }
    }

    static func narrationProvider(configuration: ModelProviderConfiguration) -> (any AgentNarrationProviding)? {
        guard configuration.preferredProvider == .openAI
            || (configuration.preferredProvider == nil && configuration.openAIAPIKey != nil) else {
            logger.debug("Agent narration provider selected: Local deterministic fallback")
            LLMNarrationDebugLog.write("narration_provider selected=Local reason=no_openai_provider_or_key openai_key_present=\(configuration.openAIAPIKey != nil)")
            return nil
        }

        let provider = OpenAIProvider(apiKey: configuration.openAIAPIKey, model: configuration.openAIModel)
        logger.debug(
            "Agent narration provider selected: OpenAI available=\(provider.isAvailable, privacy: .public) reason=\(provider.disabledReason ?? "enabled", privacy: .public)"
        )
        LLMNarrationDebugLog.write("narration_provider selected=OpenAI available=\(provider.isAvailable) model=\(configuration.openAIModel)")
        return provider
    }

    static func chatProvider(configuration: ModelProviderConfiguration) -> (any AgentChatProviding)? {
        switch configuration.preferredProvider {
        case .openAI:
            let provider = OpenAIProvider(apiKey: configuration.openAIAPIKey, model: configuration.openAIModel)
            logger.debug(
                "Agent chat provider selected: OpenAI available=\(provider.isAvailable, privacy: .public) reason=\(provider.disabledReason ?? "enabled", privacy: .public)"
            )
            LLMNarrationDebugLog.write("chat_provider selected=OpenAI available=\(provider.isAvailable) model=\(configuration.openAIModel)")
            return provider
        case .claude:
            let provider = ClaudeProvider(apiKey: configuration.anthropicAPIKey, model: configuration.claudeModel)
            logger.debug(
                "Agent chat provider selected: Claude available=\(provider.isAvailable, privacy: .public) reason=\(provider.disabledReason ?? "enabled", privacy: .public)"
            )
            LLMNarrationDebugLog.write("chat_provider selected=Claude available=\(provider.isAvailable) model=\(configuration.claudeModel)")
            return provider
        case .local:
            logger.debug("Agent chat provider selected: none for explicit local provider")
            LLMNarrationDebugLog.write("chat_provider selected=none reason=explicit_local")
            return nil
        case nil:
            if configuration.openAIAPIKey != nil {
                let provider = OpenAIProvider(apiKey: configuration.openAIAPIKey, model: configuration.openAIModel)
                logger.debug(
                    "Agent chat provider selected: OpenAI available=\(provider.isAvailable, privacy: .public) reason=\(provider.disabledReason ?? "enabled", privacy: .public)"
                )
                LLMNarrationDebugLog.write("chat_provider selected=OpenAI available=\(provider.isAvailable) model=\(configuration.openAIModel)")
                return provider
            }
            if configuration.anthropicAPIKey != nil {
                let provider = ClaudeProvider(apiKey: configuration.anthropicAPIKey, model: configuration.claudeModel)
                logger.debug(
                    "Agent chat provider selected: Claude available=\(provider.isAvailable, privacy: .public) reason=\(provider.disabledReason ?? "enabled", privacy: .public)"
                )
                LLMNarrationDebugLog.write("chat_provider selected=Claude available=\(provider.isAvailable) model=\(configuration.claudeModel)")
                return provider
            }
            logger.debug("Agent chat provider selected: none")
            LLMNarrationDebugLog.write("chat_provider selected=none reason=no_live_provider_key openai_key_present=false anthropic_key_present=false")
            return nil
        }
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}

protocol LLMHTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionLLMHTTPClient: LLMHTTPClient {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ModelRoutingError.providerRequestFailed("Remote provider returned a non-HTTP response.")
        }
        return (data, httpResponse)
    }
}

struct OpenAIProvider: ModelProvider, AgentNarrationProviding, AgentChatProviding {
    let kind: ModelProviderKind = .openAI
    let apiKey: String?
    let model: String
    let httpClient: any LLMHTTPClient
    let timeout: TimeInterval

    var modelIdentifier: String? { model }

    init(
        apiKey: String?,
        model: String = "gpt-4.1-mini",
        httpClient: any LLMHTTPClient = URLSessionLLMHTTPClient(),
        timeout: TimeInterval = 20
    ) {
        self.apiKey = apiKey
        self.model = model
        self.httpClient = httpClient
        self.timeout = timeout
    }

    var isAvailable: Bool {
        apiKey?.isEmpty == false
    }

    var disabledReason: String? {
        isAvailable ? nil : "OPENAI_API_KEY is missing"
    }

    func generatePlan(for input: String, context: ExecutionContext) async throws -> StructuredAgentOutput {
        try await requestStructuredOutput(role: .planning, input: input, context: context)
    }

    func generateDecision(prompt: CompiledPrompt, context: ExecutionContext) async throws -> StructuredAgentOutput {
        try await requestStructuredOutput(prompt: prompt)
    }

    func generateReadOnlyNextAction(prompt: CompiledPrompt, context: ExecutionContext) async throws -> ReadOnlyNextAction {
        try await requestReadOnlyNextAction(prompt: prompt)
    }

    func reasonAboutExecution(for input: String, context: ExecutionContext) async throws -> StructuredAgentOutput {
        try await requestStructuredOutput(role: .execution, input: input, context: context)
    }

    func reasonAboutRecovery(for input: String, context: ExecutionContext) async throws -> StructuredAgentOutput {
        try await requestStructuredOutput(role: .recovery, input: input, context: context)
    }

    func reasonAboutPolicy(for input: String, context: ExecutionContext) async throws -> StructuredAgentOutput {
        try await requestStructuredOutput(role: .policy, input: input, context: context)
    }

    func generateNarration(for request: AgentNarrationRequest) async throws -> AgentNarration {
        LLMNarrationDebugLog.write("openai_generateNarration_called event_type=\(request.eventType.rawValue) model=\(model)")
        guard let apiKey else {
            LLMNarrationDebugLog.write("openai_generateNarration_fallback reason=OPENAI_API_KEY_missing event_type=\(request.eventType.rawValue)")
            throw ModelRoutingError.providerUnavailable("OPENAI_API_KEY is missing")
        }

        var urlRequest = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = timeout
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "input": [
                [
                    "role": "system",
                    "content": RemoteStructuredOutputParser.narrationSystemInstruction()
                ],
                [
                    "role": "user",
                    "content": RemoteStructuredOutputParser.narrationUserPrompt(request)
                ]
            ],
            "text": [
                "format": [
                    "type": "json_object"
                ]
            ]
        ])

        LLMNarrationDebugLog.write("openai_request_started endpoint=/v1/responses event_type=\(request.eventType.rawValue) model=\(model)")
        let (data, response) = try await httpClient.data(for: urlRequest)
        LLMNarrationDebugLog.write("openai_response_received status=\(response.statusCode) bytes=\(data.count) event_type=\(request.eventType.rawValue)")
        try RemoteStructuredOutputParser.validateHTTP(response: response, provider: kind)
        let narration = try RemoteStructuredOutputParser.decodeNarrationResponse(data: data, provider: kind)
        LLMNarrationDebugLog.write("openai_response_decoded event_type=\(request.eventType.rawValue) message_type=\(narration.messageType.rawValue)")
        return narration
    }

    func generateChatResponse(for request: AgentChatRequest) async throws -> AgentChatResponse {
        LLMNarrationDebugLog.write("openai_generateChat_called model=\(model) intent=\(request.intentType.rawValue)")
        guard let apiKey else {
            LLMNarrationDebugLog.write("openai_generateChat_fallback reason=OPENAI_API_KEY_missing")
            throw ModelRoutingError.providerUnavailable("OPENAI_API_KEY is missing")
        }

        var urlRequest = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = timeout
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "input": RemoteStructuredOutputParser.chatMessages(for: request, includeSystem: true),
            "text": [
                "format": [
                    "type": "json_object"
                ]
            ]
        ])

        LLMNarrationDebugLog.write("openai_request_started endpoint=/v1/responses chat=true model=\(model)")
        let (data, response) = try await httpClient.data(for: urlRequest)
        LLMNarrationDebugLog.write("openai_response_received status=\(response.statusCode) bytes=\(data.count) chat=true")
        try RemoteStructuredOutputParser.validateHTTP(response: response, provider: kind)
        let chatResponse = try RemoteStructuredOutputParser.decodeChatResponse(data: data, provider: kind)
        LLMNarrationDebugLog.write("openai_response_decoded chat=true content_chars=\(chatResponse.content.count)")
        return chatResponse
    }

    private func requestStructuredOutput(
        role: ModelReasoningRole,
        input: String,
        context: ExecutionContext
    ) async throws -> StructuredAgentOutput {
        let prompt = RemoteStructuredOutputParser.compiledPrompt(
            for: role,
            input: input,
            context: context
        )
        return try await requestStructuredOutput(prompt: prompt)
    }

    private func requestStructuredOutput(prompt: CompiledPrompt) async throws -> StructuredAgentOutput {
        guard let apiKey else {
            throw ModelRoutingError.providerUnavailable("OPENAI_API_KEY is missing")
        }

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "input": [
                [
                    "role": "system",
                    "content": prompt.systemInstruction
                ],
                [
                    "role": "user",
                    "content": prompt.userPrompt
                ]
            ],
            "text": [
                "format": StructuredAgentOutputSchema.openAIResponseFormat()
            ]
        ])

        let startedAt = Date()
        let requestBytes = request.httpBody?.count ?? 0
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await httpClient.data(for: request)
        } catch {
            throw ModelProviderFailure.transport(
                error,
                provider: kind,
                model: model,
                startedAt: startedAt,
                requestPayloadBytes: requestBytes
            )
        }
        do {
            try RemoteStructuredOutputParser.validateHTTP(response: response, provider: kind)
        } catch {
            throw ModelProviderFailure.http(
                error,
                provider: kind,
                model: model,
                response: response,
                startedAt: startedAt,
                requestPayloadBytes: requestBytes,
                responsePayloadBytes: data.count
            )
        }
        do {
            return try RemoteStructuredOutputParser.decodeResponse(data: data, provider: kind)
        } catch {
            throw ModelProviderFailure.response(
                error,
                provider: kind,
                model: model,
                response: response,
                startedAt: startedAt,
                requestPayloadBytes: requestBytes,
                responsePayloadBytes: data.count
            )
        }
    }

    private func requestReadOnlyNextAction(prompt: CompiledPrompt) async throws -> ReadOnlyNextAction {
        guard let apiKey else {
            throw ModelRoutingError.providerUnavailable("OPENAI_API_KEY is missing")
        }
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "input": [
                ["role": "system", "content": prompt.systemInstruction],
                ["role": "user", "content": prompt.userPrompt]
            ],
            "text": ["format": ReadOnlyNextActionSchema.openAIResponseFormat()]
        ])
        let startedAt = Date()
        let requestBytes = request.httpBody?.count ?? 0
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await httpClient.data(for: request)
        } catch {
            throw ModelProviderFailure.transport(
                error,
                provider: kind,
                model: model,
                startedAt: startedAt,
                requestPayloadBytes: requestBytes
            )
        }
        do {
            try RemoteStructuredOutputParser.validateHTTP(response: response, provider: kind)
        } catch {
            throw ModelProviderFailure.http(
                error,
                provider: kind,
                model: model,
                response: response,
                startedAt: startedAt,
                requestPayloadBytes: requestBytes,
                responsePayloadBytes: data.count
            )
        }
        do {
            return try RemoteStructuredOutputParser.decodeReadOnlyNextActionResponse(data: data, provider: kind)
        } catch {
            throw ModelProviderFailure.response(
                error,
                provider: kind,
                model: model,
                response: response,
                startedAt: startedAt,
                requestPayloadBytes: requestBytes,
                responsePayloadBytes: data.count
            )
        }
    }
}

struct ClaudeProvider: ModelProvider, AgentChatProviding {
    let kind: ModelProviderKind = .claude
    let apiKey: String?
    let model: String
    let httpClient: any LLMHTTPClient
    let timeout: TimeInterval

    var modelIdentifier: String? { model }

    init(
        apiKey: String?,
        model: String = "claude-3-5-sonnet-latest",
        httpClient: any LLMHTTPClient = URLSessionLLMHTTPClient(),
        timeout: TimeInterval = 20
    ) {
        self.apiKey = apiKey
        self.model = model
        self.httpClient = httpClient
        self.timeout = timeout
    }

    var isAvailable: Bool {
        apiKey?.isEmpty == false
    }

    var disabledReason: String? {
        isAvailable ? nil : "ANTHROPIC_API_KEY is missing"
    }

    func generatePlan(for input: String, context: ExecutionContext) async throws -> StructuredAgentOutput {
        try await requestStructuredOutput(role: .planning, input: input, context: context)
    }

    func generateDecision(prompt: CompiledPrompt, context: ExecutionContext) async throws -> StructuredAgentOutput {
        try await requestStructuredOutput(prompt: prompt)
    }

    func generateReadOnlyNextAction(prompt: CompiledPrompt, context: ExecutionContext) async throws -> ReadOnlyNextAction {
        try await requestReadOnlyNextAction(prompt: prompt)
    }

    func reasonAboutExecution(for input: String, context: ExecutionContext) async throws -> StructuredAgentOutput {
        try await requestStructuredOutput(role: .execution, input: input, context: context)
    }

    func reasonAboutRecovery(for input: String, context: ExecutionContext) async throws -> StructuredAgentOutput {
        try await requestStructuredOutput(role: .recovery, input: input, context: context)
    }

    func reasonAboutPolicy(for input: String, context: ExecutionContext) async throws -> StructuredAgentOutput {
        try await requestStructuredOutput(role: .policy, input: input, context: context)
    }

    func generateChatResponse(for request: AgentChatRequest) async throws -> AgentChatResponse {
        LLMNarrationDebugLog.write("claude_generateChat_called model=\(model) intent=\(request.intentType.rawValue)")
        guard let apiKey else {
            LLMNarrationDebugLog.write("claude_generateChat_fallback reason=ANTHROPIC_API_KEY_missing")
            throw ModelRoutingError.providerUnavailable("ANTHROPIC_API_KEY is missing")
        }

        var urlRequest = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = timeout
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "max_tokens": 900,
            "system": RemoteStructuredOutputParser.chatSystemInstruction(for: request),
            "messages": RemoteStructuredOutputParser.chatMessages(for: request, includeSystem: false)
        ])

        LLMNarrationDebugLog.write("claude_request_started endpoint=/v1/messages chat=true model=\(model)")
        let (data, response) = try await httpClient.data(for: urlRequest)
        LLMNarrationDebugLog.write("claude_response_received status=\(response.statusCode) bytes=\(data.count) chat=true")
        try RemoteStructuredOutputParser.validateHTTP(response: response, provider: kind)
        let chatResponse = try RemoteStructuredOutputParser.decodeChatResponse(data: data, provider: kind)
        LLMNarrationDebugLog.write("claude_response_decoded chat=true content_chars=\(chatResponse.content.count)")
        return chatResponse
    }

    private func requestStructuredOutput(
        role: ModelReasoningRole,
        input: String,
        context: ExecutionContext
    ) async throws -> StructuredAgentOutput {
        let prompt = RemoteStructuredOutputParser.compiledPrompt(
            for: role,
            input: input,
            context: context
        )
        return try await requestStructuredOutput(prompt: prompt)
    }

    private func requestStructuredOutput(prompt: CompiledPrompt) async throws -> StructuredAgentOutput {
        guard let apiKey else {
            throw ModelRoutingError.providerUnavailable("ANTHROPIC_API_KEY is missing")
        }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "max_tokens": 1800,
            "system": prompt.systemInstruction,
            "messages": [
                [
                    "role": "user",
                    "content": prompt.userPrompt
                ]
            ]
        ])

        let (data, response) = try await httpClient.data(for: request)
        try RemoteStructuredOutputParser.validateHTTP(response: response, provider: kind)
        return try RemoteStructuredOutputParser.decodeResponse(data: data, provider: kind)
    }

    private func requestReadOnlyNextAction(prompt: CompiledPrompt) async throws -> ReadOnlyNextAction {
        guard let apiKey else {
            throw ModelRoutingError.providerUnavailable("ANTHROPIC_API_KEY is missing")
        }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "max_tokens": 1800,
            "system": prompt.systemInstruction,
            "messages": [["role": "user", "content": prompt.userPrompt]]
        ])
        let (data, response) = try await httpClient.data(for: request)
        try RemoteStructuredOutputParser.validateHTTP(response: response, provider: kind)
        return try RemoteStructuredOutputParser.decodeReadOnlyNextActionResponse(data: data, provider: kind)
    }
}

enum RemoteStructuredOutputParser {
    static func compiledPrompt(
        for role: ModelReasoningRole,
        input: String,
        context: ExecutionContext
    ) -> CompiledPrompt {
        PromptOrchestrator().compile(
            state: role.missionState,
            input: input,
            context: context
        )
    }

    static func validateHTTP(response: HTTPURLResponse, provider: ModelProviderKind) throws {
        switch response.statusCode {
        case 200..<300:
            return
        case 401, 403:
            throw ModelRoutingError.providerRequestFailed("\(provider.rawValue) authentication failed.")
        case 429:
            throw ModelRoutingError.providerRequestFailed("\(provider.rawValue) rate limit reached.")
        case 500..<600:
            throw ModelRoutingError.providerRequestFailed("\(provider.rawValue) service unavailable.")
        default:
            throw ModelRoutingError.providerRequestFailed("\(provider.rawValue) HTTP \(response.statusCode).")
        }
    }

    static func decodeResponse(data: Data, provider: ModelProviderKind) throws -> StructuredAgentOutput {
        let object = try JSONSerialization.jsonObject(with: data)
        let text = try extractText(from: object)
        let json = try extractJSONObjectText(from: text)
        try StructuredAgentOutputSchema.validateJSONText(json)
        let output = try JSONCoding.decode(StructuredAgentOutput.self, from: json)
        try StructuredOutputValidator().validate(output)
        return output
    }

    static func decodeReadOnlyNextActionResponse(data: Data, provider: ModelProviderKind) throws -> ReadOnlyNextAction {
        let object = try JSONSerialization.jsonObject(with: data)
        let text = try extractText(from: object)
        let json = try extractJSONObjectText(from: text)
        return try ReadOnlyNextActionSchema.decodeJSONText(json)
    }

    static func decodeNarrationResponse(data: Data, provider: ModelProviderKind) throws -> AgentNarration {
        let object = try JSONSerialization.jsonObject(with: data)
        let text = try extractText(from: object)
        let json = try extractJSONObjectText(from: text)
        return try JSONCoding.decode(AgentNarration.self, from: json)
    }

    static func decodeChatResponse(data: Data, provider: ModelProviderKind) throws -> AgentChatResponse {
        let object = try JSONSerialization.jsonObject(with: data)
        let text = try extractText(from: object)
        let json = try extractJSONObjectText(from: text)
        var response = try JSONCoding.decode(AgentChatResponse.self, from: json)
        response.provider = response.provider ?? provider
        return response
    }

    static func narrationSystemInstruction() -> String {
        """
        You are the FDE Cloud OS live execution narrator. Return only valid JSON matching the AgentNarration schema.
        Required top-level keys: content, message_type, confidence.
        Valid message_type values: TEXT, PROGRESS_UPDATE, PLAN_UPDATE, WARNING, ARTIFACT, OBSERVATION, ACTION_UPDATE, DECISION, EVIDENCE, RESULT, APPROVAL_REQUEST.
        Write concise first-person execution narration in the agent's voice.
        Use only the sanitized event fields provided by the user prompt.
        Never include chain-of-thought, private reasoning, secrets, tokens, credentials, tool output streams, raw execution logs, or raw payloads.
        If the event is mundane, lightly improve the deterministic fallback instead of inventing facts.
        """
    }

    static func narrationUserPrompt(_ request: AgentNarrationRequest) -> String {
        let requestJSON = (try? JSONCoding.encode(request)) ?? "{}"
        return """
        Generate one natural execution narration message from this sanitized AgentNarrationRequest JSON:
        \(requestJSON)
        """
    }

    static func chatSystemInstruction(for request: AgentChatRequest) -> String {
        var sections = [
            """
            You are FDE Agent, an engineering agent for helping traditional software systems transition safely and effectively toward AI Agent integration. You work with a selected Legacy workspace and a selected Agent workspace. You understand codebases, APIs, data flows, permissions, integrations, runtime behavior, and tests. Answer directly in the user's language; do not repeatedly introduce yourself.
            """,
            """
            Truthfulness boundaries: general engineering knowledge is not evidence about the selected workspaces. Only say a file was inspected when read-only evidence is present. Only say code changed, a command ran, tests passed, deployment happened, or work completed when real execution evidence is present. Distinguish proposals from completed changes. Ask at most one essential clarification when the request cannot proceed safely. Never reveal chain-of-thought, secrets, credentials, hidden audit fields, or raw private logs.
            """,
            modeInstruction(request.selectedMode),
            """
            Selected workspace metadata: workspace=\(request.workspaceName); Legacy=\(request.legacyWorkspaceName ?? "not selected"); Agent=\(request.agentWorkspaceName ?? "not selected"). This metadata identifies selection only and does not prove inspection.
            """,
            "Return only valid JSON with top-level keys content and confidence. The content value is the canonical assistant answer."
        ]
        if request.hasRuntimeTask || request.selectedMode == .runtimeControl {
            sections.append(
                "Relevant runtime context: active_task=\(request.hasRuntimeTask); interaction_state=\(request.interactionState.rawValue). Keep status narration separate from the conversational answer."
            )
        }
        if request.toolEvidence.isEmpty {
            sections.append(
                "Current-answer tool evidence: none. You must not claim that you read, inspected, checked, or found facts in workspace files, and must not claim that you ran commands or tests. Do not guess filenames from framework conventions."
            )
        } else {
            let evidence = request.toolEvidence.prefix(20).map { item in
                "tool=\(item.toolName); workspace=\(item.workspaceIdentity); path=\(item.targetPath); tool_call_id=\(item.toolCallID)"
            }.joined(separator: " | ")
            sections.append(
                "Current-answer verified tool evidence (successful TOOL_CALLED + TOOL_RESULT pairs only): \(evidence). Claims about a named file require an engineering.read_file pair for that exact relative path."
            )
        }
        if let repairInstruction = request.repairInstruction?.trimmingCharacters(in: .whitespacesAndNewlines),
           !repairInstruction.isEmpty {
            sections.append("Repair instruction: \(repairInstruction)")
        }
        return sections.joined(separator: "\n\n")
    }

    static func chatMessages(
        for request: AgentChatRequest,
        includeSystem: Bool
    ) -> [[String: String]] {
        var messages: [[String: String]] = []
        if includeSystem {
            messages.append(["role": "system", "content": chatSystemInstruction(for: request)])
        }
        for message in request.recentMessages {
            let role: String
            switch message.sender {
            case .user:
                role = "user"
            case .agent:
                role = "assistant"
            case .system:
                continue
            }
            appendChatMessage(role: role, content: message.content, to: &messages)
        }
        appendChatMessage(role: "user", content: request.message, to: &messages)
        return messages
    }

    private static func appendChatMessage(
        role: String,
        content: String,
        to messages: inout [[String: String]]
    ) {
        let safeContent = AgentPresentationSanitizer.safeMarkdownContent(content, fallback: "")
        guard !safeContent.isEmpty else { return }
        if messages.last?["role"] == role, role != "system" {
            let previous = messages.removeLast()
            let combined = [previous["content"], safeContent].compactMap { $0 }.joined(separator: "\n\n")
            messages.append(["role": role, "content": combined])
        } else {
            messages.append(["role": role, "content": safeContent])
        }
    }

    private static func modeInstruction(_ mode: FDEConversationMode) -> String {
        switch mode {
        case .casualConversation:
            return "Mode: casualConversation. Respond naturally and briefly. Do not list capabilities, discuss execution state, create a mission, or mention workspaces unless relevant."
        case .fdeCapabilityExplanation:
            return "Mode: fdeCapabilityExplanation. Answer the exact identity or capability question. Describe real FDE abilities and distinguish explanation, inspection, modification, execution, and verification without repeating an unrelated full capability list."
        case .engineeringExplanation:
            return "Mode: engineeringExplanation. Give a substantive engineering explanation with cause-and-effect reasoning, tradeoffs, and a concrete example when useful. Do not imply workspace inspection or create an executable mission."
        case .legacyTransformationAdvisory:
            return "Mode: legacyTransformationAdvisory. Analyze Legacy architecture, business workflow, data readiness, interfaces, permissions and approval, Agent capability, integration gaps, failure handling, testing, risk, and outcome measurement as relevant. Do not claim the selected workspaces were inspected."
        case .workspaceReadOnlyInvestigation:
            return "Mode: workspaceReadOnlyInvestigation. A grounded answer requires real read/search evidence. Separate inspected facts from inference and cite supporting files or symbols. Never imply source modification."
        case .executableEngineeringTask:
            return "Mode: executableEngineeringTask. This belongs to the existing executable runtime. Do not simulate completion; changes and verification require real evidence."
        case .runtimeControl:
            return "Mode: runtimeControl. Apply only to a real active task and respond concisely about the requested control."
        }
    }

    private static func extractText(from object: Any) throws -> String {
        if let string = object as? String {
            return string
        }
        if let dictionary = object as? [String: Any] {
            for key in ["output_text", "text"] {
                if let string = dictionary[key] as? String {
                    return string
                }
            }
            for key in ["content", "output", "message", "choices"] {
                if let value = dictionary[key],
                   let nested = try? extractText(from: value) {
                    return nested
                }
            }
            for value in dictionary.values {
                if let nested = try? extractText(from: value) {
                    return nested
                }
            }
        }
        if let array = object as? [Any] {
            for value in array {
                if let nested = try? extractText(from: value) {
                    return nested
                }
            }
        }
        throw ModelRoutingError.providerOutputInvalid("Remote provider response did not include structured output text.")
    }

    private static func extractJSONObjectText(from text: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{"), trimmed.hasSuffix("}") {
            return trimmed
        }

        throw ModelRoutingError.providerOutputInvalid("Remote provider returned wrapped or malformed structured JSON.")
    }
}

@available(*, deprecated, renamed: "OpenAIProvider")
struct RemoteLLMProvider: ModelProvider {
    let kind: ModelProviderKind
    let apiKeyEnvironmentVariable: String

    var isAvailable: Bool {
        false
    }

    var disabledReason: String? {
        "\(kind.rawValue) provider replaced by explicit OpenAIProvider/ClaudeProvider boundary"
    }

    func generatePlan(for input: String, context: ExecutionContext) async throws -> StructuredAgentOutput {
        throw ModelRoutingError.providerUnavailable(
            "\(kind.rawValue) legacy remote provider is disabled."
        )
    }
}

struct LocalDeterministicModelProvider: ModelProvider {
    let kind: ModelProviderKind = .local
    let isAvailable = true

    func generatePlan(for input: String, context: ExecutionContext) async throws -> StructuredAgentOutput {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeTitle = String(trimmed.prefix(72))
        let taskFocus = safeTitle.isEmpty ? "Untitled field task" : safeTitle
        let lowercased = trimmed.lowercased()
        let missingAPIDependencyCommand = "api.missing_dependency"
        let requestsFailureLoop = [
            "missing api dependency",
            "intentionally fails",
            "trigger recovery",
            "failure report"
        ].contains { lowercased.contains($0) }
        let mentionsConnector = ["slack", "github", "notion", "gmail"].contains { lowercased.contains($0) }
        let avoidedCommands = Set(context.policyDeltas.compactMap(\.avoidToolCommand))
        let globalPolicy = context.globalExecutionPolicy
        let globalAvoidedCommands = Set(globalPolicy?.avoidedToolCommands ?? [])
        let globalFailureCommands = Set(context.systemFailureProfile?.clusters.compactMap(\.toolCommand) ?? [])
        let replacementForList = context.policyDeltas
            .first { $0.avoidToolCommand == "/bin/ls" }?
            .replacementToolCommand
            ?? globalPolicy?.toolPreferences["/bin/ls"]
        let replacementForMissingDependency = context.policyDeltas
            .first { $0.avoidToolCommand == missingAPIDependencyCommand }?
            .replacementToolCommand
            ?? globalPolicy?.toolPreferences[missingAPIDependencyCommand]
            ?? "/usr/bin/env"
        let hasGlobalLearning = globalPolicy != nil || context.systemFailureProfile != nil
        let hasPolicyLoop = !context.policyDeltas.isEmpty || !context.failurePatterns.isEmpty || hasGlobalLearning
        let shouldAvoidList = avoidedCommands.contains("/bin/ls")
            || globalAvoidedCommands.contains("/bin/ls")
            || globalFailureCommands.contains("/bin/ls")
            || context.failurePatterns.contains { $0.command == "/bin/ls" }
        let shouldAvoidMissingDependency = avoidedCommands.contains(missingAPIDependencyCommand)
            || globalAvoidedCommands.contains(missingAPIDependencyCommand)
            || globalFailureCommands.contains(missingAPIDependencyCommand)
            || context.failurePatterns.contains { $0.command == missingAPIDependencyCommand }
        let inspectCommand = shouldAvoidList ? (replacementForList ?? "/usr/bin/env") : "/bin/ls"
        let inspectArguments = inspectCommand == "/bin/ls" ? ["-la", "."] : []
        let inspectToolID = inspectCommand == "/bin/ls" ? "tool.workspace.list" : "tool.workspace.env"
        let failureLoopToolID = shouldAvoidMissingDependency
            ? "tool.api.missing-dependency.fallback"
            : "tool.api.missing-dependency"
        let retryBudget = max(0, context.policyDeltas.map(\.retryBudget).max() ?? 0, globalPolicy?.defaultRetryBudget ?? 0)
        let decompositionDepth = max(3, globalPolicy?.decompositionDepth ?? 3)
        let checkpointBeforeInspection = globalPolicy?.checkpointBeforeInspection ?? hasPolicyLoop
        let missionIntent = context.missionIntent ?? MissionIntentParser().parse(trimmed)

        if isApprovedIntegrationImplementation(missionIntent: missionIntent, normalizedInput: lowercased) {
            return approvedIntegrationImplementationOutput(
                taskFocus: taskFocus,
                agentProjectRoot: context.workspace.localAgentProjectRoot,
                retryBudget: retryBudget
            )
        }

        if missionIntent.intentType == .architectureAnalysis
            || missionIntent.intentType == .aiAgentCompatibilityAssessment {
            return architectureAnalysisOutput(
                taskFocus: taskFocus,
                missionIntent: missionIntent,
                agentProjectRoot: context.workspace.localAgentProjectRoot,
                agentSourceDirectory: context.contextBundle?.codebases
                    .first { $0.role == "ai_agent" }?
                    .sourceDirectories
                    .first,
                legacySourceFile: primaryReadableSourceFile(in: context.contextBundle, role: "legacy_software"),
                agentSourceFile: primaryReadableSourceFile(in: context.contextBundle, role: "ai_agent"),
                retryBudget: retryBudget,
                hasPolicyLoop: hasPolicyLoop
            )
        }

        var toolCalls = [
            ToolCall(
                id: "tool.workspace.pwd",
                type: .shell,
                command: "/bin/pwd",
                arguments: [],
                workingDirectory: nil,
                requiresApproval: false
            ),
            ToolCall(
                id: inspectToolID,
                type: .shell,
                command: inspectCommand,
                arguments: inspectArguments,
                workingDirectory: nil,
                requiresApproval: false
            ),
            ToolCall(
                id: "tool.execution.checkpoint",
                type: .shell,
                command: "/bin/echo",
                arguments: ["FDE execution checkpoint prepared for: \(taskFocus)"],
                workingDirectory: nil,
                requiresApproval: false
            )
        ]

        if requestsFailureLoop {
            toolCalls.append(
                ToolCall(
                    id: failureLoopToolID,
                    type: .shell,
                    command: shouldAvoidMissingDependency ? replacementForMissingDependency : missingAPIDependencyCommand,
                    arguments: shouldAvoidMissingDependency ? [] : ["dependency=missing"],
                    workingDirectory: nil,
                    requiresApproval: false
                )
            )
        }

        if decompositionDepth > 3 {
            toolCalls.append(
                ToolCall(
                    id: "tool.learning.preflight",
                    type: .shell,
                    command: "/bin/echo",
                    arguments: ["Global execution policy applied: \(globalPolicy?.summary ?? "system memory active")"],
                    workingDirectory: nil,
                    requiresApproval: false
                )
            )
        }

        var defaultPlan = [
            PlanStep(
                id: "step.context",
                title: "Compile execution context",
                intent: "Resolve workspace, policy, graph, and recent task context before action.",
                toolCallID: "tool.workspace.pwd",
                requiresApproval: false
            ),
            PlanStep(
                id: "step.inspect",
                title: shouldAvoidList ? "Inspect runtime environment through replacement tool" : "Inspect local workspace",
                intent: shouldAvoidList
                    ? "Avoid the historically failed workspace listing command and capture safer runtime evidence."
                    : "Capture the current local file surface as deterministic evidence.",
                toolCallID: inspectToolID,
                requiresApproval: false,
                retryBudget: retryBudget
            ),
            PlanStep(
                id: "step.checkpoint",
                title: "Create execution checkpoint",
                intent: "Emit a replayable checkpoint tying the plan to the natural-language task.",
                toolCallID: "tool.execution.checkpoint",
                requiresApproval: false
            )
        ]

        if decompositionDepth > 3 {
            defaultPlan.insert(
                PlanStep(
                    id: "step.learning-preflight",
                    title: "Apply global execution policy",
                    intent: "Load system-level memory and apply globally evolved planning strategy before local execution.",
                    toolCallID: "tool.learning.preflight",
                    requiresApproval: false,
                    retryBudget: retryBudget
                ),
                at: 1
            )
        }

        var adaptedPlan = [
            PlanStep(
                id: "step.context",
                title: "Compile execution context",
                intent: "Resolve workspace, policy, graph, and recent task context before action.",
                toolCallID: "tool.workspace.pwd",
                requiresApproval: false
            ),
            PlanStep(
                id: "step.checkpoint",
                title: checkpointBeforeInspection ? "Create pre-execution policy checkpoint" : "Create execution checkpoint",
                intent: checkpointBeforeInspection
                    ? "Front-load a replayable checkpoint because learned policy identified execution risk."
                    : "Emit a replayable checkpoint tying the plan to the natural-language task.",
                toolCallID: "tool.execution.checkpoint",
                requiresApproval: false
            ),
            PlanStep(
                id: shouldAvoidList ? "step.inspect.replacement" : "step.inspect.optimized",
                title: shouldAvoidList ? "Inspect with replacement tool" : "Inspect local workspace after checkpoint",
                intent: shouldAvoidList
                    ? "Use policy-selected replacement command after a prior failure pattern."
                    : "Preserve successful execution ordering learned from the previous run.",
                toolCallID: inspectToolID,
                requiresApproval: false,
                retryBudget: retryBudget
            )
        ]

        if decompositionDepth > 3 {
            adaptedPlan.insert(
                PlanStep(
                    id: "step.learning-preflight",
                    title: "Apply global execution policy",
                    intent: "Apply cross-task failure memory before choosing execution tools.",
                    toolCallID: "tool.learning.preflight",
                    requiresApproval: false,
                    retryBudget: retryBudget
                ),
                at: 1
            )
        }

        if requestsFailureLoop {
            let failureLoopStep = PlanStep(
                id: shouldAvoidMissingDependency ? "step.missing-api.policy-fallback" : "step.missing-api.failure-validation",
                title: shouldAvoidMissingDependency ? "Use learned missing API fallback" : "Validate missing API dependency failure",
                intent: shouldAvoidMissingDependency
                    ? "Apply persisted failure policy and avoid the missing API dependency path."
                    : "Deterministically exercise the missing API dependency path once so recovery and policy learning are validated.",
                toolCallID: failureLoopToolID,
                requiresApproval: false,
                retryBudget: 0
            )
            defaultPlan.insert(failureLoopStep, at: min(1, defaultPlan.count))

            let adaptedInsertionIndex = adaptedPlan.firstIndex { $0.toolCallID == "tool.execution.checkpoint" }
                .map { min($0 + 1, adaptedPlan.count) }
                ?? min(1, adaptedPlan.count)
            adaptedPlan.insert(failureLoopStep, at: adaptedInsertionIndex)
        }

        var risks = [
            RiskSignal(
                id: "risk.permissions",
                title: "Local permissions may block automation",
                severity: .medium,
                mitigation: "Request human approval before mutating files, apps, or credentials."
            ),
            RiskSignal(
                id: "risk.partial-context",
                title: "Input may omit production constraints",
                severity: .medium,
                mitigation: "Compile workspace graph context and preserve replayable execution logs."
            )
        ]

        if mentionsConnector {
            risks.append(
                RiskSignal(
                    id: "risk.oauth",
                    title: "Connector OAuth may be missing",
                    severity: .high,
                    mitigation: "Check Keychain-backed connector vault before invoking third-party APIs."
                )
            )
        }

        if hasPolicyLoop {
            risks.append(
                RiskSignal(
                    id: "risk.policy-adapted",
                    title: hasGlobalLearning ? "Plan adapted from global system learning" : "Plan adapted from previous execution policy",
                    severity: .low,
                    mitigation: hasGlobalLearning
                        ? "Planner applied cross-task memory, failure clusters, and global execution policy before selecting tools."
                        : "Planner applied persisted policy deltas and failure patterns before selecting tools."
                )
            )
        }

        return StructuredAgentOutput(
            plan: hasPolicyLoop ? adaptedPlan : defaultPlan,
            actions: [
                AgentAction(id: "action.plan", title: "Decompose task", agent: .planner, stepID: "step.context"),
                AgentAction(id: "action.execute", title: "Execute approved local tools", agent: .executor, stepID: hasPolicyLoop ? adaptedPlan.last?.id : "step.inspect"),
                AgentAction(id: "action.policy", title: "Evaluate permissions and risks", agent: .policy, stepID: "step.checkpoint")
            ],
            toolCalls: toolCalls,
            risks: risks,
            confidence: min(0.95, (mentionsConnector ? 0.68 : 0.78) + (hasPolicyLoop ? 0.08 : 0))
        )
    }

    private func isApprovedIntegrationImplementation(
        missionIntent: MissionIntent,
        normalizedInput: String
    ) -> Bool {
        missionIntent.intentType == .modifyCode
            && normalizedInput.contains("agent")
            && (
                normalizedInput.contains("integration")
                    || normalizedInput.contains("integrate")
                    || normalizedInput.contains("接入")
                    || normalizedInput.contains("集成")
            )
            && (
                normalizedInput.contains("approved")
                    || normalizedInput.contains("批准")
                    || normalizedInput.contains("patch")
                    || normalizedInput.contains("adapter")
                    || normalizedInput.contains("client")
                    || normalizedInput.contains("service")
                    || normalizedInput.contains("写代码")
            )
    }

    private func approvedIntegrationImplementationOutput(
        taskFocus: String,
        agentProjectRoot: String?,
        retryBudget: Int
    ) -> StructuredAgentOutput {
        var toolCalls = [
            ToolCall(
                id: "tool.implementation.scope",
                type: .shell,
                command: "/bin/pwd",
                arguments: [],
                workingDirectory: nil,
                requiresApproval: false
            ),
            ToolCall(
                id: "tool.implementation.test-plan",
                type: .shell,
                command: "/bin/echo",
                arguments: ["Generate integration tests before patching: \(taskFocus)"],
                workingDirectory: nil,
                requiresApproval: false
            ),
            ToolCall(
                id: "tool.implementation.patch",
                type: .shell,
                command: "/bin/echo",
                arguments: ["Generate adapter, client, service, and tests patch artifact for: \(taskFocus)"],
                workingDirectory: nil,
                requiresApproval: false
            ),
            ToolCall(
                id: "tool.implementation.verify",
                type: .shell,
                command: "/bin/echo",
                arguments: ["Prepare verification report and list test commands needed after patch application."],
                workingDirectory: nil,
                requiresApproval: false
            )
        ]

        if let agentProjectRoot {
            toolCalls.append(
                ToolCall(
                    id: "tool.implementation.agent-scope",
                    type: .shell,
                    command: "/bin/ls",
                    arguments: ["-la", "."],
                    workingDirectory: agentProjectRoot,
                    requiresApproval: false
                )
            )
        }

        var plan = [
            PlanStep(
                id: "step.implementation-scope",
                title: "Confirm approved implementation scope",
                intent: "Confirm both selected project roots remain inside the user-approved integration scope before generating changes.",
                toolCallID: "tool.implementation.scope",
                requiresApproval: false
            ),
            PlanStep(
                id: "step.test-plan",
                title: "Write integration test plan",
                intent: "Define the tests that prove the legacy software can call the AI agent and handle success, failure, credentials, and cancellation.",
                toolCallID: "tool.implementation.test-plan",
                requiresApproval: false,
                retryBudget: retryBudget
            ),
            PlanStep(
                id: "step.code-patch",
                title: "Generate adapter/client/service patch",
                intent: "Produce the patch structure for the legacy adapter, AI agent client boundary, service orchestration, and integration tests.",
                toolCallID: "tool.implementation.patch",
                requiresApproval: false,
                retryBudget: retryBudget
            ),
            PlanStep(
                id: "step.verification-report",
                title: "Prepare verification report",
                intent: "Report the commands and checks required to prove the generated patch is ready to apply and test.",
                toolCallID: "tool.implementation.verify",
                requiresApproval: false
            )
        ]

        if agentProjectRoot != nil {
            plan.insert(
                PlanStep(
                    id: "step.agent-implementation-scope",
                    title: "Re-check AI agent implementation surface",
                    intent: "Confirm the agent-side project remains available before producing integration patch guidance.",
                    toolCallID: "tool.implementation.agent-scope",
                    requiresApproval: false,
                    retryBudget: retryBudget
                ),
                at: 1
            )
        }

        return StructuredAgentOutput(
            plan: plan,
            actions: [
                AgentAction(id: "action.test-plan", title: "Define integration tests", agent: .planner, stepID: "step.test-plan"),
                AgentAction(id: "action.patch", title: "Generate integration patch", agent: .executor, stepID: "step.code-patch"),
                AgentAction(id: "action.verify", title: "Prepare verification report", agent: .policy, stepID: "step.verification-report")
            ],
            toolCalls: toolCalls,
            risks: [
                RiskSignal(
                    id: "risk.approved-implementation-scope",
                    title: "Approved implementation still needs scoped mutation controls",
                    severity: .medium,
                    mitigation: "Generate patch artifacts first, then apply file changes only through approved project-scoped mutation tools."
                ),
                RiskSignal(
                    id: "risk.verification-command-missing",
                    title: "Project-specific test command may be unknown",
                    severity: .medium,
                    mitigation: "Infer or request the exact test command before claiming integration is fully verified."
                )
            ],
            confidence: 0.82
        )
    }

    private func architectureAnalysisOutput(
        taskFocus: String,
        missionIntent: MissionIntent,
        agentProjectRoot: String?,
        agentSourceDirectory: String?,
        legacySourceFile: String?,
        agentSourceFile: String?,
        retryBudget: Int,
        hasPolicyLoop: Bool
    ) -> StructuredAgentOutput {
        var toolCalls = [
            ToolCall(
                id: "tool.workspace.pwd",
                type: .shell,
                command: "/bin/pwd",
                arguments: [],
                workingDirectory: nil,
                requiresApproval: false
            ),
            ToolCall(
                id: "tool.package.inspect",
                type: .shell,
                command: "/bin/ls",
                arguments: ["-la", "Package.swift"],
                workingDirectory: nil,
                requiresApproval: false
            ),
            ToolCall(
                id: "tool.sources.inspect",
                type: .shell,
                command: "/bin/ls",
                arguments: ["-la", "Sources"],
                workingDirectory: nil,
                requiresApproval: false
            ),
            ToolCall(
                id: "tool.tests.inspect",
                type: .shell,
                command: "/bin/ls",
                arguments: ["-la", "Tests"],
                workingDirectory: nil,
                requiresApproval: false
            ),
            ToolCall(
                id: "tool.architecture.report",
                type: .shell,
                command: "/bin/echo",
                arguments: ["Legacy and AI agent integration evidence captured for: \(taskFocus)"],
                workingDirectory: nil,
                requiresApproval: false
            )
        ]

        if let legacySourceFile {
            toolCalls.append(
                ToolCall(
                    id: "tool.legacy.source.read",
                    type: .shell,
                    command: "/usr/bin/head",
                    arguments: ["-n", "160", legacySourceFile],
                    workingDirectory: nil,
                    requiresApproval: false
                )
            )
        }

        if let agentProjectRoot {
            toolCalls.append(
                ToolCall(
                    id: "tool.agent.root.inspect",
                    type: .shell,
                    command: "/bin/ls",
                    arguments: ["-la", "."],
                    workingDirectory: agentProjectRoot,
                    requiresApproval: false
                )
            )
            if let agentSourceDirectory {
                toolCalls.append(
                    ToolCall(
                        id: "tool.agent.sources.inspect",
                        type: .shell,
                        command: "/bin/ls",
                        arguments: ["-la", agentSourceDirectory],
                        workingDirectory: agentProjectRoot,
                        requiresApproval: false
                    )
                )
            }
            if let agentSourceFile {
                toolCalls.append(
                    ToolCall(
                        id: "tool.agent.source.read",
                        type: .shell,
                        command: "/usr/bin/head",
                        arguments: ["-n", "160", agentSourceFile],
                        workingDirectory: agentProjectRoot,
                        requiresApproval: false
                    )
                )
            }
        }

        var plan = [
            PlanStep(
                id: "step.context",
                title: "Compile architecture context",
                intent: "Confirm the workspace root before inspecting project structure.",
                toolCallID: "tool.workspace.pwd",
                requiresApproval: false
            ),
            PlanStep(
                id: "step.package",
                title: "Inspect package manifest",
                intent: "Identify package boundaries, products, dependencies, and executable/test targets from the project manifest.",
                toolCallID: "tool.package.inspect",
                requiresApproval: false,
                retryBudget: retryBudget
            ),
            PlanStep(
                id: "step.sources",
                title: "Inspect source module layout",
                intent: "Capture top-level source modules so the architecture review can reason about boundaries and ownership.",
                toolCallID: "tool.sources.inspect",
                requiresApproval: false,
                retryBudget: retryBudget
            ),
            PlanStep(
                id: "step.tests",
                title: "Inspect test layout",
                intent: "Capture the verification surface and compare it to source module boundaries.",
                toolCallID: "tool.tests.inspect",
                requiresApproval: false,
                retryBudget: retryBudget
            ),
            PlanStep(
                id: "step.legacy-source",
                title: "Read legacy source sample",
                intent: "Read a bounded source sample so architecture findings are grounded in code, not only directory names.",
                toolCallID: "tool.legacy.source.read",
                requiresApproval: false,
                retryBudget: retryBudget
            ),
            PlanStep(
                id: "step.agent-root",
                title: "Inspect AI agent project",
                intent: "Capture the AI agent codebase surface so integration feasibility is judged against both sides of the connection.",
                toolCallID: "tool.agent.root.inspect",
                requiresApproval: false,
                retryBudget: retryBudget
            ),
            PlanStep(
                id: "step.report",
                title: "Prepare architecture findings",
                intent: "Summarize legacy software evidence, AI agent evidence, integration risks, and improvements requested by the user.",
                toolCallID: "tool.architecture.report",
                requiresApproval: false
            )
        ]

        if legacySourceFile == nil {
            plan.removeAll { $0.id == "step.legacy-source" }
        }

        if agentProjectRoot == nil {
            plan.removeAll { $0.id == "step.agent-root" }
        } else if agentSourceDirectory != nil {
            plan.insert(
                PlanStep(
                    id: "step.agent-sources",
                    title: "Inspect AI agent source layout",
                    intent: "Capture agent-side modules, adapters, or SDK boundaries relevant to the planned integration.",
                    toolCallID: "tool.agent.sources.inspect",
                    requiresApproval: false,
                    retryBudget: retryBudget
                ),
                at: max(0, plan.count - 1)
            )
        }

        if agentProjectRoot != nil, agentSourceFile != nil {
            plan.insert(
                PlanStep(
                    id: "step.agent-source",
                    title: "Read AI agent source sample",
                    intent: "Read a bounded agent-side source sample so integration feasibility is judged against code boundaries.",
                    toolCallID: "tool.agent.source.read",
                    requiresApproval: false,
                    retryBudget: retryBudget
                ),
                at: max(0, plan.count - 1)
            )
        }

        if hasPolicyLoop {
            plan.insert(
                PlanStep(
                    id: "step.policy-context",
                    title: "Apply learned planning policy",
                    intent: "Preserve successful checkpoint ordering before project structure inspection.",
                    toolCallID: "tool.architecture.report",
                    requiresApproval: false,
                    retryBudget: retryBudget
                ),
                at: 1
            )
        }

        return StructuredAgentOutput(
            plan: plan,
            actions: [
                AgentAction(id: "action.intent", title: "Use architecture analysis intent", agent: .planner, stepID: "step.context"),
                AgentAction(id: "action.inspect", title: "Inspect legacy and AI agent code structure", agent: .executor, stepID: "step.sources"),
                AgentAction(id: "action.report", title: "Generate architecture recommendations", agent: .policy, stepID: "step.report")
            ],
            toolCalls: toolCalls,
            risks: [
                RiskSignal(
                    id: "risk.structure-only",
                    title: "Architecture analysis starts from structural evidence",
                    severity: .low,
                    mitigation: "Use read-only structure inspection across both selected projects first, then request deeper file reads or approval if needed."
                ),
                RiskSignal(
                    id: "risk.intent-scope",
                    title: "Intent scope may need follow-up depth",
                    severity: .medium,
                    mitigation: "Preserve the parsed mission intent and ask for clarification if the requested architecture depth is ambiguous."
                )
            ],
            confidence: min(0.95, missionIntent.confidence + (hasPolicyLoop ? 0.02 : 0))
        )
    }

    private func primaryReadableSourceFile(in contextBundle: ContextBundle?, role: String) -> String? {
        guard let codebase = contextBundle?.codebases.first(where: { $0.role == role }) else {
            return nil
        }

        let sourcePrefixes = codebase.sourceDirectories.map { directory in
            directory.hasSuffix("/") ? directory : "\(directory)/"
        }
        let candidates = codebase.fileTreeSummary
            .filter { path in
                !path.hasSuffix("/")
                    && isReadableSourceFile(path)
                    && !path.lowercased().contains("/test")
                    && (sourcePrefixes.isEmpty || sourcePrefixes.contains { path.hasPrefix($0) })
            }
            .sorted { lhs, rhs in
                if lhs.count == rhs.count {
                    return lhs < rhs
                }
                return lhs.count < rhs.count
            }

        return candidates.first
    }

    private func isReadableSourceFile(_ path: String) -> Bool {
        let lowercased = path.lowercased()
        return [
            ".swift",
            ".ts",
            ".tsx",
            ".js",
            ".jsx",
            ".py",
            ".kt",
            ".java",
            ".go",
            ".rs",
            ".rb",
            ".php",
            ".cs",
            ".c",
            ".cc",
            ".cpp",
            ".h",
            ".hpp",
            ".m",
            ".mm"
        ].contains { lowercased.hasSuffix($0) }
    }
}
