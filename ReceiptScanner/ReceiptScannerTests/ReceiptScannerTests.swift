//
//  ReceiptScannerTests.swift
//  ReceiptScannerTests
//
//  Created by Kun Niu on 2026-05-28.
//

import Testing
@testable import ReceiptScanner
@MainActor
struct ReceiptParserTests {

    @Test("Parses Costco receipt format correctly")
    func testCostcoLineParsing() async throws {
        // Arrange: The exact output an OCR engine would give for your photo
        let mockOCRText = """
        Greenville #1005
        1021 Woodruff Rd.
        Greenville, SC 29607
        V5 Member 111797119819
        E      33841 BNLS/SL BRST      22.10 E
        E      77053 GRAPE TOMATO       5.99 E
        E     384881 KS BUTTER         10.39 E
        SUBTOTAL           38.48
        TAX                 0.00
        **** TOTAL         38.48
        """
        
        // Act
        let parsedItems =  ReceiptParser.parseCostcoReceipt(rawText: mockOCRText)
        
        // Assert
        #expect(parsedItems.count == 3)
        
        #expect(parsedItems[0].itemNumber == "33841")
        #expect(parsedItems[0].name == "BNLS/SL BRST")
        #expect(parsedItems[0].price == 22.10)
        
        #expect(parsedItems[2].itemNumber == "384881")
        #expect(parsedItems[2].name == "KS BUTTER")
        #expect(parsedItems[2].price == 10.39)
    }
}
