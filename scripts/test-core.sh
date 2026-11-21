#!/usr/bin/env bash
#
# Chạy unit test cho phần logic thuần của Phase 1 (tunnel resolution, listener
# state machine, handshake, SHA-256/HMAC).
#
# Vì sao cần script: các file còn lại của WQTerm import SwiftUI/UIKit/NetworkExtension
# nên KHÔNG build được ngoài macOS. Nhưng toàn bộ quyết định "tunnel nào hợp lệ",
# "khi nào listener được coi là ready", "khi nào handshake thành công" đều nằm
# trong các file thuần Foundation dưới đây — nên chúng kiểm thử được trên Linux CI
# và trên macOS bằng cùng một lệnh.
#
# Cách dùng: bash scripts/test-core.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${TMPDIR:-/tmp}/wqterm-core-tests"

PURE_FILES=(
  "WQTerm/Core/Network/TunnelLogic.swift"
  "WQTerm/Core/Network/ListenerStateMachine.swift"
  "WQTerm/Core/Pairing/SHA256.swift"
  "WQTerm/Core/Pairing/PairingHandshake.swift"
)

rm -rf "$WORK"
mkdir -p "$WORK/Sources/PairingCore" "$WORK/Tests/PairingCoreTests"

for file in "${PURE_FILES[@]}"; do
  cp "$ROOT/$file" "$WORK/Sources/PairingCore/"
done
cp "$ROOT"/Tests/PairingCoreTests/*.swift "$WORK/Tests/PairingCoreTests/"

cat > "$WORK/Package.swift" <<'SWIFT'
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PairingCore",
    targets: [
        .target(name: "PairingCore"),
        .testTarget(name: "PairingCoreTests", dependencies: ["PairingCore"]),
    ]
)
SWIFT

cd "$WORK"
exec swift test --parallel "$@"
