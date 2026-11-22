import UIKit
@preconcurrency import Vision

enum ScannerError: Error {
    case recognitionFailed
    case invalidImage
}

/// Result of a single-image scan: the flattened text (for display and for
/// header/keyword extraction), the geometry-grouped rows (for item parsing
/// when no structured table was available), and, on iOS 26+, items already
/// extracted from a detected table when one was found and passed sanity checks.
struct ReceiptScanResult: Sendable {
    let rawText: String
    let rows: [TextRow]
    let tableItems: [ReceiptItemData]?
}

/// Abstracts OCR so `ScannerViewModel` can be unit-tested against a fake
/// scanner instead of running real Vision requests on every test.
/// `nonisolated` so conforming types can run `scan` on their own actor
/// instead of inheriting this module's default MainActor isolation.
nonisolated protocol ReceiptScanning: Sendable {
    func scan(image: UIImage) async throws -> ReceiptScanResult
}

/// Lets a task's cancellation handler stop a Vision request that may still be
/// running on a background queue. `cancel()` can arrive before the request
/// exists (the task was already cancelled) or while Vision is mid-recognition,
/// so both orders are handled under a lock.
nonisolated final class VisionRequestCanceller: @unchecked Sendable {
    private let lock = NSLock()
    private var request: VNRequest?
    private var isCancelled = false

    func attach(_ request: VNRequest) {
        lock.lock()
        defer { lock.unlock() }
        if isCancelled {
            request.cancel()
        } else {
            self.request = request
        }
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        isCancelled = true
        request?.cancel()
    }
}

