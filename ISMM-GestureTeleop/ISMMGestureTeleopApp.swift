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

class ISMMGestureTeleopApp: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureDepthDataOutputDelegate {
    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let depthOutput = AVCaptureDepthDataOutput()
    private let host: String
    private let port: UInt16

    private var dataOutputSync: AVCaptureDataOutputSynchronizer?
    private var outputStream: OutputStream?
    
    init(host: String, port: UInt16) {
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

        // Video output
        videoOutput.setSampleBufferDelegate(self, queue: DispatchQueue(label: "videoQueue"))
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
        CFStreamCreatePairWithSocketToHost(nil, "192.168.1.100" as CFString, 5000, &readStream, &writeStream)

        guard let out = writeStream?.takeRetainedValue() else {
            print("Failed to create output stream")
            return
        }

        outputStream = out
        outputStream?.schedule(in: .current, forMode: .default)
        outputStream?.open()
    }

    private func sendImageData(rgb: Data, depth: Data) {
        guard let stream = outputStream else { return }

        var packet = Data()
        packet += withUnsafeBytes(of: UInt32(rgb.count).bigEndian, { Data($0) })
        packet += rgb
        packet += withUnsafeBytes(of: UInt32(depth.count).bigEndian, { Data($0) })
        packet += depth

        _ = packet.withUnsafeBytes {
            stream.write($0.bindMemory(to: UInt8.self).baseAddress!, maxLength: packet.count)
        }
    }
}

// MARK: - Synchronizer Delegate

extension ISMMGestureTeleopApp: AVCaptureDataOutputSynchronizerDelegate {
    func dataOutputSynchronizer(_ synchronizer: AVCaptureDataOutputSynchronizer,
                                didOutput synchronizedDataCollection: AVCaptureSynchronizedDataCollection) {
        guard
            let syncedVideoData = synchronizedDataCollection.synchronizedData(for: videoOutput) as? AVCaptureSynchronizedSampleBufferData,
            let syncedDepthData = synchronizedDataCollection.synchronizedData(for: depthOutput) as? AVCaptureSynchronizedDepthData,
            !syncedVideoData.sampleBufferWasDropped,
            !syncedDepthData.depthDataWasDropped
        else {
            return
        }

        guard let rgbData = encodeRGBToJPEG(sampleBuffer: syncedVideoData.sampleBuffer),
              let depthData = encodeDepthTo16BitPNG(depthData: syncedDepthData.depthData)
        else {
            return
        }

        sendImageData(rgb: rgbData, depth: depthData)
    }

    private func encodeRGBToJPEG(sampleBuffer: CMSampleBuffer) -> Data? {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }

        let ciImage = CIImage(cvPixelBuffer: imageBuffer)
        let context = CIContext()
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return nil }

        let jpegData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(jpegData, kUTTypeJPEG, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, cgImage, nil)
        CGImageDestinationFinalize(destination)

        return jpegData as Data
    }

    private func encodeDepthTo16BitPNG(depthData: AVDepthData) -> Data? {
        let convertedDepth = depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
        let depthBuffer = convertedDepth.depthDataMap
        CVPixelBufferLockBaseAddress(depthBuffer, .readOnly)

        let width = CVPixelBufferGetWidth(depthBuffer)
        let height = CVPixelBufferGetHeight(depthBuffer)
        var uint16Buffer = [UInt16](repeating: 0, count: width * height)

        for y in 0..<height {
            let row = CVPixelBufferGetBaseAddress(depthBuffer)! + y * CVPixelBufferGetBytesPerRow(depthBuffer)
            let floatRow = row.assumingMemoryBound(to: Float32.self)
            for x in 0..<width {
                let depthMeters = floatRow[x]
                let depthMillimeters = max(0, min(UInt16(depthMeters * 1000), 65535))
                uint16Buffer[y * width + x] = depthMillimeters
            }
        }

        CVPixelBufferUnlockBaseAddress(depthBuffer, .readOnly)

        let bitsPerComponent = 16
        let bitsPerPixel = 16
        let bytesPerRow = width * 2
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let providerRef = CGDataProvider(data: Data(bytes: &uint16Buffer, count: uint16Buffer.count * 2) as CFData) else {
            return nil
        }

        guard let cgImage = CGImage(width: width,
                                    height: height,
                                    bitsPerComponent: bitsPerComponent,
                                    bitsPerPixel: bitsPerPixel,
                                    bytesPerRow: bytesPerRow,
                                    space: colorSpace,
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                    provider: providerRef,
                                    decode: nil,
                                    shouldInterpolate: false,
                                    intent: .defaultIntent) else {
            return nil
        }

        let pngData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(pngData, kUTTypePNG, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cgImage, nil)
        CGImageDestinationFinalize(dest)
        return pngData as Data
    }
}
