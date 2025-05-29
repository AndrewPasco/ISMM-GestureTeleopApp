//
//  FrameEncoder.swift
//  ISMM-GestureTeleop
//
//  Created by Andrew Pasco on 29/05/25.
//


import Foundation
import CoreImage
import AVFoundation

class FrameEncoder {
    private let context = CIContext()

    func encode(rgbBuffer: CVPixelBuffer, depthData: AVDepthData) -> Data? {
        autoreleasepool {
            let ciImage = CIImage(cvPixelBuffer: rgbBuffer)

            guard let rgbData = context.jpegRepresentation(of: ciImage, colorSpace: CGColorSpaceCreateDeviceRGB(), options: [:]) else {
                print("Failed to encode RGB image")
                return nil
            }

            let converted = depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
            let floatBuffer = converted.depthDataMap
            let width = CVPixelBufferGetWidth(floatBuffer)
            let height = CVPixelBufferGetHeight(floatBuffer)

            CVPixelBufferLockBaseAddress(floatBuffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(floatBuffer, .readOnly) }

            guard let baseAddress = CVPixelBufferGetBaseAddress(floatBuffer) else { return nil }
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
            let cgImage = CGImage(width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 16, bytesPerRow: width * 2, space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!

            guard let depthPNG = context.pngRepresentation(of: CIImage(cgImage: cgImage), format: .L16, colorSpace: colorSpace) else {
                print("Failed to encode depth PNG")
                return nil
            }

            var header = Data()
            var rgbLength = UInt32(rgbData.count).bigEndian
            var depthLength = UInt32(depthPNG.count).bigEndian
            header.append(Data(bytes: &rgbLength, count: 4))
            header.append(Data(bytes: &depthLength, count: 4))

            return header + rgbData + depthPNG
        }
    }
}
