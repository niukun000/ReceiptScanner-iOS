import XCTest
@testable import ReceiptScanner
import UIKit

/// Lets tests control OCR results instantly instead of running real Vision
/// requests. `gate` optionally blocks `scan` until released, so tests can
/// exercise the scan-generation race guard deterministically.
actor FakeReceiptScanner: ReceiptScanning {
    enum Outcome {
        case success(ReceiptScanResult)
        case failure(Error)
    }

    private var outcome: Outcome
    private var gate: CheckedContinuation<Void, Never>?
    private var isGated: Bool

    init(outcome: Outcome, gated: Bool = false) {
        self.outcome = outcome
        self.isGated = gated
    }

    func scan(image: UIImage) async throws -> ReceiptScanResult {
        if isGated {
            await withCheckedContinuation { continuation in
                self.gate = continuation
            }
        }
        switch outcome {
        case .success(let result): return result
        case .failure(let error): throw error
        }
    }

    /// Unblocks a pending `scan` call started while `gated: true`.
    func release() {
        isGated = false
        gate?.resume()
        gate = nil
    }
}

struct FakeScannerError: Error {}

@MainActor
final class ScannerViewModelTests: XCTestCase {

    private func makeImage() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        }
    }

    func testProcessImagePublishesParsedReceiptOnSuccess() async throws {
        let result = ReceiptScanResult(rawText: "COSTCO\nBANANAS 1.99\nSUBTOTAL 1.99", rows: [], tableItems: nil)
        let viewModel = ScannerViewModel(scanner: FakeReceiptScanner(outcome: .success(result)))

        viewModel.processImage(makeImage())
        await viewModel.currentTask?.value

        XCTAssertFalse(viewModel.isScanning)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(viewModel.parsedReceipt?.storeName, "Costco")
        XCTAssertEqual(viewModel.recognizedText, result.rawText)
    }

    func testProcessImageSurfacesErrorOnFailure() async throws {
        let viewModel = ScannerViewModel(scanner: FakeReceiptScanner(outcome: .failure(FakeScannerError())))

        viewModel.processImage(makeImage())
        await viewModel.currentTask?.value

        XCTAssertFalse(viewModel.isScanning)
        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertNil(viewModel.parsedReceipt)
    }

    func testIsScanningTrueWhileScanInFlight() async throws {
        let fakeScanner = FakeReceiptScanner(outcome: .success(ReceiptScanResult(rawText: "", rows: [], tableItems: nil)), gated: true)
        let viewModel = ScannerViewModel(scanner: fakeScanner)

        viewModel.processImage(makeImage())
        XCTAssertTrue(viewModel.isScanning)

        await fakeScanner.release()
        await viewModel.currentTask?.value
        XCTAssertFalse(viewModel.isScanning)
    }

    func testSecondProcessImageCallIgnoredWhileScanInFlight() async throws {
        let fakeScanner = FakeReceiptScanner(outcome: .success(ReceiptScanResult(rawText: "first", rows: [], tableItems: nil)), gated: true)
        let viewModel = ScannerViewModel(scanner: fakeScanner)

        viewModel.processImage(makeImage())
        viewModel.processImage(makeImage()) // should be a no-op: isScanning is already true

        await fakeScanner.release()
        await viewModel.currentTask?.value
        XCTAssertEqual(viewModel.recognizedText, "first")
    }

    func testStaleScanCompletionDoesNotResurrectStateAfterReset() async throws {
        // Scan starts and blocks mid-flight; reset() fires (e.g. user backed
        // out) before it finishes. Its eventual completion must be dropped by
        // the scanGeneration guard rather than resurrecting state post-reset.
        let staleResult = ReceiptScanResult(rawText: "stale", rows: [], tableItems: nil)
        let staleScanner = FakeReceiptScanner(outcome: .success(staleResult), gated: true)
        let viewModel = ScannerViewModel(scanner: staleScanner)

        viewModel.processImage(makeImage())
        let staleTask = viewModel.currentTask

        viewModel.reset() // bumps scanGeneration, invalidating the in-flight scan above

        await staleScanner.release()
        await staleTask?.value

        XCTAssertNil(viewModel.parsedReceipt)
        XCTAssertEqual(viewModel.recognizedText, "")
        XCTAssertFalse(viewModel.isScanning)
    }

    func testShiftPriceDownRecomputesSynthesizedTotals() {
        let items = [
            ReceiptItemData(itemNumber: nil, name: "A", price: 1.00),
            ReceiptItemData(itemNumber: nil, name: "B", price: 2.00),
        ]
        let parsed = ParsedReceipt(storeName: nil, items: items, subtotal: 3.00, tax: nil, total: 3.00, date: nil, validationWarning: nil, subtotalIsSynthesized: true, totalIsSynthesized: true)
        let viewModel = ScannerViewModel(scanner: FakeReceiptScanner(outcome: .success(ReceiptScanResult(rawText: "", rows: [], tableItems: nil))))
        viewModel.parsedReceipt = parsed

        viewModel.shiftPrice(at: 0, down: true)

        // Shifting down moves B's price onto A and zeroes the last row; the
        // synthesized subtotal must track that new sum, not the stale one.
        XCTAssertEqual(viewModel.parsedReceipt?.items[0].price, 0)
        XCTAssertEqual(viewModel.parsedReceipt?.items[1].price, 1.00)
        XCTAssertEqual(viewModel.parsedReceipt?.subtotal, 1.00)
    }

    func testRemoveItemDropsRowAndRecomputesTotals() {
        let items = [
            ReceiptItemData(itemNumber: nil, name: "A", price: 1.00),
            ReceiptItemData(itemNumber: nil, name: "B", price: 2.00),
        ]
        let parsed = ParsedReceipt(storeName: nil, items: items, subtotal: 3.00, tax: nil, total: 3.00, date: nil, validationWarning: nil, subtotalIsSynthesized: true, totalIsSynthesized: true)
        let viewModel = ScannerViewModel(scanner: FakeReceiptScanner(outcome: .success(ReceiptScanResult(rawText: "", rows: [], tableItems: nil))))
        viewModel.parsedReceipt = parsed

        viewModel.removeItem(id: items[0].id)

        XCTAssertEqual(viewModel.parsedReceipt?.items.count, 1)
        XCTAssertEqual(viewModel.parsedReceipt?.subtotal, 2.00)
    }
}
