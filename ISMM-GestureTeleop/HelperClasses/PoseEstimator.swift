//
//  PoseEstimator.swift
//  ISMM-GestureTeleop
//
//  Created by Andrew Pasco on 04/06/25.
//

import Foundation
import simd
import AVFoundation
import MediaPipeTasksVision

class PoseEstimator {
    static func computePose(
        result: GestureRecognizerResult,
        frameData: FrameData?
    ) -> Pose? {
        guard let depthMap = frameData?.depthData.depthDataMap else { return nil }
        let format = CVPixelBufferGetPixelFormatType(depthMap)
        guard format == kCVPixelFormatType_DepthFloat32 else {
            print("Unsupported pixel format: \(format)")
            return nil
        }

        let imageSize = CGSize(width: CVPixelBufferGetWidth(depthMap), height: CVPixelBufferGetHeight(depthMap))

        guard let handLandmarks = result.landmarks.first else {
            print("No hand landmarks detected.")
            return nil
        }

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        let rowBytes = CVPixelBufferGetBytesPerRow(depthMap)
        let baseAddress = CVPixelBufferGetBaseAddress(depthMap)!
        let buffer = baseAddress.assumingMemoryBound(to: Float32.self)
        
        guard let rgbData = frameData?.rgbData else { return nil }

        guard let K = ISMMGestureTeleopApp.getFrameIntrinsics(from: rgbData) else {
            return nil
        }
        
        let fx = K[0][0]
        let fy = K[1][1]
        let cx = K[2][0]
        let cy = K[2][1]

        var palmPoints3D: [simd_double3] = []

        for index in DefaultConstants.PALM_INDICES {
            let lm = handLandmarks[index]
            let pixelX = CGFloat(lm.x) * DefaultConstants.IMAGE_DIMS.WIDTH
            let pixelY = CGFloat(lm.y) * DefaultConstants.IMAGE_DIMS.HEIGHT
            let depthPixelX = CGFloat(lm.x) * imageSize.width
            let depthPixelY = CGFloat(lm.y) * imageSize.height

            let row = Int(depthPixelY)
            let col = Int(depthPixelX)
            let depthIndex = row * (rowBytes / MemoryLayout<Float32>.size) + col
            let depth = buffer[depthIndex]

            if depth.isNaN || depth <= 0.0 {
                continue
            }

            let x = Double((Float(pixelX) - cx) * depth / fx)
            let y = Double((Float(pixelY) - cy) * depth / fy)
            let z = Double(depth)

            palmPoints3D.append(simd_double3(x, y, z))
        }

        guard palmPoints3D.count >= 3 else { return nil }

        return pointsToPose(points: palmPoints3D)
    }

    static func pointsToPose(points: [simd_double3]) -> Pose? {
        let N = points.count
        guard N >= 3 else { return nil }

        let sum = points.reduce(simd_double3(repeating: 0), +)
        let centroid = sum / Double(N)

        guard let normal = bestPlaneNormal(from: points) else {
            return nil
        }

        let zAxis = simd_normalize(normal)
        var xAxis = simd_normalize(points[0] - centroid)
        
        // get component of xaxis in x-y plane
        // determine how to rotate
        
        xAxis = simd_normalize(xAxis - simd_dot(xAxis, zAxis) * zAxis) // gram-schmidt
        let yAxis = simd_normalize(simd_cross(zAxis, xAxis))

        let rotationMatrix = matrix_double3x3(columns: (xAxis, yAxis, zAxis))
        
        let pose = Pose(translation: centroid, rot:rotationMatrix)
        
        return pose
    }

    static func bestPlaneNormal(from points: [simd_double3],
                                threshold: Double = 0.005,
                                minInliers: Int = 3) -> simd_double3? {
        guard points.count >= 3 else { return nil }

        var bestNormal: simd_double3? = nil
        var maxInliers = 0
        let n = points.count

        for i in 0..<(n - 2) {
            for j in (i + 1)..<(n - 1) {
                for k in (j + 1)..<n {
                    let p1 = points[i]
                    let p2 = points[j]
                    let p3 = points[k]

                    let v1 = p2 - p1
                    let v2 = p3 - p1
                    let normal = simd_cross(v1, v2)
                    if simd_length(normal) < 1e-10 { continue }

                    let d = -simd_dot(normal, p1)
                    let plane = Plane(normal: normal, d: d)

                    let inliers = points.filter { abs(plane.distance(to: $0)) < threshold }

                    if inliers.count > maxInliers && inliers.count >= minInliers {
                        maxInliers = inliers.count
                        bestNormal = simd_normalize(normal)
                    }
                }
            }
        }

        return bestNormal
    }
}

struct Plane {
    var normal: simd_double3
    var d: Double
    
    func distance(to point: simd_double3) -> Double {
        (simd_dot(normal, point) + d) / simd_length(normal)
    }
}

struct Pose {
    let translation: simd_double3
    let rot: matrix_double3x3
}
