//
//  CameraManager.swift
//  ISMM-GestureTeleop
//
//  Created by Andrew Pasco on 29/05/25.
//

import AVFoundation
import UIKit

class CameraManager: NSObject {
    private let session = AVCaptureMultiCamSession()
    private let wideOutput = AVCaptureVideoDataOutput()
    private let uwOutput = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "cameraQueue")

    private var outputSynchronizer: AVCaptureDataOutputSynchronizer?
    
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var previewContainerView: UIView?

    var onFrameCaptured: ((CVPixelBuffer, CVPixelBuffer) -> Void)?
    var debug: Bool = false

    func setup(previewIn view: UIView) {
        self.previewContainerView = view

        guard AVCaptureMultiCamSession.isMultiCamSupported else {
            print("MultiCam is not supported on this device")
            return
        }

        session.beginConfiguration()

        // Configure wide camera
        guard let wideDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let wideInput = try? AVCaptureDeviceInput(device: wideDevice),
              session.canAddInput(wideInput) else {
            print("Failed to set up wide camera input")
            return
        }
        session.addInput(wideInput)
        
        // Wide camera output
        wideOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        guard session.canAddOutput(wideOutput) else {
            print("Failed to add wide output")
            return
        }
        session.addOutput(wideOutput)

        // Configure ultra wide camera as second input
        guard let ultraDevice = AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back),
              let ultraInput = try? AVCaptureDeviceInput(device: ultraDevice),
              session.canAddInput(ultraInput) else {
            print("Failed to set up ultra wide camera input")
            return
        }
        session.addInput(ultraInput)

        // Ultra wide camera output
        uwOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        guard session.canAddOutput(uwOutput) else {
            print("Failed to add ultra wide output")
            return
        }
        session.addOutput(uwOutput)


        // Synchronize outputs
        outputSynchronizer = AVCaptureDataOutputSynchronizer(dataOutputs: [wideOutput, uwOutput])
        outputSynchronizer?.setDelegate(self, queue: queue)

        session.commitConfiguration()

        // Add preview layer using wide camera's connection
        if wideOutput.connection(with: .video) != nil {
            let preview = AVCaptureVideoPreviewLayer(session: session)
            preview.videoGravity = .resizeAspectFill
            preview.frame = view.bounds
            preview.borderColor = UIColor.red.cgColor
            preview.borderWidth = 3
            view.layer.insertSublayer(preview, at: 0)
            previewLayer = preview
        } else {
            print("Failed to get wideOutput connection")
        }

        DispatchQueue.main.async {
            self.session.startRunning()
            print("Camera Session Started")
        }
    }

    func updatePreviewFrame() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  let previewLayer = self.previewLayer,
                  let containerView = self.previewContainerView else { return }
            previewLayer.frame = containerView.bounds
        }
    }
}

extension CameraManager: AVCaptureDataOutputSynchronizerDelegate {
    func dataOutputSynchronizer(_ synchronizer: AVCaptureDataOutputSynchronizer,
                                didOutput synchronizedDataCollection: AVCaptureSynchronizedDataCollection) {
        guard let wideData = synchronizedDataCollection.synchronizedData(for: wideOutput) as? AVCaptureSynchronizedSampleBufferData,
              let uwData = synchronizedDataCollection.synchronizedData(for: uwOutput) as? AVCaptureSynchronizedSampleBufferData,
              !wideData.sampleBufferWasDropped,
              !uwData.sampleBufferWasDropped else {
            return
        }

        guard let wideBuffer = CMSampleBufferGetImageBuffer(wideData.sampleBuffer),
              let uwBuffer = CMSampleBufferGetImageBuffer(uwData.sampleBuffer) else {
            return
        }

        if debug {
            print("Synchronized wide and ultrawide frames captured.")
        }

        onFrameCaptured?(wideBuffer, uwBuffer)
    }
}
