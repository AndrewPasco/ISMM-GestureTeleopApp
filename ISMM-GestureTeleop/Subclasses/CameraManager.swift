//
//  CameraManager.swift
//  ISMM-GestureTeleop
//
//  Created by Andrew Pasco on 29/05/25.
//

import AVFoundation
import UIKit
import CoreImage

import AVFoundation
import UIKit

class CameraManager: NSObject, AVCaptureDataOutputSynchronizerDelegate {
    
    private enum SessionSetupResult {
        case success
        case notAuthorized
        case configurationFailed
    }
    
    private var setupResult: SessionSetupResult = .success
    private let session = AVCaptureSession()
    private var isSessionRunning = false
    
    private var videoDeviceInput: AVCaptureDeviceInput!
    private let videoDataOutput = AVCaptureVideoDataOutput()
    private let depthDataOutput = AVCaptureDepthDataOutput()
    private var outputSynchronizer: AVCaptureDataOutputSynchronizer?

    private let videoDeviceDiscoverySession = AVCaptureDevice.DiscoverySession(
        deviceTypes: [.builtInTrueDepthCamera],
        mediaType: .video,
        position: .front
    )

    private let sessionQueue = DispatchQueue(label: "session queue")
    private let dataOutputQueue = DispatchQueue(label: "data output queue", qos: .userInitiated)
    
    public private(set) var previewLayer: AVCaptureVideoPreviewLayer?
    private var previewContainerView: UIView?
    
    var onFrameCaptured: ((CMSampleBuffer, AVDepthData) -> Void)?

    func configure(previewIn view: UIView?) {
        self.previewContainerView = view
        sessionQueue.async {
            self.configureSession()
            self.session.startRunning()
            self.isSessionRunning = self.session.isRunning
        }
    }

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
        //session.sessionPreset = .vga640x480

        guard session.canAddInput(videoDeviceInput) else {
            print("Could not add video device input to the session")
            setupResult = .configurationFailed
            session.commitConfiguration()
            return
        }
        session.addInput(videoDeviceInput)

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

        outputSynchronizer = AVCaptureDataOutputSynchronizer(dataOutputs: [videoDataOutput, depthDataOutput])
        outputSynchronizer?.setDelegate(self, queue: dataOutputQueue)
        
        session.commitConfiguration()
        
        if let view = previewContainerView {
            setupPreview(on: view)
        }
    }
    
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

    func dataOutputSynchronizer(_ synchronizer: AVCaptureDataOutputSynchronizer,
                                didOutput synchronizedDataCollection: AVCaptureSynchronizedDataCollection) {
        guard let syncedDepthData = synchronizedDataCollection.synchronizedData(for: depthDataOutput) as? AVCaptureSynchronizedDepthData,
              let syncedVideoData = synchronizedDataCollection.synchronizedData(for: videoDataOutput) as? AVCaptureSynchronizedSampleBufferData else {
            return
        }

        if syncedDepthData.depthDataWasDropped || syncedVideoData.sampleBufferWasDropped {
            return
        }

        let depthData = syncedDepthData.depthData
        let sampleBuffer = syncedVideoData.sampleBuffer

        // Trigger callback
        onFrameCaptured?(sampleBuffer, depthData)
    }


    func stop() {
        sessionQueue.async {
            if self.isSessionRunning {
                self.session.stopRunning()
                self.isSessionRunning = false
            }
        }
    }

    func start() {
        sessionQueue.async {
            if !self.isSessionRunning {
                self.session.startRunning()
                self.isSessionRunning = true
            }
        }
    }
}
