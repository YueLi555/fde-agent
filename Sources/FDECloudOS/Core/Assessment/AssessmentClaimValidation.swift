import CryptoKit
import Foundation

enum AssessmentClaimValidationFailure: String, Codable, CaseIterable, Hashable, Sendable {
    case duplicateClaimID = "duplicate_claim_id"
    case invalidClaimID = "invalid_claim_id"
    case invalidStatement = "invalid_statement"
    case missingEvidence = "missing_evidence"
    case duplicateEvidenceReference = "duplicate_evidence_reference"
    case invalidEvidenceReference = "invalid_evidence_reference"
    case invalidUnknown = "invalid_unknown"
    case duplicateUnknown = "duplicate_unknown"
    case unknownConfidenceWithoutUnknown = "unknown_confidence_without_unknown"
    case unsupportedVerificationStatus = "unsupported_verification_status"
    case unsupportedExecutionAssertion = "unsupported_execution_assertion"
    case inconsistentEvidenceLedger = "inconsistent_evidence_ledger"
    case userIntentIsNotObservedEvidence = "user_intent_is_not_observed_evidence"
    case missingToolResultEventBinding = "missing_tool_result_event_binding"
    case toolResultEventNotFound = "tool_result_event_not_found"
    case ambiguousToolResultEvent = "ambiguous_tool_result_event"
    case missingWorkspaceBinding = "missing_workspace_binding"
    case workspaceBindingMismatch = "workspace_binding_mismatch"
    case invalidEvidencePath = "invalid_evidence_path"
    case evidencePathNotInLedger = "evidence_path_not_in_ledger"
    case evidenceEventNotInLedger = "evidence_event_not_in_ledger"
    case missingClaimLevel = "missing_claim_level"
    case unsupportedClaimLevel = "unsupported_claim_level"
    case evidenceSourceMismatch = "evidence_source_mismatch"
    case observationStatusMismatch = "observation_status_mismatch"
    case fileHashMismatch = "file_hash_mismatch"
    case workspaceSnapshotMismatch = "workspace_snapshot_mismatch"
    case lineRangeMismatch = "line_range_mismatch"
    case highConfidenceRequiresDirectEvidence = "high_confidence_requires_direct_evidence"
}

struct AssessmentClaimValidationIssue: Codable, Hashable, Sendable, Identifiable {
    var failure: AssessmentClaimValidationFailure
    var claimID: String
    var evidenceReferenceID: String?
    var detail: String

    var id: String {
        "\(claimID):\(evidenceReferenceID ?? "claim"):\(failure.rawValue):\(detail)"
    }
}

struct AssessmentClaimEvidenceBindingResult: Hashable, Sendable {
    var bindings: [AssessmentClaimEvidenceBinding]
    var issues: [AssessmentClaimValidationIssue]

    var accepted: Bool { issues.isEmpty }
}

struct AssessmentClaimValidation: Hashable, Sendable {
    var bindings: [AssessmentClaimEvidenceBinding]
    var issues: [AssessmentClaimValidationIssue]

    var accepted: Bool { issues.isEmpty }
    var failures: [AssessmentClaimValidationFailure] {
        AssessmentClaimValidationFailure.allCases.filter { failure in
            issues.contains { $0.failure == failure }
        }
    }
}

