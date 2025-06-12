//
//  CameraManager.swift
//  ISMM-GestureTeleop
//
//  Created by Andrew Pasco on 29/05/25.
//
//  Description: Camera management system for synchronized RGB and depth data capture.
//  Handles TrueDepth camera configuration, preview setup, and synchronized frame delivery
//  for real-time gesture recognition applications.
//

import AVFoundation
import UIKit
import CoreImage

/**
 * Camera manager that handles TrueDepth camera configuration and synchronized RGB/depth capture.
 *
 * Features:
 * - TrueDepth camera discovery and configuration
 * - Synchronized RGB and depth data capture
 * - Camera intrinsic matrix delivery
 * - Preview layer management
 * - Thread-safe frame processing
 */
class CameraManager: NSObject, AVCaptureDataOutputSynchronizerDelegate {
    
    // MARK: - Types
    
    /**
     * Enumeration representing camera setup results.
     */
    private enum SessionSetupResult {
        case success
        case notAuthorized
        case configurationFailed
    }
    
    // MARK: - Properties
    
    /// Current setup result status
    private var setupResult: SessionSetupResult = .success
    
    /// Main capture session
    private let session = AVCaptureSession()
    
    /// Session running state flag
    private var isSessionRunning = false
    
    /// Video device input for TrueDepth camera
    private var videoDeviceInput: AVCaptureDeviceInput!
    
    /// Output for RGB video data
    private let videoDataOutput = AVCaptureVideoDataOutput()
    
    /// Output for depth data
    private let depthDataOutput = AVCaptureDepthDataOutput()
    
    /// Synchronizer for coordinated RGB/depth output
    private var outputSynchronizer: AVCaptureDataOutputSynchronizer?

    /// Device discovery session for TrueDepth cameras
    private let videoDeviceDiscoverySession = AVCaptureDevice.DiscoverySession(
        deviceTypes: [.builtInTrueDepthCamera],
        mediaType: .video,
        position: .front
    )

    /// Serial queue for session configuration
    private let sessionQueue = DispatchQueue(label: "session queue")
    
    /// Queue for data output processing
    private let dataOutputQueue = DispatchQueue(label: "data output queue", qos: .userInitiated)
    
    /// Camera preview layer (read-only access)
    public private(set) var previewLayer: AVCaptureVideoPreviewLayer?
    
    /// Container view for preview layer
    private var previewContainerView: UIView?
    
    /// Callback for synchronized frame capture
    var onFrameCaptured: ((CMSampleBuffer, AVDepthData) -> Void)?

    // MARK: - Configuration
    
    /**
     * Configures the camera session and starts capture.
     *
     * Initializes the TrueDepth camera, configures synchronized outputs,
     * and sets up the preview layer in the provided view.
     *
     * - Parameter view: Optional view to display camera preview
     */
    func configure(previewIn view: UIView?) {
        self.previewContainerView = view
        sessionQueue.async {
            self.configureSession()
            self.session.startRunning()
            self.isSessionRunning = self.session.isRunning
        }
    }

