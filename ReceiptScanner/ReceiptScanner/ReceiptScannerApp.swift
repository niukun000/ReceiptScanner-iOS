import SwiftUI
import SwiftData

@main
struct ReceiptScannerApp: App {
    private let container = AppModelContainer.make()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(container)
    }
}

/// Builds the SwiftData container the app runs against. UI tests pass
/// `-ui-testing` to get an in-memory store instead of the real on-disk one —
/// so tests never touch (or depend on) the user's real saved receipts — and
/// `-ui-testing-seeded` to additionally pre-populate it with sample data for
/// tests that need existing receipts (history, detail, spending summary).
enum AppModelContainer {
    static func make() -> ModelContainer {
        let schema = Schema([Receipt.self, ScannedItem.self])
        let arguments = ProcessInfo.processInfo.arguments

        guard arguments.contains("-ui-testing") else {
            let configuration = ModelConfiguration(schema: schema)
            return (try? ModelContainer(for: schema, configurations: [configuration]))
                ?? fatalErrorContainer(schema: schema)
        }

        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = (try? ModelContainer(for: schema, configurations: [configuration]))
            ?? fatalErrorContainer(schema: schema, inMemory: true)

        if arguments.contains("-ui-testing-seeded") {
            seedSampleData(into: container)
        }
        return container
    }

    private static func fatalErrorContainer(schema: Schema, inMemory: Bool = false) -> ModelContainer {
        fatalError("Could not create \(inMemory ? "in-memory" : "persistent") ModelContainer for schema \(schema)")
    }

    private static func seedSampleData(into container: ModelContainer) {
        let context = container.mainContext

        let grocer = Receipt(
            storeName: "Sample Grocer",
            scanDate: Calendar.current.date(byAdding: .day, value: -3, to: .now) ?? .now,
            subtotal: 5.48,
            total: 5.48
        )
        context.insert(grocer)
        grocer.items.append(ScannedItem(name: "Bananas", price: 1.99, sortOrder: 0, receipt: grocer))
        grocer.items.append(ScannedItem(name: "Milk", price: 3.49, sortOrder: 1, receipt: grocer))

        let hardware = Receipt(
            storeName: "Sample Hardware",
            scanDate: .now,
            subtotal: 14.68,
            total: 14.68
        )
        context.insert(hardware)
        hardware.items.append(ScannedItem(name: "Hammer", price: 12.99, sortOrder: 0, receipt: hardware))
        hardware.items.append(ScannedItem(name: "Nails", price: 1.69, sortOrder: 1, receipt: hardware))

        try? context.save()
    }
}