enum AssessmentClaimEvidenceBinder {
    static func bind(
        _ claim: AssessmentClaim,
        evidenceLedger: ReadOnlyFinalizationEvidenceLedger,
        evidence: [ReadOnlyInspectionEvidence]
    ) -> AssessmentClaimEvidenceBindingResult {
        let evidenceByEventID = Dictionary(grouping: evidence, by: \.toolResultEventID)
        var bindings: [AssessmentClaimEvidenceBinding] = []
        var issues: [AssessmentClaimValidationIssue] = []

        for reference in claim.evidence {
            func reject(_ failure: AssessmentClaimValidationFailure, _ detail: String) {
                issues.append(
                    AssessmentClaimValidationIssue(
                        failure: failure,
                        claimID: claim.claimID,
                        evidenceReferenceID: reference.id,
                        detail: detail
                    )
                )
            }

            guard reference.source != .userIntent,
                  reference.observationStatus != .userProvided else {
                reject(
                    .userIntentIsNotObservedEvidence,
                    "User intent records the requested outcome but cannot prove a workspace observation."
                )
                continue
            }
            guard let eventID = reference.relatedToolEventID else {
                reject(
                    .missingToolResultEventBinding,
                    "Observed evidence must identify its successful TOOL_RESULT event."
                )
                continue
            }
            guard let candidates = evidenceByEventID[eventID], !candidates.isEmpty else {
                reject(
                    .toolResultEventNotFound,
                    "The referenced TOOL_RESULT is absent from the Phase 3B.2B evidence collection."
                )
                continue
            }
            guard candidates.count == 1, let sourceEvidence = candidates.first else {
                reject(
                    .ambiguousToolResultEvent,
                    "A TOOL_RESULT event identifier must resolve to exactly one evidence item."
                )
                continue
            }
            guard let workspaceIdentity = reference.workspaceIdentity?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !workspaceIdentity.isEmpty else {
                reject(
                    .missingWorkspaceBinding,
                    "Observed evidence must name the workspace identity that produced it."
                )
                continue
            }
            guard workspaceIdentity == sourceEvidence.workspaceIdentity else {
                reject(
                    .workspaceBindingMismatch,
                    "The evidence reference and TOOL_RESULT resolve to different workspaces."
                )
                continue
            }
            guard isValidRelativePath(reference.path) else {
                reject(
                    .invalidEvidencePath,
                    "Evidence paths must be canonical, workspace-relative, and non-sensitive."
                )
                continue
            }

            let pathRecords = evidenceLedger.paths.filter {
                $0.workspaceIdentity == workspaceIdentity && $0.relativePath == reference.path
            }
            guard pathRecords.count == 1, let pathRecord = pathRecords.first else {
                reject(
                    .evidencePathNotInLedger,
                    "The workspace/path pair does not resolve to exactly one evidence-ledger record."
                )
                continue
            }
            guard let claimLevel = reference.claimLevel else {
                reject(
                    .missingClaimLevel,
                    "Observed evidence must declare the claim maturity it supports."
                )
                continue
            }
            guard claimLevelIsRecorded(
                claimLevel,
                eventID: eventID,
                workspaceIdentity: workspaceIdentity,
                path: reference.path,
                pathRecord: pathRecord,
                evidenceLedger: evidenceLedger
            ) else {
                reject(
                    .unsupportedClaimLevel,
                    "The declared claim maturity exceeds or differs from the ledger record."
                )
                continue
            }
            guard sourceMatches(reference: reference, evidence: sourceEvidence) else {
                reject(
                    .evidenceSourceMismatch,
                    "The declared evidence source does not match the successful inspection tool."
                )
                continue
            }
            guard observationIsRecorded(
                reference.observationStatus,
                eventID: eventID,
                pathRecord: pathRecord,
                evidenceLedger: evidenceLedger
            ) else {
                reject(
                    .observationStatusMismatch,
                    "The declared observation status is not recorded for this path and TOOL_RESULT."
                )
                continue
            }
            guard ledgerContains(
                eventID: eventID,
                workspaceIdentity: workspaceIdentity,
                path: reference.path,
                pathRecord: pathRecord,
                evidenceLedger: evidenceLedger
            ) else {
                reject(
                    .evidenceEventNotInLedger,
                    "The TOOL_RESULT is not ledger-bound to the referenced workspace/path pair."
                )
                continue
            }
            let sourceHash = sha256(sourceEvidence.output)
            if let fileHash = reference.fileHash,
               fileHash.lowercased() != sourceHash {
                reject(
                    .fileHashMismatch,
                    "The optional evidence hash does not match the successful TOOL_RESULT output."
                )
                continue
            }
            let expectedSnapshot = "workspace-\(sourceEvidence.workspaceID.uuidString.lowercased())"
            if let snapshot = reference.workspaceSnapshotIdentifier,
               snapshot.lowercased() != expectedSnapshot {
                reject(
                    .workspaceSnapshotMismatch,
                    "The optional workspace snapshot identifier does not match the evidence workspace."
                )
                continue
            }
            if let lineRange = reference.lineRange,
               lineRange != expectedLineRange(for: sourceEvidence.output) {
                reject(
                    .lineRangeMismatch,
                    "The optional line range does not match the bound TOOL_RESULT output."
                )
                continue
            }

            bindings.append(
                AssessmentClaimEvidenceBinding(
                    claimID: claim.claimID,
                    evidenceReferenceID: reference.id,
                    toolCallID: sourceEvidence.toolCallID,
                    toolResultEventID: eventID,
                    workspaceID: sourceEvidence.workspaceID,
                    workspaceIdentity: workspaceIdentity,
                    relativePath: reference.path,
                    claimLevel: claimLevel,
                    observationStatus: reference.observationStatus,
                    sourceOutputSHA256: sourceHash,
                    extractedFactKinds: unique(sourceEvidence.structuredFacts.factKinds)
                )
            )
        }

        return AssessmentClaimEvidenceBindingResult(
            bindings: uniqueBindings(bindings),
            issues: uniqueIssues(issues)
        )
    }

