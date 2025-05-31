//
//  CameraManager.swift
//  ISMM-GestureTeleop
//
//  Created by Andrew Pasco on 29/05/25.
//

import AVFoundation
import UIKit
import CoreImage

class CameraManager: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let session = AVCaptureMultiCamSession()
    private let wideOutput = AVCaptureVideoDataOutput()
    private let uwOutput = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "cameraQueue")
    private let context = CIContext()

    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var previewContainerView: UIView?

    var onFrameCaptured: ((CVPixelBuffer, CVPixelBuffer) -> Void)?
    var debug: Bool = false

    private var latestWideFrame: (buffer: CVPixelBuffer, timestamp: CMTime)?
    private var latestUWFrame: (buffer: CVPixelBuffer, timestamp: CMTime)?
    
    private var hasPrintedWideIntrinsics = false
    private var hasPrintedUWIntrinsics = false

    func setup(previewIn view: UIView) {
        self.previewContainerView = view

        guard AVCaptureMultiCamSession.isMultiCamSupported else {
            print("MultiCam is not supported on this device")
            return
        }

        session.beginConfiguration()

        // Configure wide camera
        guard let wideDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            print("Failed to get wide camera")
            return
        }

        guard let wideInput = try? AVCaptureDeviceInput(device: wideDevice),
              session.canAddInput(wideInput) else {
            print("Failed to set up wide camera input")
            return
        }
        session.addInput(wideInput)

        wideOutput.setSampleBufferDelegate(self, queue: queue)
        wideOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        guard session.canAddOutput(wideOutput) else {
            print("Failed to add wide output")
            return
        }
        session.addOutput(wideOutput)
        
        if let wideConnection = wideOutput.connection(with: .video) {
            wideConnection.isCameraIntrinsicMatrixDeliveryEnabled = true
        }

        // Configure ultra-wide camera
        guard let ultraDevice = AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back) else {
            print("Failed to get ultra wide camera")
            return
        }

        guard let ultraInput = try? AVCaptureDeviceInput(device: ultraDevice),
              session.canAddInput(ultraInput) else {
            print("Failed to set up ultra wide camera input")
            return
        }
        session.addInput(ultraInput)

        uwOutput.setSampleBufferDelegate(self, queue: queue)
        uwOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        guard session.canAddOutput(uwOutput) else {
            print("Failed to add ultra wide output")
            return
        }
        session.addOutput(uwOutput)
        
        if let uwConnection = uwOutput.connection(with: .video) {
            uwConnection.isCameraIntrinsicMatrixDeliveryEnabled = true
        }

        session.commitConfiguration()

        // Preview from wide camera
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

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        
        if debug {
            // Print Camera Intrinsics
            let isWide = output == wideOutput
            let isUW = output == uwOutput
            
            if (isWide && !hasPrintedWideIntrinsics) || (isUW && !hasPrintedUWIntrinsics) {
                if let attachment = CMGetAttachment(sampleBuffer,
                                                    key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix,
                                                    attachmentModeOut: nil) {
                    let matrixData = attachment as! CFData
                    var intrinsicMatrix = matrix_float3x3()
                    CFDataGetBytes(matrixData,
                                   CFRange(location: 0, length: MemoryLayout<matrix_float3x3>.size),
                                   &intrinsicMatrix)
                    
                    let label = isWide ? "WIDE" : "ULTRA-WIDE"
                    print("Intrinsic Matrix (\(label)):")
                    print("[[\(intrinsicMatrix.columns.0.x), \(intrinsicMatrix.columns.1.x), \(intrinsicMatrix.columns.2.x)]")
                    print(" [\(intrinsicMatrix.columns.0.y), \(intrinsicMatrix.columns.1.y), \(intrinsicMatrix.columns.2.y)]")
                    print(" [\(intrinsicMatrix.columns.0.z), \(intrinsicMatrix.columns.1.z), \(intrinsicMatrix.columns.2.z)]]")
                    
                    if isWide { hasPrintedWideIntrinsics = true }
                    if isUW { hasPrintedUWIntrinsics = true }
                } else {
                    print("No intrinsic matrix found in \(isWide ? "wide" : "ultra-wide") sampleBuffer.")
                }
            }
        }
        
        // Obtain other latest frame
        if output == wideOutput {
            latestWideFrame = (buffer, timestamp)
        } else if output == uwOutput {
            latestUWFrame = (buffer, timestamp)
        }

        // Try to match frames
        if let wide = latestWideFrame, let uw = latestUWFrame {
            let delta = abs(CMTimeSubtract(wide.timestamp, uw.timestamp).seconds)
            if delta < 0.015 { // Acceptable tolerance: 15ms
                if debug {
                    print("[CameraManager] Matched frames — Δt = \(String(format: "%.3f", delta))s")
                }
                // Resize both before passing to callback
                if let resizedWide = resize(pixelBuffer: wide.buffer, to: CGSize(width: 640, height: 480)),
                   let resizedUW = resize(pixelBuffer: uw.buffer, to: CGSize(width: 640, height: 480)) {
                    onFrameCaptured?(resizedWide, resizedUW)
                }
                latestWideFrame = nil
                latestUWFrame = nil
            } else if debug { print("no matched frames found") }
        }
    }
    
    func resize(pixelBuffer: CVPixelBuffer, to size: CGSize) -> CVPixelBuffer? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)

        let scaleX = size.width / CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let scaleY = size.height / CGFloat(CVPixelBufferGetHeight(pixelBuffer))

        let scaledImage = ciImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        var outputBuffer: CVPixelBuffer?
        let attrs = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ] as CFDictionary

        let status = CVPixelBufferCreate(kCFAllocatorDefault,
                                         Int(size.width),
                                         Int(size.height),
                                         CVPixelBufferGetPixelFormatType(pixelBuffer),
                                         attrs,
                                         &outputBuffer)

        guard status == kCVReturnSuccess, let output = outputBuffer else {
            return nil
        }

        context.render(scaledImage, to: output)
        return output
    }
}
