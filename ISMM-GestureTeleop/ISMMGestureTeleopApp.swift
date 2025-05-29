//
//  ISMM_GestureTeleopApp.swift
//  ISMM-GestureTeleop
//
//  Created by Andrew  on 21/05/2025.
//

import Foundation
import AVFoundation
import UIKit

enum ConnectionStatus {
    case connecting
    case connected
    case failed
    case disconnected
}

class ISMMGestureTeleopApp: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureDepthDataOutputDelegate, StreamDelegate {

    // MARK: - Properties

    private let session = AVCaptureSession()
    private var outputStream: OutputStream?

    private let videoOutput = AVCaptureVideoDataOutput()
    private let depthOutput = AVCaptureDepthDataOutput()

    private let queue = DispatchQueue(label: "cameraQueue")
    private let sendingQueue = DispatchQueue(label: "sendingQueue")

    private var latestRGBBuffer: CVPixelBuffer?
    private var latestDepthData: AVDepthData?
    private var isConnected = false
    private var reconnectTimer: Timer?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    
    private var connectionHost: String = ""
    private var connectionPort: Int = 0
    
    var onConnectionStatusChange: ((ConnectionStatus) -> Void)?

    // MARK: - Initializer

    init(host: String, port: Int, previewView: UIView) {
        self.connectionHost = host
        self.connectionPort = port
        super.init()
        connectToServer(host: host, port: port)
        setupCamera(previewView: previewView)
    }

    // MARK: - TCP Connection

    private func connectToServer(host: String, port: Int) {
        onConnectionStatusChange?(.connecting)
        isConnected = false

        var readStream: Unmanaged<CFReadStream>?
        var writeStream: Unmanaged<CFWriteStream>?

        CFStreamCreatePairWithSocketToHost(nil, host as CFString, UInt32(port), &readStream, &writeStream)

        guard let outStream = writeStream?.takeRetainedValue() else {
            print("Failed to create output stream")
            onConnectionStatusChange?(.failed)
            scheduleReconnect(to: host, port: port)
            return
        }

        outputStream = outStream
        outputStream?.delegate = self
        outputStream?.schedule(in: .current, forMode: .default)
        outputStream?.open()
    }
    
