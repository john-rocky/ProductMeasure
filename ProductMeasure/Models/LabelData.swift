//
//  LabelData.swift
//  ProductMeasure
//

import Foundation

struct LabelData: Codable {
    var cartonId: String?
    var barcodeValue: String?
    var barcodeSymbology: String?
    var destination: String?
    var poNumber: String?
    var asnNumber: String?
    var soNumber: String?
    var skuList: [SKUItem]?
    var lotNumber: String?
    var packDate: String?
    var grossWeight: String?
    var netWeight: String?
    var carrier: String?
    var trackingNumber: String?
    var handlingIcons: [HandlingIcon]?
    var expiryDate: String?
    var rawText: String

    struct SKUItem: Codable {
        var sku: String?
        var productName: String?
        var quantity: String?
    }

    enum HandlingIcon: String, Codable, CaseIterable {
        case fragile = "FRAGILE"
        case thisSideUp = "THIS SIDE UP"
        case keepDry = "KEEP DRY"
    }

    /// Returns non-nil fields as display pairs (label, value)
    var displayFields: [(icon: String, label: String, value: String)] {
        var fields: [(String, String, String)] = []

        if let v = cartonId { fields.append(("shippingbox.fill", "CTN ID", v)) }
        if let v = barcodeValue {
            let sym = barcodeSymbology.map { " (\($0))" } ?? ""
            fields.append(("barcode", "BARCODE", v + sym))
        }
        if let v = destination { fields.append(("mappin.and.ellipse", "DEST", v)) }
        if let v = poNumber { fields.append(("doc.text", "PO#", v)) }
        if let v = asnNumber { fields.append(("doc.plaintext", "ASN", v)) }
        if let v = lotNumber { fields.append(("number.circle", "LOT", v)) }
        if let v = packDate { fields.append(("calendar", "DATE", v)) }
        if let v = grossWeight { fields.append(("scalemass", "GW", v)) }
        if let v = netWeight { fields.append(("scalemass.fill", "NW", v)) }
        if let v = carrier { fields.append(("truck.box", "CARRIER", v)) }
        if let v = trackingNumber { fields.append(("number", "TRACK#", v)) }
        if let v = expiryDate { fields.append(("clock.badge.exclamationmark", "EXPIRY", v)) }

        if let icons = handlingIcons, !icons.isEmpty {
            fields.append(("exclamationmark.triangle", "HANDLING", icons.map(\.rawValue).joined(separator: ", ")))
        }

        if let skus = skuList, !skus.isEmpty {
            for (i, item) in skus.enumerated() {
                let parts = [item.sku, item.productName, item.quantity].compactMap { $0 }
                fields.append(("cube.box", "SKU \(i + 1)", parts.joined(separator: " / ")))
            }
        }

        return fields
    }

    /// Whether any OCR-parsed structured fields (excluding barcode) are present
    var hasOCRFields: Bool {
        cartonId != nil || destination != nil || poNumber != nil ||
        asnNumber != nil || soNumber != nil || lotNumber != nil ||
        packDate != nil || grossWeight != nil || netWeight != nil ||
        carrier != nil || trackingNumber != nil || expiryDate != nil ||
        handlingIcons != nil || skuList != nil
    }
}
