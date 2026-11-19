import SwiftUI
import SwiftData
import Charts

struct SpendingSummaryView: View {
    @Query private var receipts: [Receipt]

    private struct MonthlySpend: Identifiable {
        var id: Date { month }
        let month: Date
        let total: Double
    }

    private struct StoreSpend: Identifiable {
        var id: String { store }
        let store: String
        let total: Double
        let count: Int
    }

    /// Prefer the parsed receipt total; fall back to summing items (net of discounts).
    private func amount(for receipt: Receipt) -> Double {
        receipt.total ?? receipt.items.reduce(0) { $0 + $1.price + ($1.discount ?? 0) }
    }

    /// Prefer the date printed on the receipt; fall back to the scan date.
    private func date(for receipt: Receipt) -> Date {
        receipt.receiptDate ?? receipt.scanDate
    }

    private var monthlySpend: [MonthlySpend] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: receipts) { receipt in
            calendar.date(from: calendar.dateComponents([.year, .month], from: date(for: receipt))) ?? date(for: receipt)
        }
        return grouped
            .map { month, receipts in
                MonthlySpend(month: month, total: receipts.reduce(0) { $0 + amount(for: $1) })
            }
            .sorted { $0.month < $1.month }
    }

    private var storeSpend: [StoreSpend] {
        let grouped = Dictionary(grouping: receipts) { $0.storeName ?? "Unknown" }
        return grouped
            .map { store, receipts in
                StoreSpend(store: store, total: receipts.reduce(0) { $0 + amount(for: $1) }, count: receipts.count)
            }
            .sorted { $0.total > $1.total }
    }

    var body: some View {
        Group {
            if receipts.isEmpty {
                ContentUnavailableView("No Data", systemImage: "chart.bar", description: Text("Save some receipts to see spending insights."))
            } else {
                List {
                    Section("Spending by Month") {
                        Chart(monthlySpend) { entry in
                            BarMark(
                                x: .value("Month", entry.month, unit: .month),
                                y: .value("Total", entry.total)
                            )
                            .foregroundStyle(.blue.gradient)
                        }
                        .chartXAxis {
                            AxisMarks(values: .stride(by: .month)) { _ in
                                AxisGridLine()
                                AxisValueLabel(format: .dateTime.month(.abbreviated))
                            }
                        }
                        .frame(height: 220)
                        .padding(.vertical, 8)
                    }

                    Section("Spending by Store") {
                        ForEach(storeSpend) { entry in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(entry.store).font(.headline)
                                    Text("^[\(entry.count) receipt](inflect: true)").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(String(format: "$%.2f", entry.total)).font(.headline)
                            }
                        }
                    }

                    Section("All Time") {
                        LabeledContent("Receipts", value: "\(receipts.count)")
                        LabeledContent("Total Spent", value: String(format: "$%.2f", receipts.reduce(0) { $0 + amount(for: $1) }))
                    }
                }
            }
        }
        .navigationTitle("Spending")
    }
}
