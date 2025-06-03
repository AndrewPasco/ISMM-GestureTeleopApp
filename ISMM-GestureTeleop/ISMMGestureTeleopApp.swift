//
//  ISMM_GestureTeleopApp.swift
//  ISMM-GestureTeleop
//
//  Created by Andrew Pasco on 21/05/2025.
//

import UIKit
import AVFoundation
import MediaPipeTasksVision
import simd
import Foundation
import Accelerate

class ISMMGestureTeleopApp: NSObject, GestureRecognizerLiveStreamDelegate {
    private let tcpClient: TCPClient
    
    private let cameraManager = CameraManager()
    
    private let sendingQueue = DispatchQueue(label: "sendingQueue")

    private var gestureRecognizer: GestureRecognizer!
    
    private var frameDataCache = [Int: FrameMetadata]()
    private let cacheQueue = DispatchQueue(label: "frameCacheQueue")
    
    private let resultUIView = ResultOverlayView()

    var onConnectionStatusChange: ((ConnectionStatus) -> Void)? {
        didSet { tcpClient.onStatusChange = onConnectionStatusChange }
    }

    init(host: String, port: Int, previewView: UIView) {
        // Create TCPClient for sending to Remote
        tcpClient = TCPClient(host: host, port: port)
        super.init()
        // Create Gesture Recognizer Service and Result Handler
        let options = createGestureRecognizerOptions()
        
        // Assign an object of the class to the `gestureRecognizerLiveStreamDelegate`
        // property
        do {
            gestureRecognizer = try GestureRecognizer(options: options)
        } catch {
            fatalError("Failed to initialize GestureRecognizer: \(error)")
        }
        
        // Create and configure CameraManager with callback
        cameraManager.onFrameCaptured = { [weak self] sampleBuffer, depthData in
            self?.handleFrame(sampleBuffer: sampleBuffer, depthData: depthData)
        }
        
        cameraManager.configure(previewIn: previewView)
        
        // Add the overlay view on top of previewView
        resultUIView.frame = previewView.bounds
        resultUIView.backgroundColor = .clear
        resultUIView.isUserInteractionEnabled = false
        // Ensure overlay is on top
        DispatchQueue.main.async {
            previewView.addSubview(self.resultUIView) // OK to re-add
            self.resultUIView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            previewView.bringSubviewToFront(self.resultUIView)
        }
    }

    func connectToServer() {
        tcpClient.connect()
    }

    private func handleFrame(sampleBuffer: CMSampleBuffer, depthData: AVDepthData) {
        let timestampMillis = Int(CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds * 1000)
        let frameIntrinsics = getIntrinsics(from: sampleBuffer)
        
        let metadata = FrameMetadata(
            depthData: depthData,
            intrinsicMatrix: frameIntrinsics
        )
        
        // Cache the frame data for association when the recognition result comes
        cacheQueue.sync {
            frameDataCache[timestampMillis] = metadata
        }
        
        // Convert the `CMSampleBuffer` object to MediaPipe's Image object,
        // rotating since recording portrait, then pass to the Recognizer
        do {
            let image = try MPImage(sampleBuffer: sampleBuffer, orientation: .right)
            try gestureRecognizer.recognizeAsync(
                image: image,
                timestampInMilliseconds: timestampMillis
            )
        } catch {
            print("Gesture recognition error: \(error)")
        }
    }
    
    // Delegate method which takes the async result from the GestureRecognizer
    func gestureRecognizer(
            _ gestureRecognizer: GestureRecognizer,
            didFinishGestureRecognition result: GestureRecognizerResult?,
            timestampInMilliseconds: Int,
            error: Error?
        ) {
        // Ensure no error and successful result
        guard error == nil, let result = result else {
            print("Error or no result: \(String(describing: error))")
            return
        }
        
        let timestamp = timestampInMilliseconds
            
        var matchedFrameData: FrameMetadata?
            
        cacheQueue.sync {
            matchedFrameData = frameDataCache[timestamp]
            frameDataCache.removeValue(forKey: timestamp) // Remove old data to prevent memory growths
        }
        
        // Print frame intrinsics
            if let matrix = matchedFrameData?.intrinsicMatrix {
            print("Intrinsic Matrix:")
            print("[[\(matrix.columns.0.x), \(matrix.columns.1.x), \(matrix.columns.2.x)]")
            print(" [\(matrix.columns.0.y), \(matrix.columns.1.y), \(matrix.columns.2.y)]")
            print(" [\(matrix.columns.0.z), \(matrix.columns.1.z), \(matrix.columns.2.z)]]")
        } else { print("No intrinsic matrix found") }
            
        // Print Timestamp and Top Gesture
        print("Timestamp: \(timestamp) ms")

        if let gestureCategories = result.gestures.first {
            print("Recognized Gestures:")
            for gesture in gestureCategories {
                if let name = gesture.categoryName {
                    print("- \(name): \(gesture.score)")
                } else {
                    print("- <unknown gesture>: \(gesture.score)")
                }
            }
        } else {
            print("Gesture: None")
        }

        // Further Processing of gesture?
            
        // Passing for landmark drawing
        drawLandmarks(result: result)
            
        // Compute wrist pose
        let newPose = computePose(result: result, frameData: matchedFrameData)
            
//        for i in 0..<4 {
//            let row = [newPose?.columns.0[i], newPose?.columns.1[i], newPose?.columns.2[i], newPose?.columns.3[i]]
//            print(row.map { String(format: "%.3f", $0!) }.joined(separator: "\t"))
//        }
    }
    
