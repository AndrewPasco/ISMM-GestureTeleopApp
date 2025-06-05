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

    private var poseRecognizer: GestureRecognizer!
    private var gestureRecognizer: GestureRecognizer!
    private let gestureProcessingQueue = DispatchQueue(label: "gestureProcessingQueue")
    
    private var latestFrame: FrameData?
    private var processingFrame: FrameData?
    private var isProcessingFrame = false
    
    private let poseRecognizerDelegate = GestureRecognizerResultDelegate()
    private let gestureRecognizerDelegate = GestureRecognizerResultDelegate()
    private var firstResult: FirstResult?
    
    private let resultUIView = ResultOverlayView()

    var onConnectionStatusChange: ((ConnectionStatus) -> Void)? {
        didSet { tcpClient.onStatusChange = onConnectionStatusChange }
    }

    init(host: String, port: Int, previewView: UIView) {
        // Create TCPClient for sending to Remote
        tcpClient = TCPClient(host: host, port: port)
        super.init()
        
        // Setup delegate closures
        poseRecognizerDelegate.onGestureResult = { [weak self] result, timestamp in
            self?.handlePoseResult(result: result, timestampInMilliseconds: timestamp)
        }
        
        gestureRecognizerDelegate.onGestureResult = { [weak self] result, timestamp in
            self?.handleGestureResult(result: result, timestampInMilliseconds: timestamp)
        }
        
        // Create GestureRecognizers
        let poseOptions = createGestureRecognizerOptions(delegate: poseRecognizerDelegate)
        let gestureOptions = createGestureRecognizerOptions(delegate: gestureRecognizerDelegate)
        
        do {
            poseRecognizer = try GestureRecognizer(options: poseOptions)
            gestureRecognizer = try GestureRecognizer(options: gestureOptions)
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

    private func handleFrame(sampleBuffer: CMSampleBuffer, depthData: AVDepthData) {
        // Convert the `CMSampleBuffer` object to MediaPipe's Image object,
        // rotating since recording portrait, then pass to the Recognizer
        gestureProcessingQueue.async {
            if self.isProcessingFrame {
                self.latestFrame = FrameData(rgbData: sampleBuffer, depthData: depthData)
                print("saving newest frame")
                return
            }
            self.isProcessingFrame = true
            
            let timestampMillis = Int(CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds * 1000)
            
            self.processingFrame = FrameData(rgbData: sampleBuffer, depthData: depthData)
            
            do {
                let image = try MPImage(sampleBuffer: sampleBuffer, orientation: .right)
                try self.poseRecognizer.recognizeAsync(
                    image: image,
                    timestampInMilliseconds: timestampMillis
                )
            } catch {
                print("Gesture recognition error: \(error)")
                self.finishProcessing()
            }
        }
    }
    
    // Closure method which takes the async result from the poseRecognizerDelegate
    private func handlePoseResult(result: GestureRecognizerResult?,
            timestampInMilliseconds: Int) {
        // Ensure successful result
        print("hand pose result")
        guard let result = result else {
            print("No result")
            finishProcessing()
            return
        }
            
        // Compute palm pose
        guard let newPose = PoseEstimator.computePose(result: result, frameData: processingFrame) else {
            print("Pose compute failure")
            finishProcessing()
            return
        }
        
        firstResult = FirstResult(result: result, pose: newPose)
        
        // get correct orientation from initially detected pose then send cached frame to other recognizer
        let xAxis = newPose.rot.columns.0
        let xAxisXY = CGVector(dx:xAxis.x, dy:xAxis.y)
        let reorientation = getImageReorientation(for: xAxisXY)
        
        guard let rgb = processingFrame?.rgbData else {
            finishProcessing()
            return
        }
        
        // Convert the `CMSampleBuffer` object to MediaPipe's Image object,
        // rotating as determiend above, then pass to the Recognizer
        do {
            let image = try MPImage(sampleBuffer: rgb, orientation: reorientation)
            try gestureRecognizer.recognizeAsync(
                image: image,
                timestampInMilliseconds: timestampInMilliseconds
            )
        } catch {
            print("Gesture recognition error: \(error)")
            finishProcessing()
        }
        
    }
    
    private func handleGestureResult(result: GestureRecognizerResult?, timestampInMilliseconds: Int) {
        // Ensure successful result
        print("handle gesture result")
        guard let result = result else {
            print("No result")
            return
        }
        
        guard let rgb = processingFrame?.rgbData, let recognizedGesture = result.gestures.first?[0].categoryName, let pose = firstResult?.pose, let previewResult = firstResult?.result else {
            finishProcessing()
            return
        }
        
        guard let K = ISMMGestureTeleopApp.getFrameIntrinsics(from: rgb) else {
            finishProcessing()
            return
        }
        
        // Passing for landmark drawing
        DispatchQueue.main.async {
            self.updateHandPreview(firstResult: previewResult, gesture: recognizedGesture, pose: pose, intrinsics: K)
        }
        
        //sendGestureAndPose(gesture: recognizedGesture, pose: pose)
        
        self.finishProcessing()
    }

    private func finishProcessing() {
        gestureProcessingQueue.async {
            self.isProcessingFrame = false
            if let newFrame = self.latestFrame {
                self.latestFrame = nil
                self.handleFrame(sampleBuffer: newFrame.rgbData, depthData: newFrame.depthData)
            } else {
                return
            }
        }
    }
    
    func connectToServer() {
        tcpClient.connect()
    }
    
    private func sendGestureAndPose(gesture: String, pose: Pose) {
        // Transform to quat for sending
        let quat = simd_quaternion(pose.rot)
        
        let poseData = String(format: "%@ %.6f %.6f %.6f %.6f %.6f %.6f %.6f\n", gesture,
                              pose.translation.x, pose.translation.y, pose.translation.z,
                              quat.vector.w, quat.vector.x, quat.vector.y, quat.vector.z)
        
        if let dataToSend = poseData.data(using: .utf8) {
            tcpClient.send(data: dataToSend)
        }
    }
    
    private func updateHandPreview(firstResult: GestureRecognizerResult, gesture: String, pose: Pose, intrinsics: matrix_float3x3) {
        // get hand landmarks from the original recognition
        guard let handLandmarks = firstResult.landmarks.first else {
            print("No hand landmarks detected.")
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
            self.resultUIView.update(points: pointsToDraw, gestureLabel: gesture, centroid3D: pose.translation, axes3D: pose.rot, intrinsics: intrinsics)
        }
    }
    
    func getImageReorientation(for vector: CGVector) -> UIImage.Orientation {
        let absX = abs(vector.dx)
        let absY = abs(vector.dy)

        if absX > absY {
            return vector.dx >= 0 ? .right : .left
        } else {
            return vector.dy >= 0 ? .up : .down
        }
    }
    
    static func getFrameIntrinsics(from sampleBuffer: CMSampleBuffer) -> matrix_float3x3? {
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
    
    private func createGestureRecognizerOptions(delegate: GestureRecognizerLiveStreamDelegate) -> GestureRecognizerOptions {
        let options = GestureRecognizerOptions()
        options.baseOptions.modelAssetPath = DefaultConstants.modelPath!
        options.runningMode = .liveStream
        options.minHandDetectionConfidence = DefaultConstants.minHandDetectionConfidence
        options.minHandPresenceConfidence = DefaultConstants.minHandPresenceConfidence
        options.minTrackingConfidence = DefaultConstants.minTrackingConfidence
        options.numHands = 1
        options.gestureRecognizerLiveStreamDelegate = delegate
        return options
    }
}

struct FrameData {
    let rgbData: CMSampleBuffer
    let depthData: AVDepthData
}

struct FirstResult {
    let result: GestureRecognizerResult
    let pose: Pose
}
