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
struct ReceiptDiagnosis {
    @Guide(description: """
        True only if a single price that OCR missed entirely caused every item from one point \
        onward to display a price that actually belongs to the next item in the list — i.e. \
        prices are shifted by one row starting at some item. False if the mismatches instead \
        look like independent misreads of specific prices or discounts.
        """)
    var isPriceShift: Bool

    @Guide(description: "Only meaningful when isPriceShift is true: the exact name of the item, copied verbatim from the 'Parsed items' list, where the shift begins — the first item whose displayed price actually belongs to a different item.")
    var shiftStartItemName: String?

    @Guide(description: "One entry per item that needs its price or discount corrected to match the raw text. Leave this empty when isPriceShift is true, or when nothing needs correcting.")
    var corrections: [ItemCorrection]
}

/// Asks the on-device model to explain why the parsed items disagree with the
/// raw OCR text. Only ever invoked after the deterministic parser's own
/// arithmetic check has already flagged a mismatch (`ParsedReceipt.validationWarning`)
/// — this never second-guesses a receipt the parser already trusts.
///
/// Apple's guidance is that the on-device model isn't reliable for
/// arithmetic, so it is never asked to type out a corrected number for a
/// shifted price. For the shift case it only names *where* the shift starts —
/// pattern-matching against the raw text is what it's good at — and the
/// caller resolves the actual fix by moving prices the OCR already read
/// elsewhere on the receipt onto the right rows (see
/// `ScannerViewModel.offerShift`). Only for genuinely independent misreads
/// does it report a specific corrected value, and even then the caller
/// re-validates the proposed numbers against the receipt's own math rather
/// than trusting the model's judgment that a fix is correct.
@available(iOS 26.0, *)
enum ReceiptRepairer {
    struct ModelUnavailable: Error {}

    static func diagnose(items: [ReceiptItemData], rawText: String, expectedSubtotal: Double) async throws -> ReceiptDiagnosis {
        guard SystemLanguageModel.default.isAvailable else { throw ModelUnavailable() }

        let session = LanguageModelSession(instructions: """
            You proofread a receipt-scanning app's parsed items against the raw OCR text of \
            the receipt. The parser's item list didn't add up to the receipt's printed \
            subtotal. There are two common causes: (1) a single price was missed entirely by \
            OCR, which drags every later item's price up onto the previous item, shifting \
            everything by one row from that point on; or (2) one or a few independent \
            misreads, where a specific price or discount was read wrong. Decide which case \
            this is. If it's a shift, only name the item where the shift starts — do not type \
            out any corrected prices for it, the app will handle that part itself using prices \
            already present elsewhere on the receipt. If it's independent misreads, list only \
            the specific item corrections, copying prices verbatim from the raw text.
            """)

        let itemsDescription = items.map { item in
            "- \(item.name) | price: \(item.price) | discount: \(item.discount.map { String($0) } ?? "none")"
        }.joined(separator: "\n")

        let prompt = """
            Raw OCR text from the receipt:
            \"\"\"
            \(rawText)
            \"\"\"

            Parsed items, in receipt order:
            \(itemsDescription)

            The receipt's printed subtotal is \(expectedSubtotal). Is this a single shifted \
            price, or independent misreads? If shifted, which item does the shift start at? \
            If independent misreads, which item(s) have a price or discount that doesn't \
            match what's actually printed in the raw text?
            """

        let response = try await session.respond(to: prompt, generating: ReceiptDiagnosis.self)
        return response.content
    }
}