    /**
     * Configures the capture session with TrueDepth camera and synchronized outputs.
     *
     * Sets up:
     * - TrueDepth camera input with intrinsic matrix delivery
     * - RGB video output (BGRA format)
     * - Depth data output (Float32 format)
     * - Output synchronization
     * - Preview layer setup
     */
    private func configureSession() {
        guard setupResult == .success else { return }
        
        guard let videoDevice = videoDeviceDiscoverySession.devices.first else {
            print("Could not find any video device")
            setupResult = .configurationFailed
            return
        }
        
        do {
            videoDeviceInput = try AVCaptureDeviceInput(device: videoDevice)
        } catch {
            print("Could not create video device input: \(error)")
            setupResult = .configurationFailed
            return
        }

        session.beginConfiguration()

        guard session.canAddInput(videoDeviceInput) else {
            print("Could not add video device input to the session")
            setupResult = .configurationFailed
            session.commitConfiguration()
            return
        }
        session.addInput(videoDeviceInput)

        // Configure RGB video output
        if session.canAddOutput(videoDataOutput) {
            videoDataOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)]
            session.addOutput(videoDataOutput)
            if let connection = videoDataOutput.connection(with: .video),
               connection.isCameraIntrinsicMatrixDeliverySupported {
                connection.isCameraIntrinsicMatrixDeliveryEnabled = true
            } else {
                print("Camera intrinsic matrix delivery not supported.")
            }
        } else {
            print("Could not add video data output to the session")
            setupResult = .configurationFailed
            session.commitConfiguration()
            return
        }

        // Configure depth data output
        if session.canAddOutput(depthDataOutput) {
            depthDataOutput.isFilteringEnabled = false
            session.addOutput(depthDataOutput)
            if let connection = depthDataOutput.connection(with: .depthData) {
                connection.isEnabled = true
            } else {
                print("No AVCaptureConnection for depth data")
            }
        } else {
            print("Could not add depth data output to the session")
            setupResult = .configurationFailed
            session.commitConfiguration()
            return
        }

        // Configure depth format for highest resolution Float32
        let depthFormats = videoDevice.activeFormat.supportedDepthDataFormats.filter {
            CMFormatDescriptionGetMediaSubType($0.formatDescription) == kCVPixelFormatType_DepthFloat32
        }
        
        if let selectedFormat = depthFormats.max(by: {
            let width1 = CMVideoFormatDescriptionGetDimensions($0.formatDescription).width
            let width2 = CMVideoFormatDescriptionGetDimensions($1.formatDescription).width
            return width1 < width2
        }) {
            do {
                try videoDevice.lockForConfiguration()
                videoDevice.activeDepthDataFormat = selectedFormat
                videoDevice.unlockForConfiguration()
            } catch {
                print("Could not lock device for configuration: \(error)")
                setupResult = .configurationFailed
                session.commitConfiguration()
                return
            }
        }

        // Set up synchronized output
        outputSynchronizer = AVCaptureDataOutputSynchronizer(dataOutputs: [videoDataOutput, depthDataOutput])
        outputSynchronizer?.setDelegate(self, queue: dataOutputQueue)
        
        session.commitConfiguration()
        
        if let view = previewContainerView {
            setupPreview(on: view)
        }
    }
    
    /**
     * Sets up the camera preview layer on the specified view.
     *
     * Creates and configures the preview layer with appropriate styling
     * and adds it to the view hierarchy on the main thread.
     *
     * - Parameter view: The view to contain the preview layer
     */
    private func setupPreview(on view: UIView) {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer?.videoGravity = .resizeAspectFill

        DispatchQueue.main.async {
            guard let previewLayer = self.previewLayer else { return }

            previewLayer.frame = view.bounds

            view.layer.borderColor = UIColor.red.cgColor
            view.layer.borderWidth = 4.0
            view.layer.cornerRadius = 8.0
            view.layer.masksToBounds = true

            view.layer.insertSublayer(previewLayer, at: 0)
        }
    }

    // MARK: - AVCaptureDataOutputSynchronizerDelegate
    
    /**
     * Handles synchronized RGB and depth data delivery.
     *
     * Processes synchronized frame pairs from RGB and depth outputs,
     * validates data integrity, and triggers the frame capture callback.
     *
     * - Parameters:
     *   - synchronizer: The output synchronizer
     *   - synchronizedDataCollection: Collection of synchronized output data
     */
    func dataOutputSynchronizer(_ synchronizer: AVCaptureDataOutputSynchronizer,
                                didOutput synchronizedDataCollection: AVCaptureSynchronizedDataCollection) {
        guard let syncedDepthData = synchronizedDataCollection.synchronizedData(for: depthDataOutput) as? AVCaptureSynchronizedDepthData,
              let syncedVideoData = synchronizedDataCollection.synchronizedData(for: videoDataOutput) as? AVCaptureSynchronizedSampleBufferData else {
            return
        }

        if syncedDepthData.depthDataWasDropped || syncedVideoData.sampleBufferWasDropped {
            if syncedDepthData.depthDataWasDropped {
                print("Depth data was dropped")
            }
            if syncedVideoData.sampleBufferWasDropped {
                print("Video sample buffer was dropped")
            }
            return
        }

        let depthData = syncedDepthData.depthData
        let sampleBuffer = syncedVideoData.sampleBuffer

        // Trigger callback on background queue
        DispatchQueue.global(qos: .userInitiated).async {
            self.onFrameCaptured?(sampleBuffer, depthData)
        }
    }
    
    
