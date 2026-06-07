import SwiftUI
import SwiftData

struct HistoryView: View {
    @Query(sort: \Receipt.scanDate, order: .reverse) private var receipts: [Receipt]
    @Environment(\.modelContext) private var modelContext
    
    var body: some View {
        List {
            ForEach(receipts) { receipt in
                NavigationLink(destination: ReceiptDetailView(receipt: receipt)) {
                    VStack(alignment: .leading) {
                        Text(receipt.storeName ?? "Unknown Store").font(.headline)
                        HStack {
                            Text(receipt.scanDate, style: .date).font(.subheadline).foregroundStyle(.secondary)
                            Spacer()
                            if let total = receipt.total { Text(String(format: "$%.2f", total)).font(.headline).foregroundStyle(.blue) }
                        }
                    }
                }
            }.onDelete { offsets in
                for index in offsets { modelContext.delete(receipts[index]) }
            }
        }
        .navigationTitle("History")
        .overlay {
            if receipts.isEmpty {
                ContentUnavailableView("No History", systemImage: "clock.arrow.circlepath", description: Text("Scanned receipts will appear here."))
            }
        }
    }
}

struct ReceiptDetailView: View {
    let receipt: Receipt
    var body: some View {
        List {
            Section("Info") {
                LabeledContent("Store", value: receipt.storeName ?? "Unknown")
                LabeledContent("Scan Date", value: receipt.scanDate.formatted(date: .long, time: .shortened))
            }
            Section("Items") {
                ForEach(receipt.items) { item in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(item.name).font(.headline)
                            if let num = item.itemNumber { Text(num).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer(); Text(String(format: "$%.2f", item.price))
                    }
                }
            }
            Section("Totals") {
                if let total = receipt.total { LabeledContent("Total", value: String(format: "$%.2f", total)).font(.headline) }
            }
        }.navigationTitle(receipt.storeName ?? "Receipt")
    }
}
