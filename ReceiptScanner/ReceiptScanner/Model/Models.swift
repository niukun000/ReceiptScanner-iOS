import Foundation
import SwiftData

@Model
final class Receipt {
    var id: UUID
    var storeName: String?
    var scanDate: Date
    var receiptDate: Date?
    var subtotal: Double?
    var total: Double?
    var tax: Double?
    var rawText: String
    
    @Relationship(deleteRule: .cascade, inverse: \ScannedItem.receipt)
    var items: [ScannedItem] = []
    
    init(id: UUID = UUID(), storeName: String? = nil, scanDate: Date = Date(), receiptDate: Date? = nil, subtotal: Double? = nil, total: Double? = nil, tax: Double? = nil, rawText: String = "") {
        self.id = id
        self.storeName = storeName
        self.scanDate = scanDate
        self.receiptDate = receiptDate
        self.subtotal = subtotal
        self.total = total
        self.tax = tax
        self.rawText = rawText
    }
}

@Model
final class ScannedItem {
    var id: UUID
    var name: String
    var itemNumber: String?
    var price: Double
    var discount: Double?
    // SwiftData to-many relationships don't persist array order; this records
    // the receipt line order so views can sort deterministically.
    var sortOrder: Int = 0
    var receipt: Receipt?

    init(id: UUID = UUID(), name: String, itemNumber: String? = nil, price: Double, discount: Double? = nil, sortOrder: Int = 0, receipt: Receipt? = nil) {
        self.id = id
        self.name = name
        self.itemNumber = itemNumber
        self.price = price
        self.discount = discount
        self.sortOrder = sortOrder
        self.receipt = receipt
    }
}