// Testing to verify that AVDepthData is z axis from camera plane, not cartesian distance (verified successfully)
//    func dataOutputSynchronizer(_ synchronizer: AVCaptureDataOutputSynchronizer,
//                                   didOutput synchronizedDataCollection: AVCaptureSynchronizedDataCollection) {
//        guard let syncedDepthData = synchronizedDataCollection.synchronizedData(for: depthDataOutput) as? AVCaptureSynchronizedDepthData,
//              !syncedDepthData.depthDataWasDropped
//        else {
//            return
//        }
//
//        let depthData = syncedDepthData.depthData
//        analyzeDepthData(depthData)
//    }
//    
//    func analyzeDepthData(_ depthData: AVDepthData) {
//        let depthMap = depthData.depthDataMap
//        let width = CVPixelBufferGetWidth(depthMap)
//        let height = CVPixelBufferGetHeight(depthMap)
//        let pixelFormat = CVPixelBufferGetPixelFormatType(depthMap)
//        
//        print("Depth map info:")
//        print("  Resolution: \(width) x \(height)")
//        print("  Pixel format: \(pixelFormat)")
//        print("  Data type: \(depthData.depthDataType)")
//        
//        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
//        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
//        
//        // Handle different pixel formats
//        func depthAt(x: Int, y: Int) -> Float32? {
//            guard x >= 0 && x < width && y >= 0 && y < height else { return nil }
//            
//            switch pixelFormat {
//            case kCVPixelFormatType_DepthFloat32:
//                let floatBuffer = unsafeBitCast(CVPixelBufferGetBaseAddress(depthMap), to: UnsafeMutablePointer<Float32>.self)
//                return floatBuffer[y * width + x]
//                
//            case kCVPixelFormatType_DisparityFloat32:
//                let floatBuffer = unsafeBitCast(CVPixelBufferGetBaseAddress(depthMap), to: UnsafeMutablePointer<Float32>.self)
//                let disparity = floatBuffer[y * width + x]
//                // Convert disparity to depth (depth = 1/disparity for normalized disparity)
//                return disparity > 0 ? 1.0 / disparity : Float32.infinity
//                
//            default:
//                print("Unsupported pixel format: \(pixelFormat)")
//                return nil
//            }
//        }
//        
//        let pointsToCheck = [
//            ("Center", width / 2, height / 2),
//            ("Quarter from center-left", width / 4, height / 2),
//            ("Quarter from center-right", 3 * width / 4, height / 2),
//            ("Quarter from center-top", width / 2, height / 4),
//            ("Quarter from center-bottom", width / 2, 3 * height / 4)
//        ]
//        
//        print("\nDepth values (in meters):")
//        for (label, x, y) in pointsToCheck {
//            if let depth = depthAt(x: x, y: y) {
//                print("  \(label) (\(x),\(y)): \(String(format: "%.3f", depth))m")
//            } else {
//                print("  \(label) (\(x),\(y)): Invalid depth")
//            }
//        }
//        print("-------------")
//    }

    // MARK: - Session Control
    
    /**
     * Stops the camera capture session.
     *
     * Safely stops the session on the session queue and updates the running state.
     */
    func stop() {
        sessionQueue.async {
            if self.isSessionRunning {
                self.session.stopRunning()
                self.isSessionRunning = false
            }
        }
    }

    /**
     * Starts the camera capture session.
     *
     * Safely starts the session on the session queue and updates the running state.
     */
    func start() {
        sessionQueue.async {
            if !self.isSessionRunning {
                self.session.startRunning()
                self.isSessionRunning = true
            }
        }
    }
}
