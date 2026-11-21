import SwiftUI
import PhotosUI
import PDFKit

@MainActor
@Observable
class ScannerViewModel {
    var selectedImage: UIImage?
    var recognizedText: String = ""
    var parsedReceipt: ParsedReceipt?
    var isScanning = false
    var isRepairing = false
    var errorMessage: String?
    // Set when the receipt still doesn't add up after the one AI repair
    // attempt (or the model is unavailable); the user decides whether to save
    // it anyway or retake the photo.
    var mismatchUnresolved = false

    // Bumped whenever a new scan starts or state is reset; in-flight detached
    // tasks compare their captured generation before publishing, so a stale
    // scan can never overwrite a newer result (or resurrect state after reset).
    private var scanGeneration = 0

    private let scanner: ReceiptScanning
    private let repairer: ReceiptRepairing
    private var scannedRows: [TextRow] = []
    private var hasAttemptedRepair = false

    // Handles to the most recently started scan and repair. Tests await these
    // instead of sleeping to know when work has finished publishing.
    private(set) var currentTask: Task<Void, Never>?
    private(set) var repairTask: Task<Void, Never>?

    init(scanner: ReceiptScanning = ReceiptScanner(), repairer: ReceiptRepairing = AppleIntelligenceRepairer()) {
        self.scanner = scanner
        self.repairer = repairer
    }

    func reset() {
        scanGeneration += 1
        selectedImage = nil
        recognizedText = ""
        parsedReceipt = nil
        isScanning = false
        errorMessage = nil
        mismatchUnresolved = false
        scannedRows = []
        hasAttemptedRepair = false
    }

    // Corrects OCR row misalignment: slides price/discount/confidence down or up
    // the item list starting at `index`, leaving names/SKUs in place, so a price
    // that landed on the wrong row can be walked onto the right one.
    func shiftPrice(at index: Int, down: Bool) {
        guard var parsed = parsedReceipt, parsed.items.indices.contains(index) else { return }
        parsed.items = Self.shiftedItems(parsed.items, at: index, down: down)
        recomputeValidation(&parsed)
        parsedReceipt = parsed
    }

    // Pure version of the same cascade, usable without mutating state — the
    // AI-shift repair tries this experimentally in both directions and only
    // keeps the result that resolves the subtotal, so it never has to
    // introduce a price the model typed itself.
    private static func shiftedItems(_ items: [ReceiptItemData], at index: Int, down: Bool) -> [ReceiptItemData] {
        guard items.indices.contains(index) else { return items }
        var items = items

        if down {
            var carry: (price: Double, discount: Double?, confidence: Float) = (0, nil, 0)
            for i in index..<items.count {
                let current = (price: items[i].price, discount: items[i].discount, confidence: items[i].confidence)
                items[i].price = carry.price
                items[i].discount = carry.discount
                items[i].confidence = carry.confidence
                carry = current
            }
        } else {
            for i in index..<(items.count - 1) {
                items[i].price = items[i + 1].price
                items[i].discount = items[i + 1].discount
                items[i].confidence = items[i + 1].confidence
            }
            items[items.count - 1] = ReceiptItemData(
                itemNumber: items[items.count - 1].itemNumber,
                name: items[items.count - 1].name,
                price: 0,
                discount: nil,
                confidence: 0
            )
        }

        return items
    }

    // Drops a row entirely — for leftover placeholder rows (e.g. "Unmatched Price")
    // once its value has been dragged onto the item it actually belongs to.
    func removeItem(id: UUID) {
        guard var parsed = parsedReceipt else { return }
        parsed.items.removeAll { $0.id == id }
        recomputeValidation(&parsed)
        parsedReceipt = parsed
    }

    private func recomputeValidation(_ parsed: inout ParsedReceipt) {
        let sum = parsed.items.reduce(0) { $0 + $1.price + ($1.discount ?? 0) }
        let roundedSum = round(sum * 100) / 100

        // Values the parser synthesized from the item sum (no printed
        // SUBTOTAL/TOTAL was found) must track item edits — validating against
        // the stale synthesized snapshot would warn about a number that was
        // never on the receipt.
        if parsed.subtotalIsSynthesized {
            parsed.subtotal = roundedSum
        }
        if parsed.totalIsSynthesized {
            parsed.total = round((roundedSum + (parsed.tax ?? 0)) * 100) / 100
        }

        guard let sub = parsed.subtotal, !parsed.subtotalIsSynthesized else {
            parsed.difference = nil
            parsed.validationWarning = nil
            return
        }
        if abs(roundedSum - sub) > 0.01 {
            parsed.difference = sub - roundedSum
            parsed.validationWarning = "Warning: Calculated subtotal ($\(String(format: "%.2f", roundedSum))) does not match receipt subtotal ($\(String(format: "%.2f", sub)))."
        } else {
            parsed.difference = nil
            parsed.validationWarning = nil
        }
    }

    // Runs at most once per scan, and only when the parser's own subtotal
    // check failed. The model proposes moving prices between OCR lines; the
    // moves are applied to the original fragments and the normal parser runs
    // again, so the result is kept only if it actually balances. Anything
    // else — no model, a bad plan, or a plan that doesn't balance — goes to
    // the user as save-or-retake.
    func attemptAIRepair() async {
        guard !hasAttemptedRepair, !isRepairing,
              let parsed = parsedReceipt, parsed.validationWarning != nil,
              !parsed.subtotalIsSynthesized, let subtotal = parsed.subtotal else { return }
        hasAttemptedRepair = true
        let generation = scanGeneration
        let rows = scannedRows
        isRepairing = true
        defer { isRepairing = false }

        var repaired: (parsed: ParsedReceipt, rows: [TextRow])?
        if !rows.isEmpty, let moves = try? await repairer.proposeMoves(lines: rows.map(\.text), subtotal: subtotal) {
            repaired = RowRepair.reparse(rows: rows, applying: moves, expectedSubtotal: subtotal)
        }
        guard generation == scanGeneration else { return }

        if let repaired {
            parsedReceipt = repaired.parsed
            scannedRows = repaired.rows
        } else {
            mismatchUnresolved = true
        }
    }

