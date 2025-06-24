//
//  ISMM_GestureTeleopApp.swift
//  ISMM-GestureTeleop
//
//  Created by Andrew Pasco on 21/05/2025.
//
//  Main coordinator class for the ISMM Gesture Teleoperation application.
//  This class orchestrates the entire gesture recognition and teleoperation pipeline,
//  including camera management, gesture recognition, 3D pose estimation, and TCP communication.
//
//  The application captures synchronized RGB and depth frames, processes them through
//  MediaPipe gesture recognition, estimates 3D palm poses, and transmits teleoperation
//  commands to remote robot systems via TCP.

import UIKit
import AVFoundation
import MediaPipeTasksVision
import simd
import Spatial
import Foundation
import Accelerate

// MARK: - Configuration Constants
/// Configuration parameters for gesture recognition thresholds and timing
private struct GestureConfig {
    static let maxConfidence: Float = 1.0
    static let minConfidence: Float = 0.0
    /// Rate at which gesture confidence increases when detected
    static let gestureIncrement: Float = 0.04
    /// Rate at which gesture confidence decreases when not detected
    static let gestureDecrement: Float = 0.027
    /// Confidence threshold for triggering general commands
    static let commandThreshold: Float = 0.7
    /// Higher confidence threshold for gripper commands (prevents accidental triggering)
    static let gripperThreshold: Float = 0.9
    /// Duration in milliseconds to display command status messages
    static let commandStatusDisplayDurationMs: Int = 500
    /// Minimum cooldown for gripper and reset commands
    static let commandCooldownMs: Int = 2000
}

// MARK: - Gesture Recognition State
/// Manages the state and confidence levels for recognized gestures
private struct GestureState {
    var openPalmConfidence: Float = 0.0
    var victoryConfidence: Float = 0.0
    var resetConfidence: Float = 0.0
    var isTracking: Bool = false
    var gripperClosed: Bool = false
    var lastValidPose: Pose?
    
    var lastGripperCommandTime: Int?
    var lastResetCommandTime: Int?
    
    /// Updates a confidence value based on whether the gesture is currently detected
    /// - Parameters:
    ///   - current: The current confidence value
    ///   - shouldIncrease: Whether to increase or decrease confidence
    /// - Returns: The updated confidence value, clamped to valid range
    private func updateConfidence(_ current: Float, shouldIncrease: Bool) -> Float {
        if shouldIncrease {
            return min(GestureConfig.maxConfidence, current + GestureConfig.gestureIncrement)
        } else {
            return max(GestureConfig.minConfidence, current - GestureConfig.gestureDecrement)
        }
    }
    
    /// Updates all gesture confidence levels based on current detection results
    /// - Parameters:
    ///   - openPalm: Whether open palm gesture is currently detected
    ///   - victory: Whether victory sign gesture is currently detected
    ///   - reset: Whether reset (horns) gesture is currently detected
    mutating func updateConfidences(openPalm: Bool, victory: Bool, reset: Bool) {
        openPalmConfidence = updateConfidence(openPalmConfidence, shouldIncrease: openPalm)
        victoryConfidence = updateConfidence(victoryConfidence, shouldIncrease: victory)
        resetConfidence = updateConfidence(resetConfidence, shouldIncrease: reset)
    }
    
    /// Checks if gripper command is on cooldown
    /// - Parameter currentTime: Current timestamp in milliseconds
    /// - Returns: true if gripper command can be sent
    func canSendGripperCommand(currentTime: Int) -> Bool {
        guard let lastTime = lastGripperCommandTime else { return true }
        return (currentTime - lastTime) >= GestureConfig.commandCooldownMs
    }
    
    /// Checks if reset command is on cooldown
    /// - Parameter currentTime: Current timestamp in milliseconds
    /// - Returns: true if reset command can be sent
    func canSendResetCommand(currentTime: Int) -> Bool {
        guard let lastTime = lastResetCommandTime else { return true }
        return (currentTime - lastTime) >= GestureConfig.commandCooldownMs
    }
    
    /// Records when gripper command was sent
    /// - Parameter timestamp: Current timestamp in milliseconds
    mutating func recordGripperCommand(timestamp: Int) {
        lastGripperCommandTime = timestamp
    }
    
    /// Records when reset command was sent
    /// - Parameter timestamp: Current timestamp in milliseconds
    mutating func recordResetCommand(timestamp: Int) {
        lastResetCommandTime = timestamp
    }
}

