import CoreGraphics
import Foundation

struct DepthFrame {
    let width: Int
    let height: Int
    var values: [Float]

    func blended(with previous: DepthFrame?, currentWeight: Float) -> DepthFrame {
        guard let previous,
              previous.width == width,
              previous.height == height else {
            return self
        }

        let weight = min(max(currentWeight, 0), 1)
        let mixed = zip(values, previous.values).map { current, old in
            current * weight + old * (1 - weight)
        }
        return DepthFrame(width: width, height: height, values: mixed)
    }

    func grayscaleCGImage() -> CGImage? {
        let bytes = values.map { UInt8(min(max($0, 0), 1) * 255) }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else {
            return nil
        }

        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }
}
