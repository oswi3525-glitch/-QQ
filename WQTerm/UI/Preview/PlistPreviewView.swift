import SwiftUI

/// Renderer dạng cây cho plist (M7.2) — mở/đóng từng nhánh.
struct PlistPreviewView: View {
    let url: URL
    @ObservedObject var browser: FileBrowser

    @State private var nodes: [PlistNode] = []
    @State private var showRawXML = false
    @State private var rawXML = ""
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let errorMessage {
                ContentUnavailableView("Không đọc được plist",
                                       systemImage: "exclamationmark.triangle",
                                       description: Text(errorMessage))
            } else if showRawXML {
                ScrollView([.horizontal, .vertical]) {
                    Text(rawXML)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
            } else {
                List {
                    OutlineGroup(nodes, children: \.children) { node in
                        PlistRow(node: node)
                    }
                }
                .listStyle(.plain)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Toggle(isOn: $showRawXML) {
                    Label("XML gốc", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                .toggleStyle(.button)
            }
        }
        .task(id: url) { load() }
    }

    private func load() {
        guard let object = PlistViewer.shared.parse(url: url) else {
            errorMessage = "File không phải property list hợp lệ."
            return
        }
        rawXML = PlistViewer.shared.rawXML(url: url) ?? ""
        nodes = PlistNode.build(from: object, name: url.lastPathComponent)
        errorMessage = nil
    }
}

/// Một nút trong cây plist.
struct PlistNode: Identifiable {
    let id = UUID()
    let key: String
    let value: String
    let typeName: String
    let children: [PlistNode]?
    /// Giá trị thô để hỗ trợ sửa.
    let rawValue: Any?

    init(key: String, value: String, typeName: String, children: [PlistNode]?, rawValue: Any?) {
        self.key = key
        self.value = value
        self.typeName = typeName
        self.children = children
        self.rawValue = rawValue
    }

    /// Chuyển object Foundation thành cây node để hiển thị.
    static func build(from object: Any, name: String) -> [PlistNode] {
        if let dictionary = object as? [String: Any] {
            return dictionary.keys.sorted().map { key in
                make(key: key, value: dictionary[key])
            }
        }
        if let array = object as? [Any] {
            return array.enumerated().map { index, element in
                make(key: "[\(index)]", value: element)
            }
        }
        return [make(key: name, value: object)]
    }

    private static func make(key: String, value: Any?) -> PlistNode {
        guard let value else {
            return PlistNode(key: key, value: "nil", typeName: "none", children: nil, rawValue: nil)
        }
        if let dictionary = value as? [String: Any] {
            return PlistNode(key: key,
                             value: "\(dictionary.count) mục",
                             typeName: "dict",
                             children: build(from: dictionary, name: key),
                             rawValue: value)
        }
        if let array = value as? [Any] {
            return PlistNode(key: key,
                             value: "\(array.count) phần tử",
                             typeName: "array",
                             children: build(from: array, name: key),
                             rawValue: value)
        }
        if let bool = value as? Bool {
            return PlistNode(key: key, value: bool ? "true" : "false", typeName: "bool",
                             children: nil, rawValue: value)
        }
        if let number = value as? NSNumber {
            return PlistNode(key: key, value: number.stringValue, typeName: "number",
                             children: nil, rawValue: value)
        }
        if let data = value as? Data {
            return PlistNode(key: key,
                             value: "<\(BuiltinShell.sizeLabel(UInt64(data.count))) dữ liệu>",
                             typeName: "data", children: nil, rawValue: value)
        }
        if let date = value as? Date {
            return PlistNode(key: key, value: ISO8601DateFormatter().string(from: date),
                             typeName: "date", children: nil, rawValue: value)
        }
        return PlistNode(key: key, value: String(describing: value), typeName: "string",
                         children: nil, rawValue: value)
    }
}

/// Dòng hiển thị một node plist.
struct PlistRow: View {
    let node: PlistNode

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(node.key)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.primary)
                Text(node.value)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Text(node.typeName)
                .font(.caption2.monospaced())
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.15))
                .clipShape(Capsule())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
