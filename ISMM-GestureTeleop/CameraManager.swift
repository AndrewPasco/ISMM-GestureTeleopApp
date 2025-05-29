//
//  CameraManager.swift
//  ISMM-GestureTeleop
//
//  Created by Andrew Pasco on 29/05/25.
//


import AVFoundation
import UIKit

class CameraManager: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureDepthDataOutputDelegate {
    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let depthOutput = AVCaptureDepthDataOutput()
    private let queue = DispatchQueue(label: "cameraQueue")

    var onFrameCaptured: ((CVPixelBuffer?, AVDepthData?) -> Void)?
    private(set) var previewLayer: AVCaptureVideoPreviewLayer?
    
    var debug: Bool = false

    func setup(previewIn view: UIView) {
        session.beginConfiguration()
        session.sessionPreset = .vga640x480

        guard let device = AVCaptureDevice.default(.builtInTrueDepthCamera, for: .video, position: .front),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            print("Failed to access TrueDepth camera")
            return
        }
        
        // Fix framerate
        do {
            try device.lockForConfiguration()
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 10)
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 10)
            device.unlockForConfiguration()
        } catch {
            print("[CameraManager] Failed to set frame rate: \(error.localizedDescription)")
        }
        
        session.addInput(input)

        videoOutput.setSampleBufferDelegate(self, queue: queue)
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        session.addOutput(videoOutput)

        if let connection = videoOutput.connection(with: .video) {
            connection.isCameraIntrinsicMatrixDeliveryEnabled = true
        }

        if session.canAddOutput(depthOutput) {
            session.addOutput(depthOutput)
        }
        depthOutput.setDelegate(self, callbackQueue: queue)
        depthOutput.isFilteringEnabled = true

        session.commitConfiguration()

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.insertSublayer(preview, at: 0)
        previewLayer = preview

        DispatchQueue.global(qos: .userInitiated).async {
            self.session.startRunning()
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output == videoOutput, let rgbBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            
            // Only print intrinsic matrix if debugging is enabled
            if debug {
                if let attachment = CMGetAttachment(sampleBuffer,
                                                    key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix,
                                                    attachmentModeOut: nil) {
                    let matrixData = attachment as! CFData
                    var intrinsicMatrix = matrix_float3x3()
                    CFDataGetBytes(matrixData,
                                   CFRange(location: 0, length: MemoryLayout<matrix_float3x3>.size),
                                   &intrinsicMatrix)

                    print("RGB Camera Intrinsic Matrix:")
                    print("[[\(intrinsicMatrix.columns.0.x), \(intrinsicMatrix.columns.1.x), \(intrinsicMatrix.columns.2.x)]")
                    print(" [\(intrinsicMatrix.columns.0.y), \(intrinsicMatrix.columns.1.y), \(intrinsicMatrix.columns.2.y)]")
                    print(" [\(intrinsicMatrix.columns.0.z), \(intrinsicMatrix.columns.1.z), \(intrinsicMatrix.columns.2.z)]]")
                } else {
                    print("No intrinsic matrix found in RGB sampleBuffer.")
                }
            }
            
            // Send Frame
            onFrameCaptured?(rgbBuffer, nil)
        }
    }

    func depthDataOutput(_ output: AVCaptureDepthDataOutput, didOutput depthData: AVDepthData, timestamp: CMTime, connection: AVCaptureConnection) {
        onFrameCaptured?(nil, depthData)
    }
    
    func updatePreviewFrame() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  let previewLayer = self.previewLayer,
                  let superlayer = previewLayer.superlayer else { return }
            previewLayer.frame = superlayer.bounds
        }
    }
}
