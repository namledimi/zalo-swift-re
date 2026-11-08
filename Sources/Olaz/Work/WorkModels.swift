import Foundation

struct WorkProduct: Identifiable, Equatable, Sendable {
    var sourceID: UUID
    var sourceName: String
    var productID: String
    var name: String
    var sku: String
    var minPrice: Decimal?
    var maxPrice: Decimal?
    var currency: String?
    var imageURL: URL?
    var pageURL: URL?
    var fetchedAt = Date.now
    var id: String { sourceID.uuidString + ":" + productID }
    var priceText: String {
        guard let minPrice else { return "Chưa có giá" }
        func format(_ value: Decimal) -> String {
            let formatter = NumberFormatter(); formatter.locale = Locale(identifier: "vi_VN")
            if let currency { formatter.numberStyle = .currency; formatter.currencyCode = currency }
            else { formatter.numberStyle = .decimal }
            return formatter.string(from: NSDecimalNumber(decimal: value)) ?? NSDecimalNumber(decimal: value).stringValue
        }
        let range = maxPrice.flatMap { $0 > minPrice ? format(minPrice) + " – " + format($0) : nil } ?? format(minPrice)
        return currency == nil ? range + " (chưa rõ tiền tệ)" : range
    }
    var quote: String { "\(name)\(sku.isEmpty || sku == name ? "" : " · \(sku)"): \(priceText)" + (pageURL.map { "\n" + $0.absoluteString } ?? "") }

    static func parse(_ value: Any, source: MCPPluginConnection) -> (products: [Self], total: Int?) {
        let root = MCPData.unwrapped(value)
        let object = root as? [String: Any] ?? [:]
        let rows: [[String: Any]] = (root as? [[String: Any]]) ?? (["items", "products", "results"].compactMap { object[$0] as? [[String: Any]] }.first)
            ?? (object["product"] as? [String: Any]).map { [$0] } ?? (object["name"] != nil ? [object] : [])
        let defaultCurrency = object["currencyCode"] as? String ?? object["currency_code"] as? String
        let products = rows.prefix(500).compactMap { row -> Self? in
            guard let name = row["name"] as? String ?? row["title"] as? String, !name.isEmpty,
                  let rawID = row["id"] ?? row["productId"] ?? row["sku"] else { return nil }
            let productID = (rawID as? String) ?? (rawID as? NSNumber)?.stringValue ?? ""
            guard !productID.isEmpty else { return nil }
            let prices = row["prices"] as? [String: Any] ?? [:]
            let currency = row["currencyCode"] as? String ?? row["currency"] as? String ?? prices["currency_code"] as? String ?? defaultCurrency
            var minPrice = decimal(row["minPrice"] ?? row["price"] ?? row["sale_price"] ?? row["regular_price"])
            var maxPrice = decimal(row["maxPrice"])
            if minPrice == nil, let minor = decimal(prices["price"]) {
                let scale = max(0, min(6, (prices["currency_minor_unit"] as? NSNumber)?.intValue ?? 0))
                minPrice = minor / pow(Decimal(10), scale); maxPrice = minPrice
            }
            let images = row["images"] as? [[String: Any]] ?? []
            let image = row["image"] as? [String: Any] ?? row["featuredImage"] as? [String: Any] ?? [:]
            let imageString = images.first?["src"] as? String ?? images.first?["url"] as? String ?? image["url"] as? String ?? image["src"] as? String ?? row["imageUrl"] as? String ?? row["image_url"] as? String ?? row["image"] as? String
            return Self(sourceID: source.id, sourceName: source.name, productID: productID, name: String(name.prefix(300)),
                sku: row["sku"] as? String ?? (row["skus"] as? [String])?.first ?? "", minPrice: minPrice, maxPrice: maxPrice,
                currency: currency, imageURL: httpsURL(imageString), pageURL: httpsURL(row["permalink"] as? String ?? row["url"] as? String))
        }
        var seen = Set<String>()
        return (products.filter { seen.insert($0.id).inserted }, object["total"] as? Int ?? object["total_count"] as? Int)
    }
    static func decimal(_ value: Any?) -> Decimal? {
        let text = (value as? String) ?? (value as? NSNumber)?.stringValue
        guard let text, text.range(of: "^[0-9]+(?:\\.[0-9]+)?$", options: .regularExpression) != nil,
              let number = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")), !number.isNaN, number >= 0 else { return nil }
        return number
    }
    static func httpsURL(_ value: String?) -> URL? {
        guard let value, let c = URLComponents(string: value), c.scheme?.lowercased() == "https", c.host?.isEmpty == false,
              c.user == nil, c.password == nil, c.fragment == nil else { return nil }
        return c.url
    }
}

enum CustomerStage: String, Codable, CaseIterable, Identifiable {
    case newLead, quoted, waitingDeposit, ordered, completed
    var id: String { rawValue }
    var title: String {
        switch self {
        case .newLead: "Mới hỏi"
        case .quoted: "Đã báo giá"
        case .waitingDeposit: "Chờ cọc"
        case .ordered: "Đã đặt"
        case .completed: "Hoàn thành"
        }
    }
}
struct CustomerWorkRecord: Codable, Equatable, Identifiable {
    var account: String
    var conversationID: String
    var name: String
    var stage = CustomerStage.newLead
    var need = ""
    var budget = ""
    var occasion = ""
    var notes = ""
    var followUpAt: Date?
    var deliveryAt: Date?
    var id: String { account + ":" + conversationID }
}
struct WorkOrderLine: Codable, Equatable, Identifiable {
    var id = UUID()
    var sourceID: UUID
    var productID: String
    var name: String
    var quantity = 1
    var unitPrice: Decimal?
    var currency: String?
}
struct WorkOrderDraft: Codable, Equatable, Identifiable {
    var id = UUID()
    var account: String
    var conversationID: String
    var customerName: String
    var lines: [WorkOrderLine]
    var recipient = ""
    var phone = ""
    var address = ""
    var greeting = ""
    var notes = ""
    var deliveryAt = Date.now.addingTimeInterval(86400)
    var createdAt = Date.now
    var reviewedAt: Date?
    var summary: String {
        "ĐƠN NHÁP NỘI BỘ · \(customerName)\n" + lines.map { "\($0.name) [\($0.productID)] × \($0.quantity) · Đơn giá: \($0.unitPrice.map { NSDecimalNumber(decimal: $0).stringValue } ?? "chưa nhập") \($0.currency ?? "chưa rõ tiền tệ")" }.joined(separator: "\n")
        + "\nNgười nhận: \(recipient)\nĐiện thoại: \(phone)\nĐịa chỉ: \(address)\nGiao: \(deliveryAt.formatted(date: .numeric, time: .shortened))\nLời chúc: \(greeting)\nGhi chú: \(notes)"
    }
}
struct WorkDatabase: Codable, Equatable {
    var customers: [CustomerWorkRecord] = []
    var orders: [WorkOrderDraft] = []
    var notebooks: [ConversationNotebook]?
}
struct WorkDraftInsertion: Identifiable {
    var id = UUID()
    var account: String
    var conversationID: String
    var text: String
}
