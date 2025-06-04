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
        let frameIntrinsics = getFrameIntrinsics(from: sampleBuffer)
        
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
        
        guard let K = matchedFrameData?.intrinsicMatrix else {
            return
        }
            
        guard let recognizedGesture = result.gestures.first?[0].categoryName else {
            return
        }
            
        // Compute wrist pose
        guard let newPose = PoseEstimator.computePose(result: result, frameData: matchedFrameData) else {
            print("Pose compute failure")
            return
        }
            
        // Passing for landmark drawing
        updateHandPreview(result: result, pose: newPose, intrinsics: K)
            
        sendGestureAndPose(gesture: recognizedGesture, pose: newPose)
    }

    private func sendGestureAndPose(gesture: String, pose: (translation: simd_double3, rot: matrix_double3x3)) {
        // Transform to quat for sending
        let quat = simd_quaternion(pose.rot)
        
        let poseData = String(format: "%@ %.6f %.6f %.6f %.6f %.6f %.6f %.6f\n", gesture,
                              pose.translation.x, pose.translation.y, pose.translation.z,
                              quat.vector.w, quat.vector.x, quat.vector.y, quat.vector.z)
        
        if let dataToSend = poseData.data(using: .utf8) {
            tcpClient.send(data: dataToSend)
        }
    }
    
    private func updateHandPreview(result: GestureRecognizerResult, pose: (translation: simd_double3, rot: matrix_double3x3), intrinsics: matrix_float3x3) {
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
            self.resultUIView.update(points: pointsToDraw, gestureLabel: gestureResult, centroid3D: pose.translation, axes3D: pose.rot, intrinsics: intrinsics)
        }
    }
    
    func getFrameIntrinsics(from sampleBuffer: CMSampleBuffer) -> matrix_float3x3? {
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
}

struct FrameMetadata {
    let depthData: AVDepthData
    let intrinsicMatrix: simd_float3x3?
}
