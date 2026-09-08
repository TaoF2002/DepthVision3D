@preconcurrency import AVFoundation
import CoreVideo
import Foundation

enum VideoConverterError: LocalizedError {
    case noVideoTrack
    case cannotStartReader
    case cannotStartWriter
    case cannotCreateOutputBuffer
    case appendFailed

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: return "所选文件中没有可读取的视频轨道。"
        case .cannotStartReader: return "无法读取视频。"
        case .cannotStartWriter: return "无法创建输出视频。"
        case .cannotCreateOutputBuffer: return "无法创建视频帧缓冲区。"
        case .appendFailed: return "写入立体视频帧失败。"
        }
    }
}

final class VideoConverter {
    private let estimator: DepthEstimator
    private let renderer: StereoRenderer

    init() throws {
        estimator = try DepthEstimator()
        renderer = try StereoRenderer()
    }

    func convert(
        sourceURL: URL,
        strengthFraction: Float,
        convergence: Float,
        progress: @escaping (Double) -> Void
    ) async throws -> URL {
        let asset = AVURLAsset(url: sourceURL)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoConverterError.noVideoTrack
        }
        let sourceSize = try await videoTrack.load(.naturalSize)
        let assetDuration = try await asset.load(.duration)

        return try await Task.detached(priority: .userInitiated) { [self] in
            try convertSynchronously(
                asset: asset,
                videoTrack: videoTrack,
                sourceSize: sourceSize,
                assetDuration: assetDuration,
                strengthFraction: strengthFraction,
                convergence: convergence,
                progress: progress
            )
        }.value
    }

    private func convertSynchronously(
        asset: AVAsset,
        videoTrack: AVAssetTrack,
        sourceSize: CGSize,
        assetDuration: CMTime,
        strengthFraction: Float,
        convergence: Float,
        progress: @escaping (Double) -> Void
    ) throws -> URL {
        let sourceWidth = max(2, Int(abs(sourceSize.width)))
        let sourceHeight = max(2, Int(abs(sourceSize.height)))
        let maxWidth = 960.0
        let scale = min(1.0, maxWidth / Double(sourceWidth))
        let width = max(2, Int(Double(sourceWidth) * scale) & ~1)
        let height = max(2, Int(Double(sourceHeight) * scale) & ~1)

        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferMetalCompatibilityKey as String: true
            ]
        )
        readerOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(readerOutput) else {
            throw VideoConverterError.cannotStartReader
        }
        reader.add(readerOutput)

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DepthVision3D-\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let writerInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width * 2,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: max(2_000_000, width * height * 8),
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
                ]
            ]
        )
        writerInput.expectsMediaDataInRealTime = false

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width * 2,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
        )
        guard writer.canAdd(writerInput) else {
            throw VideoConverterError.cannotStartWriter
        }
        writer.add(writerInput)

        guard reader.startReading() else {
            throw reader.error ?? VideoConverterError.cannotStartReader
        }
        guard writer.startWriting() else {
            throw writer.error ?? VideoConverterError.cannotStartWriter
        }
        writer.startSession(atSourceTime: .zero)

        let duration = max(assetDuration.seconds, 0.001)
        var frameIndex = 0
        var previousDepth: DepthFrame?
        var cachedDepth: DepthFrame?
        var firstPresentationTime: CMTime?

        while let sample = readerOutput.copyNextSampleBuffer() {
            autoreleasepool {
                guard let sourceBuffer = CMSampleBufferGetImageBuffer(sample) else { return }
                let sourceTime = CMSampleBufferGetPresentationTimeStamp(sample)
                if firstPresentationTime == nil { firstPresentationTime = sourceTime }
                let relativeTime = CMTimeSubtract(sourceTime, firstPresentationTime ?? .zero)

                do {
                    if frameIndex % 3 == 0 || cachedDepth == nil {
                        let current = try estimator.predict(pixelBuffer: sourceBuffer)
                        let filtered = current.blended(with: previousDepth, currentWeight: 0.28)
                        previousDepth = filtered
                        cachedDepth = filtered
                    }
                    guard let depth = cachedDepth,
                          let pool = adaptor.pixelBufferPool else {
                        throw VideoConverterError.cannotCreateOutputBuffer
                    }

                    var outputBuffer: CVPixelBuffer?
                    guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outputBuffer) == kCVReturnSuccess,
                          let outputBuffer else {
                        throw VideoConverterError.cannotCreateOutputBuffer
                    }

                    try renderer.render(
                        pixelBuffer: sourceBuffer,
                        depth: depth,
                        into: outputBuffer,
                        strength: Float(width) * strengthFraction,
                        convergence: convergence
                    )

                    while !writerInput.isReadyForMoreMediaData {
                        Thread.sleep(forTimeInterval: 0.002)
                    }
                    guard adaptor.append(outputBuffer, withPresentationTime: relativeTime) else {
                        throw writer.error ?? VideoConverterError.appendFailed
                    }

                    frameIndex += 1
                    progress(min(max(relativeTime.seconds / duration, 0), 0.99))
                } catch {
                    reader.cancelReading()
                    writer.cancelWriting()
                }
            }

            if reader.status == .cancelled || writer.status == .cancelled {
                throw reader.error ?? writer.error ?? VideoConverterError.appendFailed
            }
        }

        if reader.status == .failed {
            throw reader.error ?? VideoConverterError.cannotStartReader
        }

        writerInput.markAsFinished()
        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting { semaphore.signal() }
        semaphore.wait()

        guard writer.status == .completed else {
            throw writer.error ?? VideoConverterError.appendFailed
        }
        progress(1)
        return outputURL
    }
}
