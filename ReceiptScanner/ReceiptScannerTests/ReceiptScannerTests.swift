import XCTest
@testable import ReceiptScanner
import UIKit
import PDFKit

@MainActor
final class ReceiptScannerTests: XCTestCase {

    func testSampleReceiptParsing() async throws {
        // 1. Load the image from the test bundle (fixtures live in TestFixtures.xcassets, test-target-only)
        let bundle = Bundle(for: type(of: self))
        // Using the actual asset name found in Assets.xcassets
        let assetName = "can-anyone-tell-me-what-a-3b-member-is-v0-jqy7dhwmuksd1"
        guard let image = UIImage(named: assetName, in: bundle, with: nil) else {
            XCTFail("Could not find asset '\(assetName)'. Please ensure it is in Assets.xcassets and the 'ReceiptScanner' target is checked.")
            return
        }
        
        let scanner = ReceiptScanner()

        // 2. Perform OCR
        let result = try await scanner.scan(image: image)
        print("--- RAW OCR TEXT START ---")
        print(result.rawText)
        print("--- RAW OCR TEXT END ---")

        // 3. Parse the results
        let parsed = ReceiptParser.parse(rawText: result.rawText, rows: result.rows, tableItems: result.tableItems)
        let items = parsed.items
        attachScanDebugInfo(image: image, rawText: result.rawText, parsed: parsed, name: "testSampleReceiptParsing")

        XCTAssertEqual(parsed.storeName, "Costco", "Should have identified store as Costco.")
        XCTAssertFalse(items.isEmpty, "Should have parsed at least some items.")
        
        let hasWaterSoftener = items.contains { $0.name.contains("WATER SOFTNR") && $0.price == 28.99 }
        let hasSugar = items.contains { $0.name.contains("SUGAR") && $0.price == 8.99 }
        
        XCTAssertTrue(hasWaterSoftener, "Failed to find Water Softener at 28.99")
        XCTAssertTrue(hasSugar, "Failed to find Sugar at 8.99")
        
        print("Parsed \(items.count) items successfully.")
    }

    func testRotatedReceiptParsing() async throws {
        // 1. Load the original image
        let bundle = Bundle(for: type(of: self))
        let assetName = "can-anyone-tell-me-what-a-3b-member-is-v0-jqy7dhwmuksd1"
        guard let originalImage = UIImage(named: assetName, in: bundle, with: nil) else {
            XCTFail("Could not find asset '\(assetName)'.")
            return
        }
        
        // 2. Rotate it by 5 degrees to simulate a tilted receipt
        let rotatedImage = ImageUtils.rotateImage(originalImage, degrees: 15)
        
        let scanner = ReceiptScanner()

        // 3. Perform OCR on the rotated image
        let result = try await scanner.scan(image: rotatedImage)
        print(result.rawText)
        // 4. Parse the results
        let parsed = ReceiptParser.parse(rawText: result.rawText, rows: result.rows, tableItems: result.tableItems)
        let items = parsed.items
        attachScanDebugInfo(image: rotatedImage, rawText: result.rawText, parsed: parsed, name: "testRotatedReceiptParsing")

        // 5. Verify accuracy
        XCTAssertEqual(parsed.storeName, "Costco")
        XCTAssertFalse(items.isEmpty, "Should have parsed items even when rotated.")
        
        let hasWaterSoftener = items.contains { $0.name.contains("WATER SOFTNR") && $0.price == 28.99 }
        XCTAssertTrue(hasWaterSoftener, "Failed to find Water Softener on rotated image.")
        
        print("Successfully parsed \(items.count) items from a rotated receipt.")
    }
    
