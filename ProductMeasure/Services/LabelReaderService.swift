//
//  LabelReaderService.swift
//  ProductMeasure
//

import Foundation
import Vision
import ARKit
import CoreImage
import UIKit

/// Detects rectangular labels on box surfaces, performs perspective correction,
/// OCR + barcode detection, and returns parsed label data.
class LabelReaderService {

    /// Dedicated serial queues per Vision task type — enables true parallelism
    /// and isolates first-use ML model init latency per request type.
    private static let rectQueue = DispatchQueue(label: "com.productmeasure.vision.rect", qos: .userInitiated)
    private static let ocrQueue = DispatchQueue(label: "com.productmeasure.vision.ocr", qos: .userInitiated)
    private static let barcodeQueue = DispatchQueue(label: "com.productmeasure.vision.barcode", qos: .userInitiated)

    /// Shared CIContext — avoids recreating on every perspectiveCorrect() call.
    private static let ciContext = CIContext()

    /// Whether ML models have been pre-loaded via warmup().
    private static var isWarmedUp = false

    /// Pre-load Vision ML models on background queues so the first real scan is instant.
    /// Safe to call multiple times; only the first invocation performs work.
    static func warmup() {
        guard !isWarmedUp else { return }
        isWarmedUp = true

        // 256x256 dummy image with text-like content — large enough to trigger
        // full Vision pipeline (1x1 images cause Vision to skip model loading).
        let size = CGSize(width: 256, height: 256)
        let renderer = UIGraphicsImageRenderer(size: size)
        let uiImage = renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            UIColor.black.setFill()
            for y in stride(from: 30, to: 220, by: 18) {
                ctx.fill(CGRect(x: 20, y: y, width: 200, height: 3))
            }
        }
        guard let cgImage = uiImage.cgImage else {
            print("[LabelReader] Warmup: failed to create dummy image")
            return
        }

        let start = CFAbsoluteTimeGetCurrent()

        // Rectangle detection warmup
        rectQueue.async {
            let req = VNDetectRectanglesRequest()
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try? handler.perform([req])
            print("[LabelReader] Rectangle detection warmed up (\(String(format: "%.1f", CFAbsoluteTimeGetCurrent() - start))s)")
        }

        // OCR warmup (heaviest — accurate level loads ~100MB model)
        ocrQueue.async {
            let req = VNRecognizeTextRequest()
            req.recognitionLevel = .accurate
            req.recognitionLanguages = ["en-US"]
            req.usesLanguageCorrection = true
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try? handler.perform([req])
            print("[LabelReader] OCR warmed up (\(String(format: "%.1f", CFAbsoluteTimeGetCurrent() - start))s)")
        }

        // Barcode detection warmup
        barcodeQueue.async {
            let req = VNDetectBarcodesRequest()
            req.symbologies = [.qr, .ean13, .code128, .code39, .dataMatrix, .itf14]
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try? handler.perform([req])
            print("[LabelReader] Barcode detection warmed up (\(String(format: "%.1f", CFAbsoluteTimeGetCurrent() - start))s)")
        }

