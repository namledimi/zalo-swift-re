import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct WorkRecordsView: View {
    @Environment(ZaloEngine.self) private var engine
    @Environment(ShellModel.self) private var shell
    @State private var target = ""
    @State private var customer: CustomerWorkRecord?
    @State private var order: WorkOrderDraft?
    @State private var error: String?
    private var records: [CustomerWorkRecord] {
        engine.work.database.customers.filter { $0.account == engine.profile?.userId }.sorted {
            ($0.followUpAt ?? .distantFuture) < ($1.followUpAt ?? .distantFuture)
        }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Khách hàng và công việc").font(.title2.bold())
                Text("Hồ sơ và lịch liên hệ lưu trên máy, theo từng tài khoản Zalo. Nhắc việc hiển thị tại đây khi mở Olaz.").font(.callout).foregroundStyle(.secondary)
                WorkTargetPicker(target: $target)
                Button("Thêm / sửa hồ sơ khách hàng…") {
                    guard let account = engine.profile?.userId, let conversation = engine.visibleConversations.first(where: { $0.id == target }) else { return }
                    customer = engine.work.customer(account: account, conversationID: target, name: conversation.displayName)
                }.disabled(target.isEmpty || engine.profile == nil)
                if let error = error ?? engine.work.error { Text(error).foregroundStyle(.red) }
                if records.isEmpty { Text("Chưa có hồ sơ. Chọn hội thoại để ghi nhu cầu và lịch liên hệ lại.").foregroundStyle(.secondary) }
                ForEach(records) { record in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { Text(record.name).font(.headline); Spacer(); Text(record.stage.title).font(.caption).foregroundStyle(.secondary) }
                        if !record.need.isEmpty { Text(record.need) }
                        if let date = record.followUpAt {
                            Text("Liên hệ lại: " + date.formatted(date: .abbreviated, time: .shortened))
                                .foregroundStyle(date <= .now ? Color.orange : Color.secondary)
                        }
                        HStack {
                            Button("Sửa hồ sơ…") { customer = record }
                            Button("Mở hội thoại") { shell.open(conversation: record.conversationID) }
                                .disabled(!engine.visibleConversations.contains { $0.id == record.conversationID })
                            if record.followUpAt != nil {
                                Button("Đã liên hệ") { do { try engine.work.finishFollowUp(record.id) } catch { self.error = error.localizedDescription } }
                            }
                        }.font(.caption)
                    }.padding(14).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                }
                Divider()
                Text("Đơn nháp nội bộ").font(.headline)
                Text("Lập đơn từ màn hình Sản phẩm. Các phiếu này chưa được gửi sang WooCommerce hay hệ thống bán hàng.").font(.caption).foregroundStyle(.secondary)
                ForEach(engine.work.database.orders.filter { $0.account == engine.profile?.userId }.sorted { $0.createdAt > $1.createdAt }) { draft in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(draft.customerName).font(.headline)
                            Text("\(draft.lines.count) dòng sản phẩm · " + (draft.reviewedAt == nil ? "Chưa duyệt" : "Đã duyệt nội bộ")).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Mở phiếu…") { order = draft }
                    }.padding(12).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                }
            }.padding(22)
        }
        .onAppear { target = shell.selection ?? "" }
        .sheet(item: $customer) { CustomerWorkEditor(record: $0) }
        .sheet(item: $order) { WorkOrderEditor(draft: $0) }
    }
}

struct CustomerWorkShortcut: View {
    let conversationID: String
    let name: String
    @Environment(ZaloEngine.self) private var engine
    @State private var record: CustomerWorkRecord?
    var body: some View {
        Button { if let account = engine.profile?.userId { record = engine.work.customer(account: account, conversationID: conversationID, name: name) } } label: {
            Label("Hồ sơ khách và lịch liên hệ…", systemImage: "person.crop.rectangle")
                .frame(maxWidth: .infinity, alignment: .leading)
        }.buttonStyle(.borderless)
            .sheet(item: $record) { CustomerWorkEditor(record: $0) }
    }
}

