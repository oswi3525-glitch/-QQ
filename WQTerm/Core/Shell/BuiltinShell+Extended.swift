import Foundation

/// Các lệnh mở rộng của Terminal (Module 5) — tách khỏi `BuiltinShell` để file
/// dispatch chính không phình to.
///
/// Nhóm lệnh:
/// - `unzip` / `zip` / `tar`: dùng `ZipArchive` thuần Swift (không cần binary).
/// - `curl` / `wget`: tải file qua `URLSession`.
/// - `ai` / `ask`: gọi LiteRouter (key đọc từ Keychain).
/// - `ipa`: dump IPA của app đã cài (gọi `IPADumper`).
/// - `sbx`: liệt kê container đã mount.
/// - `tools`: bảng toolchain + PATH hiện tại.
///
/// Trả `BuiltinShell.Output?` — `nil` nghĩa là "không phải lệnh của tôi".
extension BuiltinShell {

    /// Xử lý một lệnh mở rộng. `nil` nếu lệnh không thuộc nhóm này.
    func runExtendedCommand(_ command: String, args: [String], cwd: URL) -> Output? {
        switch command {
        case "unzip": return unzip(args: args, cwd: cwd)
        case "zip": return zip(args: args, cwd: cwd)
        case "tar": return tar(args: args, cwd: cwd)
        case "curl", "wget": return download(command: command, args: args, cwd: cwd)
        case "ai", "ask": return askAI(args: args, cwd: cwd)
        case "ipa": return dumpIPA(args: args, cwd: cwd)
        case "sbx", "sbx_ls": return listSandbox(cwd: cwd)
        case "tools": return listTools(cwd: cwd)
        default: return nil
        }
    }

    // MARK: - unzip / zip / tar

    func unzip(args: [String], cwd: URL) -> Output {
        let files = args.filter { !$0.hasPrefix("-") }
        let listOnly = args.contains("-l") || args.contains("-v")

        guard let archiveName = files.first else {
            return Output(status: 1, text: "unzip: cú pháp: unzip [-l] <file.zip> [dest]", cwd: cwd)
        }
        let archive = resolve(archiveName, cwd: cwd)
        guard FileManager.default.fileExists(atPath: archive.path) else {
            return Output(status: 1, text: "unzip: không tìm thấy \(archiveName)", cwd: cwd)
        }

        do {
            if listOnly {
                let names = try ZipArchive.listNames(archive)
                return Output(status: 0,
                              text: "Archive: \(archive.lastPathComponent)\n" + names.joined(separator: "\n"),
                              cwd: cwd)
            }
            let destination = files.count > 1
                ? resolve(files[1], cwd: cwd)
                : cwd.appendingPathComponent(archive.deletingPathExtension().lastPathComponent,
                                             isDirectory: true)
            try ZipArchive.extract(archive, to: destination)
            let count = try ZipArchive.listEntries(archive).count
            return Output(status: 0, text: "Đã giải nén \(count) mục vào \(destination.path)", cwd: cwd)
        } catch {
            return Output(status: 1, text: "unzip: \(error.localizedDescription)", cwd: cwd)
        }
    }

    func zip(args: [String], cwd: URL) -> Output {
        let files = args.filter { !$0.hasPrefix("-") }
        guard files.count >= 2 else {
            return Output(status: 1, text: "zip: cú pháp: zip <output.zip> <thư mục>", cwd: cwd)
        }
        let outputName = files[0].hasSuffix(".zip") ? files[0] : files[0] + ".zip"
        let output = resolve(outputName, cwd: cwd)
        let source = resolve(files[1], cwd: cwd)

        guard FileManager.default.fileExists(atPath: source.path) else {
            return Output(status: 1, text: "zip: không tìm thấy \(files[1])", cwd: cwd)
        }

        do {
            try ZipArchive.create(directory: source, at: output)
            let size = (try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return Output(status: 0,
                          text: "Đã tạo \(output.lastPathComponent) (\(Self.sizeLabel(UInt64(size))))",
                          cwd: cwd)
        } catch {
            return Output(status: 1, text: "zip: \(error.localizedDescription)", cwd: cwd)
        }
    }

    /// `tar -czf` / `tar -xzf`: dùng chung engine ZIP vì bundle không có bsdtar.
    func tar(args: [String], cwd: URL) -> Output {
        let flags = args.first { $0.hasPrefix("-") } ?? ""
        let files = args.filter { !$0.hasPrefix("-") }

        guard let archiveName = files.first else {
            return Output(status: 1,
                          text: "tar: cú pháp: tar -czf out.zip <dir> | tar -xzf in.zip [dest]",
                          cwd: cwd)
        }
        let archive = resolve(archiveName, cwd: cwd)

        if flags.contains("x") {
            guard FileManager.default.fileExists(atPath: archive.path) else {
                return Output(status: 1, text: "tar: không tìm thấy \(archiveName)", cwd: cwd)
            }
            let destination = files.count > 1 ? resolve(files[1], cwd: cwd) : cwd
            do {
                try ZipArchive.extract(archive, to: destination)
                return Output(status: 0,
                              text: "Đã giải nén vào \(destination.path) (engine ZIP)", cwd: cwd)
            } catch {
                return Output(status: 1, text: "tar: \(error.localizedDescription)", cwd: cwd)
            }
        }

        if flags.contains("c"), files.count >= 2 {
            let source = resolve(files[1], cwd: cwd)
            guard FileManager.default.fileExists(atPath: source.path) else {
                return Output(status: 1, text: "tar: không tìm thấy \(files[1])", cwd: cwd)
            }
            do {
                try ZipArchive.create(directory: source, at: archive)
                return Output(status: 0, text: "Đã nén vào \(archive.path) (engine ZIP)", cwd: cwd)
            } catch {
                return Output(status: 1, text: "tar: \(error.localizedDescription)", cwd: cwd)
            }
        }

        return Output(status: 1,
                      text: "tar: chỉ hỗ trợ -czf/-xzf (engine ZIP). Dùng zip/unzip cho rõ ràng.",
                      cwd: cwd)
    }
}
