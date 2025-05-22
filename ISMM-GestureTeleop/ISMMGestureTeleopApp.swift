//
//  ISMM_GestureTeleopApp.swift
//  ISMM-GestureTeleop
//
//  Created by Andrew  on 21/05/2025.
//

import UIKit
import AVFoundation
import CoreImage
import ImageIO
import MobileCoreServices
import Network
import UniformTypeIdentifiers

class ISMMGestureTeleopApp: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureDepthDataOutputDelegate, StreamDelegate {
    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let depthOutput = AVCaptureDepthDataOutput()
    private let host: String
    private let port: UInt32

    private var dataOutputSync: AVCaptureDataOutputSynchronizer?
    private var outputStream: OutputStream?
    private var isConnected: Bool = false
    private var readyToSend: Bool = false
    
    init(host: String, port: UInt32) {
        self.host = host
        self.port = port
        super.init()
        setupCaptureSession()
        setupTCPConnection()
    }
    
    deinit {
        outputStream?.close()
        print("ISMMGestureTeleopApp deinitialized and stream closed.")
    }

    private func setupCaptureSession() {
        session.beginConfiguration()
        session.sessionPreset = .vga640x480

        guard let device = AVCaptureDevice.default(.builtInTrueDepthCamera, for: .video, position: .front),
              let input = try? AVCaptureDeviceInput(device: device) else {
            print("Failed to get TrueDepth camera input")
            return
        }

        guard session.canAddInput(input) else { return }
        session.addInput(input)

        // Frame rate limiting to ~15fps
        do {
            try device.lockForConfiguration()
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
            device.unlockForConfiguration()
        } catch {
            print("Failed to configure frame rate: \(error)")
        }
        
        // Video output
        videoOutput.setSampleBufferDelegate(self, queue: DispatchQueue(label: "videoQueue"))
        videoOutput.alwaysDiscardsLateVideoFrames = true
        guard session.canAddOutput(videoOutput) else { return }
        session.addOutput(videoOutput)

        // Depth output
        guard session.canAddOutput(depthOutput) else { return }
        session.addOutput(depthOutput)
        depthOutput.setDelegate(self, callbackQueue: DispatchQueue(label: "depthQueue"))
        depthOutput.isFilteringEnabled = true

        // Synchronize video and depth
        dataOutputSync = AVCaptureDataOutputSynchronizer(dataOutputs: [videoOutput, depthOutput])
        dataOutputSync?.setDelegate(self, queue: DispatchQueue(label: "syncQueue"))

        session.commitConfiguration()
        session.startRunning()
    }

    private func setupTCPConnection() {
        var readStream: Unmanaged<CFReadStream>?
        var writeStream: Unmanaged<CFWriteStream>?

        // Replace with your server's IP and port
        CFStreamCreatePairWithSocketToHost(nil, host as CFString, port, &readStream, &writeStream)

        guard let out = writeStream?.takeRetainedValue() else {
            print("Failed to create output stream")
            return
        }

        outputStream = out
        outputStream?.delegate = self
        isConnected = true
        outputStream?.schedule(in: .current, forMode: .default)
        outputStream?.open()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.readyToSend = true
        }
    }

    func sendImageData(rgbData: Data, depthData: Data) {
        guard let outputStream = outputStream, isConnected else {
            print("Not connected to server")
            return
        }
        
        let rgbLength = UInt32(rgbData.count)
        let depthLength = UInt32(depthData.count)
        
        var header = Data()
        header.append(contentsOf: withUnsafeBytes(of: rgbLength.bigEndian, Array.init))
        header.append(contentsOf: withUnsafeBytes(of: depthLength.bigEndian, Array.init))
        
        let payload = header + rgbData + depthData
        
        let result = payload.withUnsafeBytes {
            outputStream.write($0.bindMemory(to: UInt8.self).baseAddress!, maxLength: payload.count)
        }
        
        if result <= 0 {
            print("Stream write failed: \(result)")
            if let error = outputStream.streamError {
                print("Stream error: \(error.localizedDescription)")
            }
            
            outputStream.close()
            self.outputStream = nil
            self.isConnected = false
            
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
                self.setupTCPConnection()
            }
        }
    }
        
    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        switch eventCode {
        case .openCompleted:
            print("Stream opened")
            isConnected = true

        case .hasSpaceAvailable:
            isConnected = true

        case .errorOccurred:
            print("Stream error occurred")
            isConnected = false
            aStream.close()
            outputStream = nil
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
                self.setupTCPConnection()
            }

        case .endEncountered:
            print("Stream ended")
            isConnected = false
            aStream.close()
            outputStream = nil
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
                self.setupTCPConnection()
            }

        default:
            break
        }
    }

    func addPreviewLayer(to view: UIView) {
        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.frame = view.bounds
        view.layer.insertSublayer(previewLayer, at: 0)
    }

}

