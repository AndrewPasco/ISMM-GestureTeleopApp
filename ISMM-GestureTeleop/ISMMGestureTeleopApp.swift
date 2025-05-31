//
//  ISMM_GestureTeleopApp.swift
//  ISMM-GestureTeleop
//
//  Created by Andrew Pasco on 21/05/2025.
//

import UIKit
import AVFoundation

class ISMMGestureTeleopApp {
    private let tcpClient: TCPClient
    
    private let frameEncoder = FrameEncoder()
    
    private let cameraManager = CameraManager()
    
    private let sendingQueue = DispatchQueue(label: "sendingQueue")
    
    private var frameCounter = 0
    private let frameSendInterval = 3 // 30fps/3 ~ 10fps

    var onConnectionStatusChange: ((ConnectionStatus) -> Void)? {
        didSet { tcpClient.onStatusChange = onConnectionStatusChange }
    }

    init(host: String, port: Int, previewView: UIView) {
        tcpClient = TCPClient(host: host, port: port)

        cameraManager.debug = false // Enable for camera matrix printout, frame matching verification
        cameraManager.onFrameCaptured = { [weak self] wide, uw in
            self?.handleFrames(wide: wide, uw: uw)
        }

        cameraManager.setup(previewIn: previewView)
    }

    func connectToServer() {
        tcpClient.connect()
    }

    private func handleFrames(wide: CVPixelBuffer, uw: CVPixelBuffer) {
        sendingQueue.async { [weak self] in
            guard let self = self else { return }

            self.frameCounter += 1
            if self.frameCounter % self.frameSendInterval != 0 {
                return // Skip this frame
            }

            guard let packet = self.frameEncoder.encode(wideBuffer: wide, uwBuffer: uw) else {
                return
            }

            self.tcpClient.send(data: packet)
        }
    }


    func updatePreviewFrame() {
        cameraManager.updatePreviewFrame()
    }
}
