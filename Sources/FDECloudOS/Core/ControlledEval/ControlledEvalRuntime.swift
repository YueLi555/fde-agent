import Foundation

enum ControlledEvalDigest {
    private struct Envelope<Value: Encodable>: Encodable {
        var artifactType: String
        var value: Value
    }

    static func sha256<Value: Encodable>(_ value: Value, artifactType: String) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(Envelope(artifactType: artifactType, value: value)) else {
            return ""
        }
        return CandidatePatchArtifactAuthority.sha256(data)
    }

    static func policySHA256(_ policy: ControlledEvalExecutionPolicy) -> String {
        var canonical = policy
        canonical.policySHA256 = ""
        return sha256(canonical, artifactType: "CONTROLLED_EVAL_EXECUTION_POLICY")
    }

    static func datasetCaseSHA256(_ datasetCase: EvalDatasetCase) -> String {
        var canonical = datasetCase
        canonical.caseSHA256 = ""
        return sha256(canonical, artifactType: "EVAL_DATASET_CASE")
    }

    static func datasetManifestSHA256(_ manifest: EvalDatasetManifest) -> String {
        var canonical = manifest
        canonical.manifestSHA256 = ""
        return sha256(canonical, artifactType: "EVAL_DATASET_MANIFEST")
    }

    static func authoritySHA256(_ binding: ControlledEvalAuthorityBinding) -> String {
        var canonical = binding
        canonical.authoritySHA256 = ""
        return sha256(canonical, artifactType: "CONTROLLED_EVAL_AUTHORITY")
    }

    static func executionRequestSHA256(_ request: ControlledEvalExecutionRequest) -> String {
        var canonical = request
        canonical.requestSHA256 = ""
        return sha256(canonical, artifactType: "CONTROLLED_EVAL_EXECUTION_REQUEST")
    }

    static func executionProposalSHA256(_ proposal: ControlledEvalExecutionProposal) -> String {
        var canonical = proposal
        canonical.proposalSHA256 = ""
        return sha256(canonical, artifactType: "CONTROLLED_EVAL_EXECUTION_PROPOSAL")
    }

    static func executionAuthorizationSHA256(
        _ authorization: ControlledEvalExecutionAuthorization
    ) -> String {
        var canonical = authorization
        canonical.authorizationSHA256 = ""
        return sha256(canonical, artifactType: "CONTROLLED_EVAL_EXECUTION_AUTHORIZATION")
    }

    static func resultReviewProposalSHA256(
        _ proposal: ControlledEvalResultReviewProposal
    ) -> String {
        var canonical = proposal
        canonical.proposalSHA256 = ""
        return sha256(canonical, artifactType: "CONTROLLED_EVAL_RESULT_REVIEW_PROPOSAL")
    }

    static func resultReviewAuthorizationSHA256(
        _ authorization: ControlledEvalResultReviewAuthorization
    ) -> String {
        var canonical = authorization
        canonical.authorizationSHA256 = ""
        return sha256(canonical, artifactType: "CONTROLLED_EVAL_RESULT_REVIEW_AUTHORIZATION")
    }

    static func reviewDecisionSHA256<Value: Encodable>(_ decision: Value) -> String {
        sha256(decision, artifactType: "PHASE_3A_REVIEW_DECISION")
    }

    static func evalReviewDecisionSHA256(_ decision: EvalRunReviewDecision) -> String {
        if decision.resultReviewAuthorizationID == nil {
            let legacy = LegacyEvalRunReviewDecision(
                decisionID: decision.decisionID,
                runID: decision.runID,
                runRevision: decision.runRevision,
                runSHA256: decision.runSHA256,
                attempt: decision.attempt,
                stage: decision.stage,
                decision: decision.decision,
                reviewerInstructions: decision.reviewerInstructions,
                approvalScope: decision.approvalScope,
                authenticatedLocalSessionID: decision.authenticatedLocalSessionID,
                workspaceSessionID: decision.workspaceSessionID,
                appSessionID: decision.appSessionID,
                decidedAt: decision.decidedAt,
                decisionSHA256: ""
            )
            return sha256(legacy, artifactType: "EVAL_RUN_REVIEW_DECISION")
        }
        var canonical = decision
        canonical.decisionSHA256 = ""
        return sha256(canonical, artifactType: "EVAL_RUN_REVIEW_DECISION")
    }

    private struct LegacyEvalRunReviewDecision: Encodable {
        var decisionID: UUID
        var runID: UUID
        var runRevision: Int
        var runSHA256: String
        var attempt: Int
        var stage: EvalRunReviewStage
        var decision: EvalRunReviewDecisionKind
        var reviewerInstructions: String?
        var approvalScope: String
        var authenticatedLocalSessionID: UUID
        var workspaceSessionID: UUID
        var appSessionID: UUID
        var decidedAt: Date
        var decisionSHA256: String
    }

    static func activityEventSHA256(_ event: EvalRunActivityEvent) -> String {
        var canonical = event
        canonical.eventSHA256 = ""
        return sha256(canonical, artifactType: "EVAL_RUN_ACTIVITY_EVENT")
    }

    static func restorationFailureSHA256(_ failure: EvalRunRestorationFailure) -> String {
        var canonical = failure
        canonical.failureSHA256 = ""
        return sha256(canonical, artifactType: "EVAL_RUN_RESTORATION_FAILURE")
    }

    static func metricObservationSHA256(_ observation: EvalMetricObservation) -> String {
        var canonical = observation
        canonical.deterministicSHA256 = ""
        return sha256(canonical, artifactType: "EVAL_METRIC_OBSERVATION")
    }

    static func metricResultSHA256(_ result: EvalMetricResult) -> String {
        var canonical = result
        canonical.deterministicSHA256 = ""
        return sha256(canonical, artifactType: "EVAL_METRIC_RESULT")
    }

    static func scenarioResultSHA256(_ result: EvalScenarioResult) -> String {
        var canonical = result
        canonical.deterministicSHA256 = ""
        return sha256(canonical, artifactType: "EVAL_SCENARIO_RESULT")
    }

    static func runRevisionDigest(
        _ revision: EvalRunRevision,
        requestSHA256: String
    ) -> EvalRunDigest {
        var canonical = revision
        canonical.digest = .empty
        let value = RunRevisionEnvelope(requestSHA256: requestSHA256, revision: canonical)
        return EvalRunDigest(
            algorithm: "SHA-256",
            canonicalSerializationVersion: 1,
            sha256: sha256(value, artifactType: "EVAL_RUN_REVISION")
        )
    }

    private struct RunRevisionEnvelope: Encodable {
        var requestSHA256: String
        var revision: EvalRunRevision
    }
}

enum ControlledEvalProviderMode: String, Codable, Hashable, Sendable {
    case deterministicFixture = "DETERMINISTIC_FIXTURE"
    case externallyConfiguredFuture = "EXTERNALLY_CONFIGURED_FUTURE"
}

struct ControlledEvalProviderIdentity: Codable, Hashable, Sendable {
    var evaluatorID: String
    var evaluatorVersion: String
    var modelVersion: String
    var mode: ControlledEvalProviderMode
}

struct ControlledEvalProviderOutput: Codable, Hashable, Sendable {
    var deterministicOutput: String
    var actualBehavior: String
    var metricValues: [String: Double]
    var evidenceReferences: [String]
    var tokenEstimate: Int
    var estimatedCost: Double
    var durationMilliseconds: Int
}

protocol ControlledEvalProviding: Sendable {
    var identity: ControlledEvalProviderIdentity { get }
    func evaluate(_ datasetCase: EvalDatasetCase) throws -> ControlledEvalProviderOutput
}

struct DeterministicFixtureEvalProvider: ControlledEvalProviding {
    static let evaluatorID = "fde.controlled-eval.fixture"
    static let evaluatorVersion = "1.0.0"
    static let modelVersion = "deterministic-fixture-v1"

    let identity = ControlledEvalProviderIdentity(
        evaluatorID: Self.evaluatorID,
        evaluatorVersion: Self.evaluatorVersion,
        modelVersion: Self.modelVersion,
        mode: .deterministicFixture
    )

    func evaluate(_ datasetCase: EvalDatasetCase) throws -> ControlledEvalProviderOutput {
        guard datasetCase.isSelfValidating else { throw ControlledEvalFailure.datasetDrift }
        return ControlledEvalProviderOutput(
            deterministicOutput: datasetCase.deterministicOutput,
            actualBehavior: datasetCase.actualBehavior,
            metricValues: datasetCase.metricValues,
            evidenceReferences: datasetCase.evidenceReferences,
            tokenEstimate: datasetCase.tokenEstimate,
            estimatedCost: datasetCase.estimatedCost,
            durationMilliseconds: datasetCase.simulatedDurationMilliseconds
        )
    }
}

struct ControlledEvalExecutionResult: Hashable, Sendable {
    var run: EvalRun
    var safetyCounters: ControlledEvalSafetyCounters
}

struct ControlledEvalExecutionService: Sendable {
    static let executionApprovalScope = "Approved only for this exact bounded deterministic Eval Run."
    static let resultsApprovalScope = "Approval applies only to this exact Eval Result artifact. INCONCLUSIVE remains INCONCLUSIVE. This is not production approval, deployment authorization, customer acceptance, or Phase 3B authorization."

    func makeDefaultPolicy(
        for plan: AIEvalPlan,
        datasetID: String,
        policyID: UUID? = nil
    ) throws -> ControlledEvalExecutionPolicy {
        try ProductionReadinessArtifactValidator.validate(plan)
        guard let revision = plan.currentRevision else {
            throw ControlledEvalFailure.exactApprovedPhase3APairRequired
        }
        let scenarioIDs = revision.scenarios.map(\.scenarioID).sorted()
        let metricIDs = revision.metrics.map(\.metricID).sorted()
        var policy = ControlledEvalExecutionPolicy(
            policyID: policyID ?? deterministicUUID("policy:\(plan.planID.uuidString):\(revision.digest.sha256):\(datasetID)"),
            revision: 1,
            scenarioAllowlist: scenarioIDs,
            metricAllowlist: metricIDs,
            datasetAllowlist: [datasetID],
            evaluatorID: DeterministicFixtureEvalProvider.evaluatorID,
            evaluatorVersion: DeterministicFixtureEvalProvider.evaluatorVersion,
            modelVersion: DeterministicFixtureEvalProvider.modelVersion,
            maximumCases: scenarioIDs.count,
            maximumAttemptsPerCase: 1,
            maximumRuntimeDurationMilliseconds: max(1_000, scenarioIDs.count * 25),
            maximumTokenEstimate: max(1_024, scenarioIDs.count * 128),
            maximumEstimatedCost: 0,
            allowedTools: [],
            networkAccessAllowed: false,
            productionAccessAllowed: false,
            credentialAccessAllowed: false,
            stopOnCriticalFailure: true,
            policySHA256: ""
        )
        policy.policySHA256 = ControlledEvalDigest.policySHA256(policy)
        return policy
    }

