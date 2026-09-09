@preconcurrency import AVFoundation
import CoreVideo
import Foundation

enum VideoConverterError: LocalizedError {
    case noVideoTrack
    case cannotStartReader
    case cannotStartWriter
    case cannotCreateOutputBuffer
    case appendFailed
    case cannotCreateAudioMix
    case audioExportFailed

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: return "所选文件中没有可读取的视频轨道。"
        case .cannotStartReader: return "无法读取视频。"
        case .cannotStartWriter: return "无法创建输出视频。"
        case .cannotCreateOutputBuffer: return "无法创建视频帧缓冲区。"
        case .appendFailed: return "写入立体视频帧失败。"
        case .cannotCreateAudioMix: return "无法把原视频音轨加入立体视频。"
        case .audioExportFailed: return "导出带声音的立体视频失败。"
        }
    }
}

final class VideoConverter {
    private final class ExportSessionBox: @unchecked Sendable {
        let value: AVAssetExportSession

        init(_ value: AVAssetExportSession) {
            self.value = value
        }
    }

    private struct SilentVideoResult {
        let url: URL
        let sourceTimelineOrigin: CMTime
    }

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
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
        try Task.checkCancellation()

        let conversionTask = Task.detached(priority: .userInitiated) { [self] in
            try convertSynchronously(
                asset: asset,
                videoTrack: videoTrack,
                sourceSize: sourceSize,
                assetDuration: assetDuration,
                strengthFraction: strengthFraction,
                convergence: convergence,
                progress: { value in
                    progress(min(value * 0.95, 0.95))
                }
            )
        }
        let silentResult = try await withTaskCancellationHandler {
            try await conversionTask.value
        } onCancel: {
            conversionTask.cancel()
        }
        var shouldRemoveSilentVideo = true
        defer {
            if shouldRemoveSilentVideo {
                try? FileManager.default.removeItem(at: silentResult.url)
            }
        }

        guard let audioTrack else {
            try Task.checkCancellation()
            shouldRemoveSilentVideo = false
            progress(1)
            return silentResult.url
        }

