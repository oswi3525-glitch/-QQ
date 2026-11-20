import SwiftUI

/// Tab AI (Module 4): nhập/xoá API key (Keychain), chọn model, chat trực tiếp
/// với câu trả lời dạng Markdown.
///
/// Chat và cấu hình nằm chung tab nhưng tách 2 màn hình con để màn chat chiếm
/// toàn bộ chiều cao.
struct AIView: View {
    @StateObject private var ai = AIService.shared
    @StateObject private var store = AIProviderStore.shared

    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            ChatView()
                .navigationTitle("AI")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showSettings = true
                        } label: {
                            Label("Cấu hình", systemImage: "gearshape")
                        }
                    }
                }
                .sheet(isPresented: $showSettings) {
                    NavigationStack {
                        AICLISettingsView()
                            .toolbar {
                                ToolbarItem(placement: .topBarTrailing) {
                                    Button("Xong") { showSettings = false }
                                }
                            }
                    }
                }
                .task { store.refresh() }
        }
    }
}
