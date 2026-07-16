# Security Policy

## Supported version

Security fixes are planned for the latest published `0.1.x` release after v0.1.0 is actually published. This release candidate is not production-ready and has not received an independent security audit.

## Reporting a vulnerability

Use **GitHub Private Vulnerability Reporting** for every suspected security vulnerability: open the repository's **Security** tab, choose **Report a vulnerability**, and submit the private advisory form.

Never report a security vulnerability in a public GitHub issue, discussion, pull request, or other public channel. Do not place vulnerability details, credentials, private repository content, or user data in public. If **Report a vulnerability** is unavailable, do not disclose the issue publicly; wait for the maintainer to enable GitHub Private Vulnerability Reporting. The maintainer must enable it when the GitHub repository is created and before announcing the release.

Include the affected version, a minimal synthetic reproduction, impact, and suggested mitigation. Remove API keys, absolute home paths, Sandbox IDs, task/session identifiers, and real Legacy content from the report.

## Security boundaries in v0.1.0

- The live application advertises and executes only bounded read-only inspection tools.
- Legacy and Agent roots are modeled separately.
- Safe Sandbox storage must be outside the approved Legacy root.
- Source symlinks, path traversal, absolute write targets, metadata targets, and nested Sandbox roots fail closed.
- Sensitive files and generated/local directories are excluded by policy.
- Source and copied files are compared with SHA-256; inode/device identity is checked for independent storage.
- Phase 2D.0 exposes an empty writable-operation allowlist.
- Sandbox destruction validates the Sandbox identifier and target containment.
- Public CI uses the deterministic local provider and no secrets.

## Data and network considerations

The app can persist local task metadata in the user's Application Support directory. Do not attach that database or runtime logs to reports. Optional model-provider code contains public OpenAI and Anthropic API endpoints and reads user-supplied credentials from environment/secure storage, but no credential is shipped and those providers are not required for deterministic operation. Selecting an external provider may transmit prompt context to that provider; review the provider's terms and the selected workspace scope first.

See [the threat model](docs/threat-model.md), [safety model](docs/safety-model.md), and [known limitations](docs/known-limitations.md).
