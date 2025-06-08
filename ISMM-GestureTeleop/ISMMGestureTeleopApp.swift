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

// MARK: - Configuration Constants
private struct GestureConfig {
    static let maxConfidence: Float = 1.0
    static let minConfidence: Float = 0.0
    static let gestureIncrement: Float = 0.04
    static let gestureDecrement: Float = 0.09
    static let commandThreshold: Float = 0.7
    static let gripperThreshold: Float = 0.9
    static let commandStatusDisplayDurationMs: Int = 500
}

// MARK: - Gesture Recognition State
private struct GestureState {
    var openPalmConfidence: Float = 0.0
    var fistConfidence: Float = 0.0
    var victoryConfidence: Float = 0.0
    var isTracking: Bool = false
    var gripperClosed: Bool = false
    
    private func updateConfidence(_ current: Float, shouldIncrease: Bool) -> Float {
        if shouldIncrease {
            return min(GestureConfig.maxConfidence, current + GestureConfig.gestureIncrement)
        } else {
            return max(GestureConfig.minConfidence, current - GestureConfig.gestureDecrement)
        }
    }
    
    mutating func updateConfidences(openPalm: Bool, fist: Bool, victory: Bool) {
        openPalmConfidence = updateConfidence(openPalmConfidence, shouldIncrease: openPalm)
        fistConfidence = updateConfidence(fistConfidence, shouldIncrease: fist)
        victoryConfidence = updateConfidence(victoryConfidence, shouldIncrease: victory)
    }
}

// MARK: - Command Status Tracking
private struct CommandStatus {
    var lastMessage: String?
    var lastTimestamp: Int?
    
    func getDisplayMessage(currentTime: Int) -> String {
        guard let message = lastMessage,
              let timestamp = lastTimestamp,
              (currentTime - timestamp) < GestureConfig.commandStatusDisplayDurationMs else {
            return ""
        }
        return message
    }
    
    mutating func update(message: String, timestamp: Int) {
        self.lastMessage = message
        self.lastTimestamp = timestamp
    }
}

// MARK: - Main App Class
class ISMMGestureTeleopApp: NSObject, GestureRecognizerLiveStreamDelegate {
    
    // MARK: - Dependencies
    private let tcpClient: TCPClient
    private let cameraManager = CameraManager()
    private let resultUIView = ResultOverlayView()
    
    // MARK: - Gesture Recognition
    private var poseRecognizer: GestureRecognizer!
    private var gestureRecognizer: GestureRecognizer!
    private let poseRecognizerDelegate = GestureRecognizerResultDelegate()
    private let gestureRecognizerDelegate = GestureRecognizerResultDelegate()
    
    // MARK: - Thread-Safe Processing State (CRITICAL: Access only from gestureProcessingQueue)
    private let gestureProcessingQueue = DispatchQueue(label: "gestureProcessingQueue")
    private var latestFrame: FrameData?
    private var processingFrame: FrameData?
    private var isProcessingFrame = false
    private var firstResult: FirstResult?
    
    // MARK: - State (Accessed from gestureProcessingQueue)
    private var gestureState = GestureState()
    private var commandStatus = CommandStatus()
    
    // MARK: - Public Interface
    var onConnectionStatusChange: ((ConnectionStatus) -> Void)? {
        didSet { tcpClient.onStatusChange = onConnectionStatusChange }
    }

    // MARK: - Initialization
    init(host: String, port: Int, previewView: UIView) {
        tcpClient = TCPClient(host: host, port: port)
        super.init()
        
        setupGestureRecognizers()
        setupCameraManager(previewView: previewView)
        setupOverlayView(in: previewView)
    }
    
    private func setupGestureRecognizers() {
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
    }
    
    private func setupCameraManager(previewView: UIView) {
        cameraManager.onFrameCaptured = { [weak self] sampleBuffer, depthData in
            self?.handleFrame(sampleBuffer: sampleBuffer, depthData: depthData)
        }
        cameraManager.configure(previewIn: previewView)
    }
    
    private func setupOverlayView(in previewView: UIView) {
        resultUIView.frame = previewView.bounds
        resultUIView.backgroundColor = .clear
        resultUIView.isUserInteractionEnabled = false
        
        DispatchQueue.main.async {
            previewView.addSubview(self.resultUIView)
            self.resultUIView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            previewView.bringSubviewToFront(self.resultUIView)
        }
    }

