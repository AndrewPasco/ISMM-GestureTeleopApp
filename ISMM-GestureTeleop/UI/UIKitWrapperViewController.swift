//
//  UIKitWrapperViewController.swift
//  ISMM-GestureTeleop
//
//  Created by Andrew  on 21/05/2025.
//

import SwiftUI

struct UIKitWrapperViewController: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        return ViewController()
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        // Nothing needed here
    }
}
