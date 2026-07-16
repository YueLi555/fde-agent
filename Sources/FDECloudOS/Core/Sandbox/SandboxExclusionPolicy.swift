import Foundation

struct SandboxExclusionPolicy: Sendable {
    private let versionControlDirectories: Set<String> = [".git"]
    private let dependencyDirectories: Set<String> = ["node_modules"]
    private let buildDirectories: Set<String> = [
        ".build", "build", "dist", "deriveddata", "coverage", ".next", ".turbo"
    ]
    private let temporaryDirectories: Set<String> = [
        ".cache", "cache", "caches", ".tmp", "tmp", "temp", "temporary"
    ]
    private let credentialDirectories: Set<String> = [
        ".ssh", ".aws", ".gnupg", "credentials", "secrets", "certificates", "private_keys"
    ]
    private let privateKeyNames: Set<String> = [
        "id_rsa", "id_dsa", "id_ecdsa", "id_ed25519"
    ]
    private let credentialNames: Set<String> = [
        "credentials", "credentials.json", "secrets.json", "service-account.json",
        "service_account.json", "google-credentials.json", ".npmrc", ".pypirc", ".netrc"
    ]
    private let tokenNames: Set<String> = [
        ".token", "token", "token.txt", "tokens.json", "access-token.json",
        "access_token.json", "auth-token.txt", "auth_token.txt"
    ]
    private let privateKeyExtensions: Set<String> = ["key", "keystore", "pk8"]
    private let certificateExtensions: Set<String> = [
        "pem", "p12", "pfx", "crt", "cer", "der", "mobileprovision"
    ]

    func exclusion(forRelativePath relativePath: String, isDirectory: Bool) -> SandboxExclusionReason? {
        let components = relativePath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { String($0).lowercased() }
        guard let name = components.last else { return .unsupportedFileType }

        if isDirectory {
            if versionControlDirectories.contains(name) { return .versionControlMetadata }
            if dependencyDirectories.contains(name) { return .dependencyDirectory }
            if buildDirectories.contains(name) { return .buildArtifact }
            if temporaryDirectories.contains(name) { return .cacheOrTemporary }
            if credentialDirectories.contains(name) { return .credentialMaterial }
            return nil
        }

        if name == ".ds_store" { return .operatingSystemMetadata }
        if name == ".env.example" { return nil }
        if name == ".env" || name.hasPrefix(".env.") { return .environmentFile }
        if privateKeyNames.contains(name) { return .privateKey }
        if credentialNames.contains(name)
            || name.hasSuffix("credentials.json")
            || name.contains("service-account")
            || name.contains("service_account")
            || name.hasPrefix("firebase-adminsdk") {
            return .credentialMaterial
        }
        if tokenNames.contains(name) { return .tokenFile }

        let pathExtension = URL(fileURLWithPath: name).pathExtension.lowercased()
        if privateKeyExtensions.contains(pathExtension) { return .privateKey }
        if certificateExtensions.contains(pathExtension) { return .certificate }
        return nil
    }

    func isSensitive(relativePath: String, isDirectory: Bool) -> Bool {
        guard let reason = exclusion(forRelativePath: relativePath, isDirectory: isDirectory) else {
            return false
        }
        switch reason {
        case .environmentFile, .credentialMaterial, .privateKey, .certificate, .tokenFile:
            return true
        default:
            return false
        }
    }

    func isSensitive(reason: SandboxExclusionReason) -> Bool {
        switch reason {
        case .environmentFile, .credentialMaterial, .privateKey, .certificate, .tokenFile:
            true
        default:
            false
        }
    }
}