    func makeFixtureDataset(
        for plan: AIEvalPlan,
        datasetID: String? = nil
    ) throws -> EvalDatasetManifest {
        try ProductionReadinessArtifactValidator.validate(plan)
        guard let revision = plan.currentRevision else {
            throw ControlledEvalFailure.exactApprovedPhase3APairRequired
        }
        let resolvedDatasetID = datasetID
            ?? "dataset.phase-3a1.\(plan.planID.uuidString.lowercased()).r\(revision.revision)"
        let metricsByID = Dictionary(uniqueKeysWithValues: revision.metrics.map { ($0.metricID, $0) })
        let cases = revision.scenarios.sorted { $0.scenarioID < $1.scenarioID }.map { scenario in
            let values = Dictionary(uniqueKeysWithValues: scenario.metricBindings.sorted().map { metricID in
                (metricID, defaultPassingValue(metricID: metricID, metric: metricsByID[metricID]))
            })
            var datasetCase = EvalDatasetCase(
                caseID: "fixture.case.\(scenario.scenarioID)",
                scenarioID: scenario.scenarioID,
                input: "Approved synthetic fixture input for \(scenario.title).",
                expectedBehavior: scenario.expectedBehavior,
                deterministicOutput: "fixture-output:\(scenario.scenarioID):bounded-read-only-response",
                actualBehavior: scenario.expectedBehavior.first ?? "Bounded deterministic behavior emitted.",
                metricValues: values,
                evidenceReferences: ["fixture-evidence:\(scenario.scenarioID)"],
                tokenEstimate: 32,
                estimatedCost: 0,
                simulatedDurationMilliseconds: 5,
                isCriticalFailure: false,
                caseSHA256: ""
            )
            datasetCase.caseSHA256 = ControlledEvalDigest.datasetCaseSHA256(datasetCase)
            return datasetCase
        }
        var manifest = EvalDatasetManifest(
            datasetID: resolvedDatasetID,
            revision: 1,
            sourceKind: .appManaged,
            fixturePath: nil,
            approvedDatasetRequirementIDs: revision.datasetRequirements.map(\.datasetRequirementID).sorted(),
            approvedScenarioIDs: revision.scenarios.map(\.scenarioID).sorted(),
            cases: cases,
            readOnly: true,
            deterministic: true,
            containsProductionData: false,
            containsCustomerSecrets: false,
            manifestSHA256: ""
        )
        manifest.manifestSHA256 = ControlledEvalDigest.datasetManifestSHA256(manifest)
        return manifest
    }

    func makeExecutionProposal(
        report: ProductionReadinessReport,
        evalPlan: AIEvalPlan,
        context: ControlledEvalExecutionContext,
        requestedScenarioIDs: [String]? = nil
    ) throws -> ControlledEvalExecutionProposal {
        let dataset = try makeFixtureDataset(for: evalPlan)
        let policy = try makeDefaultPolicy(for: evalPlan, datasetID: dataset.datasetID)
        return try makeExecutionProposal(
            report: report,
            evalPlan: evalPlan,
            dataset: dataset,
            policy: policy,
            context: context,
            requestedScenarioIDs: requestedScenarioIDs
        )
    }

    func makeExecutionProposal(
        report: ProductionReadinessReport,
        evalPlan: AIEvalPlan,
        dataset: EvalDatasetManifest,
        policy: ControlledEvalExecutionPolicy,
        context: ControlledEvalExecutionContext,
        requestedScenarioIDs: [String]? = nil
    ) throws -> ControlledEvalExecutionProposal {
        let approved = try validateExactApprovedPair(
            report: report,
            plan: evalPlan,
            context: context,
            acceptsPriorArtifactAppSession: true
        )
        try validatePolicyAndDataset(
            policy: policy,
            dataset: dataset,
            planRevision: approved.planRevision
        )
        let scenarios = (requestedScenarioIDs ?? policy.scenarioAllowlist).sorted()
        guard !scenarios.isEmpty,
              scenarios.count == Set(scenarios).count,
              scenarios.allSatisfy({ !$0.isEmpty }),
              Set(scenarios).isSubset(of: Set(approved.planRevision.scenarios.map(\.scenarioID))),
              Set(scenarios).isSubset(of: Set(policy.scenarioAllowlist)) else {
            throw ControlledEvalFailure.scenarioNotApproved
        }
        let selectedCases = dataset.cases.filter { scenarios.contains($0.scenarioID) }
        guard Set(selectedCases.map(\.scenarioID)) == Set(scenarios) else {
            throw ControlledEvalFailure.datasetDrift
        }
        let requestedMetrics = approved.planRevision.scenarios
            .filter { scenarios.contains($0.scenarioID) }
            .flatMap(\.metricBindings)
            .uniquedSorted()
        guard Set(requestedMetrics).isSubset(of: Set(policy.metricAllowlist)) else {
            throw ControlledEvalFailure.metricNotApproved
        }
        let tokenEstimate = selectedCases.reduce(0) { $0 + $1.tokenEstimate }
        let costEstimate = selectedCases.reduce(0) { $0 + $1.estimatedCost }
        try validateLimits(
            caseCount: selectedCases.count,
            duration: selectedCases.reduce(0) { $0 + $1.simulatedDurationMilliseconds },
            tokenEstimate: tokenEstimate,
            estimatedCost: costEstimate,
            policy: policy
        )
        var authority = ControlledEvalAuthorityBinding(
            readinessSourceBinding: report.sourceBinding,
            productionReadinessReportID: report.reportID,
            productionReadinessReportRevision: approved.reportRevision.revision,
            productionReadinessReportSHA256: approved.reportRevision.digest.sha256,
            productionReadinessReviewDecisionID: approved.reportDecision.decisionID,
            productionReadinessReviewDecisionSHA256: ControlledEvalDigest.reviewDecisionSHA256(approved.reportDecision),
            aiEvalPlanID: evalPlan.planID,
            aiEvalPlanRevision: approved.planRevision.revision,
            aiEvalPlanSHA256: approved.planRevision.digest.sha256,
            aiEvalPlanReviewDecisionID: approved.planDecision.decisionID,
            aiEvalPlanReviewDecisionSHA256: ControlledEvalDigest.reviewDecisionSHA256(approved.planDecision),
            capabilityID: report.sourceBinding.normalizedCapabilityID,
            authenticatedLocalSessionID: context.authenticatedLocalSessionID,
            workspaceSessionID: context.workspaceSessionID,
            appSessionID: context.appSessionID,
            executionPolicySHA256: policy.policySHA256,
            datasetManifestSHA256: dataset.manifestSHA256,
            evaluatorID: policy.evaluatorID,
            evaluatorVersion: policy.evaluatorVersion,
            modelVersion: policy.modelVersion,
            authoritySHA256: ""
        )
        authority.authoritySHA256 = ControlledEvalDigest.authoritySHA256(authority)
        let proposalID = deterministicUUID("proposal:\(authority.authoritySHA256):\(scenarios.joined(separator: ","))")
        var proposal = ControlledEvalExecutionProposal(
            proposalID: proposalID,
            authorizationChallengeID: deterministicUUID("authorization-challenge:\(proposalID.uuidString.lowercased()):\(authority.authoritySHA256)"),
            authority: authority,
            requestedScenarioIDs: scenarios,
            requestedMetricIDs: requestedMetrics,
            policy: policy,
            dataset: dataset,
            estimatedTokenCount: tokenEstimate,
            estimatedCost: costEstimate,
            proposalSHA256: ""
        )
        proposal.proposalSHA256 = ControlledEvalDigest.executionProposalSHA256(proposal)
        guard proposal.isSelfValidating else { throw ControlledEvalFailure.authorityMismatch }
        return proposal
    }

    func prepare(
        report: ProductionReadinessReport,
        evalPlan: AIEvalPlan,
        dataset: EvalDatasetManifest,
        policy: ControlledEvalExecutionPolicy,
        context: ControlledEvalExecutionContext,
        requestedScenarioIDs: [String]? = nil,
        runID: UUID = UUID(),
        now: Date = Date()
    ) throws -> EvalRun {
        let proposal = try makeExecutionProposal(
            report: report,
            evalPlan: evalPlan,
            dataset: dataset,
            policy: policy,
            context: context,
            requestedScenarioIDs: requestedScenarioIDs
        )
        guard proposal.originatingArtifactAppSessionID == context.appSessionID else {
            throw ControlledEvalFailure.sessionMismatch
        }
        return try makeRun(
            proposal: proposal,
            executionAuthorizationID: nil,
            runID: runID,
            now: now
        )
    }

    func authorizeExecution(
        proposal: ControlledEvalExecutionProposal,
        context: ControlledEvalExecutionContext,
        confirmationID: UUID = UUID(),
        now: Date = Date(),
        validityDuration: TimeInterval = 15 * 60
    ) throws -> ControlledEvalExecutionAuthorization {
        try validateProposal(proposal, context: context)
        guard validityDuration > 0 else { throw ControlledEvalFailure.executionAuthorizationStale }
        var authorization = ControlledEvalExecutionAuthorization(
            authorizationID: UUID(),
            authorizationChallengeID: proposal.authorizationChallengeID,
            confirmationID: confirmationID,
            proposalSHA256: proposal.proposalSHA256,
            authority: proposal.authority,
            requestedScenarioIDs: proposal.requestedScenarioIDs,
            requestedMetricIDs: proposal.requestedMetricIDs,
            executionPolicySHA256: proposal.policy.policySHA256,
            datasetManifestSHA256: proposal.dataset.manifestSHA256,
            evaluatorID: proposal.policy.evaluatorID,
            evaluatorVersion: proposal.policy.evaluatorVersion,
            modelVersion: proposal.policy.modelVersion,
            createdAt: now,
            expiresAt: now.addingTimeInterval(validityDuration),
            consumedAt: nil,
            authorizationSHA256: ""
        )
        authorization.authorizationSHA256 = ControlledEvalDigest.executionAuthorizationSHA256(authorization)
        guard authorization.isSelfValidating else { throw ControlledEvalFailure.authorityMismatch }
        return authorization
    }

    func validateExecutionAuthorization(
        _ authorization: ControlledEvalExecutionAuthorization,
        proposal: ControlledEvalExecutionProposal,
        context: ControlledEvalExecutionContext,
        now: Date = Date()
    ) throws {
        try validateProposal(proposal, context: context)
        guard authorization.isSelfValidating else { throw ControlledEvalFailure.authorityMismatch }
        guard authorization.isAvailable(at: now) else {
            throw ControlledEvalFailure.executionAuthorizationStale
        }
        guard authorization.authorizationChallengeID == proposal.authorizationChallengeID,
              authorization.proposalSHA256 == proposal.proposalSHA256,
              authorization.authority == proposal.authority,
              authorization.requestedScenarioIDs == proposal.requestedScenarioIDs,
              authorization.requestedMetricIDs == proposal.requestedMetricIDs,
              authorization.executionPolicySHA256 == proposal.policy.policySHA256,
              authorization.datasetManifestSHA256 == proposal.dataset.manifestSHA256,
              authorization.evaluatorID == proposal.policy.evaluatorID,
              authorization.evaluatorVersion == proposal.policy.evaluatorVersion,
              authorization.modelVersion == proposal.policy.modelVersion else {
            throw ControlledEvalFailure.authorityMismatch
        }
    }