        // CIContext GPU warmup — first render initializes Metal pipeline
        DispatchQueue.global(qos: .utility).async {
            let ci = CIImage(cgImage: cgImage)
            _ = ciContext.createCGImage(ci, from: ci.extent)
            print("[LabelReader] CIContext warmed up (\(String(format: "%.1f", CFAbsoluteTimeGetCurrent() - start))s)")
        }
    }

    struct LabelDetectionResult {
        let quadrilateral: VNRectangleObservation
        let correctedImage: UIImage
        let labelData: LabelData
        let worldCorners: [SIMD3<Float>]?
        let surfaceNormal: SIMD3<Float>?
    }

    // MARK: - Main Entry Point

    func detectAndReadLabel(
        frame: ARFrame,
        tapPoint: CGPoint,
        viewSize: CGSize
    ) async throws -> LabelDetectionResult? {
        let pixelBuffer = frame.capturedImage

        // Step 1: Detect rectangles
        guard let rectangle = try await detectRectangle(
            pixelBuffer: pixelBuffer,
            tapPoint: tapPoint,
            viewSize: viewSize
        ) else {
            print("[LabelReader] No rectangle detected near tap point")
            return nil
        }

        // Step 2: Perspective-correct the label image
        guard let correctedImage = perspectiveCorrect(
            pixelBuffer: pixelBuffer,
            rectangle: rectangle
        ) else {
            print("[LabelReader] Perspective correction failed")
            return nil
        }

        // Step 3: Run OCR and barcode detection concurrently
        async let ocrResult = recognizeText(image: correctedImage)
        async let barcodeResult = detectBarcodes(image: correctedImage)

        let (textObservations, barcodeObservations) = try await (ocrResult, barcodeResult)

        // Step 4: Parse fields from OCR text and barcodes
        let rawText = textObservations
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")

        var labelData = parseLabelFields(rawText: rawText)

        // Capture text line bounding boxes for scan effect
        let lineBounds = textObservations.map { $0.boundingBox }
        if !lineBounds.isEmpty {
            labelData.textLineBounds = lineBounds
        }

        // Merge barcode data (all detected barcodes)
        if !barcodeObservations.isEmpty {
            labelData.barcodes = barcodeObservations.compactMap { obs in
                guard let value = obs.payloadStringValue else { return nil }
                let sym = obs.symbology.rawValue
                    .replacingOccurrences(of: "VNBarcodeSymbology", with: "")
                return LabelData.BarcodeItem(value: value, symbology: sym, boundingBox: obs.boundingBox)
            }
            if labelData.barcodes?.isEmpty == true { labelData.barcodes = nil }
        }

        // Step 5: Compute world corners from depth map
        let worldCorners = computeWorldCorners(
            rectangle: rectangle,
            frame: frame
        )

        // Step 6: Compute surface normal
        let surfaceNormal: SIMD3<Float>?
        if let corners = worldCorners, corners.count == 4 {
            surfaceNormal = computeSurfaceNormal(corners: corners)
        } else {
            surfaceNormal = nil
        }

        return LabelDetectionResult(
            quadrilateral: rectangle,
            correctedImage: correctedImage,
            labelData: labelData,
            worldCorners: worldCorners,
            surfaceNormal: surfaceNormal
        )
    }

    // MARK: - Rectangle Detection

    /// Compute area of a quadrilateral using the Shoelace formula.
    private func quadArea(corners: [CGPoint]) -> CGFloat {
        guard corners.count == 4 else { return 0 }
        // Shoelace formula for polygon area
        var area: CGFloat = 0
        for i in 0..<4 {
            let j = (i + 1) % 4
            area += corners[i].x * corners[j].y
            area -= corners[j].x * corners[i].y
        }
        return abs(area) / 2
    }

    private func detectRectangle(
        pixelBuffer: CVPixelBuffer,
        tapPoint: CGPoint,
        viewSize: CGSize
    ) async throws -> VNRectangleObservation? {
        let request = VNDetectRectanglesRequest()
        request.minimumConfidence = AppConstants.labelMinConfidence
        request.minimumSize = AppConstants.labelMinSize
        request.minimumAspectRatio = 0.3
        request.maximumObservations = 10

        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: .right,
            options: [:]
        )
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Self.rectQueue.async {
                do {
                    try handler.perform([request])
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }

        guard let results = request.results, !results.isEmpty else {
            return nil
        }

        // Convert tap point to Vision coordinates (bottom-left origin, 0-1)
        // Screen → Vision with .right orientation:
        // visionX = 1 - (screenY / height), visionY = screenX / width
        let visionTapX = 1.0 - (tapPoint.y / viewSize.height)
        let visionTapY = tapPoint.x / viewSize.width
        let visionTap = CGPoint(x: visionTapX, y: visionTapY)

        let maxArea = CGFloat(AppConstants.labelMaxArea)
        let areaWeight = CGFloat(AppConstants.labelAreaWeight)

        // Find best rectangle using area-weighted distance score.
        // score = distance - areaWeight * area
        // Larger rectangles get a lower score (preferred), preventing
        // inner section lines from being chosen over the full label.
        var bestRect: VNRectangleObservation?
        var bestScore: CGFloat = .greatestFiniteMagnitude

        for rect in results {
            let corners = [rect.topLeft, rect.topRight, rect.bottomRight, rect.bottomLeft]
            let area = quadArea(corners: corners)

            // Skip rectangles that are too large (e.g. cardboard top surface)
            guard area < maxArea else { continue }

            let center = CGPoint(
                x: (corners[0].x + corners[1].x + corners[2].x + corners[3].x) / 4,
                y: (corners[0].y + corners[1].y + corners[2].y + corners[3].y) / 4
            )
            let dx = center.x - visionTap.x
            let dy = center.y - visionTap.y
            let dist = sqrt(dx * dx + dy * dy)

            let score = dist - areaWeight * area

            if score < bestScore {
                bestScore = score
                bestRect = rect
            }
        }

        // Distance threshold check using raw distance (not weighted score)
        if let rect = bestRect {
            let corners = [rect.topLeft, rect.topRight, rect.bottomRight, rect.bottomLeft]
            let center = CGPoint(
                x: (corners[0].x + corners[1].x + corners[2].x + corners[3].x) / 4,
                y: (corners[0].y + corners[1].y + corners[2].y + corners[3].y) / 4
            )
            let dx = center.x - visionTap.x
            let dy = center.y - visionTap.y
            let rawDist = sqrt(dx * dx + dy * dy)
            if rawDist > 0.3 {
                print("[LabelReader] Best rectangle too far from tap: \(rawDist)")
                return nil
            }
        }

        return bestRect
    }

    // MARK: - Perspective Correction

    private func perspectiveCorrect(
        pixelBuffer: CVPixelBuffer,
        rectangle: VNRectangleObservation
    ) -> UIImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            .oriented(.right)

        let imageSize = ciImage.extent.size

        // Convert Vision normalized coords to pixel coords
        func toPixel(_ point: CGPoint) -> CIVector {
            CIVector(
                x: point.x * imageSize.width,
                y: point.y * imageSize.height
            )
        }

        guard let filter = CIFilter(name: "CIPerspectiveCorrection") else {
            return nil
        }

        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(toPixel(rectangle.topLeft), forKey: "inputTopLeft")
        filter.setValue(toPixel(rectangle.topRight), forKey: "inputTopRight")
        filter.setValue(toPixel(rectangle.bottomLeft), forKey: "inputBottomLeft")
        filter.setValue(toPixel(rectangle.bottomRight), forKey: "inputBottomRight")

        guard let outputImage = filter.outputImage else { return nil }

        guard let cgImage = Self.ciContext.createCGImage(outputImage, from: outputImage.extent) else {
            return nil
        }

        return UIImage(cgImage: cgImage)
    }

    // MARK: - OCR

    private func recognizeText(image: UIImage) async throws -> [VNRecognizedTextObservation] {
        guard let cgImage = image.cgImage else { return [] }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Self.ocrQueue.async {
                do {
                    try handler.perform([request])
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }

        return request.results ?? []
    }

    // MARK: - Barcode Detection

    private func detectBarcodes(image: UIImage) async throws -> [VNBarcodeObservation] {
        guard let cgImage = image.cgImage else { return [] }

        let request = VNDetectBarcodesRequest()
        request.symbologies = [
            .qr, .ean13, .code128, .code39, .dataMatrix, .itf14
        ]

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Self.barcodeQueue.async {
                do {
                    try handler.perform([request])
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }

        return request.results ?? []
    }

    // MARK: - Field Parsing

    private func parseLabelFields(rawText: String) -> LabelData {
        let lines = rawText.components(separatedBy: "\n")
        let fullText = rawText.uppercased()

        var data = LabelData(rawText: rawText)

        // Carton ID: CTN-YYYY-NNNNNN or CTN followed by alphanumeric
        if let match = rawText.range(of: #"CTN[-\s]?\d{4}[-\s]?\d{4,8}"#, options: .regularExpression) {
            data.cartonId = String(rawText[match]).trimmingCharacters(in: .whitespaces)
        } else if let match = rawText.range(of: #"(?i)(?:carton|ctn)[\s:#]*([A-Z0-9\-]{4,})"#, options: .regularExpression) {
            data.cartonId = String(rawText[match])
                .replacingOccurrences(of: #"(?i)(?:carton|ctn)[\s:#]*"#, with: "", options: .regularExpression)
        }

        // PO Number
        if let match = rawText.range(of: #"(?i)PO[\s#:]*(\d{4,})"#, options: .regularExpression) {
            let full = String(rawText[match])
            data.poNumber = full.replacingOccurrences(of: #"(?i)PO[\s#:]*"#, with: "", options: .regularExpression)
        }

        // ASN Number
        if let match = rawText.range(of: #"(?i)ASN[\s#:]*([A-Z0-9\-]{4,})"#, options: .regularExpression) {
            let full = String(rawText[match])
            data.asnNumber = full.replacingOccurrences(of: #"(?i)ASN[\s#:]*"#, with: "", options: .regularExpression)
        }

        // SO Number
        if let match = rawText.range(of: #"(?i)SO[\s#:]*(\d{4,})"#, options: .regularExpression) {
            let full = String(rawText[match])
            data.soNumber = full.replacingOccurrences(of: #"(?i)SO[\s#:]*"#, with: "", options: .regularExpression)
        }

        // LOT / Batch number
        if let match = rawText.range(of: #"(?i)(?:LOT|BATCH)[\s#:]*([A-Z0-9\-]{3,})"#, options: .regularExpression) {
            let full = String(rawText[match])
            data.lotNumber = full.replacingOccurrences(of: #"(?i)(?:LOT|BATCH)[\s#:]*"#, with: "", options: .regularExpression)
        }

        // Gross Weight
        if let match = rawText.range(of: #"(?i)(?:GW|GROSS\s*(?:WT|WEIGHT))[\s:]*(\d+\.?\d*\s*(?:kg|lbs?|KG|LBS?))"#, options: .regularExpression) {
            let full = String(rawText[match])
            data.grossWeight = full.replacingOccurrences(of: #"(?i)(?:GW|GROSS\s*(?:WT|WEIGHT))[\s:]*"#, with: "", options: .regularExpression)
        }

        // Net Weight
        if let match = rawText.range(of: #"(?i)(?:NW|NET\s*(?:WT|WEIGHT))[\s:]*(\d+\.?\d*\s*(?:kg|lbs?|KG|LBS?))"#, options: .regularExpression) {
            let full = String(rawText[match])
            data.netWeight = full.replacingOccurrences(of: #"(?i)(?:NW|NET\s*(?:WT|WEIGHT))[\s:]*"#, with: "", options: .regularExpression)
        }

        // Carrier detection
        let carriers = ["UPS", "FEDEX", "DHL", "USPS", "TNT", "MAERSK"]
        for carrier in carriers {
            if fullText.contains(carrier) {
                data.carrier = carrier
                break
            }
        }

        // Tracking number (common patterns)
        if let match = rawText.range(of: #"(?i)(?:TRACK|TRACKING)[\s#:]*([A-Z0-9]{10,30})"#, options: .regularExpression) {
            let full = String(rawText[match])
            data.trackingNumber = full.replacingOccurrences(of: #"(?i)(?:TRACK|TRACKING)[\s#:]*"#, with: "", options: .regularExpression)
        } else if let match = rawText.range(of: #"1Z[A-Z0-9]{16}"#, options: .regularExpression) {
            // UPS tracking
            data.trackingNumber = String(rawText[match])
        }

        // Dates (MM/DD/YYYY, YYYY-MM-DD, DD-MMM-YYYY)
        if let match = rawText.range(of: #"(?i)(?:PACK|MFG|PROD)\s*(?:DATE)?[\s:]*(\d{1,2}[/\-]\d{1,2}[/\-]\d{2,4})"#, options: .regularExpression) {
            let full = String(rawText[match])
            data.packDate = full.replacingOccurrences(of: #"(?i)(?:PACK|MFG|PROD)\s*(?:DATE)?[\s:]*"#, with: "", options: .regularExpression)
        }

        // Expiry date
        if let match = rawText.range(of: #"(?i)(?:EXP|EXPIR|BEST\s*BY|USE\s*BY)[\s:]*(\d{1,2}[/\-]\d{1,2}[/\-]\d{2,4})"#, options: .regularExpression) {
            let full = String(rawText[match])
            data.expiryDate = full.replacingOccurrences(of: #"(?i)(?:EXP|EXPIR|BEST\s*BY|USE\s*BY)[\s:]*"#, with: "", options: .regularExpression)
        }

        // Destination
        for line in lines {
            if line.localizedCaseInsensitiveContains("ship to") ||
               line.localizedCaseInsensitiveContains("deliver to") ||
               line.localizedCaseInsensitiveContains("dest") {
                // Take the next non-empty part or the value after colon
                if let colonRange = line.range(of: ":") {
                    let afterColon = String(line[colonRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                    if !afterColon.isEmpty {
                        data.destination = afterColon
                    }
                }
            }
        }

        // Handling icons
        var icons: [LabelData.HandlingIcon] = []
        for icon in LabelData.HandlingIcon.allCases {
            if fullText.contains(icon.rawValue) {
                icons.append(icon)
            }
        }
        if !icons.isEmpty {
            data.handlingIcons = icons
        }

        // SKU extraction
        var skuItems: [LabelData.SKUItem] = []
        let skuPattern = #"(?i)SKU[\s#:]*([A-Z0-9\-]{3,})"#
        let skuRegex = try? NSRegularExpression(pattern: skuPattern)
        let nsRange = NSRange(rawText.startIndex..., in: rawText)
        if let matches = skuRegex?.matches(in: rawText, range: nsRange) {
            for m in matches {
                if let range = Range(m.range(at: 1), in: rawText) {
                    let sku = String(rawText[range])
                    skuItems.append(LabelData.SKUItem(sku: sku))
                }
            }
        }
        if !skuItems.isEmpty {
            data.skuList = skuItems
        }

        return data
    }

    // MARK: - World Corner Computation

    private func computeWorldCorners(
        rectangle: VNRectangleObservation,
        frame: ARFrame
    ) -> [SIMD3<Float>]? {
        let visionCorners = [
            rectangle.topLeft,
            rectangle.topRight,
            rectangle.bottomRight,
            rectangle.bottomLeft
        ]

        // Depth map unprojection with 5x5 median sampling
        guard let depthMap = frame.smoothedSceneDepth?.depthMap ?? frame.sceneDepth?.depthMap else {
            return nil
        }

        let intrinsics = frame.camera.intrinsics
        let cameraTransform = frame.camera.transform

        let imageWidth = Float(CVPixelBufferGetWidth(frame.capturedImage))
        let imageHeight = Float(CVPixelBufferGetHeight(frame.capturedImage))
        let depthWidth = CVPixelBufferGetWidth(depthMap)
        let depthHeight = CVPixelBufferGetHeight(depthMap)

        let fx = intrinsics[0][0]
        let fy = intrinsics[1][1]
        let cx = intrinsics[2][0]
        let cy = intrinsics[2][1]

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        guard let depthBase = CVPixelBufferGetBaseAddress(depthMap) else { return nil }
        let depthBytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        let depthPointer = depthBase.assumingMemoryBound(to: Float32.self)
        let depthStride = depthBytesPerRow / MemoryLayout<Float32>.size

        var worldCorners: [SIMD3<Float>] = []

        for vc in visionCorners {
            let camX = Float(vc.y) * imageWidth
            let camY = (1.0 - Float(vc.x)) * imageHeight

            let depthX = Int(camX / imageWidth * Float(depthWidth))
            let depthY = Int(camY / imageHeight * Float(depthHeight))

            guard depthX >= 0, depthX < depthWidth, depthY >= 0, depthY < depthHeight else {
                return nil
            }

            // 5x5 median sampling
            let patchRadius = 2
            var samples: [Float] = []
            for dy in -patchRadius...patchRadius {
                for dx in -patchRadius...patchRadius {
                    let sx = depthX + dx
                    let sy = depthY + dy
                    guard sx >= 0, sx < depthWidth, sy >= 0, sy < depthHeight else { continue }
                    let d = depthPointer[sy * depthStride + sx]
                    if d > 0, d < 10 { samples.append(d) }
                }
            }
            samples.sort()
            guard !samples.isEmpty else { return nil }
            let depth = samples[samples.count / 2]
            guard depth > 0, depth < 10 else { return nil }

            let localX = (camX - cx) * depth / fx
            let localY = (camY - cy) * depth / fy
            let localZ = depth

            let cameraPoint = SIMD4<Float>(localX, -localY, -localZ, 1.0)
            let worldPoint = cameraTransform * cameraPoint
            worldCorners.append(SIMD3<Float>(worldPoint.x, worldPoint.y, worldPoint.z))
        }

        print("[LabelReader] World corners from depth map (fallback)")
        return worldCorners
    }

    // MARK: - Surface Normal

    private func computeSurfaceNormal(corners: [SIMD3<Float>]) -> SIMD3<Float>? {
        guard corners.count >= 3 else { return nil }

        let edge1 = corners[1] - corners[0]
        let edge2 = corners[3] - corners[0]
        let normal = simd_normalize(simd_cross(edge1, edge2))

        guard !normal.x.isNaN else { return nil }
        return normal
    }
}
