import Foundation

struct ReceiptItemData: Identifiable, Codable {
    var id = UUID()
    let itemNumber: String?
    let name: String
    let price: Double
}

struct ParsedReceipt {
    let storeName: String?
    let items: [ReceiptItemData]
    let total: Double?
    let tax: Double?
    let date: Date?
}

@MainActor
struct ReceiptParser {
    static func parse(rawText: String) -> ParsedReceipt {
        let store = identifyStore(rawText: rawText)
        let date = extractDate(rawText: rawText)
        let total = extractKeywordValue(rawText: rawText, keyword: "TOTAL")
        let tax = extractKeywordValue(rawText: rawText, keyword: "TAX")
        
        let items = (store == "Costco") ? parseCostcoReceipt(rawText: rawText) : parseGenericItems(rawText: rawText)
        
        return ParsedReceipt(storeName: store, items: items, total: total, tax: tax, date: date)
    }
    
    private static func identifyStore(rawText: String) -> String? {
        let text = rawText.uppercased()
        if text.contains("COSTCO") { return "Costco" }
        if text.contains("WALMART") { return "Walmart" }
        if text.contains("TARGET") { return "Target" }
        return nil
    }
    
    private static func extractDate(rawText: String) -> Date? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
        return detector?.matches(in: rawText, options: [], range: NSRange(location: 0, length: rawText.utf16.count)).first?.date
    }
    
    private static func extractKeywordValue(rawText: String, keyword: String) -> Double? {
        for line in rawText.components(separatedBy: .newlines) {
            if line.uppercased().contains(keyword) {
                if let match = try? /\d+\.\d{2}/.firstMatch(in: line) {
                    return Double(match.0)
                }
            }
        }
        return nil
    }
    
    private static func parseCostcoReceipt(rawText: String) -> [ReceiptItemData] {
        var items: [ReceiptItemData] = []
        var pendingPrice: Double? = nil
        
        let lines = rawText.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        
        // Regex for a line ending in a price: [text] [price]
        let priceRegex = /(.+?)\s+(\d+\.\d{2}(-?))(?:\s+.)?$/
        
        for line in lines {
            if line.isEmpty { continue }
            let isMemberLine = line.uppercased().contains("MEMBER")
            
            if let match = try? priceRegex.wholeMatch(in: line) {
                let namePart = String(match.1)
                var priceStr = String(match.2)
                let isNegative = priceStr.hasSuffix("-")
                if isNegative { priceStr = String(priceStr.dropLast()) }
                
                guard let price = Double(priceStr) else { continue }
                let currentPrice = isNegative ? -price : price
                
                if isMemberLine {
                    // "GP Member ... 5.49" -> The price belongs to the NEXT item
                    pendingPrice = currentPrice
                } else {
                    // Line has both text and price (e.g. "YU CHOY 6.99")
                    let name = namePart.replacing(/^\d+\s+/, with: "").trimmingCharacters(in: .whitespaces)
                    
                    if let pPrice = pendingPrice {
                        // Use price carried over from above (the shift bug fix)
                        items.append(ReceiptItemData(itemNumber: nil, name: name, price: pPrice))
                        pendingPrice = currentPrice
                    } else {
                        items.append(ReceiptItemData(itemNumber: nil, name: name, price: currentPrice))
                    }
                }
            } else if !isMemberLine {
                // Line has text but NO price (e.g. "BLUEBERRIES")
                if let price = pendingPrice {
                    let name = line.replacing(/^\d+\s+/, with: "").trimmingCharacters(in: .whitespaces)
                    items.append(ReceiptItemData(itemNumber: nil, name: name, price: price))
                    pendingPrice = nil
                }
            }
        }
        return items
    }
    
    private static func parseGenericItems(rawText: String) -> [ReceiptItemData] {
        var items: [ReceiptItemData] = []
        let regex = /(.+?)\s+(\d+\.\d{2})$/
        for line in rawText.components(separatedBy: .newlines) {
            if let match = try? regex.wholeMatch(in: line.trimmingCharacters(in: .whitespaces)) {
                let name = String(match.1)
                if !["TOTAL", "SUBTOTAL", "TAX"].contains(where: { name.uppercased().contains($0) }) {
                    if let price = Double(match.2) {
                        items.append(ReceiptItemData(itemNumber: nil, name: name, price: price))
                    }
                }
            }
        }
        return items
    }
}
