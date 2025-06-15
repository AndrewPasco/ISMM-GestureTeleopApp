//
//  PoseEstimator.swift
//  ISMM-GestureTeleop
//
//  Created by Andrew Pasco on 04/06/25.
//
//  Description: 3D hand pose estimation from MediaPipe landmarks and depth data.
//  Converts 2D hand landmarks to 3D coordinates using depth information,
//  computes hand pose with coordinate frame estimation using robust plane fitting.
//

import Foundation
import simd
import AVFoundation
import MediaPipeTasksVision

/**
 * Static class for computing 3D hand poses from MediaPipe gesture recognition results and depth data.
 *
 * Features:
 * - 3D coordinate reconstruction from 2D landmarks and depth
 * - Robust plane fitting using RANSAC algorithm
 * - Hand coordinate frame estimation
 * - Camera intrinsics-based perspective projection
 */
class PoseEstimator {
    
    // MARK: - Main Pose Computation
    
    /**
     * Computes a 3D hand pose from gesture recognition results and depth data.
     *
     * Processes MediaPipe landmarks by:
     * 1. Converting 2D landmarks to 3D coordinates using depth data
     * 2. Extracting palm points for pose estimation
     * 3. Computing hand coordinate frame from palm geometry
     *
     * - Parameters:
     *   - result: MediaPipe gesture recognition result containing hand landmarks
     *   - frameData: Synchronized RGB and depth frame data
     * - Returns: Computed hand pose with translation and rotation, or nil if computation fails
     */
    static func computePose(
        result: GestureRecognizerResult?,
        frameData: FrameData?
    ) -> Pose? {
        guard let depthMap = frameData?.depthData.depthDataMap else { return nil }
        
        // Validate depth data format
        let format = CVPixelBufferGetPixelFormatType(depthMap)
        guard format == kCVPixelFormatType_DepthFloat32 else {
            print("Unsupported pixel format: \(format)")
            return nil
        }

        let depthWidth = CVPixelBufferGetWidth(depthMap)
        let depthHeight = CVPixelBufferGetHeight(depthMap)
        let imageSize = CGSize(width: depthWidth, height: depthHeight)

        guard let handLandmarks = result?.landmarks.first else {
            print("No hand landmarks detected.")
            return nil
        }

        // Lock depth buffer for reading
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(depthMap) else {
            print("Depth base address is nil")
            return nil
        }

        let rowBytes = CVPixelBufferGetBytesPerRow(depthMap)
        let rowStride = rowBytes / MemoryLayout<Float32>.size
        let buffer = baseAddress.assumingMemoryBound(to: Float32.self)

        // Get camera intrinsics for 3D reconstruction
        guard let rgbData = frameData?.rgbData else { return nil }
        guard let K = ISMMGestureTeleopApp.getFrameIntrinsics(from: rgbData) else {
            return nil
        }

        let fx = K[0][0]
        let fy = K[1][1]
        let cx = K[2][0]
        let cy = K[2][1]

        var palmPoints3D: [simd_double3] = []

        // Convert palm landmarks to 3D coordinates
        for index in DefaultConstants.PALM_INDICES {
            if index >= handLandmarks.count {
                print("Landmark index \(index) out of bounds")
                continue
            }

            let lm = handLandmarks[index]
            let pixelX = CGFloat(lm.x) * DefaultConstants.IMAGE_DIMS.WIDTH
            let pixelY = CGFloat(lm.y) * DefaultConstants.IMAGE_DIMS.HEIGHT
            let depthPixelX = CGFloat(lm.x) * imageSize.width
            let depthPixelY = CGFloat(lm.y) * imageSize.height

            let row = Int(depthPixelY)
            let col = Int(depthPixelX)

            // Bounds check for depth buffer access
            guard row >= 0, row < depthHeight,
                  col >= 0, col < depthWidth else {
                print("Skipping out-of-bounds landmark at (\(row), \(col))")
                continue
            }

            let depthIndex = row * rowStride + col
            let maxIndex = rowStride * depthHeight
            guard depthIndex >= 0 && depthIndex < maxIndex else {
                print("Depth index out of bounds: \(depthIndex) (max: \(maxIndex))")
                continue
            }

            let depth = buffer[depthIndex]
            if depth.isNaN || depth <= 0.0 {
                continue
            }

            // Convert to 3D camera coordinates using pinhole camera model
            let x = Double((Float(pixelX) - cx) * depth / fx)
            let y = Double((Float(pixelY) - cy) * depth / fy)
            let z = Double(depth)

            palmPoints3D.append(simd_double3(x, y, z))
        }

        guard palmPoints3D.count >= 3 else { return nil }

        return pointsToPose(points: palmPoints3D)
    }

    // MARK: - Pose Computation from 3D Points

