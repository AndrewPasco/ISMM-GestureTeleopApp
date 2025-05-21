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
        streamer = ISMMGestureTeleopApp(host: "192.168.1.42", port: 5000)
    }
}
