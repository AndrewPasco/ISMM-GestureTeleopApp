//
//  ViewController.swift
//  ISMM-GestureTeleop
//
//  Created by Andrew  on 21/05/2025.
//

import UIKit

class ViewController: UIViewController {

    var streamer: ISMMGestureTeleopApp?
    
    private let statusLabel = UILabel()
    private let ipTextField = UITextField()
    private let connectButton = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        
        setupUI()
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        streamer?.updatePreviewFrame()
    }


    private func setupUI() {
        // === Status Label ===
        statusLabel.text = "Not Connected"
        statusLabel.textColor = .white
        statusLabel.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        statusLabel.textAlignment = .center
        statusLabel.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
        statusLabel.layer.cornerRadius = 8
        statusLabel.clipsToBounds = true
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)

        // === IP Text Field ===
        ipTextField.placeholder = "Enter IP Address"
        ipTextField.text = "172.16.168.48"  // Default IP
        ipTextField.borderStyle = .roundedRect
        ipTextField.backgroundColor = .white
        ipTextField.keyboardType = .numbersAndPunctuation
        ipTextField.autocapitalizationType = .none
        ipTextField.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(ipTextField)

        // === Connect Button ===
        connectButton.setTitle("Connect", for: .normal)
        connectButton.setTitleColor(.white, for: .normal)
        connectButton.backgroundColor = .systemBlue
        connectButton.layer.cornerRadius = 8
        connectButton.titleLabel?.font = UIFont.boldSystemFont(ofSize: 16)
        connectButton.translatesAutoresizingMaskIntoConstraints = false
        connectButton.addTarget(self, action: #selector(connectButtonTapped), for: .touchUpInside)
        view.addSubview(connectButton)

        // === Layout Constraints ===
        NSLayoutConstraint.activate([
            ipTextField.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            ipTextField.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            ipTextField.widthAnchor.constraint(equalToConstant: 200),
            ipTextField.heightAnchor.constraint(equalToConstant: 36),

            connectButton.topAnchor.constraint(equalTo: ipTextField.bottomAnchor, constant: 12),
            connectButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            connectButton.widthAnchor.constraint(equalToConstant: 100),
            connectButton.heightAnchor.constraint(equalToConstant: 40),

            statusLabel.topAnchor.constraint(equalTo: connectButton.bottomAnchor, constant: 16),
            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.widthAnchor.constraint(equalToConstant: 180),
            statusLabel.heightAnchor.constraint(equalToConstant: 36)
        ])
    }

    @objc private func connectButtonTapped() {
        view.endEditing(true) // dismiss keyboard
        
        guard let ip = ipTextField.text, !ip.isEmpty else {
            statusLabel.text = "Invalid IP"
            return
        }

        // Only instantiate once
        if streamer == nil {
            streamer = ISMMGestureTeleopApp(host: ip, port: 5000, previewView: self.view)

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

        streamer?.connectToServer(host: ip, port: 5000)
    }
}
