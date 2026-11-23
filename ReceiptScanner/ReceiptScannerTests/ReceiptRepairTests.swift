import XCTest
import UIKit
import FoundationModels
@testable import ReceiptScanner

/// Stands in for the on-device model: returns canned moves (or an error) and
/// counts calls, so the repair flow can be tested deterministically.
actor FakeReceiptRepairer: ReceiptRepairing {
    private let result: Result<[PriceMove], Error>
    private(set) var callCount = 0
    private var gate: CheckedContinuation<Void, Never>?
    private var isGated: Bool

    init(moves: [PriceMove], gated: Bool = false) {
        result = .success(moves)
        isGated = gated
    }
    init(error: Error) { result = .failure(error); isGated = false }

    func proposeMoves(lines: [String], subtotal: Double) async throws -> [PriceMove] {
        callCount += 1
        if isGated {
            await withCheckedContinuation { continuation in self.gate = continuation }
        }
        return try result.get()
    }

    /// Unblocks a pending `proposeMoves` call started while `gated: true`.
    func release() {
        isGated = false
        gate?.resume()
        gate = nil
    }
}

@MainActor
final class ReceiptRepairTests: XCTestCase {

    // MARK: - Fixtures

    private func row(_ parts: String...) -> TextRow {
        TextRow(fragments: parts.map { TextFragment(text: $0, topLeft: .zero, topRight: .zero, bottomLeft: .zero, bottomRight: .zero) })
    }

    /// The common failure: each price landed one line below its item, so the
    /// first item has no price and every later item shows the previous one's.
    /// Correct receipt: APPLES 2.00, BREAD 3.00, MILK 4.00, SUBTOTAL 9.00.
    private var shiftedRows: [TextRow] {
        [
            row("COSTCO"),
            row("WHOLESALE"),
            row("111", "APPLES"),
            row("222", "BREAD", "2.00"),
            row("333", "MILK", "3.00"),
            row("4.00"),
            row("SUBTOTAL", "9.00"),
        ]
    }

    private let shiftFix = [
        PriceMove(fromLine: 3, toLine: 2, price: "2.00"),
        PriceMove(fromLine: 4, toLine: 3, price: "3.00"),
        PriceMove(fromLine: 5, toLine: 4, price: "4.00"),
    ]

    private func parse(_ rows: [TextRow]) -> ParsedReceipt {
        ReceiptParser.parse(rawText: rows.map(\.text).joined(separator: "\n"), rows: rows)
    }

    private func price(of name: String, in parsed: ParsedReceipt) -> Double? {
        parsed.items.first { $0.name.contains(name) }?.price
    }

