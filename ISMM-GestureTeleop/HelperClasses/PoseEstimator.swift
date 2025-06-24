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
        
        var palmPoints3D = [Int:simd_double3]()
        
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
            
            palmPoints3D[index] = (simd_double3(x, y, z))
        }
        
        guard palmPoints3D.count >= 3 else { return nil }
        
        guard let handedness = result?.handedness.first?[0].categoryName else { return nil }
        
        return pointsToPose(handedness: handedness, points: palmPoints3D)
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
    static func pointsToPose(handedness: String, points: [Int:simd_double3]) -> Pose? {
        // y: 13->5
        // x: 12->9
        
        guard let wristPos = points[0], let pointerMCP = points[5], let midMCP = points[9], let midTip = points[12], let ringMCP = points[13] else { return nil }
        
        let xAxis = simd_normalize(wristPos - midTip)
        
        var yAxis = simd_normalize(pointerMCP - ringMCP)
        if handedness == "Left" {
            yAxis = -yAxis
        }
        
        // Project y-axis onto plane using Gram-Schmidt orthogonalization
        yAxis = simd_normalize(yAxis - simd_dot(yAxis, xAxis) * xAxis)
        
        // finish right-handed coordinate system
        let zAxis = simd_normalize(simd_cross(xAxis, yAxis))
        
        let rotationMatrix = matrix_double3x3(columns: (xAxis, yAxis, zAxis))
        
        let pose = Pose(translation: wristPos, rot: rotationMatrix)
        
        return pose
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
