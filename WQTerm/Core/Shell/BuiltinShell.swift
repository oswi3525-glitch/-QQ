import Foundation

/// Bộ lệnh Unix cơ bản chạy trực tiếp trong tiến trình ứng dụng.
///
/// Trên iOS không có `/bin/sh`. Khi binary `ios_system` (a-Shell) thật chưa được nhúng
/// (stub hiện tại luôn trả về -1), lớp này đảm bảo terminal vẫn có các lệnh cơ bản để
/// hoạt động. Mọi thao tác đều bị giới hạn trong sandbox của chính ứng dụng.
final class BuiltinShell {
    static let shared = BuiltinShell()

    /// Kết quả một lần thực thi.
    struct Output {
        var status: Int32
        var text: String
        /// Thư mục làm việc sau khi chạy (thay đổi khi dùng `cd`).
        var cwd: URL
    }

    private enum Joiner {
        case always     // segment đầu tiên, hoặc sau `;`
        case onSuccess  // sau `&&`
    }

    private let fm = FileManager.default

    private init() {}

    /// Danh sách lệnh được hỗ trợ (dùng cho `help` và `which`).
    static let commandNames: [String] = [
        "help", "pwd", "cd", "ls", "cat", "echo", "mkdir", "rmdir", "rm", "touch",
        "cp", "mv", "head", "tail", "wc", "grep", "find", "date", "whoami", "env",
        "which", "clear"
    ]

    // MARK: - Entry point

    /// Chạy một dòng lệnh. Hỗ trợ nối lệnh bằng `&&` và `;`, chuyển hướng `>` `>>`.
    func execute(_ line: String, cwd: URL) -> Output {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Output(status: 0, text: "", cwd: cwd) }

        var current = cwd
        var chunks: [String] = []
        var status: Int32 = 0