struct CustomerWorkEditor: View {
    @State var record: CustomerWorkRecord
    @Environment(ZaloEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Hồ sơ · " + record.name).font(.title2.bold())
            Form {
                Picker("Giai đoạn", selection: $record.stage) { ForEach(CustomerStage.allCases) { Text($0.title).tag($0) } }
                TextField("Nhu cầu", text: $record.need)
                TextField("Ngân sách", text: $record.budget)
                TextField("Dịp tặng", text: $record.occasion)
                TextField("Ghi chú", text: $record.notes, axis: .vertical).lineLimit(3...6)
                Toggle("Có lịch liên hệ lại", isOn: Binding(get: { record.followUpAt != nil }, set: { record.followUpAt = $0 ? Date.now.addingTimeInterval(3600) : nil }))
                if record.followUpAt != nil { DatePicker("Liên hệ lại", selection: Binding(get: { record.followUpAt ?? .now }, set: { record.followUpAt = $0 })) }
                Toggle("Có lịch giao", isOn: Binding(get: { record.deliveryAt != nil }, set: { record.deliveryAt = $0 ? Date.now.addingTimeInterval(86400) : nil }))
                if record.deliveryAt != nil { DatePicker("Ngày giao", selection: Binding(get: { record.deliveryAt ?? .now }, set: { record.deliveryAt = $0 })) }
            }.formStyle(.grouped)
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Button("Hủy") { dismiss() }; Spacer()
                Button("Lưu hồ sơ") {
                    do {
                        guard record.account == engine.profile?.userId else { throw PluginError.message("Tài khoản đã thay đổi. Mở lại hồ sơ.") }
                        try engine.work.save(record); dismiss()
                    } catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent)
            }
        }.padding(22).frame(width: 540)
    }
}

struct WorkOrderEditor: View {
    @State var draft: WorkOrderDraft
    @Environment(ZaloEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Đơn nháp · " + draft.customerName).font(.title2.bold())
            Text("Giá từ nguồn là tham khảo. Kiểm tra lại giá, tiền tệ và thông tin giao trước khi đánh dấu duyệt nội bộ.").font(.caption).foregroundStyle(.secondary)
            Form {
                ForEach($draft.lines) { $line in
                    VStack(alignment: .leading) {
                        Text(line.name).font(.headline)
                        Text("Mã: " + line.productID).font(.caption).foregroundStyle(.secondary)
                        Stepper("Số lượng: \(line.quantity)", value: $line.quantity, in: 1...999)
                        TextField("Đơn giá", text: Binding(get: { line.unitPrice.map { NSDecimalNumber(decimal: $0).stringValue } ?? "" }, set: { line.unitPrice = WorkProduct.decimal($0); draft.reviewedAt = nil }))
                        TextField("Tiền tệ (VND, USD…)", text: Binding(get: { line.currency ?? "" }, set: { line.currency = $0.isEmpty ? nil : $0.uppercased(); draft.reviewedAt = nil }))
                    }
                }
                TextField("Người nhận", text: $draft.recipient)
                TextField("Điện thoại", text: $draft.phone)
                TextField("Địa chỉ", text: $draft.address)
                DatePicker("Thời gian giao", selection: $draft.deliveryAt)
                TextField("Lời chúc", text: $draft.greeting, axis: .vertical)
                TextField("Ghi chú", text: $draft.notes, axis: .vertical)
            }.formStyle(.grouped)
            Text(draft.reviewedAt == nil ? "Chưa duyệt · chưa tạo đơn ngoài Olaz" : "Đã duyệt nội bộ · chưa tạo đơn ngoài Olaz").font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                Button("Đóng") { dismiss() }
                Button("Sao chép") { WorkActions.copy(draft.summary) }
                Button("Xuất JSON…") { export() }
                Spacer()
                Button("Lưu nháp") { save(reviewed: false) }
                Button("Duyệt nội bộ") { save(reviewed: true) }.buttonStyle(.borderedProminent)
            }
        }.padding(22).frame(width: 660, height: 700)
        .onChange(of: reviewContent) { _, _ in draft.reviewedAt = nil }
    }
    private var reviewContent: WorkOrderDraft { var value = draft; value.reviewedAt = nil; return value }
    private func save(reviewed: Bool) {
        do {
            guard draft.account == engine.profile?.userId else { throw PluginError.message("Tài khoản đã thay đổi. Mở lại đơn nháp.") }
            if reviewed {
                guard draft.lines.allSatisfy({ $0.unitPrice != nil && $0.currency?.isEmpty == false }), !draft.recipient.isEmpty, !draft.phone.isEmpty, !draft.address.isEmpty else { throw PluginError.message("Cần giá, tiền tệ, người nhận, điện thoại và địa chỉ trước khi duyệt.") }
            }
            draft.reviewedAt = reviewed ? .now : nil
            try engine.work.save(draft); dismiss()
        } catch { self.error = error.localizedDescription }
    }
    private func export() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "olaz-order-\(draft.id.uuidString.prefix(8)).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; try encoder.encode(draft).write(to: url, options: .atomic); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
        catch { self.error = error.localizedDescription }
    }
}
