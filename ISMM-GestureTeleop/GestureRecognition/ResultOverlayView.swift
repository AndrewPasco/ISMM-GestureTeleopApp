//
//  LandmarkOverlayView.swift
//  ISMM-GestureTeleop
//
//  Created by Andrew Pasco on 03/06/25.
//

import UIKit
import simd

class ResultOverlayView: UIView {
    var points: [CGPoint]? = []
    var messageLabel: String? = nil

    // 3D coordinate frame
    var centroid3D: SIMD3<Double>? = nil
    var axes3D: matrix_double3x3? = nil
    var intrinsics: matrix_float3x3? = nil
    
    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else {
            return
        }
        
        // Gesture label
        if let message = messageLabel {
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.alignment = .center

            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 24, weight: .bold),
                .foregroundColor: UIColor.green,
                .paragraphStyle: paragraphStyle
            ]

            let textRect = CGRect(x: 0, y: 720, width: rect.width, height: 30)
            message.draw(in: textRect, withAttributes: attributes)
        }
        
        let points = points ?? []

        // Draw landmarks
        for point in points {
            let radius: CGFloat = 8.0
            let circleRect = CGRect(x: point.x - radius / 2, y: point.y - radius / 2, width: radius, height: radius)

            context.setFillColor(UIColor.red.cgColor)
            context.fillEllipse(in: circleRect)

            context.setStrokeColor(UIColor.yellow.cgColor)
            context.setLineWidth(2.0)
            context.strokeEllipse(in: circleRect)
        }

        // Draw centroid (from 2D points, optional)
        if !points.isEmpty {
            let sum = points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
            let centroid = CGPoint(x: sum.x / CGFloat(points.count), y: sum.y / CGFloat(points.count))

            let radius: CGFloat = 12.0
            let rect = CGRect(x: centroid.x - radius/2, y: centroid.y - radius/2, width: radius, height: radius)

            context.setFillColor(UIColor.red.cgColor)
            context.fillEllipse(in: rect)

            context.setStrokeColor(UIColor.yellow.cgColor)
            context.setLineWidth(3.0)
            context.strokeEllipse(in: rect)
        }

// Not currently working: low priority
//        // Draw 3D coordinate axes
//        if let centroid3D = centroid3D, let axes = axes3D, let K = intrinsics {
//            let fx = Double(K.columns.0.x)
//            let fy = Double(K.columns.1.y)
//            let cx = Double(K.columns.2.x)
//            let cy = Double(K.columns.2.y)
//
//            let project: (SIMD3<Double>) -> CGPoint? = { point in
//                guard point.z > 0 else {
//                    print("z < 0")
//                    return nil
//                } // avoid projecting behind the camera
//                let x = point.x / point.z
//                let y = point.y / point.z
//                let u = fx * x + cx
//                let v = fy * y + cy
//                return CGPoint(x: u, y: v)
//            }
//
//            let origin2D = project(centroid3D)
//            let scale = 0.05
//            let xEnd2D = project(centroid3D + axes[0] * scale)
//            let yEnd2D = project(centroid3D + axes[1] * scale)
//            let zEnd2D = project(centroid3D + axes[2] * scale)
//
//            if let o = origin2D {
//                if let x = xEnd2D {
//                    context.setStrokeColor(UIColor.red.cgColor)
//                    context.setLineWidth(3.0)
//                    context.move(to: o)
//                    context.addLine(to: x)
//                    context.strokePath()
//                }
//                if let y = yEnd2D {
//                    context.setStrokeColor(UIColor.green.cgColor)
//                    context.setLineWidth(3.0)
//                    context.move(to: o)
//                    context.addLine(to: y)
//                    context.strokePath()
//                }
//                if let z = zEnd2D {
//                    context.setStrokeColor(UIColor.blue.cgColor)
//                    context.setLineWidth(3.0)
//                    context.move(to: o)
//                    context.addLine(to: z)
//                    context.strokePath()
//                }
//            }
//        }
    }

    // Update everything at once
    func update(points: [CGPoint]?, messageLabel: String?,
                centroid3D: SIMD3<Double>?, axes3D: matrix_double3x3?,
                intrinsics: matrix_float3x3?) {
        self.points = points
        self.messageLabel = messageLabel
        self.centroid3D = centroid3D
        self.axes3D = axes3D
        self.intrinsics = intrinsics
        DispatchQueue.main.async {
                self.setNeedsDisplay()
                self.layer.setNeedsDisplay()
        }
    }
}
