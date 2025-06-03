class LandmarkOverlayView: UIView {
    var points: [CGPoint] = []

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }

        context.setFillColor(UIColor.red.cgColor)
        for point in points {
            let radius: CGFloat = 6.0
            let circleRect = CGRect(x: point.x - radius/2, y: point.y - radius/2, width: radius, height: radius)
            context.fillEllipse(in: circleRect)
        }
    }

    func updatePoints(_ newPoints: [CGPoint]) {
        self.points = newPoints
        setNeedsDisplay()
    }
}