// MARK: - Synchronizer Delegate

extension ISMMGestureTeleopApp: AVCaptureDataOutputSynchronizerDelegate {
    func dataOutputSynchronizer(_ synchronizer: AVCaptureDataOutputSynchronizer,
                                didOutput synchronizedDataCollection: AVCaptureSynchronizedDataCollection) {
        guard readyToSend else { return }
        guard
            let syncedVideoData = synchronizedDataCollection.synchronizedData(for: videoOutput) as? AVCaptureSynchronizedSampleBufferData,
            let syncedDepthData = synchronizedDataCollection.synchronizedData(for: depthOutput) as? AVCaptureSynchronizedDepthData,
            !syncedVideoData.sampleBufferWasDropped,
            !syncedDepthData.depthDataWasDropped
        else {
            return
        }

        // Offload processing to global concurrent queue
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard
                let rgbData = self?.encodeRGBToJPEG(sampleBuffer: syncedVideoData.sampleBuffer),
                let depthData = self?.encodeDepthTo16BitPNG(depthData: syncedDepthData.depthData)
            else {
                return
            }

            self?.sendImageData(rgbData: rgbData, depthData: depthData)
        }
    }

    private func encodeRGBToJPEG(sampleBuffer: CMSampleBuffer) -> Data? {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }

        let ciImage = CIImage(cvPixelBuffer: imageBuffer)
        let context = CIContext()
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return nil }

        let jpegData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(jpegData, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, cgImage, nil)
        CGImageDestinationFinalize(destination)

        return jpegData as Data
    }

    private func encodeDepthTo16BitPNG(depthData: AVDepthData) -> Data? {
        let convertedDepth = depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
        let depthBuffer = convertedDepth.depthDataMap
        CVPixelBufferLockBaseAddress(depthBuffer, .readOnly)

        defer {
            CVPixelBufferUnlockBaseAddress(depthBuffer, .readOnly)
        }

        let width = CVPixelBufferGetWidth(depthBuffer)
        let height = CVPixelBufferGetHeight(depthBuffer)
        let rowBytes = width * MemoryLayout<UInt16>.size

        var uint16Buffer = [UInt16](repeating: 0, count: width * height)

        for y in 0..<height {
            let row = CVPixelBufferGetBaseAddress(depthBuffer)! + y * CVPixelBufferGetBytesPerRow(depthBuffer)
            let floatRow = row.assumingMemoryBound(to: Float32.self)
            for x in 0..<width {
                let depthMeters = floatRow[x]
                let depthMillimeters = UInt16(clamping: Int(depthMeters * 1000))
                uint16Buffer[y * width + x] = depthMillimeters
            }
        }

        // Create CGImage from uint16Buffer
        let colorSpace = CGColorSpace(name: CGColorSpace.linearGray)!
        let imageData = uint16Buffer.withUnsafeBufferPointer { bufferPointer in
            return Data(buffer: bufferPointer)
        }

        guard let providerRef = CGDataProvider(data: imageData as CFData) else {
            return nil
        }

        guard let cgImage = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 16,
            bitsPerPixel: 16,
            bytesPerRow: rowBytes,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: providerRef,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            return nil
        }

        // Encode to PNG
        let pngData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(pngData, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }

        return pngData as Data
    }

}