/// Tracks the display status of command messages with timing information
private struct CommandStatus {
    var lastMessage: String?
    var lastTimestamp: Int?
    
    /// Gets the message to display based on timing constraints
    /// - Parameter currentTime: Current timestamp in milliseconds
    /// - Returns: Message to display, or empty string if expired
    func getDisplayMessage(currentTime: Int) -> String {
        guard let message = lastMessage,
              let timestamp = lastTimestamp,
              (currentTime - timestamp) < GestureConfig.commandStatusDisplayDurationMs else {
            return ""
        }
        return message
    }
    
    /// Updates the command status with a new message and timestamp
    /// - Parameters:
    ///   - message: The command message to store
    ///   - timestamp: Current timestamp in milliseconds
    mutating func update(message: String, timestamp: Int) {
        self.lastMessage = message
        self.lastTimestamp = timestamp
    }
}

// MARK: - Main App Class
/// Main coordinator class for gesture-based teleoperation
///
/// This class orchestrates the entire pipeline from camera capture to robot command transmission:
/// 1. Manages synchronized RGB and depth camera capture
/// 2. Processes frames through MediaPipe gesture recognition
/// 3. Estimates 3D palm poses using depth data
/// 4. Translates gestures into robot commands
/// 5. Transmits commands via TCP to remote robot systems
/// 6. Provides visual feedback through overlay UI
class ISMMGestureTeleopApp: NSObject, GestureRecognizerLiveStreamDelegate {
    
    // MARK: - Dependencies
    /// TCP client for communicating with remote robot systems
    private let tcpClient: TCPClient
    /// Camera manager for synchronized RGB and depth capture
    private let cameraManager = CameraManager()
    /// UI overlay for displaying hand landmarks and status messages
    private let resultUIView = ResultOverlayView()
    
    // MARK: - Gesture Recognition
    /// Setup two-stage recognition pipeline and result delegates for each
    private var poseRecognizer: GestureRecognizer!
    private var gestureRecognizer: GestureRecognizer!
    private let poseRecognizerDelegate = GestureRecognizerResultDelegate()
    private let gestureRecognizerDelegate = GestureRecognizerResultDelegate()
    
    // MARK: - Thread-Safe Processing
    /// Ensures only one frame is "active" in processing pipeline at a time
    private let gestureProcessingQueue = DispatchQueue(label: "gestureProcessingQueue")
    private var latestFrame: FrameData?
    private var processingFrame: FrameData?
    private var isProcessingFrame = false
    private var firstResult: FirstResult?
    
    // MARK: - State (Accessed from gestureProcessingQueue)
    /// Current gesture recognition state and confidence levels
    private var gestureState = GestureState()
    /// Status tracking for command display messages
    private var commandStatus = CommandStatus()
    
    // MARK: - Public Interface
    /// Callback for TCP connection status changes
    var onConnectionStatusChange: ((ConnectionStatus) -> Void)? {
        didSet { tcpClient.onStatusChange = onConnectionStatusChange }
    }

    // MARK: - Initialization
    /// Initializes the gesture teleoperation application
    /// - Parameters:
    ///   - host: IP address of the target robot system
    ///   - port: TCP port number for communication
    ///   - previewView: UI view for displaying camera preview and overlays
    init(host: String, port: Int, previewView: UIView) {
        tcpClient = TCPClient(host: host, port: port)
        super.init()
        
        setupGestureRecognizers()
        setupCameraManager(previewView: previewView)
        setupOverlayView(in: previewView)
    }
    
    /// Configures the MediaPipe gesture recognizers with appropriate delegates and options
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
    
    /// Configures the camera manager with frame capture callback
    /// - Parameter previewView: UI view for camera preview display
    private func setupCameraManager(previewView: UIView) {
        cameraManager.onFrameCaptured = { [weak self] sampleBuffer, depthData in
            self?.handleFrame(sampleBuffer: sampleBuffer, depthData: depthData)
        }
        cameraManager.configure(previewIn: previewView)
    }
    
    /// Sets up the UI overlay view for displaying hand landmarks and status messages
    /// - Parameter previewView: Parent view for the overlay
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
    
    /// Handles incoming camera frames in a thread-safe manner
    ///
    /// This method implements a non-blocking processing pipeline that prevents frame drops
    /// while ensuring thread safety. If a frame is currently being processed, new frames
    /// are cached and processed after the current frame completes.
    /// - Parameters:
    ///   - sampleBuffer: RGB video frame from the camera
    ///   - depthData: Synchronized depth data from the camera
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
            