    // MARK: - Frame Processing (Thread-Safe Pipeline)
    private func handleFrame(sampleBuffer: CMSampleBuffer, depthData: AVDepthData) {
        // CRITICAL: This maintains the thread-safe processing pipeline
        gestureProcessingQueue.async {
            if self.isProcessingFrame {
                // Store latest frame while processing - this prevents blocking the camera
                self.latestFrame = FrameData(rgbData: sampleBuffer, depthData: depthData)
                return
            }
            
            self.isProcessingFrame = true
            let timestampMillis = Int(CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds * 1000)
            self.processingFrame = FrameData(rgbData: sampleBuffer, depthData: depthData)
            
            self.recognizePose(from: sampleBuffer, timestamp: timestampMillis)
        }
    }
    
    private func recognizePose(from sampleBuffer: CMSampleBuffer, timestamp: Int) {
        do {
            let image = try MPImage(sampleBuffer: sampleBuffer, orientation: .right)
            try poseRecognizer.recognizeAsync(image: image, timestampInMilliseconds: timestamp)
        } catch {
            print("Pose recognition error: \(error)")
            finishProcessing(previewResult: nil, pose: nil, K: nil, timestamp: timestamp, gesture: nil)
        }
    }
    
    // MARK: - Result Handlers
    private func handlePoseResult(result: GestureRecognizerResult?, timestampInMilliseconds: Int?) {
        guard let result = result,
              let processingFrame = processingFrame,
              let timestamp = timestampInMilliseconds,
              !result.landmarks.isEmpty,
              let pose = PoseEstimator.computePose(result: result, frameData: processingFrame) else {
            finishProcessing(previewResult: nil, pose: nil, K: nil, timestamp: timestampInMilliseconds, gesture: nil)
            return
        }
        
        firstResult = FirstResult(result: result, pose: pose)
        recognizeGesture(with: pose, timestamp: timestamp)
    }
    
    private func recognizeGesture(with pose: Pose, timestamp: Int) {
        guard let rgb = processingFrame?.rgbData else {
            finishProcessing(previewResult: nil, pose: nil, K: nil, timestamp: timestamp, gesture: nil)
            return
        }
        
        let xAxis = pose.rot.columns.0
        let xAxisXY = CGVector(dx: xAxis.x, dy: xAxis.y)
        let reorientation = getImageReorientation(for: xAxisXY)
        
        do {
            let image = try MPImage(sampleBuffer: rgb, orientation: reorientation)
            try gestureRecognizer.recognizeAsync(image: image, timestampInMilliseconds: timestamp)
        } catch {
            print("Gesture recognition error: \(error)")
            finishProcessing(previewResult: nil, pose: nil, K: nil, timestamp: timestamp, gesture: nil)
        }
    }
    
    private func handleGestureResult(result: GestureRecognizerResult?, timestampInMilliseconds: Int) {
        guard let result = result,
              let rgb = processingFrame?.rgbData,
              let recognizedGesture = result.gestures.first?[0].categoryName,
              let pose = firstResult?.pose,
              let previewResult = firstResult?.result,
              let K = Self.getFrameIntrinsics(from: rgb) else {
            finishProcessing(previewResult: nil, pose: nil, K: nil, timestamp: timestampInMilliseconds, gesture: nil)
            return
        }
        
        finishProcessing(previewResult: previewResult, pose: pose, K: K, timestamp: timestampInMilliseconds, gesture: recognizedGesture)
    }

    // MARK: - Processing Completion (Thread-Safe Continuation)
    private func finishProcessing(previewResult: GestureRecognizerResult?, pose: Pose?, K: matrix_float3x3?, timestamp: Int?, gesture: String?) {
        // Process gesture and get status message
        if let statusMessage = processGesture(gesture, pose: pose) {
            let currentTime = timestamp ?? Int(Date().timeIntervalSince1970 * 1000)
            commandStatus.update(message: statusMessage, timestamp: currentTime)
        }
        
        // Determine display message
        let currentTime = timestamp ?? Int(Date().timeIntervalSince1970 * 1000)
        let displayMessage = commandStatus.getDisplayMessage(currentTime: currentTime)
        
        // Update UI on main thread
        DispatchQueue.main.async {
            self.updateHandPreview(firstResult: previewResult, message: displayMessage, pose: pose, intrinsics: K)
        }
        
        // CRITICAL: Continue processing pipeline on gesture queue
        gestureProcessingQueue.async {
            self.isProcessingFrame = false
            if let newFrame = self.latestFrame {
                self.latestFrame = nil
                self.handleFrame(sampleBuffer: newFrame.rgbData, depthData: newFrame.depthData)
            }
        }
    }
    
