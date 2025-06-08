//
//  ISMM_GestureTeleopApp.swift
//  ISMM-GestureTeleop
//
//  Created by Andrew Pasco on 21/05/2025.
//
// TODO: Refactor and update readme?
// Average frame processing time: 34ms

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
    
    // Buffers for gesture detection
    private var openPalmConfidence: Float = 0.0
    private var fistConfidence: Float = 0.0
    private var victoryConfidence: Float = 0.0

    // Constants
    private let maxConfidence: Float = 1.0
    private let minConfidence: Float = 0.0
    private let gestureIncrement: Float = 0.04
    private let gestureDecrement: Float = 0.03
    private let commandThreshold: Float = 0.7
    private let gripperThreshold: Float = 0.9

    // State tracking
    private var isTracking: Bool = false
    
    private var lastCommandStatus: String?
    private var lastCommandTimestamp: Int?
    private let commandStatusDisplayDuration: Int = 500  // ms
    private var gripperClosed: Bool = false

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
                self.finishProcessing(previewResult: nil, pose: nil, K: nil, timestamp: nil, gesture: nil)
            }
        }
    }
    
    // Closure method which takes the async result from the poseRecognizerDelegate
    private func handlePoseResult(result: GestureRecognizerResult?,
            timestampInMilliseconds: Int?) {
        // Ensure successful result
        guard let result = result,
              let processingFrame = processingFrame,
              !result.landmarks.isEmpty else {
            print("No hand detected or no valid frame")
            finishProcessing(previewResult: nil, pose: nil, K: nil, timestamp: nil, gesture: nil)
            return
        }
            
        // Compute palm pose
        guard let newPose = PoseEstimator.computePose(result: result, frameData: processingFrame), let timestampInMilliseconds = timestampInMilliseconds else {
            //print("Pose compute failure")
            finishProcessing(previewResult: nil, pose: nil, K: nil, timestamp: nil, gesture: nil)
            return
        }
        
        firstResult = FirstResult(result: result, pose: newPose)
        
        // get correct orientation from initially detected pose then send cached frame to other recognizer
        let xAxis = newPose.rot.columns.0
        let xAxisXY = CGVector(dx:xAxis.x, dy:xAxis.y)
        let reorientation = getImageReorientation(for: xAxisXY)
        
        let rgb = processingFrame.rgbData
        
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
            finishProcessing(previewResult: nil, pose: nil, K: nil, timestamp: nil, gesture: nil)
        }
        
    }
    
    private func handleGestureResult(result: GestureRecognizerResult?, timestampInMilliseconds: Int) {
        // Ensure successful result
        //print("handle gesture result")
        guard let result = result,
              let rgb = processingFrame?.rgbData,
              let recognizedGesture = result.gestures.first?[0].categoryName,
              let pose = firstResult?.pose,
              let previewResult = firstResult?.result,
              let K = ISMMGestureTeleopApp.getFrameIntrinsics(from: rgb) else {
            //print("gesture result guard catch")
            finishProcessing(previewResult: nil, pose: nil, K: nil, timestamp: timestampInMilliseconds, gesture: nil)
            return
        }
        
        self.finishProcessing(previewResult: previewResult, pose: pose, K: K, timestamp: timestampInMilliseconds, gesture: recognizedGesture)
    }

    private func finishProcessing(previewResult: GestureRecognizerResult?, pose: Pose?, K: matrix_float3x3?, timestamp: Int?, gesture: String?) {
        // Passing for landmark drawing
        gestureProcessingQueue.async {
            self.isProcessingFrame = false
            if let newFrame = self.latestFrame {
                self.latestFrame = nil
                self.handleFrame(sampleBuffer: newFrame.rgbData, depthData: newFrame.depthData)
            }
        }
        
        guard let previewResult = previewResult,
              let pose = pose,
              let K = K,
              let timestamp = timestamp,
              let gesture = gesture else {
            DispatchQueue.main.async {
                self.updateHandPreview(firstResult: previewResult, message: nil, pose: pose, intrinsics: K)
            }
            processGesture(gesture, pose: pose)
            return
        }
        
        // Run filtered gesture-to-command logic
        // Process command logic and get UI label string
        let status = processGesture(gesture, pose: pose)
        if let status = status {
            lastCommandStatus = status
            lastCommandTimestamp = timestamp
        }
        
        let displayStatus: String
        if let lastStatus = lastCommandStatus,
           let lastTime = lastCommandTimestamp,
           (timestamp - lastTime) < commandStatusDisplayDuration {
            displayStatus = lastStatus
        } else {
            displayStatus = ""
        }
        
        DispatchQueue.main.async {
            self.updateHandPreview(firstResult: previewResult, message: displayStatus, pose: pose, intrinsics: K)
        }
    }
    
    private func processGesture(_ gesture: String?, pose: Pose?) -> String? {
        // Update confidence levels
        updateConfidence(&openPalmConfidence, gesture == "Open_Palm")
        updateConfidence(&fistConfidence, gesture == "Closed_Fist")
        updateConfidence(&victoryConfidence, gesture == "Victory")

        // Gripper command
        if fistConfidence > gripperThreshold {
            if !gripperClosed {
                sendCommand(.gripper, pose: nil)
                fistConfidence = 0
                gripperClosed = !gripperClosed
                print("closing")
                return "Closing Gripper"
            } else {
                sendCommand(.gripper, pose: nil)
                fistConfidence = 0
                gripperClosed = !gripperClosed
                print("opening")
                return "Opening Gripper"
            }
        }
        
        // Reset command
        if victoryConfidence > commandThreshold {
            sendCommand(.reset, pose: nil)
            victoryConfidence = 0
            print("reset")
            return "Resetting"
        }

        // Tracking state logic
        if openPalmConfidence > commandThreshold {
            if !isTracking {
                sendCommand(.start, pose: pose)
                isTracking = true
                print("start")
                return "Tracking"
            } else {
                sendCommand(.track, pose: pose)
                return "Tracking"
            }
        } else {
            if isTracking {
                sendCommand(.end, pose: pose)
                isTracking = false
                print("end")
                return "Ending Tracking"
            }
        }
        return nil
    }
    
    private func updateConfidence(_ buffer: inout Float, _ increase: Bool) {
        if increase {
            buffer = min(maxConfidence, buffer + gestureIncrement)
        } else {
            buffer = max(minConfidence, buffer - gestureDecrement)
        }
    }
    
    func connectToServer() {
        tcpClient.connect()
    }
    
    private func sendCommand(_ command: TeleopCommand, pose: Pose?) {
        var message: String = command.rawValue
        
        if let pose = pose, [.start, .end, .track].contains(command) {
            let quat = simd_quaternion(pose.rot)
            message += " \(pose.translation.x) \(pose.translation.y) \(pose.translation.z) \(quat.vector.w) \(quat.vector.x) \(quat.vector.y) \(quat.vector.z)"
        }

        if let dataToSend = message.data(using: .utf8) {
            //tcpClient.send(data: dataToSend)
        }
    }
    
    private func updateHandPreview(firstResult: GestureRecognizerResult?, message: String?, pose: Pose?, intrinsics: matrix_float3x3?) {
        // get hand landmarks from the original recognition
        guard let handLandmarks = firstResult?.landmarks.first,
              let message = message,
              let pose = pose,
              let intrinsics = intrinsics else {
            //print("No hand landmarks detected.")
            DispatchQueue.main.async {
                self.resultUIView.update(points: nil, messageLabel: nil, centroid3D: nil, axes3D: nil, intrinsics: nil)
            }
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
            self.resultUIView.update(points: pointsToDraw, messageLabel: message, centroid3D: pose.translation, axes3D: pose.rot, intrinsics: intrinsics)
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

enum TeleopCommand: String {
    case start = "<Start>"
    case end = "<End>"
    case track = "<Track>"
    case gripper = "<Gripper>"
    case reset = "<Reset>"
}
