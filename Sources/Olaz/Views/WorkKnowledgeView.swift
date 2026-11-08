import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct WorkKnowledgeView: View {
    @Environment(ZaloEngine.self) private var engine
    @State private var query = ""
    @State private var error: String?
    private var guides: [AIGuide] {
        engine.aiReply.settings.guides.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.text.localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Kho hướng dẫn").font(.title2.bold()); Spacer()
                    Button("Thêm tài liệu…") { add() }.buttonStyle(.borderedProminent)
                }
                Text("Chính sách bán hàng, giọng trả lời và tài liệu tham khảo dùng chung cho AI. Hỗ trợ UTF-8 .txt, .md, .json; mỗi tệp tối đa 200 KB, tổng 400 KB.")
                    .font(.callout).foregroundStyle(.secondary)
                TextField("Tìm trong tài liệu", text: $query)
                if let error { Text(error).foregroundStyle(.red) }
                if guides.isEmpty { ContentUnavailableView("Chưa có tài liệu phù hợp", systemImage: "books.vertical", description: Text("Thông tin sản phẩm và giá cập nhật nên tra trực tiếp từ MCP.")) }
                ForEach(guides) { guide in
                    DisclosureGroup {
                        Text(guide.text).textSelection(.enabled).font(.callout).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                    } label: {
                        HStack {
                            Text(guide.name); Spacer()
                            Text("\(guide.text.utf8.count / 1000) KB").foregroundStyle(.secondary)
                            Button("Gỡ") { engine.aiReply.settings.guides.removeAll { $0.id == guide.id } }.font(.caption)
                        }
                    }.padding(14).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                }
            }.padding(22)
        }
    }
    private func add() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.plainText, .json, UTType(filenameExtension: "md") ?? .plainText]
        guard panel.runModal() == .OK else { return }
        error = nil
        do {
            for url in panel.urls {
                let resource = try url.resourceValues(forKeys: [.fileSizeKey])
                guard let size = resource.fileSize, size <= AIReplySettings.maxGuideBytes else { throw PluginError.message("Tài liệu vượt quá 200 KB.") }
                try engine.aiReply.addGuide(name: url.lastPathComponent, data: Data(contentsOf: url))
            }
        } catch { self.error = error.localizedDescription }
    }
}
