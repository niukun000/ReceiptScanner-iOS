import Foundation

struct ReceiptItemData: Identifiable, Codable {
    var id = UUID()
    let itemNumber: String?
    let name: String
    var price: Double
    var discount: Double? = nil
    var confidence: Float = 1.0
}

struct ParsedReceipt {
    let storeName: String?
    var items: [ReceiptItemData]
    var subtotal: Double?
    let tax: Double?
    var total: Double?
    let date: Date?
    var validationWarning: String?
    var difference: Double? = nil
    // True when the value was synthesized from the item sum because no usable
    // SUBTOTAL/TOTAL was read off the receipt. Synthesized values must track
    // item edits and must never be validated against as "receipt truth".
    var subtotalIsSynthesized: Bool = false
    var totalIsSynthesized: Bool = false
}

struct ReceiptParser {
    static func parse(rawText: String, rows: [TextRow], tableItems: [ReceiptItemData]? = nil) -> ParsedReceipt {
        let store = identifyStore(rawText: rawText)
        let date = extractDate(rawText: rawText)
        let subtotal = extractKeywordValue(rawText: rawText, keyword: "SUBTOTAL")
        let tax = extractKeywordValue(rawText: rawText, keyword: "TAX")
        let total = extractKeywordValue(rawText: rawText, keyword: "TOTAL")

        var items: [ReceiptItemData]
        debugPrint("rawText", rawText)
        debugPrint("rows", rows.map(\.text).joined(separator: "\n"))
        
        if let tableItems, !tableItems.isEmpty {
            items = tableItems
        } else {
            items = extractItems(from: rows)
            if items.count < 2 && countPriceLikeTokens(in: rawText) >= 3 {
                // The raw text implies a real item list but the geometry-driven
                // classifier found almost nothing (e.g. rows failed to build at
                // all) — fall back to the old regex parser as a safety net.
                items = (store == "Costco") ? parseCostcoReceiptViaRegexFallback(rawText: rawText) : parseGenericItems(rawText: rawText)
            }
        }

        items = mergeSplitNamePriceRows(items)

        // Drop leftover placeholder rows that never found a match. On real,
        // noisier phone photos these are usually store text (addresses, phone
        // numbers, promo lines) that landed in the item block and couldn't be
        // matched to anything — not genuine items — so showing them is worse
        // than silently dropping them, same as the old regex parser did for
        // anything it couldn't confidently parse. Negative "Unmatched Price"
        // rows are kept regardless: they're needed below, which folds a
        // standalone negative price into the previous item's discount whether
        // or not the split-name/price merge already paired it with something.
        items = items.filter { item in
            let isUnmergedNameOnly = item.confidence == 0 && item.name != "Unmatched Price" && item.price == 0
            let isUnmergedPositivePrice = item.confidence == 0 && item.name == "Unmatched Price" && item.price >= 0
            return !(isUnmergedNameOnly || isUnmergedPositivePrice)
        }

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
        debugPrint("items: \(mergedItems)")
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

        // Fall back to the item-level sum when free-text keyword search comes
        // up empty or clearly wrong. This happens on receipts where SUBTOTAL/
        // TOTAL labels aren't immediately followed by their value (e.g. a
        // cluster of labels before a cluster of numbers), or where a line like
        // "TOTAL NUMBER OF ITEMS SOLD" gets matched before the real total.
        // The item math is already independently validated above/by the
        // discount merge, so it's a more reliable source than chasing every
        // receipt template's exact wording.
        let effectiveSubtotal = subtotal ?? roundedSum
        let computedTotal = round((roundedSum + (tax ?? 0)) * 100) / 100
        let totalIsTrusted = total != nil && total! >= roundedSum - 0.01
        let effectiveTotal = totalIsTrusted ? total : computedTotal

        return ParsedReceipt(
            storeName: store,
            items: items,
            subtotal: effectiveSubtotal,
            tax: tax,
            total: effectiveTotal,
            date: date,
            validationWarning: warning,
            difference: diff,
            subtotalIsSynthesized: subtotal == nil,
            totalIsSynthesized: !totalIsTrusted
        )
    }