    func prepareAuthorized(
        report: ProductionReadinessReport,
        evalPlan: AIEvalPlan,
        proposal: ControlledEvalExecutionProposal,
        authorization: ControlledEvalExecutionAuthorization,
        context: ControlledEvalExecutionContext,
        runID: UUID = UUID(),
        now: Date = Date()
    ) throws -> (run: EvalRun, consumedAuthorization: ControlledEvalExecutionAuthorization) {
        let currentProposal = try makeExecutionProposal(
            report: report,
            evalPlan: evalPlan,
            dataset: proposal.dataset,
            policy: proposal.policy,
            context: context,
            requestedScenarioIDs: proposal.requestedScenarioIDs
        )
        guard currentProposal == proposal else { throw ControlledEvalFailure.authorityMismatch }
        try validateExecutionAuthorization(
            authorization,
            proposal: proposal,
            context: context,
            now: now
        )
        var consumed = authorization
        consumed.consumedAt = now
        consumed.authorizationSHA256 = ControlledEvalDigest.executionAuthorizationSHA256(consumed)
        let run = try makeRun(
            proposal: proposal,
            executionAuthorizationID: authorization.authorizationID,
            runID: runID,
            now: now
        )
        return (run, consumed)
    }

    private func makeRun(
        proposal: ControlledEvalExecutionProposal,
        executionAuthorizationID: UUID?,
        runID: UUID,
        now: Date
    ) throws -> EvalRun {
        var request = ControlledEvalExecutionRequest(
            requestID: deterministicUUID("request:\(runID.uuidString.lowercased()):\(proposal.authority.authoritySHA256)"),
            runID: runID,
            executionAuthorizationID: executionAuthorizationID,
            authority: proposal.authority,
            requestedScenarioIDs: proposal.requestedScenarioIDs,
            requestedMetricIDs: proposal.requestedMetricIDs,
            policy: proposal.policy,
            dataset: proposal.dataset,
            estimatedTokenCount: proposal.estimatedTokenCount,
            estimatedCost: proposal.estimatedCost,
            requestedAt: now,
            requestSHA256: ""
        )
        request.requestSHA256 = ControlledEvalDigest.executionRequestSHA256(request)
        var run = EvalRun(
            runID: runID,
            request: request,
            revisions: [],
            reviewDecisions: [],
            activityEvents: [],
            restorationFailures: [],
            createdAt: now,
            updatedAt: now
        )
        appendRevision(
            to: &run,
            attempt: 1,
            state: .awaitingExecutionApproval,
            overallResult: .notExecuted,
            unexecutedScenarioIDs: proposal.requestedScenarioIDs,
            now: now
        )
        try ControlledEvalArtifactValidator.validate(run)
        return run
    }

    func approveExecution(
        _ run: EvalRun,
        context: ControlledEvalExecutionContext,
        now: Date = Date()
    ) throws -> EvalRun {
        try ControlledEvalArtifactValidator.validate(run)
        try validateContext(run.request.authority, context: context)
        guard let current = run.currentRevision,
              current.state == .awaitingExecutionApproval,
              run.reviewDecision(stage: .execution, attempt: current.attempt) == nil else {
            throw ControlledEvalFailure.duplicateAction
        }
        var updated = run
        var decision = EvalRunReviewDecision(
            decisionID: UUID(),
            runID: run.runID,
            runRevision: current.revision,
            runSHA256: current.digest.sha256,
            attempt: current.attempt,
            stage: .execution,
            decision: .approveExecution,
            reviewerInstructions: nil,
            approvalScope: Self.executionApprovalScope,
            authenticatedLocalSessionID: context.authenticatedLocalSessionID,
            workspaceSessionID: context.workspaceSessionID,
            appSessionID: context.appSessionID,
            decidedAt: now,
            decisionSHA256: ""
        )
        decision.decisionSHA256 = ControlledEvalDigest.evalReviewDecisionSHA256(decision)
        updated.reviewDecisions.append(decision)
        appendRevision(
            to: &updated,
            attempt: current.attempt,
            state: .executionApproved,
            overallResult: .notExecuted,
            unexecutedScenarioIDs: run.request.requestedScenarioIDs,
            now: now
        )
        try ControlledEvalArtifactValidator.validate(updated)
        return updated
    }

    func beginExecution(
        _ run: EvalRun,
        report: ProductionReadinessReport,
        evalPlan: AIEvalPlan,
        context: ControlledEvalExecutionContext,
        provider: any ControlledEvalProviding = DeterministicFixtureEvalProvider(),
        now: Date = Date()
    ) throws -> EvalRun {
        try ControlledEvalArtifactValidator.validate(run)
        guard let current = run.currentRevision,
              current.state == .executionApproved,
              run.reviewDecision(stage: .execution, attempt: current.attempt)?.decision == .approveExecution else {
            throw ControlledEvalFailure.executionApprovalRequired
        }
        try revalidateExecutionAuthority(
            run: run,
            report: report,
            plan: evalPlan,
            context: context,
            provider: provider
        )
        var updated = run
        appendRevision(
            to: &updated,
            attempt: current.attempt,
            state: .validatingAuthority,
            overallResult: .notExecuted,
            unexecutedScenarioIDs: run.request.requestedScenarioIDs,
            now: now
        )
        appendRevision(
            to: &updated,
            attempt: current.attempt,
            state: .validatingDataset,
            overallResult: .notExecuted,
            unexecutedScenarioIDs: run.request.requestedScenarioIDs,
            now: now
        )
        appendRevision(
            to: &updated,
            attempt: current.attempt,
            state: .executing,
            overallResult: .notExecuted,
            startedAt: now,
            unexecutedScenarioIDs: run.request.requestedScenarioIDs,
            now: now
        )
        try ControlledEvalArtifactValidator.validate(updated)
        return updated
    }

