#if DEBUG
import UIKit

/// Loads the checked-in Costco PDF fixture to drive the Scan screen's
/// review/save flow in UI tests without a camera or the system file picker.
/// `#if DEBUG` keeps the loading seam out of release builds entirely; the
/// `-ui-testing` launch-argument check at the call site is a second gate.
enum UITestFixtures {
    static func sampleReceiptPDFData() -> Data? {
        NSDataAsset(name: "CostcoReceipt")?.data
    }
}
#endif
