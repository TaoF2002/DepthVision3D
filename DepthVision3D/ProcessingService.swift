import UIKit

struct ImageConversionResult {
    let depth: UIImage
    let stereo: UIImage
}

actor ProcessingService {
    static let shared = ProcessingService()

    private var estimator: DepthEstimator?
    private var renderer: StereoRenderer?

    func prepare() throws {
        if estimator == nil { estimator = try DepthEstimator() }
        if renderer == nil { renderer = try StereoRenderer() }
    }

    func convertImage(
        _ image: UIImage,
        strengthFraction: Float,
        convergence: Float
    ) throws -> ImageConversionResult {
        try prepare()
        guard let estimator, let renderer,
              let cgImage = image.normalized(maxDimension: 1280).cgImage else {
            throw StereoRendererError.cannotCreateImage
        }

        let depth = try estimator.predict(cgImage: cgImage)
        let strength = Float(cgImage.width) * strengthFraction
        let stereoCG = try renderer.render(
            image: cgImage,
            depth: depth,
            strength: strength,
            convergence: convergence
        )
        guard let depthCG = depth.grayscaleCGImage() else {
            throw StereoRendererError.cannotCreateImage
        }

        return ImageConversionResult(
            depth: UIImage(cgImage: depthCG),
            stereo: UIImage(cgImage: stereoCG)
        )
    }
}

extension UIImage {
    func normalized(maxDimension: CGFloat) -> UIImage {
        let sourceSize = size
        let scale = min(1, maxDimension / max(sourceSize.width, sourceSize.height))
        let target = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)

        return UIGraphicsImageRenderer(size: target).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