    func testCostcoPDFParsing() async throws {
        // 1. Load the PDF data from the test bundle's TestFixtures.xcassets (now a .dataset)
        guard let asset = NSDataAsset(name: "CostcoReceipt", bundle: Bundle(for: type(of: self))) else {
            XCTFail("Could not find CostcoReceipt asset.")
            return
        }
        
        guard let pdfDocument = PDFDocument(data: asset.data) else {
            XCTFail("Could not create PDFDocument from data.")
            return
        }
        
        let scanner = ReceiptScanner()
        var fullRawText = ""
        var allRows: [TextRow] = []
        var tableItemsPerPage: [[ReceiptItemData]] = []
        var pageImages: [UIImage] = []

        // Iterate through all pages and perform OCR
        for i in 0..<pdfDocument.pageCount {
            guard let page = pdfDocument.page(at: i) else { continue }

            // Render PDF page to a UIImage
            let pageRect = page.bounds(for: .mediaBox)
            let renderer = UIGraphicsImageRenderer(size: pageRect.size)
            let image = renderer.image { ctx in
                UIColor.white.set()
                ctx.fill(pageRect)
                ctx.cgContext.translateBy(x: 0.0, y: pageRect.size.height)

                ctx.cgContext.scaleBy(x: 1.0, y: -1.0)
                ctx.cgContext.drawPDFPage(page.pageRef!)
            }
            pageImages.append(image)

            let pageResult = try await scanner.scan(image: image)
            fullRawText += pageResult.rawText + "\n"
            allRows.append(contentsOf: pageResult.rows)
            if let tableItems = pageResult.tableItems {
                tableItemsPerPage.append(tableItems)
            }
        }

        // 1st: Print out the raw file
        print("\n--- COSTCO PDF RAW OCR TEXT START ---")
        print(fullRawText)
        print("--- COSTCO PDF RAW OCR TEXT END ---")

        let combinedTableItems: [ReceiptItemData]? = tableItemsPerPage.count == pdfDocument.pageCount
            ? tableItemsPerPage.flatMap { $0 }
            : nil
        let parsed = ReceiptParser.parse(rawText: fullRawText, rows: allRows, tableItems: combinedTableItems)
        if let firstPage = pageImages.first {
            attachScanDebugInfo(image: firstPage, rawText: fullRawText, parsed: parsed, name: "testCostcoPDFParsing")
        }

        XCTAssertEqual(parsed.storeName, "Costco")
        
        // 2nd: Test each item and its discount
        struct ExpectedItem {
            let searchName: String // Using partial name for robustness against OCR typos
            let fullName: String
            let price: Double
            let discount: Double?
        }
        
        let expectedItems: [ExpectedItem] = [
            ExpectedItem(searchName: "SALTED DUCK", fullName: "SALTED DUCK", price: 7.99, discount: nil),
            ExpectedItem(searchName: "RICE CHEPS", fullName: "RICE CHIPS", price: 14.99, discount: -3.00),
            ExpectedItem(searchName: "RASPBERRIES", fullName: "RASPBERRIES", price: 5.99, discount: nil),
            ExpectedItem(searchName: "GRAPE TOMATO", fullName: "GRAPE TOMATO", price: 6.99, discount: -2.00),
            ExpectedItem(searchName: "HYDRO STRAW", fullName: "HYDRO STRAW", price: 9.99, discount: -2.00),
            ExpectedItem(searchName: "GREEN GRAPES", fullName: "GREEN GRAPES", price: 12.99, discount: nil),
            ExpectedItem(searchName: "KG WATR500**", fullName: "KS WATR500", price: 4.79, discount: nil),
            ExpectedItem(searchName: "ENVIRO FEE C", fullName: "ENVIRO FEE", price: 3.20, discount: nil),
            ExpectedItem(searchName: "DEPOSIT CL", fullName: "DEPOSIT CL", price: 4.00, discount: nil),
            ExpectedItem(searchName: "COOL BLKT QN", fullName: "COOL BLKT QN", price: 34.99, discount: -7.00),
            ExpectedItem(searchName: "BANANAS", fullName: "BANANAS", price: 1.99, discount: nil),
            ExpectedItem(searchName: "MINI CUKES", fullName: "MINI CUKES", price: 3.79, discount: nil),
            ExpectedItem(searchName: "8PK FILTERS", fullName: "8PK FILTERS", price: 44.99, discount: -9.00),
            ExpectedItem(searchName: "AMBROSIA APP", fullName: "AMBROSIA APP", price: 10.99, discount: nil),
            ExpectedItem(searchName: "CROISSANT", fullName: "CROISSANT", price: 6.99, discount: nil)
        ]
        
        print("\n--- ITEM VALIDATION ---")
        for expected in expectedItems {
            let found = parsed.items.first { $0.name.uppercased().contains(expected.searchName) }
            XCTAssertNotNil(found, "Missing item: \(expected.fullName) (searched for '\(expected.searchName)')")
            
            if let item = found {
                XCTAssertEqual(item.price, expected.price, "Price mismatch for \(expected.fullName)")
                XCTAssertEqual(item.discount, expected.discount, "Discount mismatch for \(expected.fullName)")
                print("✅ Found: \(item.name) | Price: \(item.price) | Discount: \(item.discount ?? 0.0)")
            }
        }
        
        // 3rd: Compare the adding of everything to total
        let subtotalFromItems = parsed.items.reduce(0.0) { $0 + $1.price + ($1.discount ?? 0.0) }
        let roundedSubtotal = round(subtotalFromItems * 100) / 100
        
        // The parser extracts keyword values. Let's verify our sum matches the receipt's subtotal line.
        XCTAssertEqual(roundedSubtotal, parsed.subtotal ?? 0.0, "Sum of items (\(roundedSubtotal)) does not match parsed subtotal (\(parsed.subtotal ?? 0.0))")
        
        let totalCalculated = roundedSubtotal + (parsed.tax ?? 0.0)
        let finalTotal = round(totalCalculated * 100) / 100
        
        XCTAssertEqual(finalTotal, 160.03, "Calculated total (\(finalTotal)) does not match expected 160.03")
        XCTAssertEqual(finalTotal, parsed.total ?? 0.0, "Calculated total (\(finalTotal)) does not match parsed total (\(parsed.total ?? 0.0))")
        
        print("\n--- TOTAL VALIDATION ---")
        print("Subtotal (Sum of Items): \(roundedSubtotal)")
        print("Tax (from receipt): \(parsed.tax ?? 0.0)")
        print("Total (Calculated): \(finalTotal)")
        print("Total (from receipt): \(parsed.total ?? 0.0)")
        print("✅ Total validation passed.")
    }
    
