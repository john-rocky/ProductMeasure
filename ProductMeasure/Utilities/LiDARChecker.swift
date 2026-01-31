//
//  LiDARChecker.swift
//  ProductMeasure
//

import ARKit

enum LiDARChecker {
    /// Check if the device supports LiDAR depth sensing
    static var isLiDARAvailable: Bool {
        ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    }

    /// Check if the device supports smoothed scene depth
    static var isSmoothedDepthAvailable: Bool {
        ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth)
    }

    /// Check if ARKit is supported on this device
    static var isARKitSupported: Bool {
        ARWorldTrackingConfiguration.isSupported
    }

    /// Get a user-friendly message about device capabilities
    static var capabilityMessage: String? {
        if !isARKitSupported {
            return "This device does not support ARKit."
        }
        if !isLiDARAvailable {
            return "This device does not have a LiDAR sensor. For accurate 3D measurements, please use an iPhone Pro or iPad Pro with LiDAR."
        }
        return nil
    }
}
