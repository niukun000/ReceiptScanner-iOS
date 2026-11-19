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
        .toolbar {
            NavigationLink(destination: SpendingSummaryView()) {
                Label("Spending", systemImage: "chart.bar")
            }
        }
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
                if let receiptDate = receipt.receiptDate {
                    LabeledContent("Receipt Date", value: receiptDate.formatted(date: .long, time: .omitted))
                }
                LabeledContent("Scan Date", value: receipt.scanDate.formatted(date: .long, time: .shortened))
            }
            Section("Items") {
                // Relationship arrays come back in arbitrary order — sort by
                // the recorded receipt line order.
                ForEach(receipt.items.sorted { $0.sortOrder < $1.sortOrder }) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(item.name).font(.headline)
                                if let num = item.itemNumber { Text(num).font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer(); Text(String(format: "$%.2f", item.price))
                        }
                        if let disc = item.discount {
                            HStack {
                                Text("  └ Discount").font(.caption).italic().foregroundStyle(.secondary)
                                Spacer()
                                Text(String(format: "-$%.2f", abs(disc))).font(.caption).italic().foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            Section("Totals") {
                if let subtotal = receipt.subtotal { LabeledContent("Subtotal", value: String(format: "$%.2f", subtotal)) }
                if let tax = receipt.tax { LabeledContent("Tax", value: String(format: "$%.2f", tax)) }
                if let total = receipt.total { LabeledContent("Total", value: String(format: "$%.2f", total)).font(.headline) }
            }
        }.navigationTitle(receipt.storeName ?? "Receipt")
    }
}