    func completeExecution(
        _ run: EvalRun,
        report: ProductionReadinessReport,
        evalPlan: AIEvalPlan,
        context: ControlledEvalExecutionContext,
        provider: any ControlledEvalProviding = DeterministicFixtureEvalProvider(),
        cancellationRequested: Bool = false,
        now: Date = Date()
    ) throws -> ControlledEvalExecutionResult {
        try ControlledEvalArtifactValidator.validate(run)
        guard let current = run.currentRevision, current.state == .executing else {
            throw ControlledEvalFailure.invalidStateTransition
        }
        try revalidateExecutionAuthority(
            run: run,
            report: report,
            plan: evalPlan,
            context: context,
            provider: provider
        )
        if cancellationRequested {
            return ControlledEvalExecutionResult(
                run: try cancel(run, context: context, now: now),
                safetyCounters: ControlledEvalSafetyCounters()
            )
        }

        let planRevision = try requiredPlanRevision(evalPlan, authority: run.request.authority)
        let metricByID = Dictionary(uniqueKeysWithValues: planRevision.metrics.map { ($0.metricID, $0) })
        let scenarioByID = Dictionary(uniqueKeysWithValues: planRevision.scenarios.map { ($0.scenarioID, $0) })
        let casesByScenario = Dictionary(grouping: run.request.dataset.cases, by: \.scenarioID)
        var executions: [EvalScenarioExecution] = []
        var failures: [EvalFailureRecord] = []
        var evidence: [EvalExecutionEvidence] = []
        var totalTokens = 0
        var totalCost = 0.0
        var totalDuration = 0
        var stopped = false

        for scenarioID in run.request.requestedScenarioIDs {
            guard !stopped else { break }
            guard let scenario = scenarioByID[scenarioID] else {
                throw ControlledEvalFailure.scenarioNotApproved
            }
            let scenarioCases = (casesByScenario[scenarioID] ?? []).sorted { $0.caseID < $1.caseID }
            var results: [EvalScenarioResult] = []
            let scenarioStart = now.addingTimeInterval(Double(totalDuration) / 1_000)
            for datasetCase in scenarioCases {
                let output = try provider.evaluate(datasetCase)
                guard output == approvedFixtureOutput(for: datasetCase) else {
                    throw ControlledEvalFailure.providerMismatch
                }
                totalTokens += output.tokenEstimate
                totalCost += output.estimatedCost
                totalDuration += output.durationMilliseconds
                if totalTokens > run.request.policy.maximumTokenEstimate {
                    failures.append(limitFailure(.tokenLimitExceeded, "The approved token estimate limit was exceeded.", scenarioID: scenarioID, caseID: datasetCase.caseID, now: now))
                    stopped = true
                    break
                }
                if totalCost > run.request.policy.maximumEstimatedCost {
                    failures.append(limitFailure(.costLimitExceeded, "The approved estimated cost limit was exceeded.", scenarioID: scenarioID, caseID: datasetCase.caseID, now: now))
                    stopped = true
                    break
                }
                if totalDuration > run.request.policy.maximumRuntimeDurationMilliseconds {
                    failures.append(limitFailure(.runtimeLimitExceeded, "The approved runtime duration limit was exceeded.", scenarioID: scenarioID, caseID: datasetCase.caseID, now: now))
                    stopped = true
                    break
                }
                let observations = try scenario.metricBindings.sorted().map { metricID -> EvalMetricObservation in
                    guard run.request.requestedMetricIDs.contains(metricID),
                          run.request.policy.metricAllowlist.contains(metricID),
                          metricByID[metricID] != nil,
                          let value = output.metricValues[metricID] else {
                        throw ControlledEvalFailure.metricNotApproved
                    }
                    var observation = EvalMetricObservation(
                        observationID: "observation:\(scenarioID):\(datasetCase.caseID):\(metricID):attempt-\(current.attempt)",
                        metricID: metricID,
                        scenarioID: scenarioID,
                        caseID: datasetCase.caseID,
                        numeratorContribution: value,
                        denominatorContribution: 1,
                        observedValue: value,
                        evidenceReferences: output.evidenceReferences.sorted(),
                        evaluatorVersion: provider.identity.evaluatorVersion,
                        deterministicSHA256: ""
                    )
                    observation.deterministicSHA256 = ControlledEvalDigest.metricObservationSHA256(observation)
                    return observation
                }
                let outcomes = observations.map { observation in
                    metricOutcome(
                        observedValue: observation.observedValue,
                        proposedThreshold: metricByID[observation.metricID]?.proposedThreshold ?? "",
                        evidenceReferences: observation.evidenceReferences
                    )
                }
                let outcome: EvalScenarioOutcome
                if outcomes.contains(.fail) { outcome = .fail }
                else if outcomes.contains(.inconclusive) || observations.isEmpty { outcome = .inconclusive }
                else { outcome = .pass }
                let resultFailures: [UUID]
                if output.evidenceReferences.isEmpty {
                    let failure = EvalFailureRecord(
                        failureID: UUID(),
                        kind: .missingEvidence,
                        scenarioID: scenarioID,
                        caseID: datasetCase.caseID,
                        metricID: nil,
                        summary: "Required deterministic execution evidence is missing; this case cannot pass.",
                        isCritical: false,
                        evidenceReferences: [],
                        recordedAt: now
                    )
                    failures.append(failure)
                    resultFailures = [failure.failureID]
                } else if outcome == .fail {
                    let failure = EvalFailureRecord(
                        failureID: UUID(),
                        kind: datasetCase.isCriticalFailure ? .criticalGateFailure : .policyViolation,
                        scenarioID: scenarioID,
                        caseID: datasetCase.caseID,
                        metricID: observations.first(where: {
                            metricOutcome(
                                observedValue: $0.observedValue,
                                proposedThreshold: metricByID[$0.metricID]?.proposedThreshold ?? "",
                                evidenceReferences: $0.evidenceReferences
                            ) == .fail
                        })?.metricID,
                        summary: "One or more approved metric thresholds failed.",
                        isCritical: datasetCase.isCriticalFailure,
                        evidenceReferences: output.evidenceReferences.sorted(),
                        recordedAt: now
                    )
                    failures.append(failure)
                    resultFailures = [failure.failureID]
                } else {
                    resultFailures = []
                }
                var result = EvalScenarioResult(
                    scenarioID: scenarioID,
                    caseID: datasetCase.caseID,
                    expectedBehavior: datasetCase.expectedBehavior,
                    actualBehavior: output.actualBehavior,
                    deterministicOutput: output.deterministicOutput,
                    outcome: output.evidenceReferences.isEmpty ? .inconclusive : outcome,
                    metricObservations: observations,
                    evidenceReferences: output.evidenceReferences.sorted(),
                    failureIDs: resultFailures,
                    evaluatorID: provider.identity.evaluatorID,
                    evaluatorVersion: provider.identity.evaluatorVersion,
                    deterministicSHA256: ""
                )
                result.deterministicSHA256 = ControlledEvalDigest.scenarioResultSHA256(result)
                results.append(result)
                for reference in output.evidenceReferences.sorted() {
                    evidence.append(EvalExecutionEvidence(
                        evidenceID: reference,
                        scenarioID: scenarioID,
                        caseID: datasetCase.caseID,
                        sourceKind: "DETERMINISTIC_FIXTURE",
                        sourceSHA256: datasetCase.caseSHA256,
                        summary: "Deterministic fixture execution evidence for the exact approved case.",
                        limitations: "Fixture evidence is bounded eval evidence; it is not production validation or deployment authorization."
                    ))
                }
                if datasetCase.isCriticalFailure,
                   outcome == .fail,
                   run.request.policy.stopOnCriticalFailure {
                    stopped = true
                    break
                }
            }
            let unexecutedCases = scenarioCases.map(\.caseID).filter { caseID in
                !results.contains { $0.caseID == caseID }
            }
            let scenarioOutcome: EvalScenarioOutcome
            if results.contains(where: { $0.outcome == .fail }) { scenarioOutcome = .fail }
            else if !unexecutedCases.isEmpty || results.contains(where: { $0.outcome == .inconclusive }) { scenarioOutcome = .inconclusive }
            else if results.isEmpty { scenarioOutcome = .notExecuted }
            else { scenarioOutcome = .pass }
            let scenarioDuration = results.reduce(0) { partial, result in
                partial + (scenarioCases.first(where: { $0.caseID == result.caseID })?.simulatedDurationMilliseconds ?? 0)
            }
            executions.append(EvalScenarioExecution(
                executionID: deterministicUUID("execution:\(run.runID.uuidString):\(current.attempt):\(scenarioID)"),
                scenarioID: scenarioID,
                attempt: current.attempt,
                startedAt: scenarioStart,
                endedAt: scenarioStart.addingTimeInterval(Double(scenarioDuration) / 1_000),
                durationMilliseconds: scenarioDuration,
                results: results,
                outcome: scenarioOutcome,
                unexecutedCaseIDs: unexecutedCases
            ))
        }

        let executedScenarioIDs = Set(executions.filter { !$0.results.isEmpty }.map(\.scenarioID))
        let unexecutedScenarioIDs = run.request.requestedScenarioIDs.filter { !executedScenarioIDs.contains($0) }
        let metricResults = aggregateMetricResults(
            executions: executions,
            planRevision: planRevision,
            evaluatorVersion: provider.identity.evaluatorVersion
        )
        let overall = overallResult(
            metricResults: metricResults,
            planRevision: planRevision,
            requestedMetricIDs: Set(run.request.requestedMetricIDs),
            unexecutedScenarioIDs: unexecutedScenarioIDs
        )
        let end = now.addingTimeInterval(Double(totalDuration) / 1_000)
        var updated = run
        if stopped, failures.contains(where: {
            $0.kind == .runtimeLimitExceeded || $0.kind == .tokenLimitExceeded || $0.kind == .costLimitExceeded
        }) {
            appendRevision(
                to: &updated,
                attempt: current.attempt,
                state: .stoppedFailClosed,
                overallResult: .inconclusive,
                scenarioExecutions: executions,
                metricResults: metricResults,
                failures: failures,
                evidence: evidence,
                startedAt: current.startedAt,
                endedAt: end,
                durationMilliseconds: totalDuration,
                tokenEstimate: totalTokens,
                estimatedCost: totalCost,
                unexecutedScenarioIDs: unexecutedScenarioIDs,
                now: end
            )
        } else {
            appendRevision(
                to: &updated,
                attempt: current.attempt,
                state: .executionCompleted,
                overallResult: overall,
                scenarioExecutions: executions,
                metricResults: metricResults,
                failures: failures,
                evidence: evidence,
                startedAt: current.startedAt,
                endedAt: end,
                durationMilliseconds: totalDuration,
                tokenEstimate: totalTokens,
                estimatedCost: totalCost,
                unexecutedScenarioIDs: unexecutedScenarioIDs,
                now: end
            )
            appendRevision(
                to: &updated,
                attempt: current.attempt,
                state: .resultsAwaitingReview,
                overallResult: overall,
                scenarioExecutions: executions,
                metricResults: metricResults,
                failures: failures,
                evidence: evidence,
                startedAt: current.startedAt,
                endedAt: end,
                durationMilliseconds: totalDuration,
                tokenEstimate: totalTokens,
                estimatedCost: totalCost,
                unexecutedScenarioIDs: unexecutedScenarioIDs,
                now: end
            )
        }
        try ControlledEvalArtifactValidator.validate(updated)
        var counters = ControlledEvalSafetyCounters()
        counters.deterministicFixtureExecutions = executions.flatMap(\.results).count
        guard counters.hasZeroExternalAuthority else { throw ControlledEvalFailure.policyViolation }
        return ControlledEvalExecutionResult(run: updated, safetyCounters: counters)
    }

    func execute(
        _ run: EvalRun,
        report: ProductionReadinessReport,
        evalPlan: AIEvalPlan,
        context: ControlledEvalExecutionContext,
        provider: any ControlledEvalProviding = DeterministicFixtureEvalProvider(),
        cancellationRequested: Bool = false,
        now: Date = Date()
    ) throws -> ControlledEvalExecutionResult {
        let begun = try beginExecution(
            run,
            report: report,
            evalPlan: evalPlan,
            context: context,
            provider: provider,
            now: now
        )
        return try completeExecution(
            begun,
            report: report,
            evalPlan: evalPlan,
            context: context,
            provider: provider,
            cancellationRequested: cancellationRequested,
            now: now
        )
    }

    func validateResultReviewProvenance(
        _ run: EvalRun,
        report: ProductionReadinessReport,
        evalPlan: AIEvalPlan,
        context: ControlledEvalExecutionContext,
        provider: any ControlledEvalProviding = DeterministicFixtureEvalProvider()
    ) throws {
        try ControlledEvalArtifactValidator.validate(run)
        try revalidateExecutionProvenance(
            run: run,
            report: report,
            plan: evalPlan,
            context: context,
            provider: provider
        )
    }

    func makeResultReviewProposal(
        _ run: EvalRun,
        report: ProductionReadinessReport,
        evalPlan: AIEvalPlan,
        context: ControlledEvalExecutionContext,
        provider: any ControlledEvalProviding = DeterministicFixtureEvalProvider()
    ) throws -> ControlledEvalResultReviewProposal {
        try validateResultReviewProvenance(
            run,
            report: report,
            evalPlan: evalPlan,
            context: context,
            provider: provider
        )
        guard let current = run.currentRevision,
              current.state == .resultsAwaitingReview,
              run.reviewDecision(stage: .results, attempt: current.attempt) == nil,
              let executionAuthorizationID = run.request.executionAuthorizationID else {
            throw ControlledEvalFailure.reviewAuthorityUnavailable
        }
        let currentSession = ControlledEvalSessionAuthority(
            workspaceID: context.workspaceID,
            authenticatedLocalSessionID: context.authenticatedLocalSessionID,
            workspaceSessionID: context.workspaceSessionID,
            appSessionID: context.appSessionID
        )
        let seed = [
            run.runID.uuidString.lowercased(),
            String(current.revision),
            current.digest.sha256,
            currentSession.appSessionID.uuidString.lowercased(),
            currentSession.workspaceSessionID.uuidString.lowercased()
        ].joined(separator: ":")
        let proposalID = deterministicUUID("result-review-proposal:\(seed)")
        var proposal = ControlledEvalResultReviewProposal(
            proposalID: proposalID,
            reviewChallengeID: deterministicUUID("result-review-challenge:\(proposalID.uuidString.lowercased()):\(current.digest.sha256)"),
            executionAuthorizationID: executionAuthorizationID,
            executionAuthority: run.request.authority,
            currentSessionAuthority: currentSession,
            runID: run.runID,
            runRequestSHA256: run.request.requestSHA256,
            resultRevision: current.revision,
            resultSHA256: current.digest.sha256,
            attempt: current.attempt,
            overallResult: current.overallResult,
            executionPolicySHA256: run.request.policy.policySHA256,
            datasetManifestSHA256: run.request.dataset.manifestSHA256,
            evaluatorID: run.request.authority.evaluatorID,
            evaluatorVersion: run.request.authority.evaluatorVersion,
            modelVersion: run.request.authority.modelVersion,
            proposalSHA256: ""
        )
        proposal.proposalSHA256 = ControlledEvalDigest.resultReviewProposalSHA256(proposal)
        guard proposal.isSelfValidating else { throw ControlledEvalFailure.authorityMismatch }
        return proposal
    }