    // MARK: - Geometry-driven row classifier (primary item-extraction path)

    /// Classifies each geometry-grouped row into a `ReceiptItemData` directly,
    /// without ever flattening rows into a single string and regex-parsing that
    /// string — this is what replaces the old line-text-based parsing for both
    /// Costco and non-Costco receipts.
    private static func extractItems(
        from rows: [TextRow],
        stopKeywords: [String] = ["SUBTOTAL", "TOTAL", "AMOUNT", "TAX", "SHOPCARD"],
        skipKeywords: [String] = ["MEMBER"]
    ) -> [ReceiptItemData] {
        var items: [ReceiptItemData] = []

        for row in rows {
            if row.fragments.isEmpty { continue }
            let upperRowText = row.text.uppercased().replacingOccurrences(of: " ", with: "")

            // Stop/skip — same substring heuristic as before, now fed by row.text.
            if !items.isEmpty, stopKeywords.contains(where: { upperRowText.contains($0) }) {
                break
            }
            if skipKeywords.contains(where: { upperRowText.contains($0) }) {
                // Row grouping sometimes drags a neighboring item's price
                // fragment onto a skipped row (e.g. "Member 111865849526"
                // absorbing the "5.49 GP" that belongs to the item line next
                // to it). Salvage a price-shaped fragment as a price-only
                // placeholder so mergeSplitNamePriceRows can re-pair it with
                // its item; if nothing pairs, the parse() filter drops it.
                for index in row.fragments.indices.reversed() {
                    if let salvaged = matchPriceFragment(row.fragments[index].text) {
                        items.append(ReceiptItemData(itemNumber: nil, name: "Unmatched Price", price: salvaged, confidence: 0))
                        break
                    }
                }
                continue
            }

            // Rightmost fragment matching a price shape is the row's price.
            var priceFragmentIndex: Int? = nil
            var price: Double? = nil
            for index in row.fragments.indices.reversed() {
                if let value = matchPriceFragment(row.fragments[index].text) {
                    priceFragmentIndex = index
                    price = value
                    break
                }
            }

            guard let priceIdx = priceFragmentIndex, let price else {
                // No price fragment in this row at all — typically because OCR
                // split the price onto its own row elsewhere. Keep the row
                // visible (flagged low-confidence) instead of silently
                // dropping it, so its true price can be dragged onto it later.
                // The !items.isEmpty guard keeps header text (store name,
                // address) out of the item list — but the FIRST item can also
                // arrive split, so an SKU-prefixed row is kept even before any
                // priced item has been seen. Requiring no lowercase after the
                // SKU keeps address lines out ("225 Market Drive" has a street
                // number that would otherwise pass; item names are all caps).
                let looksLikeItemStart = row.text.range(of: #"^\d{3,8}\s+[^a-z]+$"#, options: .regularExpression) != nil
                if (!items.isEmpty || looksLikeItemStart) && row.text.count >= 3 {
                    items.append(ReceiptItemData(itemNumber: nil, name: row.text, price: 0, confidence: 0))
                }
                continue
            }

            // Suffix-tag consumption: a fragment right after the price that's
            // short, all-caps/*, and has no digits (Costco's "GP"/"TX"/etc.
            // arriving as its own OCR fragment rather than glued to the price).
            var consumed = Set([priceIdx])
            if priceIdx + 1 < row.fragments.count {
                let next = row.fragments[priceIdx + 1].text
                if next.count <= 3, next.range(of: #"^[A-Z\*]+$"#, options: .regularExpression) != nil {
                    consumed.insert(priceIdx + 1)
                }
            }

            let nameFragments = row.fragments.indices
                .filter { $0 < priceIdx && !consumed.contains($0) }
                .map { row.fragments[$0] }

            guard !nameFragments.isEmpty else {
                // Bare price line — no name/SKU at all on this row.
                items.append(ReceiptItemData(itemNumber: nil, name: "Unmatched Price", price: price, confidence: 0))
                continue
            }

            // Rare anomaly: a second price-shaped token among the "name"
            // fragments (discounts normally arrive as their own separate row,
            // never sharing a row with the main price — see the merge loop in
            // `parse`). If it happens anyway, keep the rightmost as the row's
            // price (handled above) and fold the stray token into the name as
            // plain text, flagged for review.
            let hasStrayPrice = nameFragments.contains { matchPriceFragment($0.text) != nil }

            var sku: String? = nil
            var nameTexts = nameFragments.map(\.text)
            if let first = nameTexts.first, first.range(of: #"^\d{3,8}$"#, options: .regularExpression) != nil {
                sku = first
                nameTexts.removeFirst()
            }
            var name = nameTexts.joined(separator: " ").trimmingCharacters(in: .whitespaces)

            // Fallback safety net: SKU glued onto the name text (e.g. Vision
            // returned "1234567 KS ALMONDS" as one fragment) — peel it the old
            // way if the fragment-based check above didn't find a standalone one.
            // Item numbers vary in length (as short as 3 digits for some items,
            // like milk, up to 8 for others) — no leading SKU at all is also
            // valid (e.g. "ENVIRO FEE C", "DEPOSIT CL" have none).
            if sku == nil, let match = name.range(of: #"^(\d{3,8})\s+"#, options: .regularExpression) {
                sku = String(name[match]).trimmingCharacters(in: .whitespaces)
                name = String(name[match.upperBound...]).trimmingCharacters(in: .whitespaces)
            }

            guard !name.isEmpty else {
                // Row had a SKU/number and a price but no readable name text
                // (OCR missed it). Keep a flagged placeholder instead of
                // dropping the item+price outright — losing the row here
                // would also desync the discount-merge loop below, which
                // merges onto whatever item it thinks came immediately
                // before the next negative-price row.
                items.append(ReceiptItemData(itemNumber: sku, name: sku ?? "Unmatched Item", price: price, confidence: 0))
                continue
            }

            items.append(ReceiptItemData(itemNumber: sku, name: name, price: price, confidence: hasStrayPrice ? 0.5 : 1.0))
        }

        return items
    }

    /// Matches a single OCR fragment's text against a price shape (e.g.
    /// "22.99", "2.00-", "-2.00", "22.99 GP"). Returns the parsed value, or
    /// nil if the fragment isn't price-shaped at all.
    private static func matchPriceFragment(_ text: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: #"^(-?\d{1,4}[.,]\d{2}-?)\s*[A-Z\*]{0,3}$"#),
              let result = regex.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)) else {
            return nil
        }
        let priceStr = (text as NSString).substring(with: result.range(at: 1))
        return TextGeometry.parsePriceToken(priceStr)
    }

    /// Rough count of price-shaped substrings in the flattened text — used only
    /// to decide whether the row-classifier's near-empty result is plausible
    /// (a genuinely short receipt) or a sign the classifier failed and the
    /// regex-based fallback parser should run instead.
    private static func countPriceLikeTokens(in rawText: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: #"\d{1,4}[.,]\d{2}"#) else { return 0 }
        return regex.numberOfMatches(in: rawText, range: NSRange(location: 0, length: rawText.utf16.count))
    }

    // OCR sometimes splits an item's name and price onto separate raw-text lines,
    // producing a name-only placeholder (price 0, confidence 0) and a nearby
    // "Unmatched Price" placeholder (confidence 0). If the two show up
    // directly adjacent to each other, in either order, cascade the
    // price/discount/confidence between them.
    //
    // Deliberately adjacent-only (maxGap = 1, no skipping over rows in
    // between): an earlier version allowed matching up to 2 rows apart, which
    // let the cascade reach straight through a genuine, correctly-parsed item
    // sitting between two unrelated placeholder rows and overwrite its price
    // with noise. Restricting to strict adjacency makes that structurally
    // impossible — there's never anything in between to corrupt.
    private static func mergeSplitNamePriceRows(_ items: [ReceiptItemData]) -> [ReceiptItemData] {
        let maxGap = 1
        var items = items
        var consumed = Set<Int>()
        var removalIndices: [Int] = []

        func isNameOnly(_ item: ReceiptItemData) -> Bool {
            item.confidence == 0 && item.name != "Unmatched Price" && item.price == 0
        }
        func isPriceOnly(_ item: ReceiptItemData) -> Bool {
            item.confidence == 0 && item.name == "Unmatched Price"
        }

        for i in items.indices {
            if consumed.contains(i) { continue }
            let item = items[i]

            let wantsMatch = isNameOnly(item) ? isPriceOnly : (isPriceOnly(item) ? isNameOnly : nil)
            let upperBound = min(i + maxGap, items.count - 1)
            guard let wantsMatch, i + 1 <= upperBound, let j = ((i + 1)...upperBound).first(where: {
                !consumed.contains($0) && wantsMatch(items[$0])
            }) else { continue }

            if isNameOnly(item) {
                // Name at i, stray price at j: cascade up through i..<j, same as
                // dragging a price up. The opening lands at j.
                for k in i..<j {
                    items[k].price = items[k + 1].price
                    items[k].discount = items[k + 1].discount
                    items[k].confidence = items[k + 1].confidence
                }
                removalIndices.append(j)
            } else {
                // Stray price at i, name at j: cascade down through j downTo i+1,
                // same as dragging a price down. The opening lands at i.
                for k in stride(from: j, to: i, by: -1) {
                    items[k].price = items[k - 1].price
                    items[k].discount = items[k - 1].discount
                    items[k].confidence = items[k - 1].confidence
                }
                removalIndices.append(i)
            }
            consumed.insert(j)
        }

        for idx in removalIndices.sorted(by: >) {
            items.remove(at: idx)
        }
        return items
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
        let lines = rawText.components(separatedBy: .newlines)
        let upperKeyword = keyword.uppercased().replacingOccurrences(of: " ", with: "")

        for (index, line) in lines.enumerated() {
            let upperLine = line.uppercased().replacingOccurrences(of: " ", with: "")

            // For 'TOTAL', avoid matching 'SUBTOTAL' or 'TOTALDISCOUNT'
            if keyword == "TOTAL" && (upperLine.contains("SUBTOTAL") || upperLine.contains("DISCOUNT")) {
                continue
            }

            if upperLine.contains(upperKeyword) {
                // 1. Check current line for a price
                var value = findPriceInString(line)

                // 2. Heuristic: if the TAX line ALSO contains SUBTOTAL, the price
                // found on it is likely the subtotal that OCR merged onto the
                // line, so a smaller price on the next line is the real tax.
                // Scoped to merged lines only: preferring any smaller next-line
                // price unconditionally misfires on receipts with a second,
                // smaller tax line ("TAX 2 0.00") or similar right below.
                if keyword == "TAX", let val = value, upperLine.contains("SUBTOTAL"),
                   index + 1 < lines.count,
                   let nextVal = findPriceInString(lines[index + 1]), nextVal < val {
                    return nextVal
                }

                // 3. If no price on current line, check the next line
                if value == nil && index + 1 < lines.count {
                    value = findPriceInString(lines[index + 1])
                }

                if let val = value {
                    return val
                }
            }
        }
        return nil
    }

    private static func findPriceInString(_ str: String) -> Double? {
        // Look for prices like 86.93 or 86,93 or even 86 93 (if space is misread)
        let pricePattern = #"(\d+[\.,\s]\d{2})"#
        if let regex = try? NSRegularExpression(pattern: pricePattern) {
            let range = NSRange(location: 0, length: str.utf16.count)
            let matches = regex.matches(in: str, options: [], range: range)
            if let lastMatch = matches.last {
                var pStr = (str as NSString).substring(with: lastMatch.range)
                pStr = pStr.replacingOccurrences(of: ",", with: ".")
                pStr = pStr.replacingOccurrences(of: " ", with: ".")
                return Double(pStr)
            }
        }
        return nil
    }

    // MARK: - Regex-based fallback parsers (safety net when the row classifier
    // finds suspiciously few items, e.g. row-grouping produced nothing usable)

    private static func parseCostcoReceiptViaRegexFallback(rawText: String) -> [ReceiptItemData] {
        var items: [ReceiptItemData] = []

        let lines = rawText.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        // Stricter price regex: requires a decimal point to avoid matching member numbers
        let priceRegex = #"(.*?)\s+([\d\.,]+[\.,]\d{2}-?)\s*([A-Z\*]*)$"#
        let skuRegex = #"^(\d{3,8})"#

        for line in lines {
            if line.isEmpty { continue }
            let upperLine = line.uppercased().replacingOccurrences(of: " ", with: "")

            // Aggressive stop: Break on any line that looks like a summary line once we have items
            if !items.isEmpty {
                if upperLine.contains("SUBTOTAL") ||
                   upperLine.contains("TOTAL") ||
                   upperLine.contains("AMOUNT") ||
                   upperLine.contains("TAX") ||
                   upperLine.contains("SHOPCARD") {
                    break
                }
            }

            // Skip the member line entirely
            if upperLine.contains("MEMBER") { continue }

            // Bare price line: just a price (positive or negative), optionally followed
            // by a suffix tag (e.g. "2.00-" or "22.99 GP"), with no name/SKU prefix —
            // which the general priceRegex below can't match since it requires
            // whitespace before the price. Surface it as a low-confidence placeholder
            // instead of silently dropping the row (or, worse, misreading the price
            // text itself as an item name because nothing else matched).
            if let bareRegex = try? NSRegularExpression(pattern: #"^([\d\.,]+[\.,]\d{2}-?)\s*[A-Z\*]*$"#),
               let bareResult = bareRegex.firstMatch(in: line, options: [], range: NSRange(location: 0, length: line.utf16.count)) {
                var priceStr = (line as NSString).substring(with: bareResult.range(at: 1)).replacingOccurrences(of: ",", with: ".")
                let isNegative = priceStr.hasSuffix("-")
                if isNegative { priceStr = String(priceStr.dropLast()) }
                if let price = Double(priceStr) {
                    items.append(ReceiptItemData(itemNumber: nil, name: "Unmatched Price", price: isNegative ? -price : price, confidence: 0))
                }
                continue
            }

            if let pMatch = line.range(of: priceRegex, options: .regularExpression) {
                let matchStr = String(line[pMatch])
                if let regex = try? NSRegularExpression(pattern: priceRegex) {
                    let nsRange = NSRange(location: 0, length: matchStr.utf16.count)
                    if let result = regex.firstMatch(in: matchStr, options: [], range: nsRange) {
                        let namePart = (matchStr as NSString).substring(with: result.range(at: 1))
                        var priceStr = (matchStr as NSString).substring(with: result.range(at: 2))

                        // Handle comma as decimal separator if present
                        priceStr = priceStr.replacingOccurrences(of: ",", with: ".")

                        let isNegative = priceStr.hasSuffix("-")
                        if isNegative { priceStr = String(priceStr.dropLast()) }

                        guard let price = Double(priceStr) else { continue }
                        let currentPrice = isNegative ? -price : price

                        var sku: String? = nil
                        var finalName = namePart
                        if let sMatch = finalName.range(of: skuRegex, options: .regularExpression) {
                            sku = String(finalName[sMatch])
                            finalName = String(finalName[sMatch.upperBound...]).trimmingCharacters(in: .whitespaces)
                        }

                        items.append(ReceiptItemData(itemNumber: sku, name: finalName, price: currentPrice))
                    }
                }
                continue
            }

            // Name-only line inside the item block: no price could be matched at all,
            // typically because OCR split the price onto its own line elsewhere. Keep
            // the row visible (flagged low-confidence) instead of silently dropping it,
            // so its true price can be dragged onto it afterward.
            if !items.isEmpty && line.count >= 3 {
                items.append(ReceiptItemData(itemNumber: nil, name: line, price: 0, confidence: 0))
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
