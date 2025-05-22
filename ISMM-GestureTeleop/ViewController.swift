//
//  ViewController.swift
//  ISMM-GestureTeleop
//
//  Created by Andrew  on 21/05/2025.
//

import UIKit

class ViewController: UIViewController {
    var streamer: ISMMGestureTeleopApp?

    override func viewDidLoad() {
        super.viewDidLoad()
        streamer = ISMMGestureTeleopApp(host: "172.16.168.48", port: 5000)
        // Add camera preview
        if let streamer = streamer {
            streamer.addPreviewLayer(to: self.view)
        }
    }
}