    func authorizeResultReview(
        proposal: ControlledEvalResultReviewProposal,
        context: ControlledEvalExecutionContext,
        confirmationID: UUID = UUID(),
        now: Date = Date(),
        validityDuration: TimeInterval = 15 * 60
    ) throws -> ControlledEvalResultReviewAuthorization {
        try validateResultReviewProposal(proposal, context: context)
        guard validityDuration > 0 else { throw ControlledEvalFailure.executionAuthorizationStale }
        let authority = proposal.executionAuthority
        var authorization = ControlledEvalResultReviewAuthorization(
            authorizationID: UUID(),
            reviewChallengeID: proposal.reviewChallengeID,
            confirmationID: confirmationID,
            proposalSHA256: proposal.proposalSHA256,
            currentSessionAuthority: proposal.currentSessionAuthority,
            workspaceID: authority.workspaceID,
            missionRunID: authority.missionRunID,
            runID: proposal.runID,
            runRequestSHA256: proposal.runRequestSHA256,
            resultRevision: proposal.resultRevision,
            resultSHA256: proposal.resultSHA256,
            attempt: proposal.attempt,
            overallResult: proposal.overallResult,
            executionAuthorizationID: proposal.executionAuthorizationID,
            executionPolicySHA256: proposal.executionPolicySHA256,
            datasetManifestSHA256: proposal.datasetManifestSHA256,
            evaluatorID: proposal.evaluatorID,
            evaluatorVersion: proposal.evaluatorVersion,
            modelVersion: proposal.modelVersion,
            productionReadinessReportID: authority.productionReadinessReportID,
            productionReadinessReportRevision: authority.productionReadinessReportRevision,
            productionReadinessReportSHA256: authority.productionReadinessReportSHA256,
            aiEvalPlanID: authority.aiEvalPlanID,
            aiEvalPlanRevision: authority.aiEvalPlanRevision,
            aiEvalPlanSHA256: authority.aiEvalPlanSHA256,
            readinessSourceBinding: authority.readinessSourceBinding,
            createdAt: now,
            expiresAt: now.addingTimeInterval(validityDuration),
            consumedAt: nil,
            authorizationSHA256: ""
        )
        authorization.authorizationSHA256 = ControlledEvalDigest.resultReviewAuthorizationSHA256(authorization)
        guard authorization.isSelfValidating else { throw ControlledEvalFailure.authorityMismatch }
        return authorization
    }

    func validateResultReviewAuthorization(
        _ authorization: ControlledEvalResultReviewAuthorization,
        proposal: ControlledEvalResultReviewProposal,
        context: ControlledEvalExecutionContext,
        now: Date = Date()
    ) throws {
        try validateResultReviewProposal(proposal, context: context)
        guard authorization.isAvailable(at: now) else {
            throw ControlledEvalFailure.executionAuthorizationStale
        }
        let authority = proposal.executionAuthority
        guard authorization.reviewChallengeID == proposal.reviewChallengeID,
              authorization.proposalSHA256 == proposal.proposalSHA256,
              authorization.currentSessionAuthority == proposal.currentSessionAuthority,
              authorization.workspaceID == authority.workspaceID,
              authorization.missionRunID == authority.missionRunID,
              authorization.runID == proposal.runID,
              authorization.runRequestSHA256 == proposal.runRequestSHA256,
              authorization.resultRevision == proposal.resultRevision,
              authorization.resultSHA256 == proposal.resultSHA256,
              authorization.attempt == proposal.attempt,
              authorization.overallResult == proposal.overallResult,
              authorization.executionAuthorizationID == proposal.executionAuthorizationID,
              authorization.executionPolicySHA256 == proposal.executionPolicySHA256,
              authorization.datasetManifestSHA256 == proposal.datasetManifestSHA256,
              authorization.evaluatorID == proposal.evaluatorID,
              authorization.evaluatorVersion == proposal.evaluatorVersion,
              authorization.modelVersion == proposal.modelVersion,
              authorization.productionReadinessReportID == authority.productionReadinessReportID,
              authorization.productionReadinessReportRevision == authority.productionReadinessReportRevision,
              authorization.productionReadinessReportSHA256 == authority.productionReadinessReportSHA256,
              authorization.aiEvalPlanID == authority.aiEvalPlanID,
              authorization.aiEvalPlanRevision == authority.aiEvalPlanRevision,
              authorization.aiEvalPlanSHA256 == authority.aiEvalPlanSHA256,
              authorization.readinessSourceBinding == authority.readinessSourceBinding else {
            throw ControlledEvalFailure.authorityMismatch
        }
    }

    func reviewResultsAuthorized(
        _ run: EvalRun,
        report: ProductionReadinessReport,
        evalPlan: AIEvalPlan,
        proposal: ControlledEvalResultReviewProposal,
        authorization: ControlledEvalResultReviewAuthorization,
        decision: EvalRunReviewDecisionKind,
        instructions: String? = nil,
        context: ControlledEvalExecutionContext,
        now: Date = Date()
    ) throws -> (
        run: EvalRun,
        consumedAuthorization: ControlledEvalResultReviewAuthorization,
        safetyCounters: ControlledEvalSafetyCounters
    ) {
        let currentProposal = try makeResultReviewProposal(
            run,
            report: report,
            evalPlan: evalPlan,
            context: context
        )
        guard currentProposal == proposal else { throw ControlledEvalFailure.authorityMismatch }
        try validateResultReviewAuthorization(
            authorization,
            proposal: proposal,
            context: context,
            now: now
        )
        guard let current = run.currentRevision,
              current.revision == authorization.resultRevision,
              current.digest.sha256 == authorization.resultSHA256,
              [.approveResults, .requestChanges, .rejectResults].contains(decision),
              run.reviewDecision(stage: .results, attempt: current.attempt) == nil else {
            throw ControlledEvalFailure.reviewAuthorityUnavailable
        }
        let trimmed = instructions?.trimmingCharacters(in: .whitespacesAndNewlines)
        if decision == .requestChanges, trimmed?.isEmpty != false {
            throw ControlledEvalFailure.reviewAuthorityUnavailable
        }
        var updated = run
        var reviewDecision = EvalRunReviewDecision(
            decisionID: UUID(),
            runID: run.runID,
            runRevision: current.revision,
            runSHA256: current.digest.sha256,
            attempt: current.attempt,
            stage: .results,
            decision: decision,
            reviewerInstructions: trimmed,
            approvalScope: Self.resultsApprovalScope,
            authenticatedLocalSessionID: context.authenticatedLocalSessionID,
            workspaceSessionID: context.workspaceSessionID,
            appSessionID: context.appSessionID,
            resultReviewAuthorizationID: authorization.authorizationID,
            resultReviewConfirmationID: authorization.confirmationID,
            executionPolicySHA256: authorization.executionPolicySHA256,
            datasetManifestSHA256: authorization.datasetManifestSHA256,
            evaluatorID: authorization.evaluatorID,
            evaluatorVersion: authorization.evaluatorVersion,
            modelVersion: authorization.modelVersion,
            decidedAt: now,
            decisionSHA256: ""
        )
        reviewDecision.decisionSHA256 = ControlledEvalDigest.evalReviewDecisionSHA256(reviewDecision)
        updated.reviewDecisions.append(reviewDecision)
        try ControlledEvalArtifactValidator.validate(updated)
        var consumed = authorization
        consumed.consumedAt = now
        consumed.authorizationSHA256 = ControlledEvalDigest.resultReviewAuthorizationSHA256(consumed)
        let counters = ControlledEvalSafetyCounters()
        guard counters.hasZeroExternalAuthority else { throw ControlledEvalFailure.policyViolation }
        return (updated, consumed, counters)
    }

    func retry(
        _ run: EvalRun,
        context: ControlledEvalExecutionContext,
        now: Date = Date()
    ) throws -> EvalRun {
        try ControlledEvalArtifactValidator.validate(run)
        try validateContext(run.request.authority, context: context)
        guard let current = run.currentRevision,
              let effectiveState = run.currentState,
              [.stoppedFailClosed, .resultsChangeRequested, .resultsRejected, .resultsApproved].contains(effectiveState) else {
            throw ControlledEvalFailure.invalidStateTransition
        }
        let nextAttempt = current.attempt + 1
        guard nextAttempt <= run.request.policy.maximumAttemptsPerCase else {
            throw ControlledEvalFailure.policyViolation
        }
        var updated = run
        appendRevision(
            to: &updated,
            attempt: nextAttempt,
            state: .awaitingExecutionApproval,
            overallResult: .notExecuted,
            unexecutedScenarioIDs: run.request.requestedScenarioIDs,
            now: now
        )
        try ControlledEvalArtifactValidator.validate(updated)
        return updated
    }

    func cancel(
        _ run: EvalRun,
        context: ControlledEvalExecutionContext,
        now: Date = Date()
    ) throws -> EvalRun {
        try ControlledEvalArtifactValidator.validate(run)
        try validateContext(run.request.authority, context: context)
        guard let current = run.currentRevision else { throw ControlledEvalFailure.invalidStateTransition }
        guard current.state == .awaitingExecutionApproval || current.state.isExecutionActive else {
            return run
        }
        var updated = run
        let failure = EvalFailureRecord(
            failureID: UUID(),
            kind: .cancelled,
            scenarioID: nil,
            caseID: nil,
            metricID: nil,
            summary: "The exact Eval Run was cancelled by the authorized local user.",
            isCritical: true,
            evidenceReferences: [],
            recordedAt: now
        )
        appendRevision(
            to: &updated,
            attempt: current.attempt,
            state: .cancelled,
            overallResult: current.overallResult == .notExecuted ? .notExecuted : .inconclusive,
            scenarioExecutions: current.scenarioExecutions,
            metricResults: current.metricResults,
            failures: current.failures + [failure],
            evidence: current.evidence,
            startedAt: current.startedAt,
            endedAt: now,
            durationMilliseconds: current.startedAt.map { max(0, Int(now.timeIntervalSince($0) * 1_000)) },
            tokenEstimate: current.tokenEstimate,
            estimatedCost: current.estimatedCost,
            unexecutedScenarioIDs: current.unexecutedScenarioIDs,
            now: now
        )
        try ControlledEvalArtifactValidator.validate(updated)
        return updated
    }

    func failClosedInterruptedRestoration(
        _ run: EvalRun,
        now: Date = Date()
    ) throws -> EvalRun {
        try ControlledEvalArtifactValidator.validate(run)
        guard let current = run.currentRevision, current.state.isExecutionActive else { return run }
        var updated = run
        var restorationFailure = EvalRunRestorationFailure(
            failureID: UUID(),
            runID: run.runID,
            workspaceID: run.request.authority.workspaceID,
            missionRunID: run.request.authority.missionRunID,
            kind: .interruptedExecution,
            summary: "An in-flight Eval Run was restored as interrupted and stopped fail-closed.",
            failedClosedAt: now,
            failureSHA256: ""
        )
        restorationFailure.failureSHA256 = ControlledEvalDigest.restorationFailureSHA256(restorationFailure)
        updated.restorationFailures.append(restorationFailure)
        let failure = EvalFailureRecord(
            failureID: UUID(),
            kind: .interrupted,
            scenarioID: nil,
            caseID: nil,
            metricID: nil,
            summary: "Execution was interrupted before an atomic completed result set was committed.",
            isCritical: true,
            evidenceReferences: [],
            recordedAt: now
        )
        appendRevision(
            to: &updated,
            attempt: current.attempt,
            state: .stoppedFailClosed,
            overallResult: .inconclusive,
            scenarioExecutions: current.scenarioExecutions,
            metricResults: current.metricResults,
            failures: current.failures + [failure],
            evidence: current.evidence,
            startedAt: current.startedAt,
            endedAt: now,
            durationMilliseconds: current.startedAt.map { max(0, Int(now.timeIntervalSince($0) * 1_000)) },
            tokenEstimate: current.tokenEstimate,
            estimatedCost: current.estimatedCost,
            unexecutedScenarioIDs: current.unexecutedScenarioIDs,
            now: now
        )
        try ControlledEvalArtifactValidator.validate(updated)
        return updated
    }
}