    func testCostco2PDFParsing() async throws {
        guard let asset = NSDataAsset(name: "CostcoReceipt2", bundle: Bundle(for: type(of: self))) else {
            XCTFail("Could not find CostcoReceipt2 asset.")
            return
        }
        
        guard let pdfDocument = PDFDocument(data: asset.data) else {
            XCTFail("Could not create PDFDocument from data.")
            return
        }
        
        let scanner = ReceiptScanner()
        var fullRawText = ""
        var allRows: [TextRow] = []
        var tableItemsPerPage: [[ReceiptItemData]] = []
        var pageImages: [UIImage] = []

        for i in 0..<pdfDocument.pageCount {
            guard let page = pdfDocument.page(at: i) else { continue }
            let pageRect = page.bounds(for: .mediaBox)
            let renderer = UIGraphicsImageRenderer(size: pageRect.size)
            let image = renderer.image { ctx in
                UIColor.white.set()
                ctx.fill(pageRect)
                ctx.cgContext.translateBy(x: 0.0, y: pageRect.size.height)
                ctx.cgContext.scaleBy(x: 1.0, y: -1.0)
                ctx.cgContext.drawPDFPage(page.pageRef!)
            }
            pageImages.append(image)

            let pageResult = try await scanner.scan(image: image)
            fullRawText += pageResult.rawText + "\n"
            allRows.append(contentsOf: pageResult.rows)
            if let tableItems = pageResult.tableItems {
                tableItemsPerPage.append(tableItems)
            }
        }

        print("\n--- COSTCO 2 PDF RAW OCR TEXT START ---")
        print(fullRawText)
        print("--- COSTCO 2 PDF RAW OCR TEXT END ---")

        let combinedTableItems: [ReceiptItemData]? = tableItemsPerPage.count == pdfDocument.pageCount
            ? tableItemsPerPage.flatMap { $0 }
            : nil
        let parsed = ReceiptParser.parse(rawText: fullRawText, rows: allRows, tableItems: combinedTableItems)
        if let firstPage = pageImages.first {
            attachScanDebugInfo(image: firstPage, rawText: fullRawText, parsed: parsed, name: "testCostco2PDFParsing")
        }
        XCTAssertEqual(parsed.storeName, "Costco")
        
        // Items to verify:
        // OMEGA EGGS (Multiple)
        // EA VIS DIFF 49.99 GP
        // BANANAS 1.99
        // WHLSME BREAD 6.99
        // GOLD KIWI 14.99
        
        let hasEggs = parsed.items.contains { $0.name.contains("OMEGA EGGS") }
        XCTAssertTrue(hasEggs, "Should have found OMEGA EGGS")
        
        let hasVisDiff = parsed.items.contains { $0.name.contains("VIS DIFF") && $0.price == 49.99 }
        XCTAssertTrue(hasVisDiff, "Should have found EA VIS DIFF at 49.99")
        
        let hasBread = parsed.items.contains { $0.name.contains("WHLSME BREAD") && $0.price == 6.99 }
        XCTAssertTrue(hasBread, "Should have found WHLSME BREAD at 6.99")
        
        // Total Validation
        let subtotalFromItems = parsed.items.reduce(0.0) { $0 + $1.price + ($1.discount ?? 0.0) }
        let roundedSubtotal = round(subtotalFromItems * 100) / 100
        
        XCTAssertEqual(roundedSubtotal, 86.93, "Sum of items should be 86.93")
        XCTAssertEqual(parsed.subtotal, 86.93)
        
        let totalCalculated = roundedSubtotal + (parsed.tax ?? 0.0)
        let finalTotal = round(totalCalculated * 100) / 100
        
        XCTAssertEqual(finalTotal, 90.23, "Calculated total should be 90.23")
        XCTAssertEqual(parsed.total, 90.23)
        
        print("\n--- COSTCO 2 TOTAL VALIDATION ---")
        print("Subtotal: \(roundedSubtotal)")
        print("Tax: \(parsed.tax ?? 0.0)")
        print("Total: \(finalTotal)")
        print("✅ Costco 2 validation passed.")
    }
    