    static func bind(
        _ claim: AssessmentClaim,
        evidence: [ReadOnlyInspectionEvidence],
        ledger: ReadOnlyFinalizationEvidenceLedger
    ) -> AssessmentClaimEvidenceBindingResult {
        bind(claim, evidenceLedger: ledger, evidence: evidence)
    }

    private static func sourceMatches(
        reference: AssessmentEvidenceReference,
        evidence: ReadOnlyInspectionEvidence
    ) -> Bool {
        guard ReadOnlyInspectionPolicy.allowedTools.contains(evidence.toolName) else {
            return false
        }
        switch reference.source {
        case .inspectedFile:
            guard evidence.toolName == "engineering.read_file" else { return false }
            if reference.observationStatus == .referenced {
                return reference.claimLevel == .referencedButNotRead
            }
            return evidence.targetPath == reference.path
                && reference.observationStatus == .directlyRead
                && reference.claimLevel != .configurationConfirmed
        case .extractedConfiguration:
            return evidence.toolName == "engineering.read_file"
                && evidence.targetPath == reference.path
                && reference.observationStatus == .directlyRead
                && reference.claimLevel == .configurationConfirmed
        case .staticSearch:
            return (evidence.toolName == "engineering.search_files"
                || evidence.toolName == "engineering.search_code")
                && reference.observationStatus == .discovered
        case .evidenceLedger:
            return (evidence.toolName == "engineering.inspect_project"
                || evidence.toolName == "engineering.list_directory")
                && (reference.observationStatus == .discovered
                    || reference.observationStatus == .referenced)
        case .userIntent:
            return false
        }
    }

    private static func observationIsRecorded(
        _ status: AssessmentEvidenceObservationStatus,
        eventID: UUID,
        pathRecord: ReadOnlyEvidencePathRecord,
        evidenceLedger: ReadOnlyFinalizationEvidenceLedger
    ) -> Bool {
        switch status {
        case .directlyRead:
            return pathRecord.successfullyReadByEventIDs.contains(eventID)
        case .referenced:
            return pathRecord.referencedBySuccessfulEventIDs.contains(eventID)
        case .discovered:
            let recorded = pathRecord.directoryEntrySuccessfulEventIDs
                + pathRecord.discoveredBySuccessfulEventIDs
                + pathRecord.searchedBySuccessfulEventIDs
                + pathRecord.manifestDerivedBySuccessfulEventIDs
            return recorded.contains(eventID)
                || evidenceLedger.requirements.contains {
                    $0.supportingSuccessfulEventIDs.contains(eventID)
                        && $0.supportingRelativePaths.contains(pathRecord.relativePath)
                }
        case .userProvided:
            return false
        }
    }

    private static func ledgerContains(
        eventID: UUID,
        workspaceIdentity: String,
        path: String,
        pathRecord: ReadOnlyEvidencePathRecord,
        evidenceLedger: ReadOnlyFinalizationEvidenceLedger
    ) -> Bool {
        let pathEventIDs = pathRecord.directoryEntrySuccessfulEventIDs
            + pathRecord.discoveredBySuccessfulEventIDs
            + pathRecord.searchedBySuccessfulEventIDs
            + pathRecord.manifestDerivedBySuccessfulEventIDs
            + pathRecord.referencedBySuccessfulEventIDs
            + pathRecord.successfullyReadByEventIDs
        if pathEventIDs.contains(eventID) { return true }
        return evidenceLedger.requirements.contains {
            $0.supportingSuccessfulEventIDs.contains(eventID)
                && $0.supportingRelativePaths.contains(path)
                && evidenceLedger.paths.contains {
                    $0.workspaceIdentity == workspaceIdentity && $0.relativePath == path
                }
        }
    }