enum ControlledEvalExecutionEligibilityEvaluator {
    static func evaluate(
        report: ProductionReadinessReport,
        evalPlan: AIEvalPlan,
        context: ControlledEvalExecutionContext?,
        authorizations: [ControlledEvalExecutionAuthorization],
        now: Date = Date()
    ) -> ControlledEvalExecutionEligibility {
        guard let context else {
            return blocker("The authenticated local and workspace sessions required for controlled Eval authorization are unavailable.")
        }
        do {
            let service = ControlledEvalExecutionService()
            let proposal = try service.makeExecutionProposal(
                report: report,
                evalPlan: evalPlan,
                context: context
            )
            let missionAuthorizations = authorizations.filter {
                $0.authority.missionRunID == context.missionRunID
                    && $0.authority.workspaceID == context.workspaceID
            }
            guard missionAuthorizations.count <= 1 else {
                return blocker("Multiple execution authorizations claim this exact Mission Run. Execution failed closed.")
            }
            if let authorization = missionAuthorizations.first {
                do {
                    try service.validateExecutionAuthorization(
                        authorization,
                        proposal: proposal,
                        context: context,
                        now: now
                    )
                    return .finalExecutionReview(
                        proposal: proposal,
                        authorization: authorization
                    )
                } catch {
                    return blockerReason(for: error)
                }
            }
            return proposal.requiresReauthorization
                ? .reauthorizationReview(proposal)
                : .currentAuthorizationReview(proposal)
        } catch {
            return blockerReason(for: error)
        }
    }

    static func blocker(_ reason: String) -> ControlledEvalExecutionEligibility {
        .blocker(reason)
    }

    private static func blockerReason(for error: Error) -> ControlledEvalExecutionEligibility {
        let code = (error as? ControlledEvalFailure)?.rawValue
            ?? (error as? ProductionReadinessFailure)?.rawValue
            ?? "EXACT_AUTHORITY_UNAVAILABLE"
        return blocker("The exact controlled Eval authority failed validation (\(code)).")
    }
}

enum ControlledEvalResultReviewEligibilityEvaluator {
    static func evaluate(
        run: EvalRun,
        report: ProductionReadinessReport,
        evalPlan: AIEvalPlan,
        context: ControlledEvalExecutionContext?,
        authorizations: [ControlledEvalResultReviewAuthorization],
        now: Date = Date()
    ) -> ControlledEvalResultReviewEligibility {
        guard let context else {
            return blocker("The authenticated local and workspace sessions required for Eval Result review are unavailable.")
        }
        do {
            let service = ControlledEvalExecutionService()
            try service.validateResultReviewProvenance(
                run,
                report: report,
                evalPlan: evalPlan,
                context: context
            )
            guard let revision = run.currentRevision else {
                return blocker("The exact Eval Result revision is unavailable.")
            }
            if let decision = run.reviewDecision(stage: .results, attempt: revision.attempt) {
                guard [.approveResults, .requestChanges, .rejectResults].contains(decision.decision),
                      [.resultsApproved, .resultsChangeRequested, .resultsRejected].contains(run.currentState) else {
                    return blocker("The Eval Result decision contradicts the immutable result revision.")
                }
                return .finalizedReadOnly()
            }
            guard revision.state == .resultsAwaitingReview else {
                return blocker("Only an intact RESULTS_AWAITING_REVIEW artifact can receive review authority.")
            }
            let proposal = try service.makeResultReviewProposal(
                run,
                report: report,
                evalPlan: evalPlan,
                context: context
            )
            let exactAuthorizations = authorizations.filter {
                $0.workspaceID == context.workspaceID
                    && $0.missionRunID == context.missionRunID
                    && $0.runID == run.runID
            }
            guard exactAuthorizations.count <= 1 else {
                return blocker("Multiple result-review authorizations claim this exact Eval Result. Review failed closed.")
            }
            if let authorization = exactAuthorizations.first {
                do {
                    try service.validateResultReviewAuthorization(
                        authorization,
                        proposal: proposal,
                        context: context,
                        now: now
                    )
                    return .finalDecisionReview(
                        proposal: proposal,
                        authorization: authorization
                    )
                } catch {
                    return blockerReason(for: error)
                }
            }
            return proposal.requiresReauthorization
                ? .reauthorizationReview(proposal)
                : .currentAuthorizationReview(proposal)
        } catch {
            return blockerReason(for: error)
        }
    }

    static func blocker(_ reason: String) -> ControlledEvalResultReviewEligibility {
        .blocker(reason)
    }

    private static func blockerReason(for error: Error) -> ControlledEvalResultReviewEligibility {
        let code = (error as? ControlledEvalFailure)?.rawValue
            ?? (error as? ProductionReadinessFailure)?.rawValue
            ?? "EXACT_RESULT_REVIEW_AUTHORITY_UNAVAILABLE"
        return blocker("The exact controlled Eval Result failed review-authority validation (\(code)).")
    }
}

enum ControlledEvalArtifactValidator {
    static func validate(_ run: EvalRun) throws {
        guard run.runID == run.request.runID,
              run.request.isSelfValidating,
              !run.revisions.isEmpty,
              run.revisions.map(\.revision) == Array(1...run.revisions.count),
              run.revisions.allSatisfy({ $0.runID == run.runID }),
              run.revisions.allSatisfy({
                  ControlledEvalDigest.runRevisionDigest(
                      $0,
                      requestSHA256: run.request.requestSHA256
                  ) == $0.digest
              }) else {
            throw ControlledEvalFailure.digestMismatch
        }
        guard run.activityEvents.count == run.revisions.count else {
            throw ControlledEvalFailure.artifactPersistenceInvalid
        }
        guard run.createdAt == run.revisions.first?.createdAt,
              run.updatedAt == run.currentRevision?.createdAt else {
            throw ControlledEvalFailure.artifactPersistenceInvalid
        }
        for (revision, event) in zip(run.revisions, run.activityEvents) {
            guard event.runID == run.runID,
                  event.runRevision == revision.revision,
                  event.attempt == revision.attempt,
                  event.state == revision.state,
                  event.occurredAt == revision.createdAt,
                  event.isSelfValidating else {
                throw ControlledEvalFailure.artifactPersistenceInvalid
            }
            try validateResults(revision)
        }
        for index in run.revisions.indices.dropFirst() {
            guard isAllowedTransition(from: run.revisions[index - 1], to: run.revisions[index]) else {
                throw ControlledEvalFailure.invalidStateTransition
            }
        }
        let grouped = Dictionary(grouping: run.reviewDecisions) { "\($0.stage.rawValue):\($0.attempt)" }
        guard grouped.values.allSatisfy({ $0.count == 1 }) else {
            throw ControlledEvalFailure.revisionImmutable
        }
        for decision in run.reviewDecisions {
            guard decision.isSelfValidating,
                  decision.runID == run.runID,
                  let revision = run.revisions.first(where: { $0.revision == decision.runRevision }),
                  revision.attempt == decision.attempt,
                  revision.digest.sha256 == decision.runSHA256 else {
                throw ControlledEvalFailure.artifactPersistenceInvalid
            }
            switch decision.stage {
            case .execution:
                guard decision.decision == .approveExecution,
                      revision.state == .awaitingExecutionApproval,
                      decision.approvalScope == ControlledEvalExecutionService.executionApprovalScope,
                      decision.authenticatedLocalSessionID == run.request.authority.authenticatedLocalSessionID,
                      decision.workspaceSessionID == run.request.authority.workspaceSessionID,
                      decision.appSessionID == run.request.authority.appSessionID,
                      decision.resultReviewAuthorizationID == nil,
                      decision.resultReviewConfirmationID == nil else {
                    throw ControlledEvalFailure.artifactPersistenceInvalid
                }
            case .results:
                guard [.approveResults, .requestChanges, .rejectResults].contains(decision.decision),
                      revision.state == .resultsAwaitingReview,
                      decision.approvalScope == ControlledEvalExecutionService.resultsApprovalScope,
                      decision.resultReviewAuthorizationID != nil,
                      decision.resultReviewConfirmationID != nil,
                      decision.executionPolicySHA256 == run.request.policy.policySHA256,
                      decision.datasetManifestSHA256 == run.request.dataset.manifestSHA256,
                      decision.evaluatorID == run.request.authority.evaluatorID,
                      decision.evaluatorVersion == run.request.authority.evaluatorVersion,
                      decision.modelVersion == run.request.authority.modelVersion else {
                    throw ControlledEvalFailure.artifactPersistenceInvalid
                }
            }
        }
        for index in run.revisions.indices.dropFirst() {
            let previous = run.revisions[index - 1]
            let next = run.revisions[index]
            if next.attempt == previous.attempt + 1,
               previous.state == .resultsAwaitingReview,
               run.reviewDecision(stage: .results, attempt: previous.attempt) == nil {
                throw ControlledEvalFailure.reviewAuthorityUnavailable
            }
        }
        guard run.restorationFailures.allSatisfy({
            $0.isSelfValidating && ($0.runID == nil || $0.runID == run.runID)
        }) else {
            throw ControlledEvalFailure.artifactPersistenceInvalid
        }
    }

    static func isAppendOnly(existing: EvalRun, proposed: EvalRun) -> Bool {
        proposed.runID == existing.runID
            && proposed.request.requestSHA256 == existing.request.requestSHA256
            && proposed.revisions.count >= existing.revisions.count
            && proposed.reviewDecisions.count >= existing.reviewDecisions.count
            && proposed.activityEvents.count >= existing.activityEvents.count
            && proposed.restorationFailures.count >= existing.restorationFailures.count
            && proposed.revisions.prefix(existing.revisions.count).map(\.digest)
                == existing.revisions.map(\.digest)
            && proposed.reviewDecisions.prefix(existing.reviewDecisions.count).map(\.decisionSHA256)
                == existing.reviewDecisions.map(\.decisionSHA256)
            && proposed.activityEvents.prefix(existing.activityEvents.count).map(\.eventSHA256)
                == existing.activityEvents.map(\.eventSHA256)
            && proposed.restorationFailures.prefix(existing.restorationFailures.count).map(\.failureSHA256)
                == existing.restorationFailures.map(\.failureSHA256)
    }

    private static func validateResults(_ revision: EvalRunRevision) throws {
        for execution in revision.scenarioExecutions {
            for result in execution.results {
                guard ControlledEvalDigest.scenarioResultSHA256(result) == result.deterministicSHA256,
                      result.metricObservations.allSatisfy({
                          ControlledEvalDigest.metricObservationSHA256($0) == $0.deterministicSHA256
                      }),
                      result.outcome != .pass || !result.evidenceReferences.isEmpty else {
                    throw ControlledEvalFailure.digestMismatch
                }
            }
        }
        guard revision.metricResults.allSatisfy({ result in
            ControlledEvalDigest.metricResultSHA256(result) == result.deterministicSHA256
                && (result.outcome != .pass || !result.evidenceReferences.isEmpty)
        }) else {
            throw ControlledEvalFailure.digestMismatch
        }
        if [.executionCompleted, .resultsAwaitingReview, .resultsApproved, .resultsRejected, .resultsChangeRequested].contains(revision.state) {
            guard revision.endedAt != nil,
                  revision.overallResult != .notExecuted,
                  !revision.scenarioExecutions.isEmpty else {
                throw ControlledEvalFailure.artifactPersistenceInvalid
            }
        }
    }

