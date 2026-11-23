import Foundation
import FoundationModels

/// One instruction to move a price that OCR placed on the wrong line onto the
/// line of the item it belongs to. Line numbers index `TextRow`s, which are
/// exactly the lines of the raw OCR text.
nonisolated struct PriceMove: Equatable, Sendable {
    let fromLine: Int
    let toLine: Int
    let price: String
}

/// Proposes price moves for a receipt whose items don't add up to its printed
/// subtotal. Abstracted so tests can substitute canned moves for the model.
nonisolated protocol ReceiptRepairing: Sendable {
    func proposeMoves(lines: [String], subtotal: Double) async throws -> [PriceMove]
}

nonisolated struct ModelUnavailableError: Error {}

nonisolated struct AppleIntelligenceRepairer: ReceiptRepairing {
    func proposeMoves(lines: [String], subtotal: Double) async throws -> [PriceMove] {
        guard #available(iOS 26.0, *) else { throw ModelUnavailableError() }
        return try await ReceiptRepairer.proposeMoves(lines: lines, subtotal: subtotal)
    }
}

@available(iOS 26.0, *)
@Generable
struct GeneratedPriceMove {
    @Guide(description: "Line number the price is currently printed on")
    var fromLine: Int

    @Guide(description: "Line number of the item this price actually belongs to")
    var toLine: Int

    @Guide(description: "The price exactly as written on fromLine, e.g. 5.49 or 2.00-")
    var price: String
}

@available(iOS 26.0, *)
@Generable
struct GeneratedRepairPlan {
    @Guide(description: "Every price that must move to a different line. Empty if no move would fix the receipt.")
    var moves: [GeneratedPriceMove]
}

/// The model only ever points at prices that already exist in the OCR text
/// and says which line they belong on — it never writes a number of its own.
/// `RowRepair` applies the moves to the original OCR fragments and re-runs the
/// normal parser, so the parser stays the only thing that pairs names with
/// prices, and the result is accepted only if it balances.
@available(iOS 26.0, *)
enum ReceiptRepairer {
    static func proposeMoves(lines: [String], subtotal: Double) async throws -> [PriceMove] {
        guard SystemLanguageModel.default.isAvailable else { throw ModelUnavailableError() }

        let session = LanguageModelSession(instructions: """
            You fix OCR line-alignment mistakes on store receipts. OCR sometimes puts an \
            item's price on a neighboring line: onto a header line such as the member \
            number, onto the next item's line, or onto a line of its own. When that \
            happens, every later item can end up one line off. The shift can continue \
            through the SUBTOTAL, TAX, and TOTAL rows, so a value currently beside one \
            of those labels may actually belong to the next summary row. Each item and \
            summary line should end with its own value. Report every move needed to align \
            the whole block. Only move values that already appear in the text; never \
            invent, change, or recalculate a number.
            """)

        let numbered = lines.enumerated().map { "\($0.offset): \($0.element)" }.joined(separator: "\n")
        let prompt = """
            Receipt lines (line number: text):
            \(numbered)

            The value currently parsed as subtotal is \(String(format: "%.2f", subtotal)), \
            but the receipt does not balance and that value may itself be shifted from a \
            neighboring TAX row. Which values are on the wrong line, and which line does \
            each belong on?
            """

        let response = try await session.respond(to: prompt, generating: GeneratedRepairPlan.self)
        return response.content.moves.map { PriceMove(fromLine: $0.fromLine, toLine: $0.toLine, price: $0.price) }
    }
}