    /**
     * Computes hand pose from a collection of 3D palm points.
     *
     * Estimates the hand coordinate frame by:
     * 1. Computing the centroid of palm points
     * 2. Finding the best-fit plane through the points
     * 3. Constructing orthogonal coordinate axes
     *
     * - Parameter points: Array of 3D palm landmark coordinates
     * - Returns: Hand pose with translation (centroid) and rotation matrix, or nil if insufficient points
     */
    static func pointsToPose(points: [simd_double3]) -> Pose? {
        let N = points.count
        guard N >= 3 else { return nil }

        // Compute centroid
        let sum = points.reduce(simd_double3(repeating: 0), +)
        let centroid = sum / Double(N)

        // Find best-fit plane normal
        guard let normal = bestPlaneNormal(from: points) else {
            return nil
        }

        // Construct coordinate frame
        let zAxis = simd_normalize(normal)
        var xAxis = simd_normalize(points[0] - centroid)
        
        // Project x-axis onto plane using Gram-Schmidt orthogonalization
        xAxis = simd_normalize(xAxis - simd_dot(xAxis, zAxis) * zAxis)
        let yAxis = simd_normalize(simd_cross(zAxis, xAxis))

        let rotationMatrix = matrix_double3x3(columns: (xAxis, yAxis, zAxis))
        
        let pose = Pose(translation: points[0], rot: rotationMatrix)
        
        return pose
    }

    // MARK: - Robust Plane Fitting

    /**
     * Finds the best-fitting plane normal using RANSAC algorithm.
     *
     * Uses a robust estimation approach to handle outliers in palm point data:
     * 1. Randomly samples 3-point combinations
     * 2. Computes plane normal for each combination
     * 3. Counts inliers within distance threshold
     * 4. Returns normal with maximum inlier support
     *
     * - Parameters:
     *   - points: Array of 3D points to fit plane through
     *   - threshold: Maximum distance for inlier classification (default: 0.005)
     *   - minInliers: Minimum number of inliers required (default: 3)
     * - Returns: Best-fit plane normal vector, or nil if no adequate plane found
     */
    static func bestPlaneNormal(from points: [simd_double3],
                                threshold: Double = 0.005,
                                minInliers: Int = 3) -> simd_double3? {
        guard points.count >= 3 else { return nil }

        var bestNormal: simd_double3? = nil
        var bestRMS = Double.infinity
        var maxInliers = 0
        let n = points.count

        for i in 0..<(n - 2) {
            for j in (i + 1)..<(n - 1) {
                for k in (j + 1)..<n {
                    let p1 = points[i]
                    let p2 = points[j]
                    let p3 = points[k]

                    // Compute plane normal from cross product
                    let v1 = p2 - p1
                    let v2 = p3 - p1
                    let normal = simd_cross(v1, v2)
                    if simd_length(normal) < 1e-10 { continue } // Skip degenerate cases

                    let d = -simd_dot(normal, p1)
                    let plane = Plane(normal: normal, d: d)

                    // Find inliers and calculate their distances
                    var inlierDistances: [Double] = []
                    for point in points {
                        let distance = abs(plane.distance(to: point))
                        if distance < threshold {
                            inlierDistances.append(distance)
                        }
                    }

                    let inlierCount = inlierDistances.count
                    
                    // Skip if not enough inliers
                    guard inlierCount >= minInliers else { continue }

                    // Calculate RMS distance for inliers
                    let sumSquaredDistances = inlierDistances.reduce(0) { $0 + $1 * $1 }
                    let rmsDistance = sqrt(sumSquaredDistances / Double(inlierCount))

                    // Update best plane using lexicographic ordering:
                    // 1. More inliers is better
                    // 2. If same inlier count, lower RMS is better
                    let isBetter = inlierCount > maxInliers ||
                                  (inlierCount == maxInliers && rmsDistance < bestRMS)
                    
                    if isBetter {
                        maxInliers = inlierCount
                        bestRMS = rmsDistance
                        bestNormal = simd_normalize(normal)
                    }
                }
            }
        }

        return bestNormal
    }
}

// MARK: - Supporting Types

/**
 * Represents a 3D plane defined by normal vector and distance from origin.
 */
struct Plane {
    /// Plane normal vector
    var normal: simd_double3
    
    /// Distance from origin (plane equation: n·x + d = 0)
    var d: Double
    
    /**
     * Computes signed distance from plane to a point.
     *
     * - Parameter point: 3D point to compute distance for
     * - Returns: Signed distance (positive = same side as normal, negative = opposite side)
     */
    func distance(to point: simd_double3) -> Double {
        (simd_dot(normal, point) + d) / simd_length(normal)
    }
}

/**
 * Represents a 3D hand pose with position and orientation.
 */
struct Pose {
    /// 3D translation vector (hand position)
    let translation: simd_double3
    
    /// 3x3 rotation matrix (hand orientation)
    let rot: matrix_double3x3
}
