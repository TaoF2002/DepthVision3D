import CoreGraphics
import CoreVideo
import Foundation
import Metal
import MetalKit

enum StereoRendererError: LocalizedError {
    case metalUnavailable
    case cannotLoadShader
    case cannotCreateTexture
    case cannotCreateImage

    var errorDescription: String? {
        switch self {
        case .metalUnavailable: return "当前环境不支持 Metal。"
        case .cannotLoadShader: return "无法加载 Metal 立体合成着色器。"
        case .cannotCreateTexture: return "无法创建 Metal 纹理。"
        case .cannotCreateImage: return "无法生成立体图像。"
        }
    }
}

final class StereoRenderer {
    private struct Uniforms {
        var outputWidth: UInt32
        var outputHeight: UInt32
        var strengthPixels: Float
        var convergence: Float
        var maxParallaxFraction: Float
        var depthCurve: Float
    }

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let textureLoader: MTKTextureLoader
    private var textureCache: CVMetalTextureCache?

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            throw StereoRendererError.metalUnavailable
        }
        let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        guard let function = library.makeFunction(name: "stereoSideBySide") else {
            throw StereoRendererError.cannotLoadShader
        }

        self.device = device
        self.queue = queue
        pipeline = try device.makeComputePipelineState(function: function)
        textureLoader = MTKTextureLoader(device: device)
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
    }

    private static let shaderSource = #"""
    #include <metal_stdlib>
    using namespace metal;

    struct StereoUniforms {
        uint outputWidth;
        uint outputHeight;
        float strengthPixels;
        float convergence;
        float maxParallaxFraction;
        float depthCurve;
    };

    kernel void stereoSideBySide(
        texture2d<float, access::sample> colorTexture [[texture(0)]],
        texture2d<float, access::sample> depthTexture [[texture(1)]],
        texture2d<float, access::write> outputTexture [[texture(2)]],
        constant StereoUniforms& uniforms [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        if (gid.x >= uniforms.outputWidth || gid.y >= uniforms.outputHeight) return;
        constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
        uint eyeWidth = uniforms.outputWidth / 2;
        bool rightEye = gid.x >= eyeWidth;
        uint localX = rightEye ? gid.x - eyeWidth : gid.x;
        float2 uv = (float2(localX, gid.y) + 0.5) / float2(eyeWidth, uniforms.outputHeight);
        float relativeDepth = depthTexture.sample(s, uv).r;
        float depthDelta = relativeDepth - uniforms.convergence;
        float sideRange = depthDelta < 0.0
            ? max(uniforms.convergence, 0.0001)
            : max(1.0 - uniforms.convergence, 0.0001);
        float normalizedDistance = clamp(abs(depthDelta) / sideRange, 0.0, 1.0);
        float curvedDistance = pow(
            normalizedDistance,
            max(uniforms.depthCurve, 0.01)
        ) * sideRange;
        float curvedDelta = depthDelta < 0.0 ? -curvedDistance : curvedDistance;
        float disparity = curvedDelta * uniforms.strengthPixels;
        float maxDisparityPixels = float(eyeWidth)
            * max(uniforms.maxParallaxFraction, 0.0) * 0.5;
        disparity = clamp(disparity, -maxDisparityPixels, maxDisparityPixels);
        float direction = rightEye ? -1.0 : 1.0;
        float2 sourceUV = uv + float2(direction * disparity / float(eyeWidth), 0.0);
        outputTexture.write(colorTexture.sample(s, sourceUV), gid);
    }
    """#

    func render(
        image: CGImage,
        depth: DepthFrame,
        strength: Float,
        convergence: Float,
        maxParallaxFraction: Float,
        depthCurve: Float
    ) throws -> CGImage {
        let input = try textureLoader.newTexture(
            cgImage: image,
            options: [
                .SRGB: false,
                .textureUsage: MTLTextureUsage.shaderRead.rawValue
            ]
        )

        guard let depthTexture = makeDepthTexture(depth),
              let output = makeOutputTexture(width: image.width * 2, height: image.height) else {
            throw StereoRendererError.cannotCreateTexture
        }

        try encode(
            input: input,
            depth: depthTexture,
            output: output,
            strength: strength,
            convergence: convergence,
            maxParallaxFraction: maxParallaxFraction,
            depthCurve: depthCurve
        )

        let bytesPerRow = output.width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * output.height)
        output.getBytes(
            &bytes,
            bytesPerRow: bytesPerRow,
            from: MTLRegionMake2D(0, 0, output.width, output.height),
            mipmapLevel: 0
        )

        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let result = CGImage(
                width: output.width,
                height: output.height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: [.byteOrder32Big, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)],
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
              ) else {
            throw StereoRendererError.cannotCreateImage
        }
        return result
    }

    func render(
        pixelBuffer: CVPixelBuffer,
        depth: DepthFrame,
        into outputPixelBuffer: CVPixelBuffer,
        strength: Float,
        convergence: Float,
        maxParallaxFraction: Float,
        depthCurve: Float
    ) throws {
        guard let textureCache,
              let input = makeTexture(
                pixelBuffer: pixelBuffer,
                cache: textureCache,
                usage: .shaderRead
              ),
              let output = makeTexture(
                pixelBuffer: outputPixelBuffer,
                cache: textureCache,
                usage: .shaderWrite
              ),
              let depthTexture = makeDepthTexture(depth) else {
            throw StereoRendererError.cannotCreateTexture
        }

        try encode(
            input: input,
            depth: depthTexture,
            output: output,
            strength: strength,
            convergence: convergence,
            maxParallaxFraction: maxParallaxFraction,
            depthCurve: depthCurve
        )
    }

    private func makeTexture(
        pixelBuffer: CVPixelBuffer,
        cache: CVMetalTextureCache,
        usage: MTLTextureUsage
    ) -> MTLTexture? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        var wrapper: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil,
            cache,
            pixelBuffer,
            [kCVMetalTextureUsage: usage.rawValue] as CFDictionary,
            .bgra8Unorm,
            width,
            height,
            0,
            &wrapper
        )
        guard status == kCVReturnSuccess, let wrapper else { return nil }
        return CVMetalTextureGetTexture(wrapper)
    }

    private func makeDepthTexture(_ depth: DepthFrame) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r32Float,
            width: depth.width,
            height: depth.height,
            mipmapped: false
        )
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }

        depth.values.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            texture.replace(
                region: MTLRegionMake2D(0, 0, depth.width, depth.height),
                mipmapLevel: 0,
                withBytes: base,
                bytesPerRow: depth.width * MemoryLayout<Float>.size
            )
        }
        return texture
    }

    private func makeOutputTexture(width: Int, height: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderWrite, .shaderRead]
        descriptor.storageMode = .shared
        return device.makeTexture(descriptor: descriptor)
    }

    private func encode(
        input: MTLTexture,
        depth: MTLTexture,
        output: MTLTexture,
        strength: Float,
        convergence: Float,
        maxParallaxFraction: Float,
        depthCurve: Float
    ) throws {
        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw StereoRendererError.metalUnavailable
        }

        var uniforms = Uniforms(
            outputWidth: UInt32(output.width),
            outputHeight: UInt32(output.height),
            strengthPixels: strength,
            convergence: convergence,
            maxParallaxFraction: maxParallaxFraction,
            depthCurve: depthCurve
        )

        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(depth, index: 1)
        encoder.setTexture(output, index: 2)
        encoder.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)

        let width = pipeline.threadExecutionWidth
        let height = max(1, pipeline.maxTotalThreadsPerThreadgroup / width)
        // Some simulator Metal devices don't support non-uniform threadgroups.
        // Round the grid up and rely on the kernel's bounds check instead.
        let threadsPerGroup = MTLSize(width: width, height: height, depth: 1)
        let groupCount = MTLSize(
            width: (output.width + width - 1) / width,
            height: (output.height + height - 1) / height,
            depth: 1
        )
        encoder.dispatchThreadgroups(
            groupCount,
            threadsPerThreadgroup: threadsPerGroup
        )
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        if let error = commandBuffer.error {
            throw error
        }
    }
}