    private func scheduleReconnect(to host: String, port: Int) {
        if reconnectTimer != nil { return } // avoid duplicate timers

        reconnectTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            print("Retrying connection...")
            self.connectToServer(host: host, port: port)
        }
    }

    // MARK: - Camera Setup

    private func setupCamera(previewView: UIView) {
        session.beginConfiguration()
        session.sessionPreset = .vga640x480

        guard let device = AVCaptureDevice.default(.builtInTrueDepthCamera, for: .video, position: .front),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            print("Failed to access TrueDepth camera")
            return
        }

        session.addInput(input)

        // Setup video output
        videoOutput.setSampleBufferDelegate(self, queue: queue)
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }
        
        // Enable Intrinsic Matrix
        if let connection = videoOutput.connection(with: .video) {
            connection.isCameraIntrinsicMatrixDeliveryEnabled = true
        }

        // Setup depth output
        if session.canAddOutput(depthOutput) {
            session.addOutput(depthOutput)
        }
        depthOutput.setDelegate(self, callbackQueue: queue)
        depthOutput.isFilteringEnabled = true
        depthOutput.connection(with: .depthData)?.isEnabled = true

        session.commitConfiguration()

        // Preview
        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.frame = previewView.bounds
        previewView.layer.insertSublayer(previewLayer, at: 0)
        self.previewLayer = previewLayer
        
        do {
            try device.lockForConfiguration()
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
            device.unlockForConfiguration()
        } catch {
            print("Failed to lock device for frame rate config: \(error)")
        }
        
        session.startRunning()
    }

    // MARK: - Delegate Methods

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output == videoOutput {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            latestRGBBuffer = pixelBuffer
            
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
        sendIfBothAvailable()
    }

    func depthDataOutput(_ output: AVCaptureDepthDataOutput, didOutput depthData: AVDepthData, timestamp: CMTime, connection: AVCaptureConnection) {
        latestDepthData = depthData
        sendIfBothAvailable()
    }

    // MARK: - Synchronization and Sending

    private func sendIfBothAvailable() {
        guard let rgbBuffer = latestRGBBuffer, let depthData = latestDepthData else { return }

        latestRGBBuffer = nil
        latestDepthData = nil

        let rgbCopy = rgbBuffer  // CVPixelBuffer is a reference type, but OK if not mutated
        let depthCopy = depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)

        sendingQueue.async {
            self.processAndSend(rgbBuffer: rgbCopy, depthData: depthCopy)
        }
    }
    
    private func processAndSend(rgbBuffer: CVPixelBuffer, depthData: AVDepthData) {
        autoreleasepool {
            let ciImage = CIImage(cvPixelBuffer: rgbBuffer)
            let context = CIContext()

            guard let rgbData = context.jpegRepresentation(of: ciImage, colorSpace: CGColorSpaceCreateDeviceRGB(), options: [:]) else {
                print("Failed to encode RGB image")
                return
            }

            let converted = depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
            let floatBuffer = converted.depthDataMap

            let width = CVPixelBufferGetWidth(floatBuffer)
            let height = CVPixelBufferGetHeight(floatBuffer)

            CVPixelBufferLockBaseAddress(floatBuffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(floatBuffer, .readOnly) }

            guard let baseAddress = CVPixelBufferGetBaseAddress(floatBuffer) else {
                print("No base address in depth buffer")
                return
            }

            let floatPointer = baseAddress.assumingMemoryBound(to: Float32.self)
            let floatCount = width * height

            let maxDepth: Float = 5.0
            var depth16 = [UInt16](repeating: 0, count: floatCount)
            for i in 0..<floatCount {
                let clamped = min(max(floatPointer[i], 0), maxDepth)
                depth16[i] = UInt16((clamped / maxDepth) * Float(UInt16.max))
            }

            let depthData = Data(bytes: depth16, count: floatCount * MemoryLayout<UInt16>.size)
            let provider = CGDataProvider(data: depthData as CFData)!
            let colorSpace = CGColorSpaceCreateDeviceGray()
            let cgImage = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 16,
                bitsPerPixel: 16,
                bytesPerRow: width * 2,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )!

            guard let depthPNG = context.pngRepresentation(of: CIImage(cgImage: cgImage), format: .L16, colorSpace: colorSpace) else {
                print("Failed to encode depth PNG")
                return
            }

            var header = Data()
            var rgbLength = UInt32(rgbData.count).bigEndian
            var depthLength = UInt32(depthPNG.count).bigEndian
            header.append(Data(bytes: &rgbLength, count: 4))
            header.append(Data(bytes: &depthLength, count: 4))

            let packet = header + rgbData + depthPNG
            self.sendData(packet)
        }
    }


    // MARK: - TCP Sending

    private func sendData(_ data: Data) {
        guard let stream = outputStream else { return }
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            var bytesRemaining = data.count
            var totalBytesSent = 0
            while bytesRemaining > 0 {
                let bytesSent = stream.write(
                    buffer.baseAddress!.advanced(by: totalBytesSent).assumingMemoryBound(to: UInt8.self),
                    maxLength: bytesRemaining
                )
                if bytesSent <= 0 {
                    print("Failed to send data")
                    return
                }
                bytesRemaining -= bytesSent
                totalBytesSent += bytesSent
            }
        }
    }

    // MARK: - StreamDelegate

    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        switch eventCode {
        case .openCompleted:
            print("Stream opened")
            isConnected = true
            reconnectTimer?.invalidate()
            reconnectTimer = nil
            onConnectionStatusChange?(.connected)

        case .errorOccurred:
            print("Stream error")
            aStream.close()
            isConnected = false
            onConnectionStatusChange?(.failed)
            scheduleReconnect(to: connectionHost, port: connectionPort)

        case .endEncountered:
            print("Stream closed")
            aStream.close()
            isConnected = false
            onConnectionStatusChange?(.disconnected)
            scheduleReconnect(to: connectionHost, port: connectionPort)

        default:
            break
        }
    }
}