actor ReceiptScanner: ReceiptScanning {

    func scan(image: UIImage) async throws -> ReceiptScanResult {
        // Don't start OCR for a scan the user already cancelled.
        try Task.checkCancellation()

        let cgOrientation = await MainActor.run {
            CGImagePropertyOrientation(image.imageOrientation)
        }

        guard let cgImage = image.cgImage else {
            throw ScannerError.invalidImage
        }

#if EXPERIMENTAL_VISION_TABLES
        if #available(iOS 26.0, *) {
            return try await scanWithDocumentRequest(cgImage: cgImage, orientation: cgOrientation)
        }
#endif
        // The document request is only worth its second OCR pass when table
        // extraction is enabled. Its transcript also segments lines its own way,
        // which breaks the keyword extractors' assumption that a label and its
        // value share a line — so outside the experimental path, row-derived
        // text is the single source of truth on every OS version.
        let (rawText, rows) = try await scanWithLegacyRequest(cgImage: cgImage, orientation: cgOrientation)
        return ReceiptScanResult(rawText: rawText, rows: rows, tableItems: nil)
    }

    // MARK: - iOS 26+: Vision document/table recognition

    @available(iOS 26.0, *)
    private func scanWithDocumentRequest(cgImage: CGImage, orientation: CGImagePropertyOrientation) async throws -> ReceiptScanResult {
        var request = RecognizeDocumentsRequest()
        request.textRecognitionOptions.useLanguageCorrection = true

        let observations = try await request.perform(on: cgImage, orientation: orientation)
        guard let document = observations.first?.document else {
            return ReceiptScanResult(rawText: "", rows: [], tableItems: nil)
        }

        // Experimental table extraction (requires matching iOS 26 Vision SDK).
        // Enable by defining EXPERIMENTAL_VISION_TABLES when the API surface matches.
#if EXPERIMENTAL_VISION_TABLES
        let rawText = document.text.transcript
        let priceRegex = #"^\d{1,4}[.,]\d{2}-?$"#
        let skuRegex = #"^\d{3,8}$"#

        for table in document.tables {
            // NOTE: Update these property names to match the real SDK before enabling.
            let rowCount = table.rowCount
            let columnCount = table.columnCount
            guard rowCount >= 3, rowCount <= 200, (2...6).contains(columnCount) else { continue }

            var cellsByRow: [Int: [(columnStart: Int, text: String)]] = [:]
            for cell in table.cells {
                let text = cell.content.text.transcript.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                cellsByRow[cell.rowIndex.lowerBound, default: []].append((cell.columnIndex.lowerBound, text))
            }

            var priceRowMatches = 0
            var items: [ReceiptItemData] = []

            for rowIndex in cellsByRow.keys.sorted() {
                guard let rowCells = cellsByRow[rowIndex] else { continue }
                let cellTexts = rowCells.sorted { $0.columnStart < $1.columnStart }.map(\.text)
                guard !cellTexts.isEmpty else { continue }

                let upperRowText = cellTexts.joined().uppercased().replacingOccurrences(of: " ", with: "")

                if !items.isEmpty {
                    if ["SUBTOTAL", "TOTAL", "AMOUNT", "TAX", "SHOPCARD"].contains(where: { upperRowText.contains($0) }) {
                        break
                    }
                }
                if upperRowText.contains("MEMBER") { continue }

                guard let lastCellText = cellTexts.last,
                      lastCellText.range(of: priceRegex, options: .regularExpression) != nil,
                      let price = TextGeometry.parsePriceToken(lastCellText) else {
                    continue
                }
                priceRowMatches += 1

                var sku: String? = nil
                var nameParts = Array(cellTexts.dropLast())
                if let first = nameParts.first, first.range(of: skuRegex, options: .regularExpression) != nil {
                    sku = first
                    nameParts.removeFirst()
                }
                let name = nameParts.joined(separator: " ").trimmingCharacters(in: CharacterSet.whitespaces)
                guard !name.isEmpty else { continue }

                items.append(ReceiptItemData(itemNumber: sku, name: name, price: price))
            }

            guard !items.isEmpty, priceRowMatches * 2 >= rowCount else { continue }
            return ReceiptScanResult(rawText: rawText, rows: [], tableItems: items)
        }
#else
        // Table parsing disabled for current SDK; fall back to legacy geometry grouping.
#endif

        // No usable table — fall back to the proven fragment/row-grouping path
        // rather than trusting document.text.lines' internal segmentation,
        // which hasn't been field-tested for column interleaving on receipts.
        let (legacyRawText, rows) = try await scanWithLegacyRequest(cgImage: cgImage, orientation: orientation)
        return ReceiptScanResult(rawText: legacyRawText, rows: rows, tableItems: nil)
    }

    // MARK: - iOS 17+: legacy Vision text recognition + geometric row grouping

    private func scanWithLegacyRequest(cgImage: CGImage, orientation cgOrientation: CGImagePropertyOrientation) async throws -> (rawText: String, rows: [TextRow]) {
        // Vision can invoke the request's completion handler with an error AND
        // make handler.perform throw for the same failure; resuming a checked
        // continuation twice is a fatal error, so every resume goes through
        // this claim-once gate.
        final class ResumeOnce: @unchecked Sendable {
            private let lock = NSLock()
            private var resumed = false
            func claim() -> Bool {
                lock.lock()
                defer { lock.unlock() }
                if resumed { return false }
                resumed = true
                return true
            }
        }
        let once = ResumeOnce()
        let canceller = VisionRequestCanceller()

        // If the scan's task is cancelled, cancel the Vision request too.
        // Vision then finishes the request with a cancellation error, which
        // goes through the same claim-once gate as any other result.
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let request = VNRecognizeTextRequest { request, error in
                    guard once.claim() else { return }
                    if let error = error {
                        continuation.resume(throwing: error)
                        return
                    }

                    guard let observations = request.results as? [VNRecognizedTextObservation] else {
                        continuation.resume(returning: ("", []))
                        return
                    }

                    let fragments = observations.map { TextFragment(obs: $0) }
                    let rows = TextGeometry.groupIntoRows(fragments)
                    let rawText = rows.map(\.text).joined(separator: "\n")
                    continuation.resume(returning: (rawText, rows))
                }

                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                canceller.attach(request)

                let handler = VNImageRequestHandler(cgImage: cgImage, orientation: cgOrientation, options: [:])

                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try handler.perform([request])
                    } catch {
                        guard once.claim() else { return }
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            canceller.cancel()
        }
    }
}

extension CGImagePropertyOrientation {
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        case .upMirrored: self = .upMirrored
        case .downMirrored: self = .downMirrored
        case .leftMirrored: self = .leftMirrored
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}