    private static func claimLevelIsRecorded(
        _ claimLevel: ReadOnlyEngineeringClaimLevel,
        eventID: UUID,
        workspaceIdentity: String,
        path: String,
        pathRecord: ReadOnlyEvidencePathRecord,
        evidenceLedger: ReadOnlyFinalizationEvidenceLedger
    ) -> Bool {
        if pathRecord.claimLevels.contains(claimLevel) { return true }
        return evidenceLedger.requirements.contains {
            $0.evidenceLevel == claimLevel
                && $0.supportingSuccessfulEventIDs.contains(eventID)
                && $0.supportingRelativePaths.contains(path)
                && evidenceLedger.paths.contains {
                    $0.workspaceIdentity == workspaceIdentity && $0.relativePath == path
                }
        }
    }

    private static func isValidRelativePath(_ path: String) -> Bool {
        let normalized = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = normalized.split(separator: "/", omittingEmptySubsequences: false)
        return !normalized.isEmpty
            && normalized == path
            && !normalized.hasPrefix("/")
            && !normalized.hasPrefix("~")
            && !normalized.contains("://")
            && !components.contains("..")
            && (normalized == "." || !components.contains(""))
            && !ReadOnlySensitivePathPolicy.isSensitive(normalized)
    }

    private static func expectedLineRange(for output: String) -> String? {
        guard !output.isEmpty else { return nil }
        let count = max(1, output.split(separator: "\n", omittingEmptySubsequences: false).count)
        return "1-\(count)"
    }

    private static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }

    private static func uniqueBindings(
        _ values: [AssessmentClaimEvidenceBinding]
    ) -> [AssessmentClaimEvidenceBinding] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0.id).inserted }
    }

    private static func uniqueIssues(
        _ values: [AssessmentClaimValidationIssue]
    ) -> [AssessmentClaimValidationIssue] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0.id).inserted }
    }
}

enum AssessmentClaimValidator {
    static func validate(
        _ claim: AssessmentClaim,
        evidenceLedger: ReadOnlyFinalizationEvidenceLedger,
        evidence: [ReadOnlyInspectionEvidence]
    ) -> AssessmentClaimValidation {
        validate([claim], evidenceLedger: evidenceLedger, evidence: evidence)
    }

    static func validate(
        _ claims: [AssessmentClaim],
        evidenceLedger: ReadOnlyFinalizationEvidenceLedger,
        evidence: [ReadOnlyInspectionEvidence]
    ) -> AssessmentClaimValidation {
        var issues: [AssessmentClaimValidationIssue] = []
        var bindings: [AssessmentClaimEvidenceBinding] = []
        var claimIDs: Set<String> = []

        if !evidenceLedger.consistencyIssues.isEmpty {
            issues.append(
                issue(
                    .inconsistentEvidenceLedger,
                    claimID: "assessment-claims",
                    detail: evidenceLedger.consistencyIssues.joined(separator: " | ")
                )
            )
        }

        for claim in claims {
            let trimmedClaimID = claim.claimID.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedClaimID.isEmpty || trimmedClaimID != claim.claimID {
                issues.append(issue(.invalidClaimID, claimID: claim.claimID, detail: "Claim IDs must be non-empty and canonical."))
            } else if !claimIDs.insert(claim.claimID).inserted {
                issues.append(issue(.duplicateClaimID, claimID: claim.claimID, detail: "Claim IDs must be unique within a validation set."))
            }

            let statement = claim.statement.trimmingCharacters(in: .whitespacesAndNewlines)
            if statement.isEmpty || statement != claim.statement {
                issues.append(issue(.invalidStatement, claimID: claim.claimID, detail: "Claim statements must be non-empty and canonical."))
            }
            if claim.evidence.isEmpty {
                issues.append(issue(.missingEvidence, claimID: claim.claimID, detail: "Every Phase 3B.3A assessment claim requires observed evidence."))
            }
            if containsUnsupportedExecutionAssertion(statement) {
                issues.append(issue(.unsupportedExecutionAssertion, claimID: claim.claimID, detail: "Read-only static evidence cannot establish build, test, runtime, deployment, or production success."))
            }
            if claim.verificationStatus != .staticOnly {
                issues.append(issue(.unsupportedVerificationStatus, claimID: claim.claimID, detail: "Phase 3B.3A claims must preserve static-only verification status."))
            }
            if claim.confidence == .unknown && claim.unknowns.isEmpty {
                issues.append(issue(.unknownConfidenceWithoutUnknown, claimID: claim.claimID, detail: "UNKNOWN confidence must identify at least one unresolved fact."))
            }

            var referenceIDs: Set<String> = []
            for reference in claim.evidence {
                if !referenceIDs.insert(reference.id).inserted {
                    issues.append(
                        issue(
                            .duplicateEvidenceReference,
                            claimID: claim.claimID,
                            evidenceReferenceID: reference.id,
                            detail: "A claim cannot cite the same evidence reference more than once."
                        )
                    )
                }
                if reference.fact.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || reference.safeEvidenceSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || reference.sourceComponent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    issues.append(
                        issue(
                            .invalidEvidenceReference,
                            claimID: claim.claimID,
                            evidenceReferenceID: reference.id,
                            detail: "Evidence references require a fact, safe summary, and source component."
                        )
                    )
                }
            }

            var unknowns: Set<String> = []
            for unknown in claim.unknowns {
                let trimmed = unknown.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty || trimmed != unknown {
                    issues.append(issue(.invalidUnknown, claimID: claim.claimID, detail: "Unknowns must be non-empty and canonical."))
                } else if !unknowns.insert(unknown.lowercased()).inserted {
                    issues.append(issue(.duplicateUnknown, claimID: claim.claimID, detail: "Unknowns must be unique within a claim."))
                }
            }

            let binding = AssessmentClaimEvidenceBinder.bind(
                claim,
                evidenceLedger: evidenceLedger,
                evidence: evidence
            )
            issues.append(contentsOf: binding.issues)
            bindings.append(contentsOf: binding.bindings)
            if claim.confidence == .high,
               !binding.bindings.contains(where: {
                   $0.observationStatus == .directlyRead
                       && [.contentRead, .configurationConfirmed, .sourceBehaviorConfirmed].contains($0.claimLevel)
               }) {
                issues.append(issue(.highConfidenceRequiresDirectEvidence, claimID: claim.claimID, detail: "HIGH confidence requires directly read content, configuration, or source behavior evidence."))
            }
        }

