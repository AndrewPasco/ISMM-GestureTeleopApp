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
    var centroid3D: simd_double3? = nil
    var axes3D: matrix_double3x3? = nil
    var intrinsics: matrix_float3x3? = nil
    
    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else {
            return
        }
        
        if let message = messageLabel, let context = UIGraphicsGetCurrentContext() {
            context.saveGState()
            
            // Move to top-left corner of the screen and rotate 90° clockwise
            // This makes the text appear at the top of the screen when device is rotated right
            context.translateBy(x: 0, y: 0)
            context.rotate(by: .pi / 2)
            
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.alignment = .center
            
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 32, weight: .bold),
                .foregroundColor: UIColor.green,
                .paragraphStyle: paragraphStyle
            ]
            
            // Position text at what will be the top of the screen after rotation
            let inset: CGFloat = 20
            let textRect = CGRect(x: inset, y: -360, width: rect.height - 2 * inset, height: 40)
            message.draw(in: textRect, withAttributes: attributes)
            
            context.restoreGState()
        }
        
        let points = points ?? []
        
        // Draw landmarks
//        for point in points {
//            let radius: CGFloat = 8.0
//            let circleRect = CGRect(x: point.x - radius / 2, y: point.y - radius / 2, width: radius, height: radius)
//            
//            context.setFillColor(UIColor.red.cgColor)
//            context.fillEllipse(in: circleRect)
//            
//            context.setStrokeColor(UIColor.yellow.cgColor)
//            context.setLineWidth(2.0)
//            context.strokeEllipse(in: circleRect)
//        }
        
        
        // Draw 3D coordinate axes on wrist landmark (points[0])
        if let centroid3D = centroid3D, let axes = axes3D, let K = intrinsics, !points.isEmpty {
            // Camera intrinsics are for 1920x1080, but preview is 763x390
            let cameraWidth: Double = 1920.0
            let cameraHeight: Double = 1080.0
            let previewWidth = Double(DefaultConstants.PREVIEW_DIMS.HEIGHT)   // 763
            let previewHeight = Double(DefaultConstants.PREVIEW_DIMS.WIDTH) // 390
            
            // Calculate scaling factors
            let scaleX = previewWidth / cameraWidth
            let scaleY = previewHeight / cameraHeight
            
            // Scale the intrinsics to match preview resolution
            let fx = Double(K.columns.0.x) * scaleX
            let fy = Double(K.columns.1.y) * scaleY
            let cx = Double(K.columns.2.x) * scaleX  // Principal point x
            let cy = Double(K.columns.2.y) * scaleY  // Principal point y
            
            let project: (SIMD3<Double>) -> CGPoint? = { point in
                guard point.z > 0 else {
                    print("Point behind camera: z = \(point.z)")
                    return nil
                }
                
                // Project 3D point to normalized image coordinates
                let x_norm = point.x / point.z
                let y_norm = point.y / point.z
                
                // Convert to pixel coordinates (now scaled for preview resolution)
                let u = fx * x_norm + cx
                let v = fy * y_norm + cy
                
                // Transform from camera image coordinates to UIView coordinates
                // Assuming your camera is rotated 90° clockwise relative to the UI
                let screen_x = previewWidth - v  // Camera's y becomes screen's x
                let screen_y = previewHeight - u  // Camera's x becomes inverted screen's y
                
                return CGPoint(x: screen_x, y: screen_y)
            }
            
            // Use the wrist landmark position (points[0]) as the origin
            let wristPosition2D = points[0]
            
            // Project the 3D coordinate frame endpoints from the centroid3D position
            let scale = 0.08  // Increased scale for better visibility
            
            // Calculate the end points of each axis in 3D, then project them
            let xEnd2D = project(centroid3D - axes.columns.0 * scale)  // X-axis (red)
            let yEnd2D = project(centroid3D - axes.columns.1 * scale)  // Y-axis (green) (- is correct, but since preview is mirrored it doesn't look like a right handed frame unless you mirror the image)
            let zEnd2D = project(centroid3D - axes.columns.2 * scale)  // Z-axis (blue)
            let origin3D_projected = project(centroid3D)  // Project the 3D origin for direction calculation
            
            // Calculate direction vectors and draw axes from wrist landmark position
            if let o = origin3D_projected {
                // Calculate direction vectors from projected 3D origin to axis endpoints
                let xDir = xEnd2D.map { CGPoint(x: $0.x - o.x, y: $0.y - o.y) }
                let yDir = yEnd2D.map { CGPoint(x: $0.x - o.x, y: $0.y - o.y) }
                let zDir = zEnd2D.map { CGPoint(x: $0.x - o.x, y: $0.y - o.y) }
                
                // Draw X-axis from wrist landmark
                if let xDirection = xDir {
                    let xEndWrist = CGPoint(x: wristPosition2D.x + xDirection.x, y: wristPosition2D.y + xDirection.y)
                    context.setStrokeColor(UIColor.red.cgColor)
                    context.setLineWidth(4.0)
                    context.move(to: wristPosition2D)
                    context.addLine(to: xEndWrist)
                    context.strokePath()
                    
                    // Add arrow head for X-axis
                    let angle = atan2(xDirection.y, xDirection.x)
                    let arrowLength: CGFloat = 10
                    let arrowAngle: CGFloat = .pi / 6
                    
                    context.move(to: xEndWrist)
                    context.addLine(to: CGPoint(x: xEndWrist.x - arrowLength * cos(angle - arrowAngle),
                                                y: xEndWrist.y - arrowLength * sin(angle - arrowAngle)))
                    context.move(to: xEndWrist)
                    context.addLine(to: CGPoint(x: xEndWrist.x - arrowLength * cos(angle + arrowAngle),
                                                y: xEndWrist.y - arrowLength * sin(angle + arrowAngle)))
                    context.strokePath()
                }
                
                // Draw Y-axis from wrist landmark
                if let yDirection = yDir {
                    let yEndWrist = CGPoint(x: wristPosition2D.x + yDirection.x, y: wristPosition2D.y + yDirection.y)
                    context.setStrokeColor(UIColor.green.cgColor)
                    context.setLineWidth(4.0)
                    context.move(to: wristPosition2D)
                    context.addLine(to: yEndWrist)
                    context.strokePath()
                    
                    // Add arrow head for Y-axis
                    let angle = atan2(yDirection.y, yDirection.x)
                    let arrowLength: CGFloat = 10
                    let arrowAngle: CGFloat = .pi / 6
                    
                    context.move(to: yEndWrist)
                    context.addLine(to: CGPoint(x: yEndWrist.x - arrowLength * cos(angle - arrowAngle),
                                                y: yEndWrist.y - arrowLength * sin(angle - arrowAngle)))
                    context.move(to: yEndWrist)
                    context.addLine(to: CGPoint(x: yEndWrist.x - arrowLength * cos(angle + arrowAngle),
                                                y: yEndWrist.y - arrowLength * sin(angle + arrowAngle)))
                    context.strokePath()
                }
                
                // Draw Z-axis from wrist landmark
                if let zDirection = zDir {
                    let zEndWrist = CGPoint(x: wristPosition2D.x + zDirection.x, y: wristPosition2D.y + zDirection.y)
                    context.setStrokeColor(UIColor.blue.cgColor)
                    context.setLineWidth(4.0)
                    context.move(to: wristPosition2D)
                    context.addLine(to: zEndWrist)
                    context.strokePath()
                    
                    // Add arrow head for Z-axis
                    let angle = atan2(zDirection.y, zDirection.x)
                    let arrowLength: CGFloat = 10
                    let arrowAngle: CGFloat = .pi / 6
                    
                    context.move(to: zEndWrist)
                    context.addLine(to: CGPoint(x: zEndWrist.x - arrowLength * cos(angle - arrowAngle),
                                                y: zEndWrist.y - arrowLength * sin(angle - arrowAngle)))
                    context.move(to: zEndWrist)
                    context.addLine(to: CGPoint(x: zEndWrist.x - arrowLength * cos(angle + arrowAngle),
                                                y: zEndWrist.y - arrowLength * sin(angle + arrowAngle)))
                    context.strokePath()
                }
            }
        }
    }

        
        
    // Update everything at once
    func update(points: [CGPoint]?,
                messageLabel: String?,
                centroid3D: simd_double3?,
                axes3D: matrix_double3x3?,
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