        for segment in Self.split(trimmed) {
            if segment.joiner == .onSuccess && status != 0 { continue }
            let out = runSegment(segment.text, cwd: current)
            current = out.cwd
            status = out.status
            if !out.text.isEmpty { chunks.append(out.text) }
        }
        return Output(status: status, text: chunks.joined(separator: "\n"), cwd: current)
    }

    // MARK: - Segment handling

    private func runSegment(_ segment: String, cwd: URL) -> Output {
        var tokens = tokenize(segment)

        // Chuyển hướng output: `cmd > file` / `cmd >> file`
        var redirect: (path: String, append: Bool)?
        if let idx = tokens.firstIndex(where: { $0 == ">" || $0 == ">>" }) {
            guard idx + 1 < tokens.count else {
                return Output(status: 2, text: "Thiếu đường dẫn sau '\(tokens[idx])'", cwd: cwd)
            }
            redirect = (tokens[idx + 1], tokens[idx] == ">>")
            tokens.removeSubrange(idx...)
        }

        guard let command = tokens.first else { return Output(status: 0, text: "", cwd: cwd) }
        let result = dispatch(command: command, args: Array(tokens.dropFirst()), cwd: cwd)

        guard let redirect else { return result }

        let destination = resolve(redirect.path, cwd: result.cwd)
        let payload = Data((result.text.isEmpty ? "" : result.text + "\n").utf8)
        do {
            if redirect.append, fm.fileExists(atPath: destination.path) {
                let handle = try FileHandle(forWritingTo: destination)
                handle.seekToEndOfFile()
                handle.write(payload)
                try? handle.close()
            } else {
                try payload.write(to: destination, options: .atomic)
            }
        } catch {
            return Output(status: 1,
                          text: "Không ghi được \(destination.path): \(error.localizedDescription)",
                          cwd: result.cwd)
        }
        return Output(status: result.status, text: "", cwd: result.cwd)
    }

    /// Tách dòng lệnh theo `;` và `&&`, giữ nguyên nội dung trong dấu nháy.
    private static func split(_ line: String) -> [(text: String, joiner: Joiner)] {
        var result: [(String, Joiner)] = []
        var buffer = ""
        var pending: Joiner = .always
        var inSingle = false
        var inDouble = false
        var index = line.startIndex

        while index < line.endIndex {
            let char = line[index]
            if char == "'" && !inDouble {
                inSingle.toggle()
            } else if char == "\"" && !inSingle {
                inDouble.toggle()
            }

            if !inSingle && !inDouble {
                if char == ";" {
                    result.append((buffer, pending))
                    buffer = ""
                    pending = .always
                    index = line.index(after: index)
                    continue
                }
                let next = line.index(after: index)
                if char == "&", next < line.endIndex, line[next] == "&" {
                    result.append((buffer, pending))
                    buffer = ""
                    pending = .onSuccess
                    index = line.index(next, offsetBy: 1)
                    continue
                }
            }

            buffer.append(char)
            index = line.index(after: index)
        }

        result.append((buffer, pending))
        return result
            .filter { !$0.0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { (text: $0.0.trimmingCharacters(in: .whitespaces), joiner: $0.1) }
    }

    /// Tách token, tôn trọng dấu nháy đơn/kép.
    private func tokenize(_ line: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var hasContent = false
        var inSingle = false
        var inDouble = false

        for char in line {
            if char == "'" && !inDouble { inSingle.toggle(); hasContent = true; continue }
            if char == "\"" && !inSingle { inDouble.toggle(); hasContent = true; continue }
            if char == " " && !inSingle && !inDouble {
                if hasContent { tokens.append(current); current = ""; hasContent = false }
                continue
            }
            current.append(char)
            hasContent = true
        }
        if hasContent { tokens.append(current) }
        return tokens
    }

    // MARK: - Command dispatch

    private func dispatch(command: String, args: [String], cwd: URL) -> Output {
        switch command {
        case "help":
            return Output(status: 0, text: Self.helpText, cwd: cwd)

        case "pwd":
            return Output(status: 0, text: cwd.path, cwd: cwd)

        case "cd":
            let target = resolve(args.first ?? ".", cwd: cwd)
            guard isDirectory(target) else {
                return Output(status: 1, text: "cd: không phải thư mục: \(args.first ?? ".")", cwd: cwd)
            }
            return Output(status: 0, text: "", cwd: target)

        case "ls", "dir":
            let showAll = args.contains { $0.hasPrefix("-") && $0.contains("a") }
            let long = args.contains { $0.hasPrefix("-") && $0.contains("l") }
            let pathArg = args.first { !$0.hasPrefix("-") }
            let target = resolve(pathArg ?? ".", cwd: cwd)
            guard fm.fileExists(atPath: target.path) else {
                return Output(status: 1, text: "ls: \(pathArg ?? "."): không tồn tại", cwd: cwd)
            }
            if !isDirectory(target) { return Output(status: 0, text: describe(target, long: long), cwd: cwd) }

            let names = (try? fm.contentsOfDirectory(atPath: target.path)) ?? []
            let visible = names.filter { showAll || !$0.hasPrefix(".") }.sorted()
            var lines = visible.map { name -> String in
                let url = target.appendingPathComponent(name)
                return long ? describe(url, long: true) : name + (isDirectory(url) ? "/" : "")
            }
            if long { lines.insert("total \(visible.count)", at: 0) }
            return Output(status: 0, text: lines.joined(separator: "\n"), cwd: cwd)

        case "cat":
            let files = args.filter { !$0.hasPrefix("-") }
            guard !files.isEmpty else { return Output(status: 1, text: "cat: cần tên file", cwd: cwd) }
            var parts: [String] = []
            for file in files {
                let url = resolve(file, cwd: cwd)
                guard let data = try? Data(contentsOf: url) else {
                    parts.append("cat: \(file): không đọc được")
                    continue
                }
                if let text = String(data: data, encoding: .utf8) {
                    parts.append(text)
                } else {
                    parts.append("(nhị phân, \(Self.sizeLabel(UInt64(data.count))))")
                }
            }
            return Output(status: 0, text: parts.joined(separator: "\n"), cwd: cwd)

        case "echo":
            return Output(status: 0, text: args.joined(separator: " "), cwd: cwd)

        case "mkdir":
            let parents = args.contains("-p")
            let targets = args.filter { !$0.hasPrefix("-") }
            guard !targets.isEmpty else { return Output(status: 1, text: "mkdir: cần tên thư mục", cwd: cwd) }
            do {
                for path in targets {
                    try fm.createDirectory(at: resolve(path, cwd: cwd),
                                           withIntermediateDirectories: parents, attributes: nil)
                }
            } catch {
                return Output(status: 1, text: "mkdir: \(error.localizedDescription)", cwd: cwd)
            }
            return Output(status: 0, text: "", cwd: cwd)

        case "rmdir":
            let targets = args.filter { !$0.hasPrefix("-") }
            guard !targets.isEmpty else { return Output(status: 1, text: "rmdir: cần tên thư mục", cwd: cwd) }
            do {
                for path in targets { try fm.removeItem(at: resolve(path, cwd: cwd)) }
            } catch {
                return Output(status: 1, text: "rmdir: \(error.localizedDescription)", cwd: cwd)
            }
            return Output(status: 0, text: "", cwd: cwd)

        case "rm":
            let recursive = args.contains { $0.hasPrefix("-") && $0.contains("r") }
            let targets = args.filter { !$0.hasPrefix("-") }
            guard !targets.isEmpty else { return Output(status: 1, text: "rm: cần tên file", cwd: cwd) }
            do {
                for path in targets {
                    let url = resolve(path, cwd: cwd)
                    guard fm.fileExists(atPath: url.path) else { continue }
                    if isDirectory(url) && !recursive {
                        return Output(status: 1, text: "rm: \(path) là thư mục (dùng -r)", cwd: cwd)
                    }
                    try fm.removeItem(at: url)
                }
            } catch {
                return Output(status: 1, text: "rm: \(error.localizedDescription)", cwd: cwd)
            }
            return Output(status: 0, text: "", cwd: cwd)

        case "touch":
            let targets = args.filter { !$0.hasPrefix("-") }
            guard !targets.isEmpty else { return Output(status: 1, text: "touch: cần tên file", cwd: cwd) }
            for path in targets {
                let url = resolve(path, cwd: cwd)
                if fm.fileExists(atPath: url.path) {
                    try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
                } else {
                    fm.createFile(atPath: url.path, contents: Data())
                }
            }
            return Output(status: 0, text: "", cwd: cwd)

        case "cp", "mv":
            let paths = args.filter { !$0.hasPrefix("-") }
            guard paths.count >= 2 else {
                return Output(status: 1, text: "\(command): cần nguồn và đích", cwd: cwd)
            }
            let source = resolve(paths[0], cwd: cwd)
            var destination = resolve(paths[1], cwd: cwd)
            guard fm.fileExists(atPath: source.path) else {
                return Output(status: 1, text: "\(command): \(paths[0]): không tồn tại", cwd: cwd)
            }
            if isDirectory(destination) {
                destination = destination.appendingPathComponent(source.lastPathComponent)
            }
            do {
                if command == "cp" {
                    try fm.copyItem(at: source, to: destination)
                } else {
                    try fm.moveItem(at: source, to: destination)
                }
            } catch {
                return Output(status: 1, text: "\(command): \(error.localizedDescription)", cwd: cwd)
            }
            return Output(status: 0, text: "", cwd: cwd)

        case "head", "tail":
            var count = 10
            var path: String?
            var index = 0
            while index < args.count {
                let arg = args[index]
                if arg == "-n", index + 1 < args.count {
                    count = Int(args[index + 1]) ?? 10
                    index += 2
                    continue
                }
                if arg.hasPrefix("-"), let value = Int(arg.dropFirst()) {
                    count = value
                    index += 1
                    continue
                }
                path = arg
                index += 1
            }
            guard let path else { return Output(status: 1, text: "\(command): cần tên file", cwd: cwd) }
            guard let text = readText(resolve(path, cwd: cwd)) else {
                return Output(status: 1, text: "\(command): \(path): không đọc được", cwd: cwd)
            }
            let lines = text.components(separatedBy: "\n")
            let slice = command == "head" ? Array(lines.prefix(count)) : Array(lines.suffix(count))
            return Output(status: 0, text: slice.joined(separator: "\n"), cwd: cwd)

        case "wc":
            let files = args.filter { !$0.hasPrefix("-") }
            guard !files.isEmpty else { return Output(status: 1, text: "wc: cần tên file", cwd: cwd) }
            var lines: [String] = []
            for file in files {
                guard let text = readText(resolve(file, cwd: cwd)) else {
                    lines.append("wc: \(file): không đọc được")
                    continue
                }
                let lineCount = text.components(separatedBy: "\n").count
                let wordCount = text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).count
                lines.append("\(lineCount) \(wordCount) \(text.utf8.count) \(file)")
            }
            return Output(status: 0, text: lines.joined(separator: "\n"), cwd: cwd)

        case "grep":
            let caseInsensitive = args.contains("-i")
            let showLineNumbers = args.contains("-n")
            let positional = args.filter { !$0.hasPrefix("-") }
            guard positional.count >= 2 else {
                return Output(status: 1, text: "grep: cú pháp: grep [-i] [-n] <mẫu> <file>", cwd: cwd)
            }
            let pattern = positional[0]
            var matches: [String] = []
            for file in positional.dropFirst() {
                guard let text = readText(resolve(file, cwd: cwd)) else { continue }
                for (number, line) in text.components(separatedBy: "\n").enumerated() {
                    let haystack = caseInsensitive ? line.lowercased() : line
                    let needle = caseInsensitive ? pattern.lowercased() : pattern
                    guard haystack.contains(needle) else { continue }
                    matches.append(showLineNumbers ? "\(number + 1):\(line)" : line)
                }
            }
            return Output(status: matches.isEmpty ? 1 : 0, text: matches.joined(separator: "\n"), cwd: cwd)

        case "find":
            let start = args.first { !$0.hasPrefix("-") && $0 != "-name" }
            var pattern: String?
            if let idx = args.firstIndex(of: "-name"), idx + 1 < args.count { pattern = args[idx + 1] }
            let root = resolve(start ?? ".", cwd: cwd)
            guard let enumerator = fm.enumerator(at: root,
                                                includingPropertiesForKeys: [.isDirectoryKey],
                                                options: [.skipsHiddenFiles]) else {
                return Output(status: 1, text: "find: không duyệt được \(root.path)", cwd: cwd)
            }
            var found: [String] = []
            for case let url as URL in enumerator {
                if let pattern, !url.lastPathComponent.matchesGlob(pattern) { continue }
                found.append(url.path)
                if found.count >= 2000 { break }
            }
            return Output(status: 0, text: found.joined(separator: "\n"), cwd: cwd)

        case "date":
            return Output(status: 0, text: ISO8601DateFormatter().string(from: Date()), cwd: cwd)

        case "whoami":
            return Output(status: 0, text: "mobile", cwd: cwd)

        case "env":
            let env = ProcessInfo.processInfo.environment
            let lines = env.keys.sorted().map { "\($0)=\(env[$0] ?? "")" }
            return Output(status: 0, text: lines.joined(separator: "\n"), cwd: cwd)

        case "which":
            guard let name = args.first else { return Output(status: 1, text: "which: cần tên lệnh", cwd: cwd) }
            if Self.commandNames.contains(name) { return Output(status: 0, text: "\(name): builtin", cwd: cwd) }
            let candidate = resolve(name, cwd: cwd)
            if fm.isExecutableFile(atPath: candidate.path) {
                return Output(status: 0, text: candidate.path, cwd: cwd)
            }
            return Output(status: 1, text: "", cwd: cwd)

        case "clear":
            return Output(status: 0, text: "", cwd: cwd)

        // MARK: dispatch-part2
        default:
            return Output(status: 127,
                          text: "\(command): không tìm thấy lệnh. Gõ 'help' để xem danh sách.",
                          cwd: cwd)
        }
    }

    // MARK: - Helpers

    private func resolve(_ path: String, cwd: URL) -> URL {
        if path.isEmpty || path == "." { return cwd.standardizedFileURL }
        let expanded: String
        if path == "~" {
            expanded = cwd.path
        } else if path.hasPrefix("~/") {
            expanded = cwd.path + String(path.dropFirst(1))
        } else {
            expanded = path
        }
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded).standardizedFileURL
        }
        return URL(fileURLWithPath: cwd.path)
            .appendingPathComponent(expanded)
            .standardizedFileURL
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    private func readText(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func describe(_ url: URL, long: Bool) -> String {
        let attributes = (try? fm.attributesOfItem(atPath: url.path)) ?? [:]
        let directory = isDirectory(url)
        let name = url.lastPathComponent + (directory ? "/" : "")
        guard long else { return name }

        let mode = (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o644
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let modified = (attributes[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
        let sizeText = directory ? "<DIR>" : Self.sizeLabel(size)
        return "\(Self.permissionString(mode, isDirectory: directory))  "
            + "\(sizeText.padding(toLength: 7, withPad: " ", startingAt: 0))  "
            + "\(Self.longDateFormatter.string(from: modified))  \(name)"
    }

    private static func permissionString(_ mode: UInt16, isDirectory: Bool) -> String {
        let letters: [Character] = ["r", "w", "x"]
        func triplet(_ shift: UInt16) -> String {
            letters.enumerated().map { index, letter in
                (mode >> (shift + UInt16(2 - index))) & 1 == 1 ? String(letter) : "-"
            }.joined()
        }
        return (isDirectory ? "d" : "-") + triplet(6) + triplet(3) + triplet(0)
    }

    static func sizeLabel(_ bytes: UInt64) -> String {
        let units = ["B", "K", "M", "G", "T"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        return unit == 0 ? "\(bytes)B" : String(format: "%.1f%@", value, units[unit])
    }

    private static let longDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    private static let helpText: String = """
    WQTerm builtin shell — các lệnh được hỗ trợ:
      help                 Hiển thị trợ giúp này
      pwd                  In thư mục làm việc hiện tại
      cd <dir>             Đổi thư mục
      ls [-l] [-a] [dir]   Liệt kê nội dung
      cat <file...>        In nội dung file
      echo <text>          In chuỗi (hỗ trợ > và >>)
      mkdir [-p] <dir>     Tạo thư mục
      rmdir <dir>          Xóa thư mục rỗng
      rm [-r] <path...>    Xóa file/thư mục
      touch <file...>      Tạo file rỗng / cập nhật thời gian
      cp <src> <dst>       Sao chép
      mv <src> <dst>       Di chuyển / đổi tên
      head|tail [-n N] <file>
      wc <file...>         Đếm dòng / từ / byte
      grep [-i] [-n] <mẫu> <file...>
      find [dir] [-name <mẫu>]
      date | whoami | env | which <cmd> | clear

    Nối lệnh: `cmd1 && cmd2`, `cmd1 ; cmd2`. Chuyển hướng: `> file`, `>> file`.
    """
}

// MARK: - Glob matching

private extension String {
    /// So khớp tên file với mẫu kiểu `*.log` (chỉ hỗ trợ `*` và `?`).
    func matchesGlob(_ pattern: String) -> Bool {
        NSPredicate(format: "SELF LIKE %@", pattern).evaluate(with: self as NSString)
    }
}