    private func makeImage() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        }
    }

    private func makeViewModel(rows: [TextRow], repairer: ReceiptRepairing) -> ScannerViewModel {
        let result = ReceiptScanResult(rawText: rows.map(\.text).joined(separator: "\n"), rows: rows, tableItems: nil)
        return ScannerViewModel(scanner: FakeReceiptScanner(outcome: .success(result)), repairer: repairer)
    }

    // MARK: - Layer 1: applying moves and re-parsing (no model)

    func testShiftedFixtureFailsWithoutRepair() {
        XCTAssertNotNil(parse(shiftedRows).validationWarning, "Fixture must reproduce the mismatch for the repair tests to mean anything.")
    }

    func testBalancingMovesFixShiftedReceipt() throws {
        let result = try XCTUnwrap(RowRepair.reparse(rows: shiftedRows, applying: shiftFix, expectedSubtotal: 9.00))

        XCTAssertNil(result.parsed.validationWarning)
        XCTAssertTrue(result.parsed.wasAIRepaired)
        XCTAssertEqual(price(of: "APPLES", in: result.parsed), 2.00)
        XCTAssertEqual(price(of: "BREAD", in: result.parsed), 3.00)
        XCTAssertEqual(price(of: "MILK", in: result.parsed), 4.00)
    }

    func testMoveNamingAPriceNotOnThatLineIsRejected() {
        let invented = [PriceMove(fromLine: 3, toLine: 2, price: "7.77")]
        XCTAssertNil(RowRepair.apply(invented, to: shiftedRows))
    }

    func testOutOfRangeLineIsRejected() {
        let bad = [PriceMove(fromLine: 3, toLine: 99, price: "2.00")]
        XCTAssertNil(RowRepair.apply(bad, to: shiftedRows))
    }

    func testMovesThatDoNotBalanceAreRejected() {
        let partial = [PriceMove(fromLine: 5, toLine: 4, price: "4.00")]
        XCTAssertNil(RowRepair.reparse(rows: shiftedRows, applying: partial, expectedSubtotal: 9.00))
    }

    func testMovesNeverAddOrChangeNumbers() throws {
        let edited = try XCTUnwrap(RowRepair.apply(shiftFix, to: shiftedRows))
        let before = shiftedRows.flatMap(\.fragments).map(\.text).sorted()
        let after = edited.flatMap(\.fragments).map(\.text).sorted()
        XCTAssertEqual(before, after)
    }

    /// A fabricated OCR failure shaped so the parser fixes it *without* the
    /// model: the skipped MEMBER line sits immediately before MILK's
    /// price-less line, so the parser's own adjacent-row cascade
    /// (`mergeSplitNamePriceRows`, maxGap = 1) bridges them on its own — the
    /// mismatch never has a chance to surface. The item still comes back
    /// flagged low-confidence, since it was reconstructed by a heuristic
    /// rather than read cleanly off its own line.
    func testAdjacentMisplacedPriceIsFixedByParserAlone() {
        let rows = [
            row("GREENGROCER"),
            row("MEMBER", "#4821", "4.29"), // MILK's price, on the wrong line
            row("111", "MILK 2L"),          // price missing — right next to MEMBER
            row("222", "BREAD WHEAT", "3.49"),
            row("333", "EGGS DOZEN", "5.99"),
            row("SUBTOTAL", "13.77"),
        ]

        let parsed = parse(rows)

        XCTAssertNil(parsed.validationWarning, "Adjacent placeholders should self-repair without the model ever being asked.")
        XCTAssertEqual(price(of: "MILK", in: parsed), 4.29)
        XCTAssertEqual(price(of: "BREAD", in: parsed), 3.49)
        XCTAssertEqual(price(of: "EGGS", in: parsed), 5.99)
    }

    /// The YU CHOY case on real OCR output: IMG_8410 parses correctly today,
    /// so break it by moving YU CHOY's price (which OCR puts on the Member line)
    /// onto the BLUEBERRIES line instead, then check one move repairs it.
    func testRepairFixesBrokenIMG8410() async throws {
        let broken = try await brokenIMG8410()
        let original = parse(broken.rows)
        XCTAssertNotNil(original.validationWarning, "Breaking the fixture should produce a mismatch.")
        let subtotal = try XCTUnwrap(original.subtotal)

        let fix = [PriceMove(fromLine: broken.blueberriesLine, toLine: broken.yuChoyLine, price: "5.49")]
        let result = try XCTUnwrap(RowRepair.reparse(rows: broken.rows, applying: fix, expectedSubtotal: subtotal))

        XCTAssertEqual(price(of: "YU CHOY", in: result.parsed), 5.49)
        XCTAssertEqual(price(of: "BLUEBERRIES", in: result.parsed), 6.99)
    }

    private func brokenIMG8410() async throws -> (rows: [TextRow], blueberriesLine: Int, yuChoyLine: Int) {
        guard let image = UIImage(named: "IMG_8410", in: Bundle(for: type(of: self)), with: nil) else {
            throw XCTSkip("'IMG_8410' isn't checked in (real receipt, kept local-only). See .gitignore.")
        }
        var rows = try await ReceiptScanner().scan(image: image).rows

        guard let memberLine = rows.firstIndex(where: { $0.text.uppercased().contains("MEMBER") }),
              let priceIndex = rows[memberLine].fragments.firstIndex(where: { $0.text.hasPrefix("5.49") }),
              let yuChoyLine = rows.firstIndex(where: { $0.text.contains("YU CHOY") }),
              let blueberriesLine = rows.firstIndex(where: { $0.text.contains("BLUEBERRIES") }) else {
            throw XCTSkip("IMG_8410's OCR layout differs from what this test expects.")
        }

        var memberFragments = rows[memberLine].fragments
        let yuChoyPrice = memberFragments.remove(at: priceIndex)
        rows[memberLine] = TextRow(fragments: memberFragments)
        rows[blueberriesLine] = TextRow(fragments: rows[blueberriesLine].fragments + [yuChoyPrice])
        return (rows, blueberriesLine, yuChoyLine)
    }

    // MARK: - Layer 2: view model flow (fake model)

    func testBalancingRepairIsAppliedAutomatically() async throws {
        let repairer = FakeReceiptRepairer(moves: shiftFix)
        let viewModel = makeViewModel(rows: shiftedRows, repairer: repairer)

        viewModel.processImage(makeImage())
        await viewModel.currentTask?.value
        await viewModel.repairTask?.value

        let parsed = try XCTUnwrap(viewModel.parsedReceipt)
        XCTAssertNil(parsed.validationWarning)
        XCTAssertTrue(parsed.wasAIRepaired)
        XCTAssertFalse(viewModel.mismatchUnresolved)
        let calls = await repairer.callCount
        XCTAssertEqual(calls, 1)
    }

    /// A readable, end-to-end walkthrough of the whole repair story with a
    /// fabricated (not real-photo) receipt, for demoing the feature: OCR
    /// grouped MILK's price onto the neighboring MEMBER line instead of its
    /// own — the exact failure mode the real IMG_8410 fixture hits — so the
    /// parser's own math fails first, then the model's proposed move fixes
    /// it, kept only because the result actually balances.
    func testParserFailsThenModelRepairsAMisplacedPrice() async throws {
        let rows = [
            row("GREENGROCER"),
            row("111", "MILK 2L"),               // price missing — OCR lost it
            row("222", "BREAD WHEAT", "3.49"),
            row("333", "EGGS DOZEN", "5.99"),
            row("MEMBER", "#4821", "4.29"),      // MILK's price, on the wrong line
            row("SUBTOTAL", "13.77"),
        ]

        // 1. The deterministic parser fails on its own. MEMBER sits three
        // rows from MILK, past the parser's own adjacent-row cascade
        // (maxGap = 1 — see testAdjacentMisplacedPriceIsFixedByParserAlone
        // for the case where it's close enough to self-repair), and the
        // parser already drops "MEMBER" lines as store/account info, so
        // that 4.29 isn't just misattributed — it's invisible to the item sum.
        let broken = parse(rows)
        XCTAssertNotNil(broken.validationWarning, "Item sum ($9.48: BREAD + EGGS, MILK missing) shouldn't match the printed subtotal ($13.77).")
        XCTAssertNil(price(of: "MILK", in: broken), "MILK should have no price — it was misread onto the MEMBER line.")

        // 2. The model engages: told the subtotal doesn't match, it reports
        // that the price on the MEMBER line belongs on MILK's line instead.
        let repairer = FakeReceiptRepairer(moves: [PriceMove(fromLine: 4, toLine: 1, price: "4.29")])
        let viewModel = makeViewModel(rows: rows, repairer: repairer)

        viewModel.processImage(makeImage())
        await viewModel.currentTask?.value
        await viewModel.repairTask?.value

        // 3. The move is applied to the original OCR fragments and
        // re-parsed from scratch; it's kept only because that result
        // actually balances against the printed subtotal.
        let fixed = try XCTUnwrap(viewModel.parsedReceipt)
        XCTAssertNil(fixed.validationWarning)
        XCTAssertTrue(fixed.wasAIRepaired)
        XCTAssertEqual(price(of: "MILK", in: fixed), 4.29)
        XCTAssertEqual(price(of: "BREAD", in: fixed), 3.49)
        XCTAssertEqual(price(of: "EGGS", in: fixed), 5.99)
        let calls = await repairer.callCount
        XCTAssertEqual(calls, 1, "The fix must actually come from the model being asked, not some other path.")
    }

    /// A harder variant of the same receipt: each item's line shows the next
    /// item's price, while EGGS is left empty — a three-hop chain, not a
    /// single swap. The model has to propose every move; a partial fix would
    /// not balance and must be rejected.
    func testNonAdjacentShiftDropsAnItemUntilModelProposesAChain() async throws {
        let rows = [
            row("GREENGROCER"),
            row("MEMBER", "#4821", "4.29"), // MILK's real price, stranded here
            row("111", "MILK 2L", "3.49"),  // showing BREAD's price instead
            row("222", "BREAD WHEAT", "5.99"), // showing EGGS' price instead
            row("333", "EGGS DOZEN"),           // price missing entirely
            row("SUBTOTAL", "13.77"),
        ]

        // 1. MILK and BREAD survive with shifted prices, while the empty EGGS
        // row is dropped. Their $9.48 sum does not match the $13.77 subtotal.
        let broken = parse(rows)
        XCTAssertNotNil(broken.validationWarning)
        XCTAssertEqual(price(of: "MILK", in: broken), 3.49)
        XCTAssertEqual(price(of: "BREAD", in: broken), 5.99)
        XCTAssertNil(price(of: "EGGS", in: broken), "EGGS should be absent because its row has no price.")
        XCTAssertEqual(broken.items.count, 2, "Only MILK and BREAD survive the parser's own pass.")

        // 2. The model has to report the whole three-hop chain for the repair
        // to balance.
        let repairer = FakeReceiptRepairer(moves: [
            PriceMove(fromLine: 3, toLine: 4, price: "5.99"), // BREAD's line -> EGGS' line
            PriceMove(fromLine: 2, toLine: 3, price: "3.49"), // MILK's line -> BREAD's line
            PriceMove(fromLine: 1, toLine: 2, price: "4.29"), // MEMBER's line -> MILK's line
        ])
        let viewModel = makeViewModel(rows: rows, repairer: repairer)

        viewModel.processImage(makeImage())
        await viewModel.currentTask?.value
        await viewModel.repairTask?.value

        let fixed = try XCTUnwrap(viewModel.parsedReceipt)
        XCTAssertNil(fixed.validationWarning)
        XCTAssertTrue(fixed.wasAIRepaired)
        XCTAssertEqual(price(of: "MILK", in: fixed), 4.29)
        XCTAssertEqual(price(of: "BREAD", in: fixed), 3.49)
        XCTAssertEqual(price(of: "EGGS", in: fixed), 5.99)
        let calls = await repairer.callCount
        XCTAssertEqual(calls, 1, "The fix must actually come from the model being asked, not some other path.")
    }

    /// The OCR shift continues through the summary rows. The model proposes
    /// one atomic chain, and deterministic item/subtotal/tax/total arithmetic
    /// decides whether the corrected alignment is safe to accept.
    func testShiftedSummaryBlockIsRepairedWhenAllArithmeticBalances() async throws {
        let rows = [
            row("GREENGROCER"),
            row("MEMBER", "#4821", "4.29"),
            row("111", "MILK 2L", "3.49"),
            row("222", "BREAD WHEAT", "5.99"),
            row("333", "EGGS DOZEN", "13.77"),
            row("SUBTOTAL", "0.00"),
            row("TAX", "13.77"),
            row("TOTAL"),
        ]
        let repairer = FakeReceiptRepairer(moves: [
            PriceMove(fromLine: 6, toLine: 7, price: "13.77"),
            PriceMove(fromLine: 5, toLine: 6, price: "0.00"),
            PriceMove(fromLine: 4, toLine: 5, price: "13.77"),
            PriceMove(fromLine: 3, toLine: 4, price: "5.99"),
            PriceMove(fromLine: 2, toLine: 3, price: "3.49"),
            PriceMove(fromLine: 1, toLine: 2, price: "4.29"),
        ])
        let viewModel = makeViewModel(rows: rows, repairer: repairer)

        viewModel.processImage(makeImage())
        await viewModel.currentTask?.value
        await viewModel.repairTask?.value

        let parsed = try XCTUnwrap(viewModel.parsedReceipt)
        XCTAssertFalse(viewModel.mismatchUnresolved)
        XCTAssertNil(parsed.validationWarning)
        XCTAssertTrue(parsed.wasAIRepaired)
        XCTAssertEqual(price(of: "MILK", in: parsed), 4.29)
        XCTAssertEqual(price(of: "BREAD", in: parsed), 3.49)
        XCTAssertEqual(price(of: "EGGS", in: parsed), 5.99)
        XCTAssertEqual(parsed.subtotal, 13.77)
        XCTAssertEqual(parsed.tax, 0.00)
        XCTAssertEqual(parsed.total, 13.77)
        let calls = await repairer.callCount
        XCTAssertEqual(calls, 1)
    }

    func testShiftedSummaryRepairRejectsNoncontiguousMoves() {
        let rows = shiftedSummaryRows()
        let moves = [
            PriceMove(fromLine: 6, toLine: 7, price: "13.77"),
            PriceMove(fromLine: 5, toLine: 6, price: "0.00"),
            PriceMove(fromLine: 4, toLine: 5, price: "13.77"),
            PriceMove(fromLine: 2, toLine: 3, price: "3.49"),
            PriceMove(fromLine: 1, toLine: 2, price: "4.29"),
        ]

        XCTAssertNil(RowRepair.reparse(rows: rows, applying: moves, expectedSubtotal: 0))
    }

    func testShiftedSummaryRepairRejectsIncompleteSummaryChain() {
        let rows = shiftedSummaryRows()
        let moves = [
            PriceMove(fromLine: 5, toLine: 6, price: "0.00"),
            PriceMove(fromLine: 4, toLine: 5, price: "13.77"),
            PriceMove(fromLine: 3, toLine: 4, price: "5.99"),
            PriceMove(fromLine: 2, toLine: 3, price: "3.49"),
            PriceMove(fromLine: 1, toLine: 2, price: "4.29"),
        ]

        XCTAssertNil(RowRepair.reparse(rows: rows, applying: moves, expectedSubtotal: 0))
    }

    private func shiftedSummaryRows() -> [TextRow] {
        [
            row("GREENGROCER"),
            row("MEMBER", "#4821", "4.29"),
            row("111", "MILK 2L", "3.49"),
            row("222", "BREAD WHEAT", "5.99"),
            row("333", "EGGS DOZEN", "13.77"),
            row("SUBTOTAL", "0.00"),
            row("TAX", "13.77"),
            row("TOTAL"),
        ]
    }

    func testRepairThatDoesNotBalanceAsksUser() async throws {
        let repairer = FakeReceiptRepairer(moves: [PriceMove(fromLine: 5, toLine: 4, price: "4.00")])
        let viewModel = makeViewModel(rows: shiftedRows, repairer: repairer)

        viewModel.processImage(makeImage())
        await viewModel.currentTask?.value
        await viewModel.repairTask?.value

        XCTAssertTrue(viewModel.mismatchUnresolved)
        let parsed = try XCTUnwrap(viewModel.parsedReceipt)
        XCTAssertNotNil(parsed.validationWarning, "The original parse should be kept, warning and all.")
        XCTAssertFalse(parsed.wasAIRepaired)
    }

    func testUnavailableModelAsksUser() async {
        let viewModel = makeViewModel(rows: shiftedRows, repairer: FakeReceiptRepairer(error: ModelUnavailableError()))

        viewModel.processImage(makeImage())
        await viewModel.currentTask?.value
        await viewModel.repairTask?.value

        XCTAssertTrue(viewModel.mismatchUnresolved)
    }

    func testRepairIsAttemptedOnlyOncePerScan() async {
        let repairer = FakeReceiptRepairer(moves: [])
        let viewModel = makeViewModel(rows: shiftedRows, repairer: repairer)

        viewModel.processImage(makeImage())
        await viewModel.currentTask?.value
        await viewModel.repairTask?.value
        await viewModel.attemptAIRepair()

        let calls = await repairer.callCount
        XCTAssertEqual(calls, 1)
    }

    func testBalancedReceiptNeverCallsModel() async {
        let repairer = FakeReceiptRepairer(moves: [])
        let viewModel = makeViewModel(rows: [row("111", "APPLES", "2.00"), row("SUBTOTAL", "2.00")], repairer: repairer)

        viewModel.processImage(makeImage())
        await viewModel.currentTask?.value

        XCTAssertNil(viewModel.repairTask)
        let calls = await repairer.callCount
        XCTAssertEqual(calls, 0)
    }

    func testCancelDuringRepairStopsItAndDropsTheResult() async throws {
        let repairer = FakeReceiptRepairer(moves: shiftFix, gated: true)
        let viewModel = makeViewModel(rows: shiftedRows, repairer: repairer)

        viewModel.processImage(makeImage())
        await viewModel.currentTask?.value
        XCTAssertTrue(viewModel.isRepairing, "Repair should be in flight once the scan finishes with a mismatch.")

        viewModel.cancelScan()
        XCTAssertFalse(viewModel.isRepairing, "Cancel should clear isRepairing immediately, not wait for the model call to return.")

        await repairer.release()
        await viewModel.repairTask?.value

        XCTAssertFalse(viewModel.isRepairing)
        XCTAssertFalse(viewModel.mismatchUnresolved, "A cancelled repair isn't the same as the model failing to find a fix.")
        let parsed = try XCTUnwrap(viewModel.parsedReceipt)
        XCTAssertFalse(parsed.wasAIRepaired, "The late-arriving repair must not apply after cancellation.")
    }

    // MARK: - Layer 3: real on-device model (opt-in quality check)

    /// Skipped where Apple Intelligence isn't available. Model output varies
    /// between runs, so a miss is recorded as an expected failure rather than
    /// failing the suite — check the printed moves to judge prompt quality.
    func testRealModelRepairsBrokenIMG8410() async throws {
        guard #available(iOS 26.0, *), SystemLanguageModel.default.isAvailable else {
            throw XCTSkip("Apple Intelligence model not available on this device.")
        }
        let broken = try await brokenIMG8410()
        let original = parse(broken.rows)
        let subtotal = try XCTUnwrap(original.subtotal)

        XCTExpectFailure("On-device model output varies; this is a quality check, not a gate.", strict: false)
        do {
            let moves = try await AppleIntelligenceRepairer().proposeMoves(lines: broken.rows.map(\.text), subtotal: subtotal)
            print("Model proposed moves: \(moves)")
            let result = RowRepair.reparse(rows: broken.rows, applying: moves, expectedSubtotal: subtotal)
            XCTAssertNotNil(result, "Model's moves did not balance the receipt.")
            if let result {
                XCTAssertEqual(price(of: "YU CHOY", in: result.parsed), 5.49)
            }
        } catch {
            XCTFail("Model call failed: \(error)")
        }
    }
}
