//
//  DebugVisualization.swift
//  ProductMeasure
//

import UIKit
import ARKit
import RealityKit
import simd

/// Debug visualization utilities for troubleshooting measurement issues
class DebugVisualization {

    // MARK: - Mask Visualization

    /// Create a debug image showing the segmentation mask overlaid on the camera image
    /// Both camera image and mask are in landscape orientation (same coordinate system)
    /// We rotate to portrait for proper viewing on screen
    static func visualizeMask(
        mask: CVPixelBuffer,
        cameraImage: CVPixelBuffer,
        tapPoint: CGPoint? = nil
    ) -> UIImage? {
        let maskWidth = CVPixelBufferGetWidth(mask)
        let maskHeight = CVPixelBufferGetHeight(mask)
        let imageWidth = CVPixelBufferGetWidth(cameraImage)
        let imageHeight = CVPixelBufferGetHeight(cameraImage)

        print("[DebugViz] Mask size: \(maskWidth)x\(maskHeight)")
        print("[DebugViz] Camera image size: \(imageWidth)x\(imageHeight)")

        // Create UIImage from camera with proper orientation
        let ciImage = CIImage(cvPixelBuffer: cameraImage)
        let context = CIContext()

        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            return nil
        }

        // Create the image in landscape, then rotate for display
        // First, draw everything in landscape coordinates
        let landscapeSize = CGSize(width: imageWidth, height: imageHeight)
        UIGraphicsBeginImageContextWithOptions(landscapeSize, false, 1.0)
        guard let ctx = UIGraphicsGetCurrentContext() else { return nil }