enum RowRepair {
    /// Applies `moves` to the OCR rows and re-parses. Returns nil unless the
    /// result balances against the same printed subtotal. Moves relocate
    /// existing fragments only, so no number can be added or altered.
    static func reparse(rows: [TextRow], applying moves: [PriceMove], expectedSubtotal: Double) -> (parsed: ParsedReceipt, rows: [TextRow])? {
        guard let edited = apply(moves, to: rows) else { return nil }
        let rawText = edited.map(\.text).joined(separator: "\n")
        var parsed = ReceiptParser.parse(rawText: rawText, rows: edited)
        guard parsed.validationWarning == nil, !parsed.subtotalIsSynthesized,
              let subtotal = parsed.subtotal else { return nil }

        let subtotalIsUnchanged = abs(subtotal - expectedSubtotal) < 0.005
        let correctedSummaryBalances: Bool
        if !parsed.totalIsSynthesized, let tax = parsed.tax, let total = parsed.total {
            correctedSummaryBalances = subtotal > 0 && tax >= 0 &&
                abs(subtotal + tax - total) < 0.005 &&
                isContiguousSummaryShift(moves: moves, originalRows: rows, editedRows: edited)
        } else {
            correctedSummaryBalances = false
        }
        // A changed subtotal is accepted only for the narrow OCR failure where
        // one contiguous block shifted down by exactly one row through
        // SUBTOTAL, TAX, and TOTAL, and the corrected arithmetic balances.
        guard subtotalIsUnchanged || correctedSummaryBalances else { return nil }
        parsed.wasAIRepaired = true
        return (parsed, edited)
    }

    private static func isContiguousSummaryShift(
        moves: [PriceMove],
        originalRows: [TextRow],
        editedRows: [TextRow]
    ) -> Bool {
        func rowIndex(containing keyword: String, excluding excluded: String? = nil) -> Int? {
            originalRows.indices.first { index in
                let text = originalRows[index].text.uppercased()
                return text.contains(keyword) && excluded.map { !text.contains($0) } != false
            }
        }

        guard let subtotalIndex = rowIndex(containing: "SUBTOTAL"),
              let taxIndex = rowIndex(containing: "TAX"),
              let totalIndex = rowIndex(containing: "TOTAL", excluding: "SUBTOTAL"),
              taxIndex == subtotalIndex + 1,
              totalIndex == taxIndex + 1,
              let firstSource = moves.map(\.fromLine).min(),
              firstSource < subtotalIndex else { return false }

        // The only accepted shape is one move per edge in a gapless chain:
        // start -> start+1 -> ... -> SUBTOTAL -> TAX -> TOTAL.
        guard moves.count == totalIndex - firstSource else { return false }
        let edges = Set(moves.map { "\($0.fromLine):\($0.toLine)" })
        for source in firstSource..<totalIndex {
            guard edges.contains("\(source):\(source + 1)") else { return false }
        }

        // After the atomic shift, every destination in the repaired block must
        // contain exactly one price-like fragment. This rejects duplicate or
        // partial placements even when the final arithmetic happens to match.
        for index in (firstSource + 1)...totalIndex {
            let priceCount = editedRows[index].fragments.count { priceValue($0.text) != nil }
            guard priceCount == 1 else { return false }
        }
        return true
    }

    static func apply(_ moves: [PriceMove], to rows: [TextRow]) -> [TextRow]? {
        guard !moves.isEmpty else { return nil }
        var removals: [Int: Set<Int>] = [:]
        var additions: [Int: [TextFragment]] = [:]

        for move in moves {
            guard rows.indices.contains(move.fromLine), rows.indices.contains(move.toLine),
                  move.fromLine != move.toLine,
                  let movedValue = priceValue(move.price) else { return nil }
            let source = rows[move.fromLine].fragments
            let alreadyMoved = removals[move.fromLine, default: []]
            // The model must name a price that is really on that line.
            guard let fragmentIndex = source.indices.first(where: {
                !alreadyMoved.contains($0) && priceValue(source[$0].text).map { abs($0 - movedValue) < 0.005 } == true
            }) else { return nil }
            removals[move.fromLine, default: []].insert(fragmentIndex)
            additions[move.toLine, default: []].append(source[fragmentIndex])
        }

        // All removals happen before any additions, so a chain of moves (a
        // whole block shifted by one line) doesn't depend on move order.
        return rows.indices.map { index in
            let kept = rows[index].fragments.enumerated()
                .filter { !(removals[index]?.contains($0.offset) ?? false) }
                .map(\.element)
            // Appended last because the parser reads a row's rightmost price.
            return TextRow(fragments: kept + (additions[index] ?? []))
        }
    }

    /// Value of a fragment that starts with a price ("5.49", "2.00-", "22.99 GP").
    private static func priceValue(_ text: String) -> Double? {
        guard let range = text.range(of: #"^\s*-?\d{1,4}[.,]\d{2}-?"#, options: .regularExpression) else { return nil }
        return TextGeometry.parsePriceToken(String(text[range]))
    }
}
