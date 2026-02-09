//
//  LabelData.swift
//  ProductMeasure
//

import Foundation

struct LabelData: Codable {
    var cartonId: String?
    var barcodes: [BarcodeItem]?
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

    struct BarcodeItem: Codable {
        var value: String
        var symbology: String?
    }

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

    // Backward-compatible decoding: migrates old barcodeValue/barcodeSymbology
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cartonId = try container.decodeIfPresent(String.self, forKey: .cartonId)
        barcodes = try container.decodeIfPresent([BarcodeItem].self, forKey: .barcodes)
        destination = try container.decodeIfPresent(String.self, forKey: .destination)
        poNumber = try container.decodeIfPresent(String.self, forKey: .poNumber)
        asnNumber = try container.decodeIfPresent(String.self, forKey: .asnNumber)
        soNumber = try container.decodeIfPresent(String.self, forKey: .soNumber)
        skuList = try container.decodeIfPresent([SKUItem].self, forKey: .skuList)
        lotNumber = try container.decodeIfPresent(String.self, forKey: .lotNumber)
        packDate = try container.decodeIfPresent(String.self, forKey: .packDate)
        grossWeight = try container.decodeIfPresent(String.self, forKey: .grossWeight)
        netWeight = try container.decodeIfPresent(String.self, forKey: .netWeight)
        carrier = try container.decodeIfPresent(String.self, forKey: .carrier)
        trackingNumber = try container.decodeIfPresent(String.self, forKey: .trackingNumber)
        handlingIcons = try container.decodeIfPresent([HandlingIcon].self, forKey: .handlingIcons)
        expiryDate = try container.decodeIfPresent(String.self, forKey: .expiryDate)
        rawText = try container.decode(String.self, forKey: .rawText)

        // Migrate legacy single-barcode fields
        if barcodes == nil,
           let oldValue = try container.decodeIfPresent(String.self, forKey: .barcodeValue) {
            let oldSym = try container.decodeIfPresent(String.self, forKey: .barcodeSymbology)
            barcodes = [BarcodeItem(value: oldValue, symbology: oldSym)]
        }
    }

    private enum CodingKeys: String, CodingKey {
        case cartonId, barcodes, destination, poNumber, asnNumber, soNumber
        case skuList, lotNumber, packDate, grossWeight, netWeight
        case carrier, trackingNumber, handlingIcons, expiryDate, rawText
        case barcodeValue, barcodeSymbology  // legacy keys for decoding only
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(cartonId, forKey: .cartonId)
        try container.encodeIfPresent(barcodes, forKey: .barcodes)
        try container.encodeIfPresent(destination, forKey: .destination)
        try container.encodeIfPresent(poNumber, forKey: .poNumber)
        try container.encodeIfPresent(asnNumber, forKey: .asnNumber)
        try container.encodeIfPresent(soNumber, forKey: .soNumber)
        try container.encodeIfPresent(skuList, forKey: .skuList)
        try container.encodeIfPresent(lotNumber, forKey: .lotNumber)
        try container.encodeIfPresent(packDate, forKey: .packDate)
        try container.encodeIfPresent(grossWeight, forKey: .grossWeight)
        try container.encodeIfPresent(netWeight, forKey: .netWeight)
        try container.encodeIfPresent(carrier, forKey: .carrier)
        try container.encodeIfPresent(trackingNumber, forKey: .trackingNumber)
        try container.encodeIfPresent(handlingIcons, forKey: .handlingIcons)
        try container.encodeIfPresent(expiryDate, forKey: .expiryDate)
        try container.encode(rawText, forKey: .rawText)
    }

    init(
        cartonId: String? = nil, barcodes: [BarcodeItem]? = nil,
        destination: String? = nil, poNumber: String? = nil,
        asnNumber: String? = nil, soNumber: String? = nil,
        skuList: [SKUItem]? = nil, lotNumber: String? = nil,
        packDate: String? = nil, grossWeight: String? = nil,
        netWeight: String? = nil, carrier: String? = nil,
        trackingNumber: String? = nil, handlingIcons: [HandlingIcon]? = nil,
        expiryDate: String? = nil, rawText: String
    ) {
        self.cartonId = cartonId
        self.barcodes = barcodes
        self.destination = destination
        self.poNumber = poNumber
        self.asnNumber = asnNumber
        self.soNumber = soNumber
        self.skuList = skuList
        self.lotNumber = lotNumber
        self.packDate = packDate
        self.grossWeight = grossWeight
        self.netWeight = netWeight
        self.carrier = carrier
        self.trackingNumber = trackingNumber
        self.handlingIcons = handlingIcons
        self.expiryDate = expiryDate
        self.rawText = rawText
    }

    /// Returns non-nil fields as display pairs (label, value)
    var displayFields: [(icon: String, label: String, value: String)] {
        var fields: [(String, String, String)] = []

        if let v = cartonId { fields.append(("shippingbox.fill", "CTN ID", v)) }
        if let codes = barcodes {
            for (i, item) in codes.enumerated() {
                let sym = item.symbology.map { " (\($0))" } ?? ""
                let label = codes.count == 1 ? "BARCODE" : "BARCODE \(i + 1)"
                fields.append(("barcode", label, item.value + sym))
            }
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