    func processPDF(data: Data) {
        guard !isScanning else { return }
        scanGeneration += 1
        let generation = scanGeneration
        self.isScanning = true
        self.errorMessage = nil
        self.mismatchUnresolved = false
        self.hasAttemptedRepair = false
        self.selectedImage = nil // Reset preview for PDF
        let scanner = self.scanner

        currentTask = Task.detached(priority: .userInitiated) {
            guard let pdfDocument = PDFDocument(data: data) else {
                await MainActor.run {
                    guard generation == self.scanGeneration else { return }
                    self.errorMessage = "Could not read PDF file."
                    self.isScanning = false
                }
                return
            }

            var combinedText = ""
            var combinedRows: [TextRow] = []
            var tableItemsPerPage: [[ReceiptItemData]] = []
            var firstPageImage: UIImage?

            for i in 0..<pdfDocument.pageCount {
                guard let page = pdfDocument.page(at: i) else { continue }
                // pageRef is Optional: pages without a backing CGPDFPage exist
                // (corrupt or non-CGPDF-backed pages) and must not crash the import.
                guard let pageRef = page.pageRef else { continue }

                // Render straight to the OCR pixel budget ImageUtils.resizeImage
                // enforces on the photo path (short side ≤1200px, long side
                // ≤4800px). The renderer's default format multiplies by the
                // device screen scale (2-3x), which tripled memory per page and
                // fed Vision 4-9x more pixels than needed.
                let pageRect = page.bounds(for: .mediaBox)
                let shortSide = min(pageRect.width, pageRect.height)
                let longSide = max(pageRect.width, pageRect.height)
                let renderScale = min(1200 / shortSide, 4800 / longSide, 2.0)
                let renderSize = CGSize(
                    width: (pageRect.width * renderScale).rounded(),
                    height: (pageRect.height * renderScale).rounded()
                )
                let format = UIGraphicsImageRendererFormat()
                format.scale = 1
                format.opaque = true
                let renderer = UIGraphicsImageRenderer(size: renderSize, format: format)
                let image = renderer.image { ctx in
                    UIColor.white.set()
                    ctx.fill(CGRect(origin: .zero, size: renderSize))
                    ctx.cgContext.translateBy(x: 0.0, y: renderSize.height)
                    ctx.cgContext.scaleBy(x: renderScale, y: -renderScale)
                    ctx.cgContext.drawPDFPage(pageRef)
                }

                if i == 0 { firstPageImage = image }

                do {
                    let pageResult = try await scanner.scan(image: image)
                    combinedText += pageResult.rawText + "\n"
                    // Append only — never re-sort across pages, since each
                    // page's rotation-corrected row Y is only comparable
                    // within that page.
                    combinedRows.append(contentsOf: pageResult.rows)
                    if let tableItems = pageResult.tableItems {
                        tableItemsPerPage.append(tableItems)
                    }
                } catch {
                    print("Error scanning page \(i): \(error)")
                }
            }

            // Only trust the table-sourced items if every page produced them;
            // otherwise fall back to the accumulated rows for the whole document.
            let combinedTableItems: [ReceiptItemData]? = tableItemsPerPage.count == pdfDocument.pageCount
                ? tableItemsPerPage.flatMap { $0 }
                : nil

            let parsed = ReceiptParser.parse(rawText: combinedText, rows: combinedRows, tableItems: combinedTableItems)
            let rows = combinedRows
            await MainActor.run {
                guard generation == self.scanGeneration else { return }
                self.selectedImage = firstPageImage // Use first page as preview
                self.recognizedText = combinedText
                self.scannedRows = rows
                self.parsedReceipt = parsed
                self.isScanning = false
                if parsed.validationWarning != nil { self.repairTask = Task { await self.attemptAIRepair() } }
            }
        }
    }

    func processImage(_ image: UIImage) {
        guard !isScanning else { return }
        scanGeneration += 1
        let generation = scanGeneration
        self.isScanning = true
        self.errorMessage = nil
        self.mismatchUnresolved = false
        self.hasAttemptedRepair = false
        let scanner = self.scanner

        currentTask = Task.detached(priority: .userInitiated) {
            let resized = ImageUtils.resizeImage(image)
            do {
                let result = try await scanner.scan(image: resized)
                let parsed = ReceiptParser.parse(rawText: result.rawText, rows: result.rows, tableItems: result.tableItems)
                await MainActor.run {
                    guard generation == self.scanGeneration else { return }
                    self.selectedImage = resized
                    self.recognizedText = result.rawText
                    self.scannedRows = result.rows
                    self.parsedReceipt = parsed
                    self.isScanning = false
                    if parsed.validationWarning != nil { self.repairTask = Task { await self.attemptAIRepair() } }
                }
            } catch {
                await MainActor.run {
                    guard generation == self.scanGeneration else { return }
                    self.errorMessage = error.localizedDescription
                    self.isScanning = false
                }
            }
        }
    }
}