    func testIMG8410StrictPriceComparison() async throws {
        // 1. Load image
        let bundle = Bundle(for: type(of: self))
        guard let image = UIImage(named: "IMG_8410", in: bundle, with: nil) else {
            XCTFail("Could not find IMG_8410.")
            return
        }

        let scanner = ReceiptScanner()
        let result = try await scanner.scan(image: image)

        print("\n--- IMG_8410 RAW OCR TEXT START ---")
        print(result.rawText)
        print("--- IMG_8410 RAW OCR TEXT END ---")

        let parsed = ReceiptParser.parse(rawText: result.rawText, rows: result.rows, tableItems: result.tableItems)
        attachScanDebugInfo(image: image, rawText: result.rawText, parsed: parsed, name: "testIMG8410StrictPriceComparison")

        // 2. Define Expected Prices (Mathematically verified for IMG_8410)
        let expectedItems: [String: Double] = [
            "YU CHOY": 5.49,
            "BLUEBERRIES": 6.99,
            "BANANAS": 1.99,
            "CUCUMBERS": 2.79,
            "GOLD KEWI": 14.99,
            "SWEET/CORN": 6.99,
            "WHITE NECTAR": 15.99,
            "TILARIA": 32.24,
        ]

        print("\n--- IMG_8410 STRICT PRICE COMPARISON ---")

        for (expectedName, expectedPrice) in expectedItems {
            // Find the item in our parsed results
            let foundItem = parsed.items.first { $0.name.uppercased().contains(expectedName) }

            if let item = foundItem {
                let isMatch = abs(item.price - expectedPrice) < 0.01
                if isMatch {
                    print("✅ MATCH: \(expectedName) is \(item.price)")
                } else {
                    print("❌ ERROR: \(expectedName) expected \(expectedPrice) but found \(item.price)")
                }
                XCTAssertTrue(isMatch, "\(expectedName) price mismatch. Expected \(expectedPrice), got \(item.price)")
            } else {
                print("⚠️ MISSING: Could not find \(expectedName) in parsed results.")
                XCTFail("Missing item: \(expectedName)")
            }
        }
    }

