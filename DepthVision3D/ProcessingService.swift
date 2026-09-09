import UIKit

struct ImageConversionResult {
    let depth: UIImage
    let stereo: UIImage
}

enum ProcessingServiceError: LocalizedError {
    case depthPrediction(Error)
    case stereoRendering(Error)

    var errorDescription: String? {
        switch self {
        case .depthPrediction(let error):
            return "V2 深度推理失败：\(error.localizedDescription)"
        case .stereoRendering(let error):
            return "Metal 立体合成失败：\(error.localizedDescription)"
        }
    }
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

        let depth: DepthFrame
        do {
            depth = try estimator.predict(cgImage: cgImage)
        } catch {
            throw ProcessingServiceError.depthPrediction(error)
        }
        let strength = Float(cgImage.width) * strengthFraction
        let stereoCG: CGImage
        do {
            stereoCG = try renderer.render(
                image: cgImage,
                depth: depth,
                strength: strength,
                convergence: convergence
            )
        } catch {
            throw ProcessingServiceError.stereoRendering(error)
        }
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
        let target = CGSize(
            width: max(1, (sourceSize.width * scale).rounded()),
            height: max(1, (sourceSize.height * scale).rounded())
        )

        // Photos can deliver HEIF/HDR/Display-P3 images backed by deferred or
        // extended-range storage. They display correctly in UIKit, but some of
        // those CGImage layouts cannot be decoded by MTKTextureLoader. Render
        // once into a predictable standard-range, 8-bit bitmap before passing
        // the image to either Core ML or Metal.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard

        return UIGraphicsImageRenderer(size: target, format: format).image { context in
            context.cgContext.setFillColor(UIColor.black.cgColor)
            context.cgContext.fill(CGRect(origin: .zero, size: target))
            draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
