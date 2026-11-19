import Foundation
import FoundationModels

@available(iOS 26.0, *)
@Generable
struct ItemCorrection {
    @Guide(description: "Exact name of the item being corrected, copied verbatim from the 'Parsed items' list in the prompt")
    var itemName: String

    @Guide(description: "The item's correct price as printed on the receipt, only if the parsed price was wrong. Omit if the price was already correct.")
    var correctedPrice: Double?

    @Guide(description: "The item's correct discount as printed on the receipt, as a negative number (e.g. -2.00), only if a discount was missing or wrong. Omit if there's no discount or it was already correct.")
    var correctedDiscount: Double?
}

@available(iOS 26.0, *)
@Generable
struct ReceiptCorrections {
    @Guide(description: "One entry per item that needs its price or discount corrected. Empty array if nothing needs correcting.")
    var corrections: [ItemCorrection]
}

/// Asks the on-device model to find which parsed item disagrees with the raw
/// OCR text. Only ever invoked after the deterministic parser's own
/// arithmetic check has already flagged a mismatch (`ParsedReceipt.validationWarning`)
/// — this never second-guesses a receipt the parser already trusts.
///
/// Apple's guidance is that the on-device model isn't reliable for
/// arithmetic, so its output is used only for *pattern matching* against the
/// raw text (spotting a misread or dropped line); the caller is responsible
/// for re-validating the proposed numbers against the receipt's own math
/// rather than trusting the model's judgment that a fix is correct.
@available(iOS 26.0, *)
enum ReceiptRepairer {
    struct ModelUnavailable: Error {}

    static func suggestCorrections(items: [ReceiptItemData], rawText: String, expectedSubtotal: Double) async throws -> [ItemCorrection] {
        guard SystemLanguageModel.default.isAvailable else { throw ModelUnavailable() }

        let session = LanguageModelSession(instructions: """
            You proofread a receipt-scanning app's parsed items against the raw OCR text \
            of the receipt. The parser's item list didn't add up to the receipt's printed \
            subtotal, which usually means one line's price was misread or a discount line \
            was missed entirely. Find the specific item(s) responsible by re-reading the \
            raw text, and report only the corrected price/discount for those items — leave \
            every other item out of your response.
            """)

        let itemsDescription = items.map { item in
            "- \(item.name) | price: \(item.price) | discount: \(item.discount.map { String($0) } ?? "none")"
        }.joined(separator: "\n")

        let prompt = """
            Raw OCR text from the receipt:
            \"\"\"
            \(rawText)
            \"\"\"

            Parsed items:
            \(itemsDescription)

            The receipt's printed subtotal is \(expectedSubtotal). Which item(s) above have a \
            price or discount that doesn't match what's actually printed in the raw text?
            """

        let response = try await session.respond(to: prompt, generating: ReceiptCorrections.self)
        return response.content.corrections
    }
}
