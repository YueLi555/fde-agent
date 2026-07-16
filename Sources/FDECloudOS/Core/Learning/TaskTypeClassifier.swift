import Foundation

enum TaskTypeClassifier {
    static func classify(_ input: String) -> String {
        let lowercased = input.lowercased()

        if containsAny(lowercased, ["workspace", "directory", "project", "files", "audit", "inspect", "review"]) {
            return "workspace-inspection"
        }
        if containsAny(lowercased, ["deploy", "deployment", "release", "rollback", "github", "build"]) {
            return "deployment"
        }
        if containsAny(lowercased, ["slack", "gmail", "notion", "sync", "oauth", "integration"]) {
            return "integration"
        }
        if containsAny(lowercased, ["incident", "failure", "outage", "debug", "investigate"]) {
            return "incident-response"
        }
        return "general-execution"
    }

    private static func containsAny(_ value: String, _ tokens: [String]) -> Bool {
        tokens.contains { value.contains($0) }
    }
}
