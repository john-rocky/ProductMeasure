//
//  ShippingBoxSelector.swift
//  SnapMeasure
//

import Foundation

// MARK: - Shipping Box Recommendation

struct ShippingBoxRecommendation {
    let shippingBox: ShippingBox
    let fillingRate: Float

    var fillingRatePercent: Int {
        Int((fillingRate * 100).rounded())
    }

    var displayText: String {
        "\(shippingBox.displayName) (\(fillingRatePercent)%)"
    }
}

// MARK: - Shipping Box Selector

enum ShippingBoxSelector {
    /// Find the smallest shipping box that fits the measured object.
    /// All dimensions are in meters.
    static func selectBestFit(
        objectLength: Float,
        objectWidth: Float,
        objectHeight: Float,
        objectVolume: Float
    ) -> ShippingBoxRecommendation? {
        let objDims = [objectLength, objectWidth, objectHeight].sorted()

        let fittingBoxes = ShippingBoxRepository.allBoxes.filter { box in
            let boxDims = box.sortedDimensionsMeters
            return objDims[0] <= boxDims.small
                && objDims[1] <= boxDims.mid
                && objDims[2] <= boxDims.large
        }

        guard let bestBox = fittingBoxes.min(by: { $0.volumeCubicMeters < $1.volumeCubicMeters }) else {
            return nil
        }

        let fillingRate = bestBox.volumeCubicMeters > 0
            ? objectVolume / bestBox.volumeCubicMeters
            : 0

        return ShippingBoxRecommendation(
            shippingBox: bestBox,
            fillingRate: fillingRate
        )
    }
}
