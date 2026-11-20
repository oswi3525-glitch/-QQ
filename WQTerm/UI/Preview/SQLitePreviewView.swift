import SwiftUI

/// Renderer cho SQLite database (M7.2) — danh sách bảng + xem nội dung.
struct SQLitePreviewView: View {
    let url: URL

    @State private var tables: [SQLiteViewer.TableInfo] = []
    @State private var selectedTable: SQLiteViewer.TableInfo?
    @State private var tableData: SQLiteViewer.TableData?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let errorMessage {
                ContentUnavailableView("Không mở được database",
                                       systemImage: "cylinder.split.1x2",
                                       description: Text(errorMessage))
            } else if tables.isEmpty {
                ContentUnavailableView("Database rỗng",
                                       systemImage: "cylinder.split.1x2",
                                       description: Text("Không có bảng nào trong file này."))
            } else {
                // iOS không có HSplitView (macOS-only) → dùng NavigationSplitView.
                NavigationSplitView {
                    tableList
                } detail: {
                    tableContent
                }
            }
        }
        .task(id: url) { loadTables() }
    }

    // MARK: - Sections

    private var tableList: some View {
        List(tables, selection: Binding(
            get: { selectedTable?.name },
            set: { name in
                selectedTable = tables.first { $0.name == name }
                loadTable()
            }
        )) { table in
            VStack(alignment: .leading, spacing: 2) {
                Label(table.name, systemImage: "tablecells")
                    .font(.subheadline)
                Text("\(table.rowCount) dòng • \(table.columnNames.count) cột")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .tag(table.name)
        }
        .listStyle(.sidebar)
        .frame(minWidth: 180)
    }

    @ViewBuilder
    private var tableContent: some View {
        if let data = tableData {
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 0) {
                    if data.truncated {
                        Text("Chỉ hiển thị \(SQLiteViewer.shared.rowLimit) dòng đầu tiên.")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .padding(8)
                    }
                    Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                        GridRow {
                            ForEach(data.columnNames, id: \.self) { column in
                                Text(column)
                                    .font(.caption.bold().monospaced())
                                    .frame(minWidth: 100, alignment: .leading)
                                    .padding(6)
                                    .background(Color.secondary.opacity(0.2))
                            }
                        }
                        ForEach(Array(data.rows.enumerated()), id: \.offset) { _, row in
                            Divider()
                            GridRow {
                                ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                    Text(cell)
                                        .font(.caption.monospaced())
                                        .frame(minWidth: 100, alignment: .leading)
                                        .padding(6)
                                }
                            }
                        }
                    }
                }
            }
        } else {
            ContentUnavailableView("Chọn một bảng",
                                   systemImage: "tablecells",
                                   description: Text("Chọn bảng ở cột bên trái để xem nội dung."))
        }
    }

    // MARK: - Loading

    private func loadTables() {
        do {
            tables = try SQLiteViewer.shared.listTables(at: url)
            errorMessage = nil
            if let first = tables.first {
                selectedTable = first
                loadTable()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadTable() {
        guard let table = selectedTable else { return }
        do {
            tableData = try SQLiteViewer.shared.readTable(table.name, at: url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