        let mixedURL = try await Self.attachAudio(
            audioTrack: audioTrack,
            sourceTimelineOrigin: silentResult.sourceTimelineOrigin,
            toVideoAt: silentResult.url
        )
        if Task.isCancelled {
            if mixedURL != silentResult.url {
                try? FileManager.default.removeItem(at: mixedURL)
            }
            throw CancellationError()
        }
        shouldRemoveSilentVideo = mixedURL != silentResult.url
        progress(1)
        return mixedURL
    }

    private func convertSynchronously(
        asset: AVAsset,
        videoTrack: AVAssetTrack,
        sourceSize: CGSize,
        assetDuration: CMTime,
        strengthFraction: Float,
        convergence: Float,
        progress: @escaping (Double) -> Void
    ) throws -> SilentVideoResult {
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
        var shouldKeepOutput = false
        defer {
            if !shouldKeepOutput {
                reader.cancelReading()
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: outputURL)
            }
        }
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
            try Task.checkCancellation()
            try autoreleasepool {
                guard let sourceBuffer = CMSampleBufferGetImageBuffer(sample) else { return }
                let sourceTime = CMSampleBufferGetPresentationTimeStamp(sample)
                if firstPresentationTime == nil { firstPresentationTime = sourceTime }
                let relativeTime = CMTimeSubtract(sourceTime, firstPresentationTime ?? .zero)

                if frameIndex % 3 == 0 || cachedDepth == nil {
                    try Task.checkCancellation()
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
                    try Task.checkCancellation()
                    Thread.sleep(forTimeInterval: 0.002)
                }
                guard adaptor.append(outputBuffer, withPresentationTime: relativeTime) else {
                    throw writer.error ?? VideoConverterError.appendFailed
                }

                frameIndex += 1
                progress(min(max(relativeTime.seconds / duration, 0), 0.99))
            }
        }

        if reader.status == .failed {
            throw reader.error ?? VideoConverterError.cannotStartReader
        }

        writerInput.markAsFinished()
        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting { semaphore.signal() }
        while semaphore.wait(timeout: .now() + 0.05) == .timedOut {
            try Task.checkCancellation()
        }

        guard writer.status == .completed else {
            throw writer.error ?? VideoConverterError.appendFailed
        }
        shouldKeepOutput = true
        progress(1)
        return SilentVideoResult(
            url: outputURL,
            sourceTimelineOrigin: firstPresentationTime ?? .zero
        )
    }

    /// Adds the original audio only after the expensive V2/Metal pass has
    /// completed. Keeping audio out of the frame writer avoids cross-input
    /// back-pressure stalling the depth conversion.
    private static func attachAudio(
        audioTrack: AVAssetTrack,
        sourceTimelineOrigin: CMTime,
        toVideoAt videoURL: URL
    ) async throws -> URL {
        let processedAsset = AVURLAsset(url: videoURL)
        guard let processedVideoTrack = try await processedAsset
            .loadTracks(withMediaType: .video)
            .first else {
            throw VideoConverterError.cannotCreateAudioMix
        }

        let processedDuration = try await processedAsset.load(.duration)
        let audioRange = try await audioTrack.load(.timeRange)
        let sourceVideoEnd = CMTimeAdd(sourceTimelineOrigin, processedDuration)
        let audioStart = CMTimeCompare(audioRange.start, sourceTimelineOrigin) < 0
            ? sourceTimelineOrigin
            : audioRange.start
        let audioRangeEnd = CMTimeRangeGetEnd(audioRange)
        let audioEnd = CMTimeCompare(audioRangeEnd, sourceVideoEnd) > 0
            ? sourceVideoEnd
            : audioRangeEnd

        // An audio track with no overlap cannot contribute sound to this clip.
        guard CMTimeCompare(audioEnd, audioStart) > 0 else {
            return videoURL
        }

        let composition = AVMutableComposition()
        guard let compositionVideo = composition.addMutableTrack(
                  withMediaType: .video,
                  preferredTrackID: kCMPersistentTrackID_Invalid
              ),
              let compositionAudio = composition.addMutableTrack(
                  withMediaType: .audio,
                  preferredTrackID: kCMPersistentTrackID_Invalid
              ) else {
            throw VideoConverterError.cannotCreateAudioMix
        }

        try compositionVideo.insertTimeRange(
            CMTimeRange(start: .zero, duration: processedDuration),
            of: processedVideoTrack,
            at: .zero
        )
        compositionVideo.preferredTransform = try await processedVideoTrack.load(.preferredTransform)

        let destinationAudioStart = CMTimeSubtract(audioStart, sourceTimelineOrigin)
        try compositionAudio.insertTimeRange(
            CMTimeRange(start: audioStart, duration: CMTimeSubtract(audioEnd, audioStart)),
            of: audioTrack,
            at: destinationAudioStart
        )

        guard let exporter = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetPassthrough
        ) else {
            throw VideoConverterError.cannotCreateAudioMix
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DepthVision3D-Audio-\(UUID().uuidString).mp4")
        exporter.outputURL = outputURL
        exporter.outputFileType = .mp4
        exporter.shouldOptimizeForNetworkUse = true

        do {
            try await export(exporter)
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
        return outputURL
    }

    private static func export(_ exporter: AVAssetExportSession) async throws {
        let box = ExportSessionBox(exporter)
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                exporter.exportAsynchronously {
                    let exporter = box.value
                    switch exporter.status {
                    case .completed:
                        continuation.resume()
                    case .cancelled:
                        continuation.resume(throwing: CancellationError())
                    case .failed:
                        continuation.resume(
                            throwing: exporter.error ?? VideoConverterError.audioExportFailed
                        )
                    default:
                        continuation.resume(throwing: VideoConverterError.audioExportFailed)
                    }
                }
            }
        } onCancel: {
            box.value.cancelExport()
        }
    }
}