        return AssessmentClaimValidation(
            bindings: uniqueBindings(bindings),
            issues: uniqueIssues(issues)
        )
    }

    static func validate(
        _ claim: AssessmentClaim,
        evidence: [ReadOnlyInspectionEvidence],
        ledger: ReadOnlyFinalizationEvidenceLedger
    ) -> AssessmentClaimValidation {
        validate(claim, evidenceLedger: ledger, evidence: evidence)
    }

    static func validate(
        _ claims: [AssessmentClaim],
        evidence: [ReadOnlyInspectionEvidence],
        ledger: ReadOnlyFinalizationEvidenceLedger
    ) -> AssessmentClaimValidation {
        validate(claims, evidenceLedger: ledger, evidence: evidence)
    }

    private static func containsUnsupportedExecutionAssertion(_ statement: String) -> Bool {
        var normalized = statement.lowercased()
        for safePhrase in [
            "build not executed", "build was not executed", "build did not run",
            "tests not executed", "tests were not executed", "tests did not run",
            "runtime not verified", "runtime was not verified", "not runtime verified",
            "deployment not verified", "deployment was not verified", "not deployed",
            "构建未执行", "测试未执行", "运行时未验证", "部署未验证"
        ] {
            normalized = normalized.replacingOccurrences(of: safePhrase, with: "<unverified>")
        }
        return [
            "build passed", "build succeeds", "build succeeded", "build verified",
            "tests passed", "test passed", "runtime verified", "service is running",
            "deployment verified", "production ready", "production-ready", "is deployed",
            "构建成功", "构建已通过", "测试通过", "运行状态已验证", "服务正在运行", "部署已验证", "生产就绪"
        ].contains { normalized.contains($0) }
    }

    private static func issue(
        _ failure: AssessmentClaimValidationFailure,
        claimID: String,
        evidenceReferenceID: String? = nil,
        detail: String
    ) -> AssessmentClaimValidationIssue {
        AssessmentClaimValidationIssue(
            failure: failure,
            claimID: claimID,
            evidenceReferenceID: evidenceReferenceID,
            detail: detail
        )
    }

    private static func uniqueBindings(
        _ values: [AssessmentClaimEvidenceBinding]
    ) -> [AssessmentClaimEvidenceBinding] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0.id).inserted }
    }

    private static func uniqueIssues(
        _ values: [AssessmentClaimValidationIssue]
    ) -> [AssessmentClaimValidationIssue] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0.id).inserted }
    }
}