    private static func isAllowedTransition(from: EvalRunRevision, to: EvalRunRevision) -> Bool {
        if to.attempt == from.attempt + 1 {
            return to.state == .awaitingExecutionApproval
                && [.stoppedFailClosed, .resultsAwaitingReview, .resultsChangeRequested, .resultsRejected, .resultsApproved].contains(from.state)
        }
        guard to.attempt == from.attempt else { return false }
        return switch (from.state, to.state) {
        case (.awaitingExecutionApproval, .executionApproved),
             (.awaitingExecutionApproval, .cancelled),
             (.executionApproved, .validatingAuthority),
             (.executionApproved, .stoppedFailClosed),
             (.executionApproved, .cancelled),
             (.validatingAuthority, .validatingDataset),
             (.validatingAuthority, .stoppedFailClosed),
             (.validatingAuthority, .cancelled),
             (.validatingDataset, .executing),
             (.validatingDataset, .stoppedFailClosed),
             (.validatingDataset, .cancelled),
             (.executing, .executionCompleted),
             (.executing, .stoppedFailClosed),
             (.executing, .cancelled),
             (.executionCompleted, .resultsAwaitingReview),
             (.resultsAwaitingReview, .resultsApproved),
             (.resultsAwaitingReview, .resultsRejected),
             (.resultsAwaitingReview, .resultsChangeRequested):
            true
        default:
            false
        }
    }
}

private extension ControlledEvalExecutionService {
    struct ApprovedPair {
        var reportRevision: ProductionReadinessReportRevision
        var reportDecision: ProductionReadinessReviewDecision
        var planRevision: AIEvalPlanRevision
        var planDecision: AIEvalReviewDecision
    }

    func validateExactApprovedPair(
        report: ProductionReadinessReport,
        plan: AIEvalPlan,
        context: ControlledEvalExecutionContext,
        acceptsPriorArtifactAppSession: Bool = false
    ) throws -> ApprovedPair {
        try ProductionReadinessArtifactValidator.validate(report)
        try ProductionReadinessArtifactValidator.validate(plan)
        guard report.sourceBinding == plan.sourceBinding.readinessSourceBinding,
              let reportRevision = report.currentRevision,
              let planRevision = plan.currentRevision,
              let reportDecision = report.reviewDecision(for: reportRevision.revision),
              let planDecision = plan.reviewDecision(for: planRevision.revision),
              reportDecision.decision == .approvePlan,
              planDecision.decision == .approvePlan,
              reportDecision.reportSHA256 == reportRevision.digest.sha256,
              planDecision.planSHA256 == planRevision.digest.sha256 else {
            throw ControlledEvalFailure.exactApprovedPhase3APairRequired
        }
        try validateSourceContext(
            report.sourceBinding,
            context: context,
            acceptsPriorArtifactAppSession: acceptsPriorArtifactAppSession
        )
        return ApprovedPair(
            reportRevision: reportRevision,
            reportDecision: reportDecision,
            planRevision: planRevision,
            planDecision: planDecision
        )
    }

    func validatePolicyAndDataset(
        policy: ControlledEvalExecutionPolicy,
        dataset: EvalDatasetManifest,
        planRevision: AIEvalPlanRevision
    ) throws {
        guard policy.isSelfValidating else { throw ControlledEvalFailure.digestMismatch }
        guard dataset.isSelfValidating else { throw ControlledEvalFailure.datasetDrift }
        let approvedScenarios = Set(planRevision.scenarios.map(\.scenarioID))
        let approvedMetrics = Set(planRevision.metrics.map(\.metricID))
        let approvedDatasetRequirements = Set(planRevision.datasetRequirements.map(\.datasetRequirementID))
        guard !policy.scenarioAllowlist.isEmpty,
              policy.scenarioAllowlist.count == Set(policy.scenarioAllowlist).count,
              Set(policy.scenarioAllowlist).isSubset(of: approvedScenarios) else {
            throw ControlledEvalFailure.scenarioNotApproved
        }
        guard !policy.metricAllowlist.isEmpty,
              policy.metricAllowlist.count == Set(policy.metricAllowlist).count,
              Set(policy.metricAllowlist).isSubset(of: approvedMetrics) else {
            throw ControlledEvalFailure.metricNotApproved
        }
        guard policy.datasetAllowlist.contains(dataset.datasetID),
              !dataset.datasetID.isEmpty,
              dataset.readOnly,
              dataset.deterministic,
              !dataset.containsProductionData,
              !dataset.containsCustomerSecrets,
              dataset.approvedScenarioIDs.count == Set(dataset.approvedScenarioIDs).count,
              Set(dataset.approvedScenarioIDs).isSubset(of: approvedScenarios),
              Set(dataset.approvedDatasetRequirementIDs) == approvedDatasetRequirements,
              dataset.cases.allSatisfy({ dataset.approvedScenarioIDs.contains($0.scenarioID) }),
              dataset.cases.allSatisfy({
                  !$0.caseID.isEmpty
                      && !$0.scenarioID.isEmpty
                      && $0.tokenEstimate >= 0
                      && $0.estimatedCost.isFinite
                      && $0.estimatedCost >= 0
                      && $0.simulatedDurationMilliseconds >= 0
                      && $0.metricValues.values.allSatisfy(\.isFinite)
              }),
              dataset.cases.map(\.caseID).count == Set(dataset.cases.map(\.caseID)).count else {
            throw ControlledEvalFailure.datasetDrift
        }
        guard policy.maximumCases > 0,
              policy.maximumAttemptsPerCase > 0,
              policy.maximumRuntimeDurationMilliseconds > 0,
              policy.maximumTokenEstimate >= 0,
              policy.maximumEstimatedCost.isFinite,
              policy.maximumEstimatedCost >= 0,
              policy.allowedTools.isEmpty,
              !policy.networkAccessAllowed,
              !policy.productionAccessAllowed,
              !policy.credentialAccessAllowed else {
            throw ControlledEvalFailure.policyViolation
        }
        guard policy.evaluatorID == DeterministicFixtureEvalProvider.evaluatorID,
              policy.evaluatorVersion == DeterministicFixtureEvalProvider.evaluatorVersion,
              policy.modelVersion == DeterministicFixtureEvalProvider.modelVersion else {
            throw ControlledEvalFailure.providerMismatch
        }
        try validateLimits(
            caseCount: dataset.cases.count,
            duration: dataset.cases.reduce(0) { $0 + $1.simulatedDurationMilliseconds },
            tokenEstimate: dataset.cases.reduce(0) { $0 + $1.tokenEstimate },
            estimatedCost: dataset.cases.reduce(0) { $0 + $1.estimatedCost },
            policy: policy
        )
    }

    func validateLimits(
        caseCount: Int,
        duration: Int,
        tokenEstimate: Int,
        estimatedCost: Double,
        policy: ControlledEvalExecutionPolicy
    ) throws {
        guard caseCount <= policy.maximumCases else { throw ControlledEvalFailure.datasetLimitExceeded }
        guard duration <= policy.maximumRuntimeDurationMilliseconds else { throw ControlledEvalFailure.runtimeLimitExceeded }
        guard tokenEstimate <= policy.maximumTokenEstimate else { throw ControlledEvalFailure.tokenLimitExceeded }
        guard estimatedCost <= policy.maximumEstimatedCost else { throw ControlledEvalFailure.costLimitExceeded }
    }

    func validateSourceContext(
        _ source: ProductionReadinessSourceBinding,
        context: ControlledEvalExecutionContext,
        acceptsPriorArtifactAppSession: Bool
    ) throws {
        guard source.missionRunID == context.missionRunID,
              source.workspaceID == context.workspaceID else {
            throw ControlledEvalFailure.authorityMismatch
        }
        guard source.authenticatedLocalSessionID == context.authenticatedLocalSessionID else {
            throw ControlledEvalFailure.sessionMismatch
        }
        if !acceptsPriorArtifactAppSession, source.appSessionID != context.appSessionID {
            throw ControlledEvalFailure.sessionMismatch
        }
    }

    func validateProposal(
        _ proposal: ControlledEvalExecutionProposal,
        context: ControlledEvalExecutionContext
    ) throws {
        guard proposal.isSelfValidating,
              proposal.authority.missionRunID == context.missionRunID,
              proposal.authority.workspaceID == context.workspaceID else {
            throw ControlledEvalFailure.authorityMismatch
        }
        try validateContext(proposal.authority, context: context)
        guard proposal.requestedScenarioIDs == proposal.requestedScenarioIDs.sorted(),
              proposal.requestedMetricIDs == proposal.requestedMetricIDs.sorted(),
              proposal.estimatedTokenCount >= 0,
              proposal.estimatedCost.isFinite,
              proposal.estimatedCost >= 0 else {
            throw ControlledEvalFailure.authorityMismatch
        }
    }

    func validateResultReviewProposal(
        _ proposal: ControlledEvalResultReviewProposal,
        context: ControlledEvalExecutionContext
    ) throws {
        guard proposal.isSelfValidating,
              proposal.executionAuthority.missionRunID == context.missionRunID,
              proposal.executionAuthority.workspaceID == context.workspaceID,
              proposal.currentSessionAuthority.workspaceID == context.workspaceID,
              proposal.currentSessionAuthority.authenticatedLocalSessionID == context.authenticatedLocalSessionID,
              proposal.currentSessionAuthority.workspaceSessionID == context.workspaceSessionID,
              proposal.currentSessionAuthority.appSessionID == context.appSessionID else {
            throw ControlledEvalFailure.sessionMismatch
        }
    }

    func validateContext(
        _ authority: ControlledEvalAuthorityBinding,
        context: ControlledEvalExecutionContext
    ) throws {
        guard authority.missionRunID == context.missionRunID,
              authority.workspaceID == context.workspaceID else {
            throw ControlledEvalFailure.authorityMismatch
        }
        guard authority.authenticatedLocalSessionID == context.authenticatedLocalSessionID,
              authority.workspaceSessionID == context.workspaceSessionID,
              authority.appSessionID == context.appSessionID else {
            throw ControlledEvalFailure.sessionMismatch
        }
    }

    func revalidateExecutionAuthority(
        run: EvalRun,
        report: ProductionReadinessReport,
        plan: AIEvalPlan,
        context: ControlledEvalExecutionContext,
        provider: any ControlledEvalProviding
    ) throws {
        try revalidateExecutionProvenance(
            run: run,
            report: report,
            plan: plan,
            context: context,
            provider: provider
        )
        try validateContext(run.request.authority, context: context)
    }