    // MARK: - New real-world receipts (no verified expected values yet)
    //
    // These are diagnostic, not strict: I don't have hand-verified ground
    // truth for these receipts, so they only assert basic sanity (store
    // identified, items non-empty). Run them, open Xcode's Report Navigator
    // (Cmd+9 → this test run → click a test → Attachments) to see the image,
    // raw OCR text, and parsed result side by side, and check the printed
    // output below against the real receipt. Paste back anything wrong.

    private func diagnosticParseTest(assetName: String, testName: String) async throws {
        let bundle = Bundle(for: type(of: self))
        guard let image = UIImage(named: assetName, in: bundle, with: nil) else {
            XCTFail("Could not find asset '\(assetName)'.")
            return
        }

        let scanner = ReceiptScanner()
        let result = try await scanner.scan(image: image)
        let parsed = ReceiptParser.parse(rawText: result.rawText, rows: result.rows, tableItems: result.tableItems)
        attachScanDebugInfo(image: image, rawText: result.rawText, parsed: parsed, name: testName)

        print("\n--- \(testName) RAW OCR TEXT START ---")
        print(result.rawText)
        print("--- \(testName) RAW OCR TEXT END ---")

        print("\n--- \(testName) PARSED RESULT ---")
        print("Store: \(parsed.storeName ?? "nil")")
        print("Date: \(parsed.date.map(String.init(describing:)) ?? "nil")")
        print("Subtotal: \(parsed.subtotal.map { String(format: "%.2f", $0) } ?? "nil")")
        print("Tax: \(parsed.tax.map { String(format: "%.2f", $0) } ?? "nil")")
        print("Total: \(parsed.total.map { String(format: "%.2f", $0) } ?? "nil")")
        if let warning = parsed.validationWarning { print("Warning: \(warning)") }

        print("\n--- \(testName) ITEMS (\(parsed.items.count)) ---")
        for item in parsed.items {
            var line = "\(item.itemNumber ?? "-")\t\(item.name)\t$\(String(format: "%.2f", item.price))"
            if let discount = item.discount {
                line += "\tdiscount: $\(String(format: "%.2f", discount))"
            }
            if item.confidence < 1.0 {
                line += "\t(confidence: \(item.confidence))"
            }
            print(line)
        }

        XCTAssertEqual(parsed.storeName, "Costco", "Should have identified store as Costco.")
        XCTAssertFalse(parsed.items.isEmpty, "Should have parsed at least some items.")
    }

    func testCostco3Parsing() async throws {
        try await diagnosticParseTest(assetName: "COSTCO 3", testName: "testCostco3Parsing")
    }

    func testCostco4Parsing() async throws {
        try await diagnosticParseTest(assetName: "COSTCO 4", testName: "testCostco4Parsing")
    }

    func testCostco5Parsing() async throws {
        try await diagnosticParseTest(assetName: "COSTCO 5", testName: "testCostco5Parsing")
    }

    func testWholesaleParsing() async throws {
        try await diagnosticParseTest(assetName: "WHOLESALE", testName: "testWholesaleParsing")
    }
}