        // Draw camera image - need to flip because CGContext has flipped Y
        ctx.saveGState()
        ctx.translateBy(x: 0, y: CGFloat(imageHeight))
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight))
        ctx.restoreGState()

        // Read and overlay mask (mask is in same landscape coordinates as camera)
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }

        guard let maskBase = CVPixelBufferGetBaseAddress(mask) else { return nil }
        let maskBytesPerRow = CVPixelBufferGetBytesPerRow(mask)
        let maskPtr = maskBase.assumingMemoryBound(to: UInt8.self)

        // Scale from mask to image coordinates
        let scaleX = CGFloat(imageWidth) / CGFloat(maskWidth)
        let scaleY = CGFloat(imageHeight) / CGFloat(maskHeight)

        // Draw mask overlay - sample every few pixels for performance
        ctx.setFillColor(UIColor.green.withAlphaComponent(0.4).cgColor)

        // Determine bytes per pixel based on format
        let maskPixelFormat = CVPixelBufferGetPixelFormatType(mask)
        let bytesPerPixel: Int
        if maskPixelFormat == kCVPixelFormatType_32BGRA || maskPixelFormat == kCVPixelFormatType_32ARGB {
            bytesPerPixel = 4
        } else {
            bytesPerPixel = 1
        }

        var maskedPixelCount = 0
        let sampleStep = max(1, min(maskWidth, maskHeight) / 200)  // Sample for performance
        for my in Swift.stride(from: 0, to: maskHeight, by: sampleStep) {
            for mx in Swift.stride(from: 0, to: maskWidth, by: sampleStep) {
                let pixelOffset = my * maskBytesPerRow + mx * bytesPerPixel
                // For BGRA, check alpha channel (offset +3)
                let value: UInt8
                if bytesPerPixel == 4 {
                    value = maskPtr[pixelOffset + 3]  // Alpha channel
                } else {
                    value = maskPtr[pixelOffset]
                }

                if value > 0 {
                    maskedPixelCount += 1
                    let rect = CGRect(
                        x: CGFloat(mx) * scaleX,
                        y: CGFloat(my) * scaleY,
                        width: scaleX * CGFloat(sampleStep),
                        height: scaleY * CGFloat(sampleStep)
                    )
                    ctx.fill(rect)
                }
            }
        }

        print("[DebugViz] Masked pixels in mask: \(maskedPixelCount)")

        // Draw tap point if provided (in landscape normalized coordinates)
        // The tap is drawn in landscape canvas, then rotated to portrait with the whole image
        if let tap = tapPoint {
            let tapX = tap.x * CGFloat(imageWidth)
            let tapY = tap.y * CGFloat(imageHeight)

            ctx.setFillColor(UIColor.red.cgColor)
            ctx.fillEllipse(in: CGRect(x: tapX - 20, y: tapY - 20, width: 40, height: 40))

            ctx.setStrokeColor(UIColor.white.cgColor)
            ctx.setLineWidth(3)
            ctx.strokeEllipse(in: CGRect(x: tapX - 20, y: tapY - 20, width: 40, height: 40))

            print("[DebugViz] Tap point in landscape canvas: (\(tapX), \(tapY))")
            print("[DebugViz] Tap point normalized: (\(tap.x), \(tap.y))")
        }

        guard let landscapeImage = UIGraphicsGetImageFromCurrentImageContext() else {
            UIGraphicsEndImageContext()
            return nil
        }
        UIGraphicsEndImageContext()

        // Rotate the landscape image to portrait for display
        // Rotate 90 degrees clockwise
        let portraitSize = CGSize(width: imageHeight, height: imageWidth)
        UIGraphicsBeginImageContextWithOptions(portraitSize, false, 1.0)
        guard let portraitCtx = UIGraphicsGetCurrentContext() else { return nil }

        portraitCtx.translateBy(x: portraitSize.width / 2, y: portraitSize.height / 2)
        portraitCtx.rotate(by: .pi / 2)
        portraitCtx.translateBy(x: -landscapeSize.width / 2, y: -landscapeSize.height / 2)

        landscapeImage.draw(in: CGRect(origin: .zero, size: landscapeSize))

        let result = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()

        return result
    }

    // MARK: - Point Cloud Visualization

    /// Create RealityKit entities for visualizing point cloud
    static func createPointCloudEntity(
        points: [SIMD3<Float>],
        color: UIColor = .cyan,
        pointSize: Float = 0.005
    ) -> Entity {
        let parentEntity = Entity()

        // Limit points for performance
        let maxPoints = min(points.count, 500)
        let stepSize = max(1, points.count / maxPoints)

        print("[DebugViz] Creating point cloud with \(maxPoints) points (step: \(stepSize))")

        var material = SimpleMaterial()
        material.color = .init(tint: color)

        let sphereMesh = MeshResource.generateSphere(radius: pointSize)

        for i in Swift.stride(from: 0, to: points.count, by: stepSize) {
            let point = points[i]
            let pointEntity = ModelEntity(mesh: sphereMesh, materials: [material])
            pointEntity.position = point
            parentEntity.addChild(pointEntity)
        }

        // Add centroid marker (larger, different color)
        if !points.isEmpty {
            let centroid = points.reduce(.zero, +) / Float(points.count)
            var centroidMaterial = SimpleMaterial()
            centroidMaterial.color = .init(tint: .red)
            let centroidEntity = ModelEntity(
                mesh: MeshResource.generateSphere(radius: pointSize * 3),
                materials: [centroidMaterial]
            )
            centroidEntity.position = centroid
            parentEntity.addChild(centroidEntity)

            print("[DebugViz] Point cloud centroid: \(centroid)")
        }

        return parentEntity
    }

    // MARK: - Depth Map Visualization

    /// Create a debug image showing depth values
    /// Depth map is in landscape, we rotate to portrait for display
    static func visualizeDepthMap(
        depthMap: CVPixelBuffer,
        maskedPixels: [(x: Int, y: Int)]? = nil,
        imageSize: CGSize
    ) -> UIImage? {
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)

        guard let baseAddress = CVPixelBufferGetBaseAddress(depthMap) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        let depthPtr = baseAddress.assumingMemoryBound(to: Float32.self)

        // Find min/max depth for normalization
        var minDepth: Float = .infinity
        var maxDepth: Float = 0

        for y in 0..<height {
            for x in 0..<width {
                let index = y * (bytesPerRow / MemoryLayout<Float32>.size) + x
                let depth = depthPtr[index]
                if depth.isFinite && depth > 0 {
                    minDepth = min(minDepth, depth)
                    maxDepth = max(maxDepth, depth)
                }
            }
        }

        print("[DebugViz] Depth map size: \(width)x\(height)")
        print("[DebugViz] Depth range: \(minDepth)m - \(maxDepth)m")

        // First create in landscape orientation
        let landscapeSize = CGSize(width: width, height: height)
        UIGraphicsBeginImageContextWithOptions(landscapeSize, false, 1.0)
        guard let ctx = UIGraphicsGetCurrentContext() else { return nil }

        // Draw depth as grayscale (closer = brighter)
        for y in 0..<height {
            for x in 0..<width {
                let index = y * (bytesPerRow / MemoryLayout<Float32>.size) + x
                let depth = depthPtr[index]

                var brightness: CGFloat = 0
                if depth.isFinite && depth > 0 && maxDepth > minDepth {
                    brightness = CGFloat(1.0 - (depth - minDepth) / (maxDepth - minDepth))
                }

                ctx.setFillColor(UIColor(white: brightness, alpha: 1.0).cgColor)
                ctx.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }

        // Overlay masked pixels if provided (in image coordinates, need to scale to depth coords)
        if let pixels = maskedPixels {
            let scaleX = CGFloat(width) / imageSize.width
            let scaleY = CGFloat(height) / imageSize.height

            ctx.setFillColor(UIColor.green.withAlphaComponent(0.6).cgColor)

            for pixel in pixels {
                let depthX = Int(CGFloat(pixel.x) * scaleX)
                let depthY = Int(CGFloat(pixel.y) * scaleY)
                ctx.fill(CGRect(x: depthX, y: depthY, width: 3, height: 3))
            }

            print("[DebugViz] Overlaid \(pixels.count) masked pixels on depth map")
        }

        guard let landscapeImage = UIGraphicsGetImageFromCurrentImageContext() else {
            UIGraphicsEndImageContext()
            return nil
        }
        UIGraphicsEndImageContext()

        // Rotate to portrait for display
        let portraitSize = CGSize(width: height, height: width)
        UIGraphicsBeginImageContextWithOptions(portraitSize, false, 1.0)
        guard let portraitCtx = UIGraphicsGetCurrentContext() else { return nil }

        portraitCtx.translateBy(x: portraitSize.width / 2, y: portraitSize.height / 2)
        portraitCtx.rotate(by: .pi / 2)
        portraitCtx.translateBy(x: -landscapeSize.width / 2, y: -landscapeSize.height / 2)

        landscapeImage.draw(in: CGRect(origin: .zero, size: landscapeSize))

        let result = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()

        return result
    }

    // MARK: - Coordinate System Visualization

    /// Create axes at the camera position
    static func createAxesEntity(at transform: simd_float4x4, length: Float = 0.1) -> Entity {
        let parentEntity = Entity()

        let position = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)

        // X axis - Red
        let xAxis = createLineEntity(
            from: position,
            to: position + SIMD3<Float>(length, 0, 0),
            color: .red
        )
        parentEntity.addChild(xAxis)

        // Y axis - Green
        let yAxis = createLineEntity(
            from: position,
            to: position + SIMD3<Float>(0, length, 0),
            color: .green
        )
        parentEntity.addChild(yAxis)

        // Z axis - Blue
        let zAxis = createLineEntity(
            from: position,
            to: position + SIMD3<Float>(0, 0, length),
            color: .blue
        )
        parentEntity.addChild(zAxis)

        print("[DebugViz] Created axes at position: \(position)")

        return parentEntity
    }

    private static func createLineEntity(from start: SIMD3<Float>, to end: SIMD3<Float>, color: UIColor) -> Entity {
        let direction = end - start
        let length = simd_length(direction)

        let mesh = MeshResource.generateBox(size: [0.003, 0.003, length])
        var material = SimpleMaterial()
        material.color = .init(tint: color)

        let entity = ModelEntity(mesh: mesh, materials: [material])
        entity.position = (start + end) / 2

        // Orient along the line
        let defaultDir = SIMD3<Float>(0, 0, 1)
        let normalizedDir = simd_normalize(direction)

        if simd_length(normalizedDir - defaultDir) > 0.001 && simd_length(normalizedDir + defaultDir) > 0.001 {
            let axis = simd_cross(defaultDir, normalizedDir)
            let axisLen = simd_length(axis)
            if axisLen > 0.001 {
                let angle = acos(simd_clamp(simd_dot(defaultDir, normalizedDir), -1, 1))
                entity.orientation = simd_quatf(angle: angle, axis: axis / axisLen)
            }
        }

        return entity
    }

    // MARK: - Tap Point 3D Visualization

    /// Create a marker at the raycast hit point
    static func createTapMarker(at position: SIMD3<Float>) -> Entity {
        var material = SimpleMaterial()
        material.color = .init(tint: .yellow)

        let entity = ModelEntity(
            mesh: MeshResource.generateSphere(radius: 0.02),
            materials: [material]
        )
        entity.position = position

        print("[DebugViz] Created tap marker at: \(position)")

        return entity
    }
}

// MARK: - Debug Image View

import SwiftUI

struct DebugImageView: View {
    let image: UIImage
    let title: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding()

                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .navigationTitle("Debug View")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
        }
    }
}
