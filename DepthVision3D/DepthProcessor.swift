import UIKit

struct DepthProcessingOutput {
    let sbs: UIImage
    let engineLabel: String
}

/// Compatibility layer expected by the View1 Cinema session.
///
/// It deliberately reuses the app's existing Depth Anything V2 pipeline so
/// the phone preview and the external-display result are produced by the same
/// model and renderer.
@MainActor
final class DepthProcessor {
    var throttle = false

    func makeStereoSBS(from image: UIImage) async -> DepthProcessingOutput {
        await convert(
            image,
            strengthFraction: throttle ? 0.018 : 0.025,
            maxParallaxFraction: throttle ? 0.018 : 0.025,
            depthCurve: 1.0,
            label: throttle ? "Depth Anything V2 · Throttled" : "Depth Anything V2"
        )
    }

    func makeDepthRelief(from image: UIImage) async -> DepthProcessingOutput {
        // The company-facing API calls this lane "depth relief". Until a
        // dedicated company algorithm is supplied, keep it as a stronger V2
        // depth-driven SBS presentation rather than showing a raw depth map.
        await convert(
            image,
            strengthFraction: throttle ? 0.025 : 0.040,
            maxParallaxFraction: throttle ? 0.025 : 0.035,
            depthCurve: throttle ? 1.0 : 0.8,
            label: throttle
                ? "Depth Anything V2 · Relief throttled"
                : "Depth Anything V2 · Relief"
        )
    }

    private func convert(
        _ image: UIImage,
        strengthFraction: Float,
        maxParallaxFraction: Float,
        depthCurve: Float,
        label: String
    ) async -> DepthProcessingOutput {
        let input = throttle ? image.normalized(maxDimension: 768) : image
        do {
            let result = try await ProcessingService.shared.convertImage(
                input,
                strengthFraction: strengthFraction,
                convergence: 0.5,
                maxParallaxFraction: maxParallaxFraction,
                depthCurve: depthCurve
            )
            return DepthProcessingOutput(sbs: result.stereo, engineLabel: label)
        } catch {
            return DepthProcessingOutput(
                sbs: Self.makeFlatSBS(from: input),
                engineLabel: "V2 failed: \(error.localizedDescription)"
            )
        }
    }

    private static func makeFlatSBS(from image: UIImage) -> UIImage {
        View1SBSLayout.makeFlatSBS(from: image.normalized(maxDimension: 1920))
    }
}
