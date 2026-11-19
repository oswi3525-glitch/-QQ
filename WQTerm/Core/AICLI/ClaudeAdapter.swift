import Foundation

/// Adapter cho Anthropic Claude Code CLI (PRD Module 4: @anthropic-ai/claude-code).
final class ClaudeAdapter: AICLIAdapter {
    let toolName = "claude"
    let binaryRelativePath = "Resources/node_modules/.bin/claude"

    func apiKey() -> String? {
        try? KeychainService.shared.read(key: "WQTerm.AIKey.Claude").flatMap { String(data: $0, encoding: .utf8) }
    }

    func storeAPIKey(_ key: String) throws {
        try KeychainService.shared.write(key: "WQTerm.AIKey.Claude", data: Data(key.utf8))
    }

    func run(_ arguments: [String], env: [String: String]) -> (output: String, error: String?) {
        guard let key = apiKey() else {
            return ("", "Chưa cấu hình API key Claude trong Settings › AI.")
        }
        var fullEnv = env
        fullEnv["ANTHROPIC_API_KEY"] = key
        // Thực thi qua Node.js runtime
        let nodeRuntime = RuntimeManager.shared.binaryURL(for: .node)
        guard let nodePath = nodeRuntime?.path else {
            return ("", "Node.js runtime không tìm thấy. Vui lòng cài đặt node-ios-arm64 trong Resources.")
        }
        let cliPath = Bundle.main.bundleURL.appendingPathComponent(binaryRelativePath).path
        let envPrefix = fullEnv.sorted { $0.key < $1.key }
            .map { "\($0.key)=\(CommandRunner.shellQuote($0.value))" }
            .joined(separator: " ")
        let command = "\(envPrefix) \( ([nodePath, cliPath] + arguments).map(CommandRunner.shellQuote).joined(separator: " ") )"
        let result = CommandRunner.runCommand(command)
        if result.status == 0 {
            return (result.output, nil)
        }
        return ("", result.output.isEmpty ? "Claude CLI thoát với mã \(result.status)" : result.output)
    }
}