    private func computePose(result: GestureRecognizerResult, frameData: FrameMetadata?) -> simd_double4x4? {
        // Unwrap depth map and verify it is float32 buffer
        guard let depthMap = frameData?.depthData.depthDataMap else { return nil }
        let format = CVPixelBufferGetPixelFormatType(depthMap)
        guard format == kCVPixelFormatType_DepthFloat32 else {
            print("Unsupported pixel format: \(format)")
            return nil
        }
        // get depth resolution
        let imageSize = CGSize(width: CVPixelBufferGetWidth(depthMap), height: CVPixelBufferGetHeight(depthMap))

        // get handLandmarks and handWorldLandmarks
        guard let handLandmarks = result.landmarks.first else {
            print("No hand landmarks detected.")
            return nil
        }
        
        // Get orientations and centroid position from normal approach
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        let rowBytes = CVPixelBufferGetBytesPerRow(depthMap)
        let baseAddress = CVPixelBufferGetBaseAddress(depthMap)!

        let buffer = baseAddress.assumingMemoryBound(to: Float32.self)
        
        guard let K = frameData?.intrinsicMatrix else { return nil }

        let fx = K[0][0]
        let fy = K[1][1]
        let cx = K[2][0]
        let cy = K[2][1]
        
        var palmPoints3D: [simd_double3] = []

        for index in DefaultConstants.PALM_INDICES {
            let lm = handLandmarks[index]
            let pixelX = CGFloat(lm.x) * imageSize.width
            let pixelY = CGFloat(lm.y) * imageSize.height

            let row = Int(pixelY)
            let col = Int(pixelX)
            let index = row * (rowBytes / MemoryLayout<Float32>.size) + col
            let depth = buffer[index]

            // Skip invalid or missing depth values
            if depth.isNaN || depth <= 0.0 { continue }

            let x = Double((Float(pixelX) - cx) * depth / fx)
            let y = Double((Float(pixelY) - cy) * depth / fy)
            let z = Double(depth)

            palmPoints3D.append(simd_double3(x, y, z))
        }
        
        guard palmPoints3D.count >= 3 else {
            print("Not enough valid palm points for plane fitting.")
            return nil
        }

        guard let (palmCentroid, palmNormal) = fitPlaneSVD(points: palmPoints3D) else {
            print("Plane fitting failed")
            return nil
        }
        
        // 3×3 rotation matrix from quaternion
        let R = double3x3(palmNormal)

        // Build a 4×4 Pose
        var pose = matrix_identity_double4x4

        // Set rotation part
        pose.columns.0 = SIMD4<Double>(R.columns.0, 0)
        pose.columns.1 = SIMD4<Double>(R.columns.1, 0)
        pose.columns.2 = SIMD4<Double>(R.columns.2, 0)

        // Set translation (centroid)
        pose.columns.3 = SIMD4<Double>(palmCentroid, 1)

        return pose
    }

