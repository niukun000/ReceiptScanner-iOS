import XCTest
@testable import ReceiptScanner
import UIKit

@MainActor
final class ReceiptScannerTests: XCTestCase {

    func testSampleReceiptParsing() async throws {
        // 1. Load the image from the Main App Bundle
        let bundle = Bundle(for: ReceiptScanner.self)
        // Using the actual asset name found in Assets.xcassets
        let assetName = "can-anyone-tell-me-what-a-3b-member-is-v0-jqy7dhwmuksd1"
        guard let image = UIImage(named: assetName, in: bundle, with: nil) else {
            XCTFail("Could not find asset '\(assetName)'. Please ensure it is in Assets.xcassets and the 'ReceiptScanner' target is checked.")
            return
        }
        
        let scanner = ReceiptScanner()
        
        // 2. Perform OCR
        let rawText = try await scanner.scanForRawText(image: image)
        print("--- RAW OCR TEXT START ---")
        print(rawText)
        print("--- RAW OCR TEXT END ---")
        
        // 3. Parse the results
        let parsed = ReceiptParser.parse(rawText: rawText)
        let items = parsed.items
        
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
        let bundle = Bundle(for: ReceiptScanner.self)
        let assetName = "can-anyone-tell-me-what-a-3b-member-is-v0-jqy7dhwmuksd1"
        guard let originalImage = UIImage(named: assetName, in: bundle, with: nil) else {
            XCTFail("Could not find asset '\(assetName)'.")
            return
        }
        
        // 2. Rotate it by 5 degrees to simulate a tilted receipt
        let rotatedImage = ImageUtils.rotateImage(originalImage, degrees: 5)
        
        let scanner = ReceiptScanner()
        
        // 3. Perform OCR on the rotated image
        let rawText = try await scanner.scanForRawText(image: rotatedImage)
        
        // 4. Parse the results
        let parsed = ReceiptParser.parse(rawText: rawText)
        let items = parsed.items
        
        // 5. Verify accuracy
        XCTAssertEqual(parsed.storeName, "Costco")
        XCTAssertFalse(items.isEmpty, "Should have parsed items even when rotated.")
        
        let hasWaterSoftener = items.contains { $0.name.contains("WATER SOFTNR") && $0.price == 28.99 }
        XCTAssertTrue(hasWaterSoftener, "Failed to find Water Softener on rotated image.")
        
        print("Successfully parsed \(items.count) items from a rotated receipt.")
    }
    
    func testIMG8410StrictPriceComparison() async throws {
        // 1. Load image
        let bundle = Bundle(for: ReceiptScanner.self)
        guard let image = UIImage(named: "IMG_8410", in: bundle, with: nil) else {
            XCTFail("Could not find IMG_8410.")
            return
        }

        let scanner = ReceiptScanner()
        let rawText = try await scanner.scanForRawText(image: image)
        
        print("\n--- IMG_8410 RAW OCR TEXT START ---")
        print(rawText)
        print("--- IMG_8410 RAW OCR TEXT END ---")
        
        let parsed = ReceiptParser.parse(rawText: rawText)

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
            "TPD/22202": -5.00
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
}
