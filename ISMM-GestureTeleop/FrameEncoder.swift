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

    /// Encodes wide and uw CVPixelBuffers as JPEG and returns a Data packet.
    /// The format is: [4 bytes wide length][4 bytes uw length][wide JPEG][uw JPEG]
    func encode(wideBuffer: CVPixelBuffer, uwBuffer: CVPixelBuffer) -> Data? {
        autoreleasepool {
            let wideImage = CIImage(cvPixelBuffer: wideBuffer)
            let uwImage = CIImage(cvPixelBuffer: uwBuffer)

            guard let wideJPEG = context.jpegRepresentation(
                of: wideImage,
                colorSpace: CGColorSpaceCreateDeviceRGB(),
                options: [:]
            ) else {
                print("Failed to encode wide image")
                return nil
            }

            guard let uwJPEG = context.jpegRepresentation(
                of: uwImage,
                colorSpace: CGColorSpaceCreateDeviceRGB(),
                options: [:]
            ) else {
                print("Failed to encode uw image")
                return nil
            }

            // Header with 4-byte big-endian lengths for each image
            var header = Data()
            var wideLength = UInt32(wideJPEG.count).bigEndian
            var uwLength = UInt32(uwJPEG.count).bigEndian
            header.append(Data(bytes: &wideLength, count: 4))
            header.append(Data(bytes: &uwLength, count: 4))

            return header + wideJPEG + uwJPEG
        }
    }
}