    func revalidateExecutionProvenance(
        run: EvalRun,
        report: ProductionReadinessReport,
        plan: AIEvalPlan,
        context: ControlledEvalExecutionContext,
        provider: any ControlledEvalProviding
    ) throws {
        let approved = try validateExactApprovedPair(
            report: report,
            plan: plan,
            context: context,
            acceptsPriorArtifactAppSession: true
        )
        let authority = run.request.authority
        guard authority.isSelfValidating,
              authority.readinessSourceBinding == report.sourceBinding,
              authority.productionReadinessReportID == report.reportID,
              authority.productionReadinessReportRevision == approved.reportRevision.revision,
              authority.productionReadinessReportSHA256 == approved.reportRevision.digest.sha256,
              authority.productionReadinessReviewDecisionID == approved.reportDecision.decisionID,
              authority.productionReadinessReviewDecisionSHA256 == ControlledEvalDigest.reviewDecisionSHA256(approved.reportDecision),
              authority.aiEvalPlanID == plan.planID,
              authority.aiEvalPlanRevision == approved.planRevision.revision,
              authority.aiEvalPlanSHA256 == approved.planRevision.digest.sha256,
              authority.aiEvalPlanReviewDecisionID == approved.planDecision.decisionID,
              authority.aiEvalPlanReviewDecisionSHA256 == ControlledEvalDigest.reviewDecisionSHA256(approved.planDecision),
              authority.capabilityID == report.sourceBinding.normalizedCapabilityID,
              authority.authenticatedLocalSessionID == report.sourceBinding.authenticatedLocalSessionID,
              authority.executionPolicySHA256 == run.request.policy.policySHA256,
              authority.datasetManifestSHA256 == run.request.dataset.manifestSHA256,
              authority.evaluatorID == run.request.policy.evaluatorID,
              authority.evaluatorVersion == run.request.policy.evaluatorVersion,
              authority.modelVersion == run.request.policy.modelVersion else {
            throw ControlledEvalFailure.authorityMismatch
        }
        try validatePolicyAndDataset(
            policy: run.request.policy,
            dataset: run.request.dataset,
            planRevision: approved.planRevision
        )
        guard provider.identity.mode == .deterministicFixture,
              provider.identity.evaluatorID == authority.evaluatorID,
              provider.identity.evaluatorVersion == authority.evaluatorVersion,
              provider.identity.modelVersion == authority.modelVersion else {
            throw ControlledEvalFailure.providerMismatch
        }
    }

    func requiredPlanRevision(
        _ plan: AIEvalPlan,
        authority: ControlledEvalAuthorityBinding
    ) throws -> AIEvalPlanRevision {
        guard plan.planID == authority.aiEvalPlanID,
              let revision = plan.revisions.first(where: { $0.revision == authority.aiEvalPlanRevision }),
              revision.digest.sha256 == authority.aiEvalPlanSHA256,
              plan.currentRevision?.revision == revision.revision else {
            throw ControlledEvalFailure.revisionMismatch
        }
        return revision
    }

    func appendRevision(
        to run: inout EvalRun,
        attempt: Int,
        state: EvalRunState,
        overallResult: EvalOverallResult,
        scenarioExecutions: [EvalScenarioExecution] = [],
        metricResults: [EvalMetricResult] = [],
        failures: [EvalFailureRecord] = [],
        evidence: [EvalExecutionEvidence] = [],
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        durationMilliseconds: Int? = nil,
        tokenEstimate: Int = 0,
        estimatedCost: Double = 0,
        unexecutedScenarioIDs: [String],
        now: Date
    ) {
        var revision = EvalRunRevision(
            runID: run.runID,
            revision: run.revisions.count + 1,
            attempt: attempt,
            state: state,
            overallResult: overallResult,
            scenarioExecutions: scenarioExecutions,
            metricResults: metricResults,
            failures: failures,
            evidence: evidence,
            startedAt: startedAt,
            endedAt: endedAt,
            durationMilliseconds: durationMilliseconds,
            tokenEstimate: tokenEstimate,
            estimatedCost: estimatedCost,
            unexecutedScenarioIDs: unexecutedScenarioIDs,
            digest: .empty,
            createdAt: now
        )
        revision.digest = ControlledEvalDigest.runRevisionDigest(
            revision,
            requestSHA256: run.request.requestSHA256
        )
        run.revisions.append(revision)
        var event = EvalRunActivityEvent(
            eventID: deterministicUUID("activity:\(run.runID.uuidString):\(revision.revision):\(state.rawValue)"),
            runID: run.runID,
            runRevision: revision.revision,
            attempt: attempt,
            state: state,
            summary: state.displayName,
            occurredAt: now,
            eventSHA256: ""
        )
        event.eventSHA256 = ControlledEvalDigest.activityEventSHA256(event)
        run.activityEvents.append(event)
        run.updatedAt = now
    }

    func approvedFixtureOutput(for datasetCase: EvalDatasetCase) -> ControlledEvalProviderOutput {
        ControlledEvalProviderOutput(
            deterministicOutput: datasetCase.deterministicOutput,
            actualBehavior: datasetCase.actualBehavior,
            metricValues: datasetCase.metricValues,
            evidenceReferences: datasetCase.evidenceReferences,
            tokenEstimate: datasetCase.tokenEstimate,
            estimatedCost: datasetCase.estimatedCost,
            durationMilliseconds: datasetCase.simulatedDurationMilliseconds
        )
    }

    func aggregateMetricResults(
        executions: [EvalScenarioExecution],
        planRevision: AIEvalPlanRevision,
        evaluatorVersion: String
    ) -> [EvalMetricResult] {
        let metrics = Dictionary(uniqueKeysWithValues: planRevision.metrics.map { ($0.metricID, $0) })
        return planRevision.scenarios.sorted { $0.scenarioID < $1.scenarioID }.flatMap { scenario in
            scenario.metricBindings.sorted().map { metricID in
                let observations = executions
                    .filter { $0.scenarioID == scenario.scenarioID }
                    .flatMap(\.results)
                    .flatMap(\.metricObservations)
                    .filter { $0.metricID == metricID }
                let numerator = observations.compactMap(\.numeratorContribution).reduce(0, +)
                let denominator = observations.compactMap(\.denominatorContribution).reduce(0, +)
                let value: Double? = denominator > 0 ? numerator / denominator : nil
                let evidence = observations.flatMap(\.evidenceReferences).uniquedSorted()
                let threshold = metrics[metricID]?.proposedThreshold ?? "Threshold unavailable"
                let outcome: EvalMetricOutcome = observations.isEmpty
                    ? .notExecuted
                    : metricOutcome(
                        observedValue: value,
                        proposedThreshold: threshold,
                        evidenceReferences: evidence
                    )
                var result = EvalMetricResult(
                    metricID: metricID,
                    scenarioID: scenario.scenarioID,
                    numerator: observations.isEmpty ? nil : numerator,
                    denominator: observations.isEmpty ? nil : denominator,
                    observedValue: value,
                    proposedThreshold: threshold,
                    outcome: outcome,
                    evidenceReferences: evidence,
                    evaluatorVersion: evaluatorVersion,
                    deterministicSHA256: ""
                )
                result.deterministicSHA256 = ControlledEvalDigest.metricResultSHA256(result)
                return result
            }
        }
    }

    func metricOutcome(
        observedValue: Double?,
        proposedThreshold: String,
        evidenceReferences: [String]
    ) -> EvalMetricOutcome {
        guard let observedValue, !evidenceReferences.isEmpty else { return .inconclusive }
        let normalized = proposedThreshold.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.contains("human approval required")
            || normalized.contains("not defined")
            || normalized.contains("tolerance not defined")
            || normalized.isEmpty {
            return .inconclusive
        }
        if normalized.contains("no violations") || normalized == "proposed: 0" || normalized == "0" {
            return observedValue <= 0 ? .pass : .fail
        }
        if normalized.contains("100%") {
            return observedValue >= 1 ? .pass : .fail
        }
        if let value = parsedThreshold(normalized, marker: ">=") ?? parsedThreshold(normalized, marker: "at least") {
            return observedValue >= value ? .pass : .fail
        }
        if let value = parsedThreshold(normalized, marker: "<=") ?? parsedThreshold(normalized, marker: "at most") {
            return observedValue <= value ? .pass : .fail
        }
        return .inconclusive
    }

    func parsedThreshold(_ text: String, marker: String) -> Double? {
        guard let range = text.range(of: marker) else { return nil }
        let suffix = text[range.upperBound...]
        let token = suffix.split(whereSeparator: { $0 == " " || $0 == "," }).first
        guard var raw = token.map(String.init) else { return nil }
        let isPercent = raw.hasSuffix("%")
        raw = raw.replacingOccurrences(of: "%", with: "")
        guard let value = Double(raw) else { return nil }
        return isPercent ? value / 100 : value
    }

    func overallResult(
        metricResults: [EvalMetricResult],
        planRevision: AIEvalPlanRevision,
        requestedMetricIDs: Set<String>,
        unexecutedScenarioIDs: [String]
    ) -> EvalOverallResult {
        let mandatoryMetricIDs = Set(planRevision.releaseGates.flatMap(\.metricIDs))
        guard mandatoryMetricIDs.isSubset(of: requestedMetricIDs) else { return .inconclusive }
        let mandatory = metricResults.filter { mandatoryMetricIDs.contains($0.metricID) }
        guard !mandatory.isEmpty else { return .inconclusive }
        if mandatory.contains(where: { $0.outcome == .fail }) { return .fail }
        guard unexecutedScenarioIDs.isEmpty else { return .inconclusive }
        if mandatory.contains(where: { $0.outcome == .inconclusive || $0.outcome == .notExecuted }) {
            return .inconclusive
        }
        let covered = Set(mandatory.filter { $0.outcome == .pass }.map(\.metricID))
        return mandatoryMetricIDs.isSubset(of: covered) ? .pass : .inconclusive
    }

    func limitFailure(
        _ kind: EvalFailureKind,
        _ summary: String,
        scenarioID: String,
        caseID: String,
        now: Date
    ) -> EvalFailureRecord {
        EvalFailureRecord(
            failureID: UUID(),
            kind: kind,
            scenarioID: scenarioID,
            caseID: caseID,
            metricID: nil,
            summary: summary,
            isCritical: true,
            evidenceReferences: [],
            recordedAt: now
        )
    }

    func defaultPassingValue(metricID: String, metric: AIEvalMetric?) -> Double {
        let lowered = metricID.lowercased()
        if lowered.contains("violation")
            || lowered.contains("leakage")
            || lowered.contains("hallucination")
            || lowered.contains("regression")
            || lowered.contains("cost") {
            return 0
        }
        if lowered.contains("latency") { return 5 }
        if lowered.contains("token") { return 32 }
        if metric?.proposedThreshold.contains("100%") == true { return 1 }
        return 1
    }
}

private func deterministicUUID(_ seed: String) -> UUID {
    let digest = CandidatePatchArtifactAuthority.sha256(Data("phase-3a.1:\(seed)".utf8))
    let value = "\(digest.prefix(8))-\(digest.dropFirst(8).prefix(4))-\(digest.dropFirst(12).prefix(4))-\(digest.dropFirst(16).prefix(4))-\(digest.dropFirst(20).prefix(12))"
    return UUID(uuidString: value)!
}

private extension Sequence where Element == String {
    func uniquedSorted() -> [String] {
        Array(Set(self)).sorted()
    }
}
