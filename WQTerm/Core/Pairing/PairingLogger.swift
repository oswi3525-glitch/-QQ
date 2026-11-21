import Foundation
import Combine

enum PairingLogLevel: String, Codable {
    case info
    case warn
    case error
}

struct PairingLogEntry: Identifiable, Codable, Equatable {
    let id: UUID
    let date: Date
    let level: PairingLogLevel
    let stage: String
    let message: String
    let detail: String?

    init(id: UUID = UUID(), date: Date = Date(), level: PairingLogLevel,
         stage: String, message: String, detail: String? = nil) {
        self.id = id
        self.date = date
        self.level = level
        self.stage = stage
        self.message = message
        self.detail = detail
    }
}

/// Log riêng cho từng giai đoạn pairing — tách khỏi audit log (ghi file thao tác).
final class PairingLogger: ObservableObject {
    static let shared = PairingLogger()

    @Published private(set) var entries: [PairingLogEntry] = []

    private let maxEntries = 300
    private let fileURL: URL? = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        return docs?.appendingPathComponent(".terminal/pairing-debug.log", isDirectory: false)
    }()
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    private init() {
        try? FileManager.default.createDirectory(
            at: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(".terminal", isDirectory: true),
            withIntermediateDirectories: true, attributes: nil
        )
    }

    func log(_ level: PairingLogLevel = .info,
             stage: String,
             _ message: String,
             detail: String? = nil) {
        let entry = PairingLogEntry(level: level, stage: stage, message: message, detail: detail)
        DispatchQueue.main.async {
            self.entries.append(entry)
            if self.entries.count > self.maxEntries {
                self.entries.removeFirst(self.entries.count - self.maxEntries)
            }
        }
        let line = "\(dateFormatter.string(from: entry.date)) [\(level.rawValue.uppercased())] "
            + "[\(stage)] \(message)" + (detail.map { " | \($0)" } ?? "") + "\n"
        guard let fileURL, let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: fileURL.path),
           let handle = try? FileHandle(forWritingTo: fileURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        } else {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    func clear() {
        DispatchQueue.main.async { entries.removeAll() }
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
    }

    func exportURL() -> URL? {
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return fileURL
    }
}
