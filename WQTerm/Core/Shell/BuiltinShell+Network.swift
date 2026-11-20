import Foundation

/// Nhóm lệnh mạng / AI / IPA của Terminal (Module 4 & 5).
extension BuiltinShell {

    // MARK: - curl / wget

    /// Tải file qua `URLSession` (đồng bộ bằng semaphore).
    ///
    /// Hỗ trợ `curl -o <file> <url>`, `curl -L <url>`, `wget <url>`,
    /// và `-H "Key: Value"`. Không có `-o` và dữ liệu là text ≤ 256KB ⇒ in ra stdout.
    func download(command: String, args: [String], cwd: URL) -> Output {
        var urlString: String?
        var outputPath: String?
        var headers: [String] = []
        var index = 0

        while index < args.count {
            let arg = args[index]
            switch arg {
            case "-o", "-O", "--output":
                if index + 1 < args.count {
                    outputPath = args[index + 1]
                    index += 2
                    continue
                }
            case "-H", "--header":
                if index + 1 < args.count {
                    headers.append(args[index + 1])
                    index += 2
                    continue
                }
            default:
                if !arg.hasPrefix("-"), urlString == nil { urlString = arg }
            }
            index += 1
        }

        guard let urlString,
              let url = URL(string: urlString),
              url.scheme?.hasPrefix("http") == true else {
            return Output(status: 1,
                          text: "\(command): cú pháp: \(command) [-o file] <http(s)-url>",
                          cwd: cwd)
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 120
        for header in headers {
            let parts = header.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                request.setValue(parts[1].trimmingCharacters(in: .whitespaces),
                                 forHTTPHeaderField: parts[0])
            }
        }

        let semaphore = DispatchSemaphore(value: 0)
        var payload: Data?
        var failure: String?
        var statusCode = 0

        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                failure = error.localizedDescription
                return
            }
            statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            payload = data
        }.resume()

        // Shell chạy trên background queue nên chờ đồng bộ không chặn UI.
        if semaphore.wait(timeout: .now() + 180) == .timedOut {
            return Output(status: 1, text: "\(command): hết thời gian chờ (180s)", cwd: cwd)
        }
        if let failure { return Output(status: 1, text: "\(command): \(failure)", cwd: cwd) }
        guard let payload else {
            return Output(status: 1, text: "\(command): không nhận được dữ liệu", cwd: cwd)
        }

        let suggested = url.lastPathComponent.isEmpty ? "index.html" : url.lastPathComponent
        let destination = resolve(outputPath ?? suggested, cwd: cwd)

        if outputPath == nil, payload.count <= 256 * 1024,
           let text = String(data: payload, encoding: .utf8) {
            return Output(status: 0, text: text, cwd: cwd)
        }

        do {
            try payload.write(to: destination, options: .atomic)
            return Output(status: 0,
                          text: "Đã tải \(Self.sizeLabel(UInt64(payload.count))) "
                              + "(HTTP \(statusCode)) → \(destination.path)",
                          cwd: cwd)
        } catch {
            return Output(status: 1,
                          text: "\(command): không ghi được file: \(error.localizedDescription)",
                          cwd: cwd)
        }
    }

    // MARK: - ai

    /// `ai "câu hỏi"` — gọi LiteRouter qua `AIService` (key đọc từ Keychain).
    ///
    /// Chạy in-process (không cần Python) nhưng cùng endpoint/model với `ai.py`.
    /// `ai -f <file> "..."` gửi kèm nội dung file để tóm tắt/phân tích.
    func askAI(args: [String], cwd: URL) -> Output {
        var filePath: String?
        var questionParts: [String] = []
        var index = 0

        while index < args.count {
            let arg = args[index]
            if arg == "-f" || arg == "--file", index + 1 < args.count {
                filePath = args[index + 1]
                index += 2
                continue
            }
            questionParts.append(arg)
            index += 1
        }

        var prompt = questionParts.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        if let filePath {
            let url = resolve(filePath, cwd: cwd)
            guard let data = try? Data(contentsOf: url),
                  data.count <= 256 * 1024,
                  let text = String(data: data, encoding: .utf8) else {
                return Output(status: 1,
                              text: "ai: không đọc được \(filePath) (hoặc file > 256KB)",
                              cwd: cwd)
            }
            prompt = "Nội dung file `\(filePath)`:\n```\n\(text)\n```\n\n" + prompt
        }

        guard !prompt.isEmpty else {
            return Output(status: 1, text: "ai: cú pháp: ai [-f file] \"câu hỏi\"", cwd: cwd)
        }

        let service = AIService.shared
        guard let key = service.apiKey else {
            return Output(status: 1,
                          text: "ai: chưa có API key. Nhập key trong tab AI (lưu vào Keychain).",
                          cwd: cwd)
        }

        // Gọi async rồi chờ đồng bộ — đúng mô hình của shell một lệnh.
        let semaphore = DispatchSemaphore(value: 0)
        var reply: String?
        var failure: String?

        Task {
            defer { semaphore.signal() }
            do {
                reply = try await service.requestCompletion(prompt: prompt, apiKey: key)
            } catch {
                failure = error.localizedDescription
            }
        }

        if semaphore.wait(timeout: .now() + 180) == .timedOut {
            return Output(status: 1, text: "ai: hết thời gian chờ (180s)", cwd: cwd)
        }
        if let failure { return Output(status: 1, text: "ai: \(failure)", cwd: cwd) }
        return Output(status: 0, text: reply ?? "(phản hồi rỗng)", cwd: cwd)
    }

    // MARK: - ipa / sbx / tools

    /// `ipa <bundle-id>` — dump app thành IPA trong Documents.
    func dumpIPA(args: [String], cwd: URL) -> Output {
        let targets = args.filter { !$0.hasPrefix("-") }
        guard !targets.isEmpty else {
            let names = SandboxManager.shared.apps.map { "\($0.bundleID)  (\($0.name))" }
            return Output(status: 1,
                          text: "ipa: cú pháp: ipa <bundle-id>\nĐang có:\n" + names.joined(separator: "\n"),
                          cwd: cwd)
        }

        let query = targets[0]
        let app = SandboxManager.shared.apps.first {
            $0.bundleID == query || $0.name.localizedCaseInsensitiveContains(query)
        }
        guard let app else {
            return Output(status: 1, text: "ipa: không tìm thấy app '\(query)'. Chạy 'sbx' để xem danh sách.",
                          cwd: cwd)
        }

        do {
            let result = try IPADumper.shared.dump(app) { _ in }
            return Output(status: 0,
                          text: "Đã dump \(app.name) (\(result.sizeLabel)) → \(result.ipaURL.path)",
                          cwd: cwd)
        } catch {
            return Output(status: 1, text: "ipa: \(error.localizedDescription)", cwd: cwd)
        }
    }

    /// `sbx` — liệt kê app đã cài + trạng thái mount.
    func listSandbox(cwd: URL) -> Output {
        let manager = SandboxManager.shared
        guard !manager.apps.isEmpty else {
            return Output(status: 1,
                          text: "sbx: chưa quét được app nào. Kiểm tra tab Sandbox → Quét lại.",
                          cwd: cwd)
        }
        let lines = manager.apps.map { app -> String in
            let state: String
            switch manager.mountStates[app.bundleID] {
            case .mounted: state = "mounted"
            case .failed(let reason): state = "failed: \(reason.prefix(60))"
            case .notMounted, .none: state = "-"
            }
            return "\(app.bundleID)\t\(app.name)\t\(app.versionLabel)\t\(state)"
        }
        return Output(status: 0, text: lines.joined(separator: "\n"), cwd: cwd)
    }

    /// `tools` — bảng toolchain + PATH hiện tại.
    func listTools(cwd: URL) -> Output {
        let setup = EnvironmentSetup.shared
        let tools = setup.availableTools
        var lines = tools.map { tool in
            let mark = tool.kind.isAvailable ? "✓" : "✗"
            return "\(mark) \(tool.name.padding(toLength: 10, withPad: " ", startingAt: 0))"
                + "[\(tool.kind.rawValue)] \(tool.detail)"
        }
        lines.append("")
        lines.append("PATH=\(setup.pathValue)")
        return Output(status: 0, text: lines.joined(separator: "\n"), cwd: cwd)
    }
}

