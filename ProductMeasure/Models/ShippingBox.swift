//
//  ShippingBox.swift
//  SnapMeasure
//

import Foundation

// MARK: - Shipping Carrier

enum ShippingCarrier: String, CaseIterable {
    case yamato
    case japanPost
    case fedex
    case dhl

    var displayName: String {
        switch self {
        case .yamato: return "Yamato"
        case .japanPost: return "Japan Post"
        case .fedex: return "FedEx"
        case .dhl: return "DHL"
        }
    }
}

// MARK: - Shipping Box

struct ShippingBox {
    let carrier: ShippingCarrier
    let name: String
    let lengthCm: Float
    let widthCm: Float
    let heightCm: Float

    /// Dimensions sorted ascending (small, mid, large) in meters
    var sortedDimensionsMeters: (small: Float, mid: Float, large: Float) {
        let dims = [lengthCm, widthCm, heightCm].sorted()
        return (dims[0] / 100.0, dims[1] / 100.0, dims[2] / 100.0)
    }

    /// Volume in cubic meters
    var volumeCubicMeters: Float {
        (lengthCm / 100.0) * (widthCm / 100.0) * (heightCm / 100.0)
    }

    /// Display name combining carrier and box name
    var displayName: String {
        "\(carrier.displayName) \(name)"
    }
}

// MARK: - Shipping Box Repository

enum ShippingBoxRepository {
    static let allBoxes: [ShippingBox] = [
        // Yamato (Ta-Q-Bin) boxes
        ShippingBox(carrier: .yamato, name: "Size 60",  lengthCm: 32, widthCm: 23, heightCm: 15),
        ShippingBox(carrier: .yamato, name: "Size 80",  lengthCm: 40, widthCm: 30, heightCm: 20),
        ShippingBox(carrier: .yamato, name: "Size 100", lengthCm: 48, widthCm: 38, heightCm: 29),
        ShippingBox(carrier: .yamato, name: "Size 120", lengthCm: 54, widthCm: 45, heightCm: 34),
        ShippingBox(carrier: .yamato, name: "Size 140", lengthCm: 64, widthCm: 52, heightCm: 40),
        ShippingBox(carrier: .yamato, name: "Size 160", lengthCm: 70, widthCm: 58, heightCm: 46),
        ShippingBox(carrier: .yamato, name: "Size 200", lengthCm: 90, widthCm: 70, heightCm: 55),

        // Japan Post boxes
        ShippingBox(carrier: .japanPost, name: "Box T",    lengthCm: 32, widthCm: 22.5, heightCm: 14.5),
        ShippingBox(carrier: .japanPost, name: "Box 60",   lengthCm: 34, widthCm: 23.5, heightCm: 11.5),
        ShippingBox(carrier: .japanPost, name: "Box 80",   lengthCm: 39, widthCm: 29, heightCm: 15),
        ShippingBox(carrier: .japanPost, name: "Box 100",  lengthCm: 44, widthCm: 34, heightCm: 22),
        ShippingBox(carrier: .japanPost, name: "Box 120",  lengthCm: 51, widthCm: 36, heightCm: 33),

        // FedEx boxes
        ShippingBox(carrier: .fedex, name: "Small",        lengthCm: 31.4, widthCm: 23.5, heightCm: 6.4),
        ShippingBox(carrier: .fedex, name: "Medium",       lengthCm: 33.7, widthCm: 29.2, heightCm: 11.4),
        ShippingBox(carrier: .fedex, name: "Large",        lengthCm: 44.5, widthCm: 32.4, heightCm: 15.2),
        ShippingBox(carrier: .fedex, name: "Extra Large",  lengthCm: 53.3, widthCm: 38.1, heightCm: 24.1),

        // DHL boxes
        ShippingBox(carrier: .dhl, name: "Box 2",  lengthCm: 33.7, widthCm: 18.2, heightCm: 10),
        ShippingBox(carrier: .dhl, name: "Box 3",  lengthCm: 33.7, widthCm: 32.2, heightCm: 10),
        ShippingBox(carrier: .dhl, name: "Box 4",  lengthCm: 33.7, widthCm: 32.2, heightCm: 18),
        ShippingBox(carrier: .dhl, name: "Box 5",  lengthCm: 40.6, widthCm: 31.6, heightCm: 26.6),
        ShippingBox(carrier: .dhl, name: "Box 6",  lengthCm: 47.4, widthCm: 36.8, heightCm: 35.8),
        ShippingBox(carrier: .dhl, name: "Box 7",  lengthCm: 53.9, widthCm: 41.3, heightCm: 40.3),
    ]
}
