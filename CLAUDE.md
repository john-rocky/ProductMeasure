# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build

```bash
xcodebuild -scheme ProductMeasure -destination 'generic/platform=iOS' build
```

- iOS 17.0+, requires LiDAR device (iPhone 12 Pro+, iPad Pro 2020+)
- No external dependencies — only Apple frameworks (SwiftUI, RealityKit, ARKit, Vision, SwiftData)
- SourceKit may show false "No such module" errors for UIKit/ARKit — ignore them, the build succeeds

## Architecture

SwiftUI + RealityKit AR measurement app using LiDAR. MVVM pattern centered on `ARMeasurementView` and its ViewModel.

### Measurement Pipeline

The core flow from user interaction to 3D box visualization:

1. **User tap/box selection** → screen coordinates converted to normalized image coordinates; ARKit raycast determines 3D world position
2. **Instance Segmentation** (`InstanceSegmentationService`) → Vision `VNGenerateForegroundInstanceMaskRequest` segments all foreground instances; mask is in portrait orientation (rotated 90° from landscape camera)
3. **Depth Filtering** (`MeasurementCalculator.filterMaskedPixelsByDepth`) → filters mask pixels to those within ±25% of tap-point depth (min ±10cm) using LiDAR depth map
4. **Point Cloud Generation** (`PointCloudGenerator`) → MAD-based outlier removal, 3mm grid downsampling, unprojection via camera intrinsics to world coordinates
5. **3D Proximity Filtering** (`MeasurementCalculator`) → spatial hash-grid flood-fill clustering (4cm cells) from raycast hit point to isolate the tapped object
6. **Bounding Box Estimation** (`BoundingBoxEstimator`) → Box Priority mode: 2D convex hull + MABR (rotating calipers) on XZ plane, snaps to nearby AR plane anchors; Free Object mode: full 3D PCA. Iterative refinement with percentile-based extents (1% trim)
7. **Axis Mapping** (`BoundingBox3D.calculateAxisMapping`) → assigns Height/Length/Width based on camera orientation at measurement time
8. **Floor Extension** → extends bottom face to floor if raycast hit floor (max 5cm)
9. **Animation + Visualization** (`BoxAnimationCoordinator` → `BoxVisualization`) → 4-phase edge-trace animation (1.6s total), then interactive wireframe with handles, dimension billboard, and action icons

### Key Service Responsibilities

| Service | Role |
|---------|------|
| `ARSessionManager` | AR session lifecycle, frame callbacks, RealityKit scene management |
| `MeasurementCalculator` | Orchestrates full pipeline; entry points: `measure()`, `measureWithROI()`, `measureForRefinement()` |
| `BoundingBoxEstimator` | Convex hull, MABR, PCA, AR plane snapping, iterative refinement |
| `PointCloudGenerator` | Depth → 3D points with MAD outlier removal and grid downsampling |
| `DepthProcessor` | Low-level depth/confidence map extraction from ARFrame |
| `InstanceSegmentationService` | Vision-based foreground segmentation |
| `BoxEditingService` | Interactive face dragging, rotation, fit-to-points |
| `BoxVisualization` | RealityKit wireframe: dual-layer edges, corner markers, face handles, rotation ring, dimension billboard, action icons |
| `ActionIconBuilder` | 3D pill-shaped action buttons with SF Symbol textures; presets: normal, editing, refining, completed |

### Coordinate Systems

Five coordinate systems are used — conversions are in `MeasurementCalculator`:
- **Screen**: SwiftUI (top-left origin, points)
- **Camera Image**: ARKit landscape (top-left origin, pixels)
- **Vision**: Normalized (bottom-left origin, 0-1)
- **Depth Map**: Lower resolution (top-left origin, pixels)
- **World Space**: ARKit (right-handed, Y-up, meters)

### Data Models

- `BoundingBox3D`: center, extents, rotation quaternion; has `contains()`, `extendBottomToFloor()`, `calculateAxisMapping()`, `dimensions(withMapping:)`
- `ProductMeasurement` (SwiftData): persisted measurement with dimensions, bounding box geometry, quality metrics, annotated JPEG image
- `MeasurementQuality`: depthCoverage, depthConfidence, pointCount, overallQuality (High/Medium/Low)

### Configuration

- `AppConstants` (Constants.swift): processing thresholds — max 20k points, 3mm grid, depth confidence/coverage thresholds, refinement parameters
- `PMTheme` (Theme.swift): design tokens — accent color is neon green (`0x39FF14`), 3D edge radii, animation durations, surface colors
- `MeasurementMode`: `.boxPriority` (locks vertical axis) vs `.freeObject` (full 3D rotation)
- `SelectionMode`: `.tap` (single point) vs `.box` (drag rectangle)

### Performance Constraints

- Point cloud: 3mm grid downsampling, max 20,000 points
- Clustering stops processing at 10,000 points
- Mask sampling: adaptive stride, max 20,000 pixels
- Max 10 completed boxes in scene (oldest auto-removed)