            /// Send to pose recognition
            do {
                let image = try MPImage(sampleBuffer: sampleBuffer, orientation: .right)
                try self.poseRecognizer.recognizeAsync(image: image, timestampInMilliseconds: timestampMillis)
            } catch {
                print("Pose recognition error: \(error)")
                self.finishProcessing(previewResult: nil, pose: nil, K: nil, timestamp: timestampMillis, gesture: nil)
            }
        }
    }
    
    // MARK: - Result Handlers
    
    /// Handles results from pose recognition and initiates 3D pose estimation
    /// - Parameters:
    ///   - result: MediaPipe gesture recognition result containing hand landmarks
    ///   - timestampInMilliseconds: Frame timestamp for synchronization
    private func handlePoseResult(result: GestureRecognizerResult?, timestampInMilliseconds: Int?) {
        guard let result = result,
              let processingFrame = processingFrame,
              let timestamp = timestampInMilliseconds,
              !result.landmarks.isEmpty,
              let pose = PoseEstimator.computePose(result: result, frameData: processingFrame) else {
            finishProcessing(previewResult: nil, pose: nil, K: nil, timestamp: timestampInMilliseconds, gesture: nil)
            return
        }
        
        // apply SLERP from last valid pose to newly computed pose (only if we have a last valid pose)
        // Save pose-slerp as last valid pose
        if let lastPose = gestureState.lastValidPose {
            // Verify no large/jerky movement or faulty readings
            let lastPoseQuat = simd_quatd(lastPose.rot)
            let newPoseQuat = simd_quatd(pose.rot)
            let clampedDot = min(1.0, max(-1.0, abs(simd_dot(lastPoseQuat.vector, newPoseQuat.vector))))
            let angleDiff = 2 * acos(clampedDot)
            
            let degDiff = angleDiff * 180/Double.pi
            //print("Angle diff, deg: \(degDiff)")
            
            let posDiff = length(lastPose.translation - pose.translation)
            //print("Pos diff, m: \(posDiff)")
            
            if angleDiff > DefaultConstants.MAX_ANGLE_DIFF || posDiff > DefaultConstants.MAX_POS_DIFF {
                print("rejecting pose due to large diff")
                finishProcessing(previewResult: nil, pose: nil, K: nil, timestamp: timestampInMilliseconds, gesture: nil)
                if gestureState.isTracking {
                    return
                } else {
                    gestureState.lastValidPose = nil
                    return
                }
            }
            
            // SLERP for orientation filtering
            let lastRot3D = Rotation3D(lastPoseQuat)
            let newRot3D = Rotation3D(newPoseQuat)
            
            let rotSLERP = Rotation3D.slerp(from:lastRot3D, to:newRot3D, t:DefaultConstants.SLERP_T)
            let slerpQuat = rotSLERP.quaternion
            let slerpRot = R_from_quat(slerpQuat)
            
            // EMA for position filtering
            let emaPos = posEMA(old: lastPose.translation, new: pose.translation)
            
            gestureState.lastValidPose = Pose(translation: emaPos, rot: slerpRot)
        } else {
            print("setting new lastValidPose")
            gestureState.lastValidPose = pose
        }
        
        guard let filteredPose = gestureState.lastValidPose else {
            print("filtered pose issue")
            return
        }
    
        firstResult = FirstResult(result: result, pose: filteredPose)
        recognizeGesture(with: filteredPose, timestamp: timestamp)
    }
    
    /// Performs gesture recognition on a reoriented image based on hand pose
    /// - Parameters:
    ///   - pose: 3D pose of the detected hand
    ///   - timestamp: Frame timestamp in milliseconds
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
    
    /// Handles final gesture recognition results and prepares for processing completion
    /// - Parameters:
    ///   - result: MediaPipe gesture recognition result
    ///   - timestampInMilliseconds: Frame timestamp for synchronization
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
        
        print("gesture: \(recognizedGesture)")
        
        finishProcessing(previewResult: previewResult, pose: pose, K: K, timestamp: timestampInMilliseconds, gesture: recognizedGesture)
    }

    // MARK: - Processing Completion (Thread-Safe Continuation)
    /// Completes frame processing by updating UI and continuing the processing pipeline
    /// - Parameters:
    ///   - previewResult: MediaPipe result for UI display
    ///   - pose: Estimated 3D pose of the hand
    ///   - K: Camera intrinsic matrix
    ///   - timestamp: Frame timestamp in milliseconds
    ///   - gesture: Recognized gesture name
    private func finishProcessing(previewResult: GestureRecognizerResult?, pose: Pose?, K: matrix_float3x3?, timestamp: Int?, gesture: String?) {
        let currentTime = timestamp ?? Int(Date().timeIntervalSince1970 * 1000)
        
        // Process gesture and get status message
        if let statusMessage = processGesture(gesture, pose: pose, timestamp: currentTime) {
            commandStatus.update(message: statusMessage, timestamp: currentTime)
        }
        
        // Determine display message
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
    
    /// Processes recognized gestures and generates appropriate robot commands
    /// - Parameters:
    ///   - gesture: Name of the recognized gesture
    ///   - pose: 3D pose of the hand
    /// - Returns: Status message for UI display, if any
    private func processGesture(_ gesture: String?, pose: Pose?, timestamp: Int) -> String? {
        updateGestureConfidences(for: gesture)
        
        // Check commands in priority order, now with cooldown
        if let gripperCommand = processGripperCommand(timestamp: timestamp) {
            return gripperCommand
        }
        
        if let resetCommand = processResetCommand(timestamp: timestamp) {
            return resetCommand
        }
        
        return processTrackingCommand(pose: pose)
    }
    
    /// Updates gesture confidence levels based on current detection results
    /// - Parameter gesture: Name of the currently detected gesture
    private func updateGestureConfidences(for gesture: String?) {
        gestureState.updateConfidences(
            openPalm: gesture == "Open_Palm",
            victory: gesture == "Victory",
            reset: gesture == "ILoveYou"
        )
    }
    
    /// Processes gripper commands based on fist gesture confidence
    /// - Returns: Status message if gripper command was triggered
    private func processGripperCommand(timestamp: Int) -> String? {
        guard gestureState.victoryConfidence > GestureConfig.gripperThreshold,
              gestureState.canSendGripperCommand(currentTime: timestamp) else {
            return nil
        }
        
        sendCommand(.gripper, pose: nil)
        gestureState.victoryConfidence = 0
        gestureState.gripperClosed.toggle()
        gestureState.recordGripperCommand(timestamp: timestamp)
        
        let action = gestureState.gripperClosed ? "Closing" : "Opening"
        print("\(action.lowercased()) gripper")
        return "\(action) Gripper"
    }
    
    /// Processes reset commands based on reset (horns) gesture confidence
    /// - Returns: Status message if reset command was triggered
    private func processResetCommand(timestamp: Int) -> String? {
        guard gestureState.resetConfidence > GestureConfig.commandThreshold,
              gestureState.canSendResetCommand(currentTime: timestamp) else {
            return nil
        }
        
        sendCommand(.reset, pose: nil)
        gestureState.resetConfidence = 0
        gestureState.recordResetCommand(timestamp: timestamp)
        print("reset")
        return "Resetting"
    }
    
    /// Processes tracking commands based on open palm gesture confidence
    /// - Parameter pose: Current 3D pose of the hand
    /// - Returns: Status message if tracking command was triggered
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
    /// Sends teleoperation commands to the remote robot system via TCP
    /// - Parameters:
    ///   - command: Type of command to send
    ///   - pose: 3D pose data to include with the command (if applicable)
    private func sendCommand(_ command: TeleopCommand, pose: Pose?) {
        var message: String = command.rawValue
        
        // Handle different command types
        switch command {
        case .gripper, .reset:
            // These commands don't need pose data
            break
            
        case .end:
            // Always use lastValidPose for end commands
            guard let lastPose = gestureState.lastValidPose else { return }
            let sendPose = transformToRobotFrame(lastPose)
            message += formatPoseForTransmission(sendPose)
            gestureState.lastValidPose = nil
            
        case .start, .track:
            // Use current pose for tracking commands
            guard let currentPose = pose else { return }
            let sendPose = transformToRobotFrame(currentPose)
            message += formatPoseForTransmission(sendPose)
        }
        
        //message += "\n" // comment if sending to real system
        
        if let dataToSend = message.data(using: .utf8) {
            tcpClient.send(data: dataToSend) // comment if testing in place
        }
    }
    
    /// Transforms a pose from camera coordinates to robot coordinates
    /// - Parameter cameraFramePose: Pose in camera coordinate system
    /// - Returns: Pose transformed to robot coordinate system
    private func transformToRobotFrame(_ cameraFramePose: Pose) -> Pose {
        let rotAB = rotx(Double.pi/2) * rotz(0) // rotz(0) for landscape, rotz(.pi/2) for portrait?
        let poseMat = poseMatrix(pos: cameraFramePose.translation, rot: cameraFramePose.rot)
        let transformedMat = transformFromRot(rotAB).transpose * poseMat
        let (newTrans, newRot) = posRotFromMat(transformedMat)
        return Pose(translation: newTrans, rot: newRot)
    }

    /// Creates a formatted pose string for TCP transmission
    /// - Parameter pose: Pose to format (should be in robot coordinates)
    /// - Returns: String containing position and quaternion values
    private func formatPoseForTransmission(_ pose: Pose) -> String {
        let quat = simd_quaternion(pose.rot)
        return " \(Float(pose.translation.x)) \(Float(pose.translation.y)) \(Float(pose.translation.z)) \(Float(quat.vector.w)) \(Float(quat.vector.x)) \(Float(quat.vector.y)) \(Float(quat.vector.z))"
    }
    
    // MARK: - UI Updates
        
    /// Updates the hand preview overlay with landmarks and status messages
    /// - Parameters:
    ///   - firstResult: MediaPipe result containing hand landmarks
    ///   - message: Status message to display
    ///   - pose: 3D pose for coordinate frame visualization
    ///   - intrinsics: Camera intrinsic matrix for projection
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
    
    /// Extracts palm landmark points for UI display
    /// - Parameter landmarks: Array of normalized hand landmarks from MediaPipe
    /// - Returns: Array of screen coordinate points for palm landmarks
    private func extractPalmPoints(from landmarks: [NormalizedLandmark]) -> [CGPoint] {
        var points: [CGPoint] = []
        
        // try drawing all points
        for landmark in landmarks {
            let x = Int(Float(DefaultConstants.PREVIEW_DIMS.WIDTH) * landmark.y)
            let y = Int(Float(DefaultConstants.PREVIEW_DIMS.HEIGHT) * landmark.x)
            points.append(CGPoint(x: x, y: y))
        }
        

//        for index in DefaultConstants.PALM_INDICES {
//            guard index < landmarks.count else { continue }
//            
//            let landmark = landmarks[index]
//            let x = Int(Float(DefaultConstants.PREVIEW_DIMS.WIDTH) * landmark.y)
//            let y = Int(Float(DefaultConstants.PREVIEW_DIMS.HEIGHT) * landmark.x)
//            points.append(CGPoint(x: x, y: y))
//        }
        
        return points
    }
    
    // MARK: - Utility Methods
    
    func posEMA(old: simd_double3, new: simd_double3) -> simd_double3 {
        return DefaultConstants.EMA_ALPHA * new + (1.0 - DefaultConstants.EMA_ALPHA) * old
    }
    
    /// Initiates connection to the target system
    func connectToServer() {
        tcpClient.connect()
    }
    
    /// Provides access to the camera preview layer for UI integration
    /// - Returns: AVCaptureVideoPreviewLayer for camera preview display
    func getPreviewLayer() -> AVCaptureVideoPreviewLayer? {
        return cameraManager.previewLayer
    }
    
    /// Determines correct orientation for second stage of gesture processing based on vector from palm centroid to wrist
    ///  - Parameter vector: CGVector from palm centroid to wrist keypoint in original camera frame
    ///  - Returns: UIImage.Orientation for passing into second stage
    private func getImageReorientation(for vector: CGVector) -> UIImage.Orientation {
        let absX = abs(vector.dx)
        let absY = abs(vector.dy)

        if absX > absY {
            return vector.dx >= 0 ? .right : .left
        } else {
            return vector.dy >= 0 ? .up : .down
        }
    }
    
    /// Static function to extract frame instrinsics matrix from image buffer
    /// - Parameter sampleBuffer: Image buffer
    /// - Returns: matrix\_float3x3 with standard camera intrinsics format
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
    
    /// Create options for initialization of a MediaPipe GestureRecognizer
    /// - Parameter delegate: GestureRecognizerLiveStreamDelegate to be associated with the created GestureRecognizer
    /// - Returns GestureRecognizerOptions
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