    // MARK: - Gesture Processing
    private func processGesture(_ gesture: String?, pose: Pose?) -> String? {
        updateGestureConfidences(for: gesture)
        
        // Check commands in priority order
        if let gripperCommand = processGripperCommand() {
            return gripperCommand
        }
        
        if let resetCommand = processResetCommand() {
            return resetCommand
        }
        
        return processTrackingCommand(pose: pose)
    }
    
    private func updateGestureConfidences(for gesture: String?) {
        gestureState.updateConfidences(
            openPalm: gesture == "Open_Palm",
            fist: gesture == "Closed_Fist",
            victory: gesture == "Victory"
        )
    }
    
    private func processGripperCommand() -> String? {
        guard gestureState.fistConfidence > GestureConfig.gripperThreshold else { return nil }
        
        sendCommand(.gripper, pose: nil)
        gestureState.fistConfidence = 0
        gestureState.gripperClosed.toggle()
        
        let action = gestureState.gripperClosed ? "Closing" : "Opening"
        print("\(action.lowercased()) gripper")
        return "\(action) Gripper"
    }
    
    private func processResetCommand() -> String? {
        guard gestureState.victoryConfidence > GestureConfig.commandThreshold else { return nil }
        
        sendCommand(.reset, pose: nil)
        gestureState.victoryConfidence = 0
        print("reset")
        return "Resetting"
    }
    
    private func processTrackingCommand(pose: Pose?) -> String? {
        if gestureState.openPalmConfidence > GestureConfig.commandThreshold {
            if !gestureState.isTracking {
                sendCommand(.start, pose: pose)
                gestureState.isTracking = true
                print("start tracking")
                return "Tracking"
            } else {
                sendCommand(.track, pose: pose)
                return "Tracking"
            }
        } else if gestureState.isTracking {
            sendCommand(.end, pose: pose)
            gestureState.isTracking = false
            print("end tracking")
            return "Ending Tracking"
        }
        
        return nil
    }
    
    // MARK: - Command Sending
    private func sendCommand(_ command: TeleopCommand, pose: Pose?) {
        // Don't send track command if hand goes offscreen
        if command == .track && pose == nil {
            return
        }
        
        var message = command.rawValue
        
        if let pose = pose, [.start, .end, .track].contains(command) {
            let quat = simd_quaternion(pose.rot)
            message += " \(pose.translation.x) \(pose.translation.y) \(pose.translation.z) \(quat.vector.w) \(quat.vector.x) \(quat.vector.y) \(quat.vector.z)"
        }

        if let dataToSend = message.data(using: .utf8) {
            // tcpClient.send(data: dataToSend)
        }
    }
    
    // MARK: - UI Updates
    private func updateHandPreview(firstResult: GestureRecognizerResult?, message: String, pose: Pose?, intrinsics: matrix_float3x3?) {
        // Handle case where we have a message but no hand data
        guard let handLandmarks = firstResult?.landmarks.first,
              let pose = pose,
              let intrinsics = intrinsics else {
            resultUIView.update(points: nil, messageLabel: message.isEmpty ? nil : message,
                              centroid3D: nil, axes3D: nil, intrinsics: nil)
            return
        }
        
        let pointsToDraw = extractPalmPoints(from: handLandmarks)
        resultUIView.update(points: pointsToDraw, messageLabel: message.isEmpty ? nil : message,
                          centroid3D: pose.translation, axes3D: pose.rot, intrinsics: intrinsics)
    }
    
    private func extractPalmPoints(from landmarks: [NormalizedLandmark]) -> [CGPoint] {
        var points: [CGPoint] = []
        
        for index in DefaultConstants.PALM_INDICES {
            guard index < landmarks.count else { continue }
            
            let landmark = landmarks[index]
            let x = Int(Float(DefaultConstants.PREVIEW_DIMS.WIDTH) * landmark.y)
            let y = Int(Float(DefaultConstants.PREVIEW_DIMS.HEIGHT) * landmark.x)
            points.append(CGPoint(x: x, y: y))
        }
        
        return points
    }
    
    // MARK: - Utility Methods
    func connectToServer() {
        tcpClient.connect()
    }
    
    func getPreviewLayer() -> AVCaptureVideoPreviewLayer? {
        return cameraManager.previewLayer
    }
    
    private func getImageReorientation(for vector: CGVector) -> UIImage.Orientation {
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

// MARK: - Supporting Types
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
