import CoreImage
import CoreML
import Foundation

enum DepthEstimatorError: LocalizedError {
    case cannotCreateInputBuffer
    case invalidDepthBuffer
    case modelMissing

    var errorDescription: String? {
        switch self {
        case .cannotCreateInputBuffer:
            return "无法创建 Core ML 输入缓冲区。"
        case .invalidDepthBuffer:
            return "Depth Anything 返回了无法读取的深度图。"
        case .modelMissing:
            return "App 包中缺少已编译的 Depth Anything V2 模型。"
        }
    }
}

final class DepthEstimator {
    static let inputWidth = 518
    static let inputHeight = 392

    private let model: MLModel
    private let context = CIContext(options: [.cacheIntermediates: false])

    init() throws {
        let configuration = MLModelConfiguration()
        #if targetEnvironment(simulator)
        // The iOS simulator's Espresso build may not include a compatible
        // MPSGraph engine. CPU mode avoids that backend while remaining fully
        // functional for demonstrations.
        configuration.computeUnits = .cpuOnly
        #else
        configuration.computeUnits = .all
        #endif
        guard let modelURL = Bundle.main.url(
            forResource: "DepthAnythingV2SmallF16",
            withExtension: "mlmodelc"
        ) else {
            throw DepthEstimatorError.modelMissing
        }
        model = try MLModel(contentsOf: modelURL, configuration: configuration)
    }

    func predict(cgImage: CGImage) throws -> DepthFrame {
        try predict(ciImage: CIImage(cgImage: cgImage))
    }

    func predict(pixelBuffer: CVPixelBuffer) throws -> DepthFrame {
        try predict(ciImage: CIImage(cvPixelBuffer: pixelBuffer))
    }

    private func predict(ciImage: CIImage) throws -> DepthFrame {
        guard let input = Self.makePixelBuffer(
            width: Self.inputWidth,
            height: Self.inputHeight,
            pixelFormat: kCVPixelFormatType_32BGRA
        ) else {
            throw DepthEstimatorError.cannotCreateInputBuffer
        }

        let sourceExtent = ciImage.extent.standardized
        guard sourceExtent.width.isFinite,
              sourceExtent.height.isFinite,
              sourceExtent.width > 0,
              sourceExtent.height > 0 else {
            throw DepthEstimatorError.invalidDepthBuffer
        }

        let inputBounds = CGRect(
            x: 0,
            y: 0,
            width: Self.inputWidth,
            height: Self.inputHeight
        )
        let scale = min(
            inputBounds.width / sourceExtent.width,
            inputBounds.height / sourceExtent.height
        )
        let scaledSize = CGSize(
            width: sourceExtent.width * scale,
            height: sourceExtent.height * scale
        )
        let contentRect = CGRect(
            x: (inputBounds.width - scaledSize.width) * 0.5,
            y: (inputBounds.height - scaledSize.height) * 0.5,
            width: scaledSize.width,
            height: scaledSize.height
        )

        let resized = ciImage
            .transformed(by: CGAffineTransform(
                translationX: -sourceExtent.origin.x,
                y: -sourceExtent.origin.y
            ))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(
                translationX: contentRect.minX,
                y: contentRect.minY
            ))
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1))
            .cropped(to: inputBounds)

        context.render(
            resized.composited(over: black),
            to: input,
            bounds: inputBounds,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )

        let provider = try MLDictionaryFeatureProvider(dictionary: [
            "image": MLFeatureValue(pixelBuffer: input)
        ])
        let output = try model.prediction(from: provider)
        guard let depth = output.featureValue(for: "depth")?.imageBufferValue else {
            throw DepthEstimatorError.invalidDepthBuffer
        }
        return try Self.readAndNormalize(
            depth,
            cropRect: Self.integralCropRect(contentRect, within: inputBounds)
        )
    }

    private static func integralCropRect(
        _ rect: CGRect,
        within bounds: CGRect
    ) -> CGRect {
        let minX = max(Int(bounds.minX), Int(floor(rect.minX)))
        let minY = max(Int(bounds.minY), Int(floor(rect.minY)))
        let maxX = min(Int(bounds.maxX), Int(ceil(rect.maxX)))
        let maxY = min(Int(bounds.maxY), Int(ceil(rect.maxY)))
        return CGRect(
            x: minX,
            y: minY,
            width: max(1, maxX - minX),
            height: max(1, maxY - minY)
        )
    }

    private static func readAndNormalize(
        _ pixelBuffer: CVPixelBuffer,
        cropRect: CGRect
    ) throws -> DepthFrame {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let bufferWidth = CVPixelBufferGetWidth(pixelBuffer)
        let bufferHeight = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        let cropX = min(max(0, Int(cropRect.minX)), bufferWidth - 1)
        let cropY = min(max(0, Int(cropRect.minY)), bufferHeight - 1)
        let width = min(max(1, Int(cropRect.width)), bufferWidth - cropX)
        let height = min(max(1, Int(cropRect.height)), bufferHeight - cropY)

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw DepthEstimatorError.invalidDepthBuffer
        }

        var values = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = baseAddress
                .advanced(by: (cropY + y) * bytesPerRow)
                .assumingMemoryBound(to: UInt16.self)
            for x in 0..<width {
                values[y * width + x] = Float(Float16(bitPattern: row[cropX + x]))
            }
        }

        let finite = values.filter(\.isFinite).sorted()
        guard finite.count > 8 else {
            throw DepthEstimatorError.invalidDepthBuffer
        }

        let low = finite[Int(Double(finite.count - 1) * 0.02)]
        let high = finite[Int(Double(finite.count - 1) * 0.98)]
        let range = max(high - low, 0.000_001)

        for index in values.indices {
            let value = values[index].isFinite ? values[index] : low
            values[index] = min(max((value - low) / range, 0), 1)
        }

        return DepthFrame(width: width, height: height, values: values)
    }

    static func makePixelBuffer(
        width: Int,
        height: Int,
        pixelFormat: OSType
    ) -> CVPixelBuffer? {
        let attributes: [CFString: Any] = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            pixelFormat,
            attributes as CFDictionary,
            &buffer
        )
        return status == kCVReturnSuccess ? buffer : nil
    }
}
