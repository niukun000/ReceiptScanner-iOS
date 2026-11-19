import XCTest
import UIKit
@testable import ReceiptScanner

extension XCTestCase {
    /// Attaches the receipt image, raw OCR text, and parsed result to the test
    /// run so all three can be inspected together in Xcode's Report Navigator
    /// (select the test run → click the test → Attachments) instead of having
    /// to cross-reference console prints against the image by hand.
    func attachScanDebugInfo(image: UIImage, rawText: String, parsed: ParsedReceipt, name: String = "Scan Result") {
        XCTContext.runActivity(named: name) { activity in
            let imageAttachment = XCTAttachment(image: image)
            imageAttachment.name = "Receipt Image"
            imageAttachment.lifetime = .keepAlways
            activity.add(imageAttachment)

            let textAttachment = XCTAttachment(string: rawText)
            textAttachment.name = "Raw OCR Text"
            textAttachment.lifetime = .keepAlways
            activity.add(textAttachment)

            let itemLines = parsed.items.map { item -> String in
                var line = "\(item.itemNumber ?? "-")\t\(item.name)\t$\(String(format: "%.2f", item.price))"
                if let discount = item.discount {
                    line += "\tdiscount: $\(String(format: "%.2f", discount))"
                }
                if item.confidence < 1.0 {
                    line += "\t(confidence: \(item.confidence))"
                }
                return line
            }.joined(separator: "\n")

            let summary = """
            Store: \(parsed.storeName ?? "nil")
            Date: \(parsed.date.map(String.init(describing:)) ?? "nil")
            Subtotal: \(parsed.subtotal.map { String(format: "%.2f", $0) } ?? "nil")
            Tax: \(parsed.tax.map { String(format: "%.2f", $0) } ?? "nil")
            Total: \(parsed.total.map { String(format: "%.2f", $0) } ?? "nil")
            Warning: \(parsed.validationWarning ?? "none")

            Items (\(parsed.items.count)):
            \(itemLines)
            """

            let parsedAttachment = XCTAttachment(string: summary)
            parsedAttachment.name = "Parsed Result"
            parsedAttachment.lifetime = .keepAlways
            activity.add(parsedAttachment)
        }
    }
}