    private func drawLandmarks(result: GestureRecognizerResult) {
        guard let handLandmarks = result.landmarks.first else {
            print("No hand landmarks detected.")
            return
        }
        
        guard let gestureResult = result.gestures.first?[0].categoryName else {
            print("No gesture detected.")
            return
        }
            
        var pointsToDraw: [CGPoint] = []

        for index in DefaultConstants.PALM_INDICES {
            if index < handLandmarks.count {
                let lm = handLandmarks[index]

                let previewX = Int(Float(DefaultConstants.PREVIEW_DIMS.WIDTH) * lm.y)
                let previewY = Int(Float(DefaultConstants.PREVIEW_DIMS.HEIGHT) *  lm.x)

                let viewPoint = CGPoint(x: previewX, y: previewY)
                pointsToDraw.append(viewPoint)
            }
        }
            
        // Update overlay view on main thread
        DispatchQueue.main.async {
            self.resultUIView.updatePoints(pointsToDraw, gestureLabel: gestureResult)
        }
    }
    
    func getIntrinsics(from sampleBuffer: CMSampleBuffer) -> matrix_float3x3? {
        guard let attachment = CMGetAttachment(
            sampleBuffer,
            key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix,
            attachmentModeOut: nil
        ) else {
            print("No intrinsic matrix attachment found.")
            return nil
        }

        let matrixData = attachment as! CFData
        var intrinsicMatrix = matrix_float3x3()
        
        CFDataGetBytes(
            matrixData,
            CFRange(location: 0, length: MemoryLayout.size(ofValue: intrinsicMatrix)),
            &intrinsicMatrix
        )

        return intrinsicMatrix
    }
    
    func getPreviewLayer() -> AVCaptureVideoPreviewLayer? {
        return cameraManager.previewLayer
    }

    
    private func createGestureRecognizerOptions() -> GestureRecognizerOptions {
        let options = GestureRecognizerOptions()
        options.baseOptions.modelAssetPath = DefaultConstants.modelPath!
        options.runningMode = .liveStream
        options.minHandDetectionConfidence = DefaultConstants.minHandDetectionConfidence
        options.minHandPresenceConfidence = DefaultConstants.minHandPresenceConfidence
        options.minTrackingConfidence = DefaultConstants.minTrackingConfidence
        options.numHands = 1
        options.gestureRecognizerLiveStreamDelegate = self
        return options
    }

    func fitPlaneSVD(points: [SIMD3<Double>]) -> (centroid: SIMD3<Double>, normalQuat: simd_quatd)? {
        let N = points.count
        guard N >= 3 else { return nil }

        // 1. Compute the centroid
        let sum = points.reduce(SIMD3<Double>(repeating: 0), +)
        let centroid = sum / Double(N)

        // 2. Center the points
        let centered = points.map { $0 - centroid }

        // 3. Build 3xN matrix for SVD
        // Column-major: X, Y, Z rows — N columns
        var matrix = centered.flatMap { [$0.x, $0.y, $0.z] }

        // 4. Compute covariance matrix: 3x3
        var covMatrix = [Double](repeating: 0, count: 9) // row-major
        vDSP_mmulD(matrix, 1,
                   matrix, 1,
                   &covMatrix, 1,
                   3, 3, vDSP_Length(N))

        let scale = 1.0 / Double(N - 1)
        vDSP_vsmulD(covMatrix, 1, [scale], &covMatrix, 1, 9)

        // 5. Eigen decomposition of covariance matrix
        var jobz: Int8 = 86 // 'V'
        var uplo: Int8 = 85 // 'U'
        var n: Int32 = 3
        var lda: Int32 = 3
        var info: Int32 = 0
        var eigenvalues = [Double](repeating: 0, count: 3)
        var covMatrixCopy = covMatrix // dsyev modifies in-place
        var work = [Double](repeating: 0, count: 15 * 3)
        var lwork = Int32(work.count)

        dsyev_(&jobz, &uplo, &n, &covMatrixCopy, &lda, &eigenvalues, &work, &lwork, &info)

        if info != 0 {
            print("Eigen decomposition failed.")
            return nil
        }

        // 6. Extract normal (eigenvector with smallest eigenvalue)
        // Columns of covMatrixCopy are eigenvectors in row-major
        let minIndex = eigenvalues.firstIndex(of: eigenvalues.min()!)!
        let normal = SIMD3<Double>(covMatrixCopy[minIndex],
                                   covMatrixCopy[minIndex + 3],
                                   covMatrixCopy[minIndex + 6])

        let normalizedNormal = simd_normalize(normal)

        // 7. Create orientation quaternion where +Z aligns with normal
        let zAxis = SIMD3<Double>(0, 0, 1)
        let rotation = simd_quaternion(zAxis, normalizedNormal)

        return (centroid, rotation)
    }
}

struct FrameMetadata {
    let depthData: AVDepthData
    let intrinsicMatrix: simd_float3x3?
}
