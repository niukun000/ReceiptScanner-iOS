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
            happens, every later item can end up one line off. Each item line should end \
            with exactly one price. Report which prices must move to which line so every \
            item line gets its own price. Only move prices that already appear in the \
            text; never invent, change, or recalculate a number.
            """)

        let numbered = lines.enumerated().map { "\($0.offset): \($0.element)" }.joined(separator: "\n")
        let prompt = """
            Receipt lines (line number: text):
            \(numbered)

            The items should add up to the printed subtotal of \(String(format: "%.2f", subtotal)), \
            but they don't. Which prices are on the wrong line, and which line does each belong on?
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
        // A move onto the SUBTOTAL line would change the number we validate
        // against, so the printed subtotal must come through untouched.
        guard parsed.validationWarning == nil, !parsed.subtotalIsSynthesized,
              let subtotal = parsed.subtotal, abs(subtotal - expectedSubtotal) < 0.005 else { return nil }
        parsed.wasAIRepaired = true
        return (parsed, edited)
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
