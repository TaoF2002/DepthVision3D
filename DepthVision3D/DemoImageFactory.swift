import UIKit

enum DemoImageFactory {
    static func make() -> UIImage {
        let size = CGSize(width: 960, height: 720)
        return UIGraphicsImageRenderer(size: size).image { context in
            let cg = context.cgContext
            let colors = [
                UIColor(red: 0.05, green: 0.11, blue: 0.24, alpha: 1).cgColor,
                UIColor(red: 0.18, green: 0.45, blue: 0.72, alpha: 1).cgColor
            ] as CFArray
            let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: colors,
                locations: [0, 1]
            )!
            cg.drawLinearGradient(
                gradient,
                start: .zero,
                end: CGPoint(x: 0, y: size.height),
                options: []
            )

            UIColor(red: 0.12, green: 0.24, blue: 0.36, alpha: 1).setFill()
            cg.fillEllipse(in: CGRect(x: 600, y: 90, width: 210, height: 210))

            UIColor(red: 0.96, green: 0.55, blue: 0.20, alpha: 1).setFill()
            UIBezierPath(roundedRect: CGRect(x: 335, y: 235, width: 290, height: 310), cornerRadius: 70).fill()

            UIColor(red: 0.97, green: 0.91, blue: 0.73, alpha: 1).setFill()
            cg.fillEllipse(in: CGRect(x: 405, y: 285, width: 150, height: 150))

            UIColor(red: 0.06, green: 0.08, blue: 0.14, alpha: 0.85).setFill()
            cg.fillEllipse(in: CGRect(x: 448, y: 328, width: 64, height: 64))

            UIColor(red: 0.08, green: 0.16, blue: 0.22, alpha: 1).setFill()
            UIBezierPath(rect: CGRect(x: 0, y: 570, width: 960, height: 150)).fill()

            let title = "DEPTH"
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 76, weight: .black),
                .foregroundColor: UIColor.white.withAlphaComponent(0.92)
            ]
            title.draw(at: CGPoint(x: 44, y: 590), withAttributes: attributes)
        }
    }
}
