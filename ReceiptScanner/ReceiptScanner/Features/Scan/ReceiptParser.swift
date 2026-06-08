import Foundation

struct ReceiptItemData: Identifiable, Codable {
    var id = UUID()
    let itemNumber: String?
    let name: String
    let price: Double
    var discount: Double? = nil
    var confidence: Float = 1.0
}

struct ParsedReceipt {
    let storeName: String?
    let items: [ReceiptItemData]
    let subtotal: Double?
    let tax: Double?
    let total: Double?
    let date: Date?
    var validationWarning: String?
    var difference: Double? = nil
}

@MainActor
struct ReceiptParser {
    static func parse(rawText: String) -> ParsedReceipt {
        let store = identifyStore(rawText: rawText)
        let date = extractDate(rawText: rawText)
        let subtotal = extractKeywordValue(rawText: rawText, keyword: "SUBTOTAL")
        let tax = extractKeywordValue(rawText: rawText, keyword: "TAX")
        let total = extractKeywordValue(rawText: rawText, keyword: "TOTAL")
        
        var items = (store == "Costco") ? parseCostcoReceipt(rawText: rawText) : parseGenericItems(rawText: rawText)
        
        // --- Smart Matching for Discounts ---
        // Merge standalone negative prices into the preceding item if they look like coupons
        var mergedItems: [ReceiptItemData] = []
        for item in items {
            if item.price < 0, let lastIdx = mergedItems.indices.last {
                var parentItem = mergedItems[lastIdx]
                // If it's a negative price and the previous item didn't have a discount yet, merge it
                if parentItem.discount == nil {
                    parentItem.discount = item.price
                    mergedItems[lastIdx] = parentItem
                    continue
                }
            }
            mergedItems.append(item)
        }
        items = mergedItems
        
        var warning: String? = nil
        var diff: Double? = nil
        let sum = items.reduce(0) { $0 + $1.price + ($1.discount ?? 0) }
        let roundedSum = round(sum * 100) / 100
        
        if let sub = subtotal {
            if abs(roundedSum - sub) > 0.01 {
                diff = sub - roundedSum
                warning = "Warning: Calculated subtotal ($\(String(format: "%.2f", roundedSum))) does not match receipt subtotal ($\(String(format: "%.2f", sub)))."
                print(warning!)
            } else {
                print("✅ Subtotal validation passed: $\(String(format: "%.2f", roundedSum)) == $\(String(format: "%.2f", sub))")
            }
        }
        
        return ParsedReceipt(
            storeName: store,
            items: items,
            subtotal: subtotal,
            tax: tax,
            total: total,
            date: date,
            validationWarning: warning,
            difference: diff
        )
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
            let upper = line.uppercased()
            if upper.contains(keyword) {
                let pricePattern = #"\d+\.\d{2}"#
                if let regex = try? NSRegularExpression(pattern: pricePattern) {
                    let range = NSRange(location: 0, length: line.utf16.count)
                    let matches = regex.matches(in: line, options: [], range: range)
                    if let lastMatch = matches.last {
                        let pStr = (line as NSString).substring(with: lastMatch.range)
                        return Double(pStr)
                    }
                }
            }
        }
        return nil
    }
    
    private static func parseCostcoReceipt(rawText: String) -> [ReceiptItemData] {
        var items: [ReceiptItemData] = []
        var pendingPrice: Double? = nil
        
        let lines = rawText.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        let priceRegex = #"(.*?)\s+(\d+\.\d{2}(-?))(?:\s+.)?$"#
        let skuRegex = #"^(\d{4,8})"#
        
        for line in lines {
            if line.isEmpty { continue }
            let upperLine = line.uppercased()
            if upperLine.contains("SUBTOTAL") || (upperLine.contains("TOTAL") && !upperLine.contains("SUBTOTAL")) {
                break
            }
            
            let isMemberLine = upperLine.contains("MEMBER")
            
            if let pMatch = line.range(of: priceRegex, options: .regularExpression) {
                let matchStr = String(line[pMatch])
                if let regex = try? NSRegularExpression(pattern: priceRegex) {
                    let nsRange = NSRange(location: 0, length: matchStr.utf16.count)
                    if let result = regex.firstMatch(in: matchStr, options: [], range: nsRange) {
                        let namePart = (matchStr as NSString).substring(with: result.range(at: 1))
                        var priceStr = (matchStr as NSString).substring(with: result.range(at: 2))
                        
                        let isNegative = priceStr.hasSuffix("-")
                        if isNegative { priceStr = String(priceStr.dropLast()) }
                        
                        guard let price = Double(priceStr) else { continue }
                        let currentPrice = isNegative ? -price : price
                        
                        if isMemberLine {
                            pendingPrice = currentPrice
                        } else {
                            var sku: String? = nil
                            var finalName = namePart
                            if let sMatch = finalName.range(of: skuRegex, options: .regularExpression) {
                                sku = String(finalName[sMatch])
                                finalName = String(finalName[sMatch.upperBound...]).trimmingCharacters(in: .whitespaces)
                            }
                            
                            if let pPrice = pendingPrice {
                                items.append(ReceiptItemData(itemNumber: sku, name: finalName, price: pPrice))
                                pendingPrice = currentPrice
                            } else {
                                items.append(ReceiptItemData(itemNumber: sku, name: finalName, price: currentPrice))
                            }
                        }
                    }
                }
            } else if !isMemberLine && !upperLine.contains("TAX") {
                if let price = pendingPrice {
                    var finalName = line
                    var sku: String? = nil
                    if let sMatch = finalName.range(of: skuRegex, options: .regularExpression) {
                        sku = String(finalName[sMatch])
                        finalName = String(finalName[sMatch.upperBound...]).trimmingCharacters(in: .whitespaces)
                    }
                    items.append(ReceiptItemData(itemNumber: sku, name: finalName, price: price))
                    pendingPrice = nil
                }
            }
        }
        return items
    }
    
    private static func parseGenericItems(rawText: String) -> [ReceiptItemData] {
        var items: [ReceiptItemData] = []
        let priceRegex = #"(.*?)\s+(\d+\.\d{2})$"#
        
        for line in rawText.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            
            if let regex = try? NSRegularExpression(pattern: priceRegex) {
                let nsRange = NSRange(location: 0, length: trimmed.utf16.count)
                if let result = regex.firstMatch(in: trimmed, options: [], range: nsRange) {
                    let name = (trimmed as NSString).substring(with: result.range(at: 1))
                    let priceStr = (trimmed as NSString).substring(with: result.range(at: 2))
                    
                    if !["TOTAL", "SUBTOTAL", "TAX"].contains(where: { name.uppercased().contains($0) }) {
                        if let price = Double(priceStr) {
                            items.append(ReceiptItemData(itemNumber: nil, name: name, price: price))
                        }
                    }
                }
            }
        }
        return items
    }
}
