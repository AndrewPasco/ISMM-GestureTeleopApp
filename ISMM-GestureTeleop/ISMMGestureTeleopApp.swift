//
//  ISMM_GestureTeleopApp.swift
//  ISMM-GestureTeleop
//
//  Created by Andrew  on 21/05/2025.
//

import Foundation
import AVFoundation
import UIKit
import VideoToolbox

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
    
    private var compressionSession: VTCompressionSession?
    private var frameIndex: Int64 = 0

    var onConnectionStatusChange: ((ConnectionStatus) -> Void)?

    init(host: String, port: Int, previewView: UIView) {
        self.connectionHost = host
        self.connectionPort = port
        super.init()
        connectToServer(host: host, port: port)
        setupCamera(previewView: previewView)
        setupHEVCCompression(width: 640 * 2, height: 480) // side-by-side
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
        if reconnectTimer != nil { return }
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.connectToServer(host: host, port: port)
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

        videoOutput.setSampleBufferDelegate(self, queue: queue)
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }

        if session.canAddOutput(depthOutput) {
            session.addOutput(depthOutput)
        }
        depthOutput.setDelegate(self, callbackQueue: queue)
        depthOutput.isFilteringEnabled = true
        depthOutput.connection(with: .depthData)?.isEnabled = true

        session.commitConfiguration()

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

    // MARK: - HEVC Compression Setup

    private func setupHEVCCompression(width: Int, height: Int) {
        let status = VTCompressionSessionCreate(
            allocator: nil,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: compressionOutputCallback,
            refcon: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            compressionSessionOut: &compressionSession
        )
        
        guard status == noErr else {
            print("Failed to create HEVC session")
            return
        }
        
        VTSessionSetProperty(compressionSession!, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(compressionSession!, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_HEVC_Main10_AutoLevel)
        VTSessionSetProperty(compressionSession!, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTCompressionSessionPrepareToEncodeFrames(compressionSession!)
    }

    private func sendIfBothAvailable() {
        guard let rgbBuffer = latestRGBBuffer, let depthData = latestDepthData else { return }

        latestRGBBuffer = nil
        latestDepthData = nil

        let rgbCopy = rgbBuffer
        let depthCopy = depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)

        sendingQueue.async {
            self.composeAndEncodeHEVC(rgbBuffer: rgbCopy, depthData: depthCopy)
        }
    }

    private func composeAndEncodeHEVC(rgbBuffer: CVPixelBuffer, depthData: AVDepthData) {
        let depthBuffer = depthData.depthDataMap
        let width = CVPixelBufferGetWidth(rgbBuffer)
        let height = CVPixelBufferGetHeight(rgbBuffer)

        let sideBySideWidth = width * 2
        let pixelFormat = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange // 10-bit HEVC-compatible

        var combinedBuffer: CVPixelBuffer?

        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: pixelFormat,
            kCVPixelBufferWidthKey: sideBySideWidth,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]

        let status = CVPixelBufferCreate(nil, sideBySideWidth, height, pixelFormat, attrs as CFDictionary, &combinedBuffer)
        guard status == kCVReturnSuccess, let outBuffer = combinedBuffer else {
            print("Failed to create composite pixel buffer")
            return
        }

        CVPixelBufferLockBaseAddress(rgbBuffer, .readOnly)
        CVPixelBufferLockBaseAddress(depthBuffer, .readOnly)
        CVPixelBufferLockBaseAddress(outBuffer, [])

        defer {
            CVPixelBufferUnlockBaseAddress(rgbBuffer, .readOnly)
            CVPixelBufferUnlockBaseAddress(depthBuffer, .readOnly)
            CVPixelBufferUnlockBaseAddress(outBuffer, [])
        }

        // Copy RGB to left half
        if let srcBase = CVPixelBufferGetBaseAddress(rgbBuffer),
           let dstBase = CVPixelBufferGetBaseAddress(outBuffer) {
            let bytesPerRow = CVPixelBufferGetBytesPerRow(rgbBuffer)
            for y in 0..<height {
                let src = srcBase.advanced(by: y * bytesPerRow)
                let dst = dstBase.advanced(by: y * CVPixelBufferGetBytesPerRow(outBuffer))
                memcpy(dst, src, bytesPerRow)
            }
        }

        // Encode depth to grayscale 16-bit -> left-normalized to right half as grayscale
        let floatPtr = CVPixelBufferGetBaseAddress(depthBuffer)?.assumingMemoryBound(to: Float32.self)
        let dstPtr = CVPixelBufferGetBaseAddress(outBuffer)?.advanced(by: width * 2) // Start at right half
        let depthWidth = CVPixelBufferGetWidth(depthBuffer)

        let maxDepth: Float = 5.0
        for y in 0..<height {
            for x in 0..<width {
                let idx = y * depthWidth + x
                let depthVal = min(max(floatPtr![idx], 0), maxDepth)
                let gray = UInt8((depthVal / maxDepth) * 255.0)
                let dstOffset = y * CVPixelBufferGetBytesPerRow(outBuffer) + (x + width)
                dstPtr?.storeBytes(of: gray, toByteOffset: dstOffset, as: UInt8.self)
            }
        }

        // Send to HEVC encoder
        let pts = CMTime(value: frameIndex, timescale: 30)
        frameIndex += 1

        VTCompressionSessionEncodeFrame(
            compressionSession!,
            imageBuffer: outBuffer,
            presentationTimeStamp: pts,
            duration: .invalid,
            frameProperties: nil,
            sourceFrameRefcon: nil,
            infoFlagsOut: nil
        )
    }
    
    // MARK: - Delegate Methods

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output == videoOutput {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            latestRGBBuffer = pixelBuffer
        }
        sendIfBothAvailable()
    }

    func depthDataOutput(_ output: AVCaptureDepthDataOutput, didOutput depthData: AVDepthData, timestamp: CMTime, connection: AVCaptureConnection) {
        latestDepthData = depthData
        sendIfBothAvailable()
    }

    // MARK: - TCP Sending

    func sendData(_ data: Data) {
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

func convertSampleBufferToAnnexB(_ sampleBuffer: CMSampleBuffer) -> Data? {
    guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
          let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
        return nil
    }

    var totalLength = 0
    var dataPointer: UnsafeMutablePointer<Int8>?
    guard CMBlockBufferGetDataPointer(
        dataBuffer,
        atOffset: 0,
        lengthAtOffsetOut: nil,
        totalLengthOut: &totalLength,
        dataPointerOut: &dataPointer
    ) == kCMBlockBufferNoErr,
       let basePointer = dataPointer else {
        return nil
    }

    var annexBData = Data()

    // Check if it's a keyframe
    var isKeyFrame = false
    if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false),
       CFArrayGetCount(attachments) > 0,
       let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFDictionary.self) as? [CFString: Any],
       let dependsOnOthers = dict[kCMSampleAttachmentKey_DependsOnOthers] as? Bool {
        isKeyFrame = !dependsOnOthers
    }

    if isKeyFrame {
        // Prepend VPS, SPS, PPS
        var vpsPointer: UnsafePointer<UInt8>?
        var spsPointer: UnsafePointer<UInt8>?
        var ppsPointer: UnsafePointer<UInt8>?
        var vpsSize = 0
        var spsSize = 0
        var ppsSize = 0
        var vpsCount = 0
        var spsCount = 0
        var ppsCount = 0

        CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(formatDesc, parameterSetIndex: 0, parameterSetPointerOut: &vpsPointer, parameterSetSizeOut: &vpsSize, parameterSetCountOut: &vpsCount, nalUnitHeaderLengthOut: nil)
        CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(formatDesc, parameterSetIndex: 1, parameterSetPointerOut: &spsPointer, parameterSetSizeOut: &spsSize, parameterSetCountOut: &spsCount, nalUnitHeaderLengthOut: nil)
        CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(formatDesc, parameterSetIndex: 2, parameterSetPointerOut: &ppsPointer, parameterSetSizeOut: &ppsSize, parameterSetCountOut: &ppsCount, nalUnitHeaderLengthOut: nil)

        let startCode: [UInt8] = [0x00, 0x00, 0x00, 0x01]

        if let vps = vpsPointer {
            annexBData.append(contentsOf: startCode)
            annexBData.append(vps, count: vpsSize)
        }
        if let sps = spsPointer {
            annexBData.append(contentsOf: startCode)
            annexBData.append(sps, count: spsSize)
        }
        if let pps = ppsPointer {
            annexBData.append(contentsOf: startCode)
            annexBData.append(pps, count: ppsSize)
        }
    }

    // Convert NAL units to Annex B
    var bufferOffset = 0
    let startCode: [UInt8] = [0x00, 0x00, 0x00, 0x01]

    while bufferOffset + 4 <= totalLength {
        var nalUnitLength: UInt32 = 0
        memcpy(&nalUnitLength, basePointer.advanced(by: bufferOffset), 4)
        nalUnitLength = CFSwapInt32BigToHost(nalUnitLength)

        guard nalUnitLength > 0,
              bufferOffset + 4 + Int(nalUnitLength) <= totalLength else {
            break // corrupt data
        }

        annexBData.append(contentsOf: startCode)

        let nalStart = UnsafeRawPointer(basePointer.advanced(by: bufferOffset + 4)).assumingMemoryBound(to: UInt8.self)
        annexBData.append(nalStart, count: Int(nalUnitLength))

        bufferOffset += 4 + Int(nalUnitLength)
    }

    return annexBData
}

func compressionOutputCallback(
    outputCallbackRefCon: UnsafeMutableRawPointer?,
    sourceFrameRefCon: UnsafeMutableRawPointer?,
    status: OSStatus,
    infoFlags: VTEncodeInfoFlags,
    sampleBuffer: CMSampleBuffer?
) {
    guard status == noErr,
          let sampleBuffer = sampleBuffer,
          CMSampleBufferDataIsReady(sampleBuffer),
          let refCon = outputCallbackRefCon else {
        print("Error in compression callback")
        return
    }

    let encoder = Unmanaged<ISMMGestureTeleopApp>.fromOpaque(refCon).takeUnretainedValue()

    if let annexB = convertSampleBufferToAnnexB(sampleBuffer) {
        print("Frame starts with: \(annexB.prefix(12).map { String(format: "%02x", $0) }.joined())")
        encoder.sendData(annexB)
    } else {
        print("Failed to convert sampleBuffer to Annex B format")
    }
}
