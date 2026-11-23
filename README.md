# Receipt Scanner

An iOS app that scans paper and PDF receipts with on-device OCR, parses them into structured line items, and tracks spending over time — built with SwiftUI, SwiftData, and Vision.

## What it does

- **Scan or import** a receipt from the camera or as a PDF (including multi-page PDFs).
- **OCR + parse** the text into a store name, date, line items, discounts, tax, and totals — without sending anything to a server.
- **Catch its own mistakes**: the parser cross-checks the sum of items against the receipt's printed subtotal, and flags a mismatch instead of silently saving a wrong total.
- **Self-repair OCR misreads** on-device: when the parser's math doesn't add up, an on-device Apple Intelligence model proposes which existing values landed on the wrong line (a common OCR failure mode on skewed photos). It never invents, edits, duplicates, or recalculates a number. Ordinary item-price repairs are re-verified against the unchanged printed subtotal. The model may also propose a shift that continues through `SUBTOTAL`, `TAX`, and `TOTAL`, but that broader repair is accepted only for one complete, contiguous one-row-down chain where every corrected row has exactly one value, the items sum to the corrected subtotal, and subtotal plus tax equals total. Incomplete, noncontiguous, or mathematically inconsistent proposals are rejected and the user is asked to save as-is or retake the photo.
- **Track spending** across saved receipts: a monthly bar chart and a per-store breakdown via Swift Charts.
- **Correct OCR by hand**: drag a misplaced price up or down onto the item it actually belongs to.
- **Cancel a scan or an AI repair in progress**: a Cancel button stops an in-flight scan, a multi-page PDF import, or the on-device repair call (the slowest step, where cancelling matters most) — cancellation propagates through Swift Concurrency all the way into the underlying Vision request, not just the surrounding task.

## Architecture

- **SwiftUI** throughout, **SwiftData** for persistence (`Receipt` / `ScannedItem`).
- OCR runs on an `actor` (`ReceiptScanner`) using Vision's `VNRecognizeTextRequest`, with recognized text fragments grouped into rows by geometry (`TextGeometry`) rather than relying on Vision's own line segmentation — this is what lets the parser handle skewed/rotated photos and multi-column layouts.
- `ReceiptParser` is pure, `nonisolated` parsing logic decoupled from both the scanner and the UI, which is what makes it independently unit-testable against canned OCR output.
- The AI-repair path (`ReceiptRepairer` / `RowRepair`) is built behind a protocol (`ReceiptRepairing`) so the on-device model can be swapped for a fake in tests. The model only proposes moves; deterministic code applies them atomically and decides whether they are safe. A changed subtotal is accepted only when `SUBTOTAL`, `TAX`, and `TOTAL` are consecutive, the proposal forms a gapless one-row-down chain ending at `TOTAL`, each corrected destination has exactly one price-like value, and both item and summary arithmetic balance.
- Swift Concurrency (`async`/`await`, actors, `Task.detached`) for scanning and repair; `ScannerViewModel` tracks a generation counter so a stale scan result can never resurrect UI state after the user resets or starts a new scan.

## Requirements

- iOS 17+ (core scanning and parsing).
- iOS 26+ on a device that supports Apple Intelligence for the AI-repair feature — on older OS versions or unsupported devices, the app falls back to asking the user to save-as-is or retake the photo.
- Xcode 16+.

## Testing

- Unit tests validate parsing against several real-world receipt formats (photos and multi-page PDFs from different stores), checking store identification, item/price/discount extraction, and subtotal/total math.
- The AI-repair logic has layered tests: pure row-editing logic (no model involved), the view-model flow against a fake model, rejection tests for incomplete and noncontiguous summary shifts, a full item → subtotal → tax → total cascade, and an opt-in quality check against the real on-device model (skipped where Apple Intelligence isn't available, recorded as an expected failure rather than a hard gate since model output varies between runs).
- Cancellation is tested against a gated fake scanner: cancelling flips scanning state off immediately, a result that arrives after cancellation is dropped rather than resurrecting state, and a new scan can start cleanly right after.
- A scoped XCUITest accessibility audit (`performAccessibilityAudit(for: .contrast)`) covers the Scan screen's Dark Mode contrast.
- XCUITests cover History (empty state, newest-first ordering, swipe-to-delete), receipt detail (items in receipt order), and the Spending summary (per-store totals), running against an in-memory SwiftData store seeded with synthetic data (`-ui-testing` / `-ui-testing-seeded` launch arguments) — never the user's real saved receipts.
- Code coverage is enabled in the test plan; current measured coverage is **61.90%** of the app target.
- Real receipt photos/PDFs used for some of the parsing tests are personal data and are gitignored rather than committed — those specific tests skip gracefully (`XCTSkip`) if the files aren't present locally, so a fresh clone's test run doesn't show spurious failures.

## Building and running

1. Open `ReceiptScanner/ReceiptScanner.xcodeproj` in Xcode.
2. Pick a simulator, or your own device:
   - **Simulator**: select one from the scheme's run-destination menu and press **Run** (⌘R).
   - **Physical device**: connect it, set your team under the target's **Signing & Capabilities** tab, select your device as the run destination, and press **Run**. The first launch will likely need you to trust the developer certificate on-device: **Settings → General → VPN & Device Management → [your certificate] → Trust**.
3. To run the test suite: **Product → Test** (⌘U).

## Currently in progress

- Full accessibility pass (VoiceOver labels/actions, Dynamic Type layout, Reduce Motion) — a Dark Mode contrast fix is in, the rest is not yet.
