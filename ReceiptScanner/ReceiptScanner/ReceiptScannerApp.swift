import SwiftUI
import SwiftData

@main
struct ReceiptScannerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: [Receipt.self, ScannedItem.self])
    }
}
