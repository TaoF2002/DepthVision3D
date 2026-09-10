import UIKit

struct ImageConversionResult {
    let depth: UIImage
    let stereo: UIImage
}

/// View1 3D mode is treated as a 3840×1080 Full-SBS canvas. Each eye owns a
/// 1920×1080 region and source content is aspect-fitted inside that region.
/// Baking the bars into the result prevents players or display boxes from
/// stretching portrait, square, or ultra-wide media.
enum View1SBSLayout {
    static let eyeSize = CGSize(width: 1920, height: 1080)
    static let outputSize = CGSize(width: 3840, height: 1080)

    static func fittedRect(for sourceSize: CGSize, in bounds: CGRect) -> CGRect {
        guard sourceSize.width > 0, sourceSize.height > 0 else { return bounds }
        let scale = min(bounds.width / sourceSize.width, bounds.height / sourceSize.height)
        let size = CGSize(
            width: sourceSize.width * scale,
            height: sourceSize.height * scale
        )
        return CGRect(
            x: bounds.minX + (bounds.width - size.width) * 0.5,
            y: bounds.minY + (bounds.height - size.height) * 0.5,
            width: size.width,
            height: size.height
        )
    }

    static func evenFittedContentSize(for sourceSize: CGSize) -> CGSize {
        let rect = fittedRect(
            for: sourceSize,
            in: CGRect(origin: .zero, size: eyeSize)
        )
        return CGSize(
            width: CGFloat(max(2, Int(rect.width.rounded()) & ~1)),
            height: CGFloat(max(2, Int(rect.height.rounded()) & ~1))
        )
    }

    static func format(stereoCGImage: CGImage) throws -> UIImage {
        let sourceEyeWidth = stereoCGImage.width / 2
        let sourceEyeHeight = stereoCGImage.height
        guard sourceEyeWidth > 0,
              let leftCG = stereoCGImage.cropping(to: CGRect(
                  x: 0,
                  y: 0,
                  width: sourceEyeWidth,
                  height: sourceEyeHeight
              )),
              let rightCG = stereoCGImage.cropping(to: CGRect(
                  x: sourceEyeWidth,
                  y: 0,
                  width: sourceEyeWidth,
                  height: sourceEyeHeight
              )) else {
            throw StereoRendererError.cannotCreateImage
        }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        let renderer = UIGraphicsImageRenderer(size: outputSize, format: format)
        return renderer.image { context in
            context.cgContext.setFillColor(UIColor.black.cgColor)
            context.cgContext.fill(CGRect(origin: .zero, size: outputSize))

            let eyeBounds = CGRect(origin: .zero, size: eyeSize)
            let contentRect = fittedRect(
                for: CGSize(width: sourceEyeWidth, height: sourceEyeHeight),
                in: eyeBounds
            )
            UIImage(cgImage: leftCG).draw(in: contentRect)
            UIImage(cgImage: rightCG).draw(
                in: contentRect.offsetBy(dx: eyeSize.width, dy: 0)
            )
        }
    }

    static func makeFlatSBS(from image: UIImage) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        let renderer = UIGraphicsImageRenderer(size: outputSize, format: format)
        return renderer.image { context in
            context.cgContext.setFillColor(UIColor.black.cgColor)
            context.cgContext.fill(CGRect(origin: .zero, size: outputSize))

            let eyeBounds = CGRect(origin: .zero, size: eyeSize)
            let contentRect = fittedRect(for: image.size, in: eyeBounds)
            image.draw(in: contentRect)
            image.draw(in: contentRect.offsetBy(dx: eyeSize.width, dy: 0))
        }
    }
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
              let cgImage = image.normalized(maxDimension: 1920).cgImage else {
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

        let view1Stereo = try View1SBSLayout.format(stereoCGImage: stereoCG)
        return ImageConversionResult(
            depth: UIImage(cgImage: depthCG),
            stereo: view1Stereo
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
