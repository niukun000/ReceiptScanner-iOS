import Foundation
import SwiftData

@Model
final class Receipt {
    var id: UUID
    var storeName: String?
    var scanDate: Date
    var receiptDate: Date?
    var total: Double?
    var tax: Double?
    var rawText: String
    
    @Relationship(deleteRule: .cascade, inverse: \ScannedItem.receipt)
    var items: [ScannedItem] = []
    
    init(id: UUID = UUID(), storeName: String? = nil, scanDate: Date = Date(), receiptDate: Date? = nil, total: Double? = nil, tax: Double? = nil, rawText: String = "") {
        self.id = id
        self.storeName = storeName
        self.scanDate = scanDate
        self.receiptDate = receiptDate
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
    var receipt: Receipt?
    
    init(id: UUID = UUID(), name: String, itemNumber: String? = nil, price: Double, receipt: Receipt? = nil) {
        self.id = id
        self.name = name
        self.itemNumber = itemNumber
        self.price = price
        self.receipt = receipt
    }
}
