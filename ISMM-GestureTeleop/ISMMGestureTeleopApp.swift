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

class ISMMGestureTeleopApp: NSObject, GestureRecognizerLiveStreamDelegate {
    private let tcpClient: TCPClient
    
    private let frameEncoder = FrameEncoder()
    
    private let cameraManager = CameraManager()
    
    private let sendingQueue = DispatchQueue(label: "sendingQueue")

    private var gestureRecognizer: GestureRecognizer!
    
    private var frameDataCache = [Int: FrameMetadata]()
    private let cacheQueue = DispatchQueue(label: "frameCacheQueue")
    
    private let landmarkView = LandmarkOverlayView()

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
        landmarkView.frame = previewView.bounds
        landmarkView.backgroundColor = .clear
        landmarkView.isUserInteractionEnabled = false
        // Ensure overlay is on top
        DispatchQueue.main.async {
            previewView.addSubview(self.landmarkView) // OK to re-add
            self.landmarkView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            previewView.bringSubviewToFront(self.landmarkView)
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

    private func computePose(result: GestureRecognizerResult, depthData: AVDepthData?) {
        // TODO
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
            
        var matchedDepthData: AVDepthData?
        var matchedIntrinsicMatrix: simd_float3x3?
            
        cacheQueue.sync {
            matchedDepthData = frameDataCache[timestamp]?.depthData
            matchedIntrinsicMatrix = frameDataCache[timestamp]?.intrinsicMatrix
            frameDataCache.removeValue(forKey: timestamp) // Remove old data to prevent memory growths
        }
        
        // Print frame intrinsics
        if let matrix = matchedIntrinsicMatrix {
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
        computePose(result: result, depthData: matchedDepthData)
    }

    private func drawLandmarks(result: GestureRecognizerResult) {
        guard let handLandmarks = result.landmarks.first else {
            print("No hand landmarks detected.")
            return
        }
        
        let previewWidth = 390
        let previewHeight = 763
            
        let landmarkIndices = [0, 5, 9, 13, 17]
        var pointsToDraw: [CGPoint] = []

        for index in landmarkIndices {
            if index < handLandmarks.count {
                let lm = handLandmarks[index]

                let previewX = Int(Float(previewWidth) * lm.y)
                let previewY = previewHeight - Int(Float(previewHeight) * (1-lm.x))

                let viewPoint = CGPoint(x: previewX, y: previewY)
                pointsToDraw.append(viewPoint)
            }
        }
            
        // Update overlay view on main thread
        DispatchQueue.main.async {
            self.landmarkView.updatePoints(pointsToDraw)
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
}

struct FrameMetadata {
    let depthData: AVDepthData
    let intrinsicMatrix: simd_float3x3?
}
