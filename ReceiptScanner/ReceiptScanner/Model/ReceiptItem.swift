//
//  ReceiptItem.swift
//  ReceiptScanner
//
//  Created by Kun Niu on 2026-05-28.
//

import Foundation

struct ReceiptItem: Identifiable, Equatable, Sendable{
    let id = UUID()
    var itemNumber: String
    var name: String
    var price: Double
}
