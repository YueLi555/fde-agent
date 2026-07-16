# Notices and Dependency Inventory

FDE Agent v0.1.0 is licensed under the Mozilla Public License 2.0 (`SPDX-License-Identifier: MPL-2.0`). The official license text is provided in `LICENSE`.

The project does not vendor third-party source packages and declares no remote Swift Package Manager dependencies.

The shipped package uses:

- The Swift standard library and Swift Package Manager, distributed under the Apache License 2.0 with Runtime Library Exception by the Swift project.
- Apple macOS SDK frameworks including SwiftUI, Foundation, AppKit, Security, CryptoKit, Combine, and OSLog, governed by Apple's SDK and platform terms.
- The operating-system `libsqlite3` library through a project-owned C module shim. SQLite is dedicated to the public domain by its authors.
- GitHub Actions `actions/checkout@v6` in CI, licensed under the MIT License. The action is fetched by GitHub Actions and is not vendored in this repository.

No copied third-party implementation or required attribution header was discovered in the release files. This notice is informational, does not modify the MPL-2.0 terms for FDE Agent, and does not replace the licenses or terms of the named projects.
