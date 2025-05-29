//
//  ISMM_GestureTeleopApp.swift
//  ISMM-GestureTeleop
//
//  Created by Andrew  on 21/05/2025.
//

import UIKit
import AVFoundation

class ISMMGestureTeleopApp {
    private let tcpClient: TCPClient
    private let frameEncoder = FrameEncoder()
    private let cameraManager = CameraManager()

    private var latestRGB: CVPixelBuffer?
    private var latestDepth: AVDepthData?
    private let sendingQueue = DispatchQueue(label: "sendingQueue")

    var onConnectionStatusChange: ((ConnectionStatus) -> Void)? {
        didSet { tcpClient.onStatusChange = onConnectionStatusChange }
    }

    init(host: String, port: Int, previewView: UIView) {
        cameraManager.debug = true // true for matrix printout
        tcpClient = TCPClient(host: host, port: port)
        cameraManager.onFrameCaptured = { [weak self] rgb, depth in
            self?.handleFrame(rgb: rgb, depth: depth)
        }
        cameraManager.setup(previewIn: previewView)
    }

    func connectToServer() {
        tcpClient.connect()
    }

    private func handleFrame(rgb: CVPixelBuffer?, depth: AVDepthData?) {
        if let rgb = rgb {
            latestRGB = rgb
        }
        if let depth = depth {
            latestDepth = depth
        }

        guard let rgbBuffer = latestRGB, let depthData = latestDepth else { return }

        latestRGB = nil
        latestDepth = nil

        sendingQueue.async { [weak self] in
            guard let self = self,
                  let packet = self.frameEncoder.encode(rgbBuffer: rgbBuffer, depthData: depthData) else { return }
            self.tcpClient.send(data: packet)
        }
    }
    
    func updatePreviewFrame() {
        // Passthrough from cameraManager
        cameraManager.updatePreviewFrame()
    }
}
