//
//  LandmarkOverlayView.swift
//  ISMM-GestureTeleop
//
//  Created by Andrew Pasco on 03/06/25.
//

import UIKit

class LandmarkOverlayView: UIView {
    var points: [CGPoint] = []

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }

        context.setFillColor(UIColor.red.cgColor)
        // Draw landmarks: red fill, yellow outline
        for point in points {
            let radius: CGFloat = 8.0
            let circleRect = CGRect(x: point.x - radius / 2, y: point.y - radius / 2, width: radius, height: radius)

            context.setFillColor(UIColor.red.cgColor)
            context.fillEllipse(in: circleRect)

            context.setStrokeColor(UIColor.yellow.cgColor)
            context.setLineWidth(2.0)
            context.strokeEllipse(in: circleRect)
        }

        // Compute centroid
        if !points.isEmpty {
            let sum = points.reduce(CGPoint.zero) { partialResult, point in
                CGPoint(x: partialResult.x + point.x, y: partialResult.y + point.y)
            }
            let count = CGFloat(points.count)
            let centroid = CGPoint(x: sum.x / count, y: sum.y / count)

            // Draw centroid: larger red circle with yellow outline
            let centroidRadius: CGFloat = 12.0
            let centroidRect = CGRect(x: centroid.x - centroidRadius / 2, y: centroid.y - centroidRadius / 2,
                                       width: centroidRadius, height: centroidRadius)

            context.setFillColor(UIColor.red.cgColor)
            context.fillEllipse(in: centroidRect)

            context.setStrokeColor(UIColor.yellow.cgColor)
            context.setLineWidth(3.0)
            context.strokeEllipse(in: centroidRect)
        }
    }

    func updatePoints(_ newPoints: [CGPoint]) {
        self.points = newPoints
        setNeedsDisplay()
    }
}
