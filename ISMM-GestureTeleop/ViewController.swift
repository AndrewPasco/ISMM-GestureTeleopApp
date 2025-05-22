//
//  ViewController.swift
//  ISMM-GestureTeleop
//
//  Created by Andrew  on 21/05/2025.
//

import UIKit

import UIKit

class ViewController: UIViewController {

    var streamer: ISMMGestureTeleopApp?
    private let statusLabel = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()

        // Setup status label
        statusLabel.text = "Connecting..."
        statusLabel.textColor = .white
        statusLabel.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        statusLabel.textAlignment = .center
        statusLabel.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
        statusLabel.layer.cornerRadius = 8
        statusLabel.clipsToBounds = true
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.widthAnchor.constraint(equalToConstant: 180),
            statusLabel.heightAnchor.constraint(equalToConstant: 36)
        ])

        // Init streamer and observe status
        streamer = ISMMGestureTeleopApp(host: "172.16.168.48", port: 5000, previewView: self.view)

        // Assign callback to update the status label
        streamer?.onConnectionStatusChange = { [weak self] status in
            DispatchQueue.main.async {
                self?.statusLabel.text = {
                    switch status {
                    case .connecting: return "Connecting..."
                    case .connected: return "Connected"
                    case .failed: return "Connection Failed"
                    case .disconnected: return "Disconnected"
                    }
                }()
            }
        }
    }
}

