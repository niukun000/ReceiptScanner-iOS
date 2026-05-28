//
//  ReceiptParser.swift
//  ReceiptScanner
//
//  Created by Kun Niu on 2026-05-28.
//

import Foundation

struct ReceiptParser {
    
    static func parseCostcoReceipt(rawText: String) -> [ReceiptItem] {
        var items: [ReceiptItem] = []
        let lines = rawText.components(separatedBy: .newlines)
        
        // Swift Regex Literal Explanation:
        // (?:^[A-Z]\s+)?  -> Optionally ignores a starting letter and space (like "E ")
        // (\d{4,})        -> Capture Group 1: Matches 4 or more digits (Item Number)
        // \s+(.+?)\s+     -> Capture Group 2: Matches the text in the middle (Item Name)
        // (\d+\.\d{2})    -> Capture Group 3: Matches the price format (e.g., 22.10)
        // (?:\s+[A-Z])?$  -> Optionally ignores a trailing space and letter (like " E")
        
        let regex = /(?:^[A-Z]\s+)?(\d{4,})\s+(.+?)\s+(\d+\.\d{2})(?:\s+[A-Z])?$/
        
        for line in lines {
            // Trim leading/trailing whitespace from the ML Kit line output
            let cleanLine = line.trimmingCharacters(in: .whitespaces)
            
            if let match = try? regex.wholeMatch(in: cleanLine) {
                // Extract our capture groups
                let itemNumber = String(match.1)
                let name = String(match.2)
                let priceString = String(match.3)
                
                if let price = Double(priceString) {
                    items.append(ReceiptItem(itemNumber: itemNumber, name: name, price: price))
                }
            }
        }
        
        return items
    }
}
