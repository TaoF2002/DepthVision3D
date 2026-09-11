@preconcurrency import AVFoundation
import CoreImage
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

struct VideoConversionResult {
    let url: URL
    let metrics: VideoProcessingMetrics
}

struct VideoProcessingMetrics {
    let totalSeconds: TimeInterval
    let engineInitializationSeconds: TimeInterval
    let assetLoadingSeconds: TimeInterval
    let pipelineSetupSeconds: TimeInterval
    let frameLoopSeconds: TimeInterval
    let frameReadSeconds: TimeInterval
    let orientationAndScaleSeconds: TimeInterval
    let depthInferenceSeconds: TimeInterval
    let stereoRenderingSeconds: TimeInterval
    let outputLayoutSeconds: TimeInterval
    let encodingWaitAndAppendSeconds: TimeInterval
    let encodingFinalizationSeconds: TimeInterval
    let audioPackagingSeconds: TimeInterval
    let silentPipelineSeconds: TimeInterval
    let sourceDurationSeconds: TimeInterval
    let frameCount: Int
    let depthInferenceCount: Int
    let contentWidth: Int
    let contentHeight: Int
    let audioAttached: Bool

    var report: String {
        let sourceFPS = sourceDurationSeconds > 0
            ? Double(frameCount) / sourceDurationSeconds
            : 0
        let processingFPS = frameLoopSeconds > 0
            ? Double(frameCount) / frameLoopSeconds
            : 0
        let inferenceAverage = depthInferenceCount > 0
            ? depthInferenceSeconds * 1_000 / Double(depthInferenceCount)
            : 0
        let audioText = audioAttached
            ? Self.seconds(audioPackagingSeconds)
            : "未封装音轨（\(Self.seconds(audioPackagingSeconds))）"

        return [
            "视频性能统计",
            "总耗时：\(Self.seconds(totalSeconds))",
            "素材：\(Self.seconds(sourceDurationSeconds)) / \(frameCount)帧 / 约\(Self.decimal(sourceFPS))fps",
            "逐帧处理速度：\(Self.decimal(processingFPS))帧/秒",
            "内容区域：\(contentWidth)×\(contentHeight)，输出：3840×1080",
            "引擎初始化：\(Self.seconds(engineInitializationSeconds))",
            "素材信息读取：\(Self.seconds(assetLoadingSeconds))",
            "读写管线准备：\(Self.seconds(pipelineSetupSeconds))",
            "取帧/解码等待：\(Self.seconds(frameReadSeconds))",
            "方向修正与缩放：\(Self.seconds(orientationAndScaleSeconds))",
            "V2推理：\(Self.seconds(depthInferenceSeconds))（\(depthInferenceCount)次，平均\(Self.milliseconds(inferenceAverage))）",
            "Metal SBS：\(Self.seconds(stereoRenderingSeconds))",
            "3840×1080布局：\(Self.seconds(outputLayoutSeconds))",
            "编码等待与写入：\(Self.seconds(encodingWaitAndAppendSeconds))",
            "编码收尾：\(Self.seconds(encodingFinalizationSeconds))",
            "无声视频阶段：\(Self.seconds(silentPipelineSeconds))",
            "音频封装：\(audioText)"
        ].joined(separator: "\n")
    }

    private static func seconds(_ value: TimeInterval) -> String {
        String(format: "%.3f秒", value)
    }

    private static func milliseconds(_ value: TimeInterval) -> String {
        String(format: "%.2f毫秒", value)
    }

    private static func decimal(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}

final class VideoConverter {
    private final class ExportSessionBox: @unchecked Sendable {
        let value: AVAssetExportSession

        init(_ value: AVAssetExportSession) {
            self.value = value
        }
    }

    private struct SilentVideoTiming {
        let pipelineSeconds: TimeInterval
        let setupSeconds: TimeInterval
        let frameLoopSeconds: TimeInterval
        let frameReadSeconds: TimeInterval
        let orientationAndScaleSeconds: TimeInterval
        let depthInferenceSeconds: TimeInterval
        let stereoRenderingSeconds: TimeInterval
        let outputLayoutSeconds: TimeInterval
        let encodingWaitAndAppendSeconds: TimeInterval
        let encodingFinalizationSeconds: TimeInterval
        let frameCount: Int
        let depthInferenceCount: Int
        let contentWidth: Int
        let contentHeight: Int
    }

    private struct SilentVideoResult {
        let url: URL
        let sourceTimelineOrigin: CMTime
        let timing: SilentVideoTiming
    }

    private let estimator: DepthEstimator
    private let renderer: StereoRenderer
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private let engineInitializationSeconds: TimeInterval

    init() throws {
        let start = ProcessInfo.processInfo.systemUptime
        estimator = try DepthEstimator()
        renderer = try StereoRenderer()
        engineInitializationSeconds = ProcessInfo.processInfo.systemUptime - start
    }

    func convert(
        sourceURL: URL,
        strengthFraction: Float,
        convergence: Float,
        maxParallaxFraction: Float,
        depthCurve: Float,
        progress: @escaping (Double) -> Void
    ) async throws -> VideoConversionResult {
        let conversionStart = ProcessInfo.processInfo.systemUptime
        let assetLoadingStart = ProcessInfo.processInfo.systemUptime
        let asset = AVURLAsset(url: sourceURL)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoConverterError.noVideoTrack
        }
        let sourceSize = try await videoTrack.load(.naturalSize)
        let sourceTransform = try await videoTrack.load(.preferredTransform)
        let assetDuration = try await asset.load(.duration)
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
        let assetLoadingSeconds = ProcessInfo.processInfo.systemUptime - assetLoadingStart
        try Task.checkCancellation()

        let conversionTask = Task.detached(priority: .userInitiated) { [self] in
            try convertSynchronously(
                asset: asset,
                videoTrack: videoTrack,
                sourceSize: sourceSize,
                sourceTransform: sourceTransform,
                assetDuration: assetDuration,
                strengthFraction: strengthFraction,
                convergence: convergence,
                maxParallaxFraction: maxParallaxFraction,
                depthCurve: depthCurve,
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
            return makeResult(
                url: silentResult.url,
                silentResult: silentResult,
                assetLoadingSeconds: assetLoadingSeconds,
                sourceDurationSeconds: assetDuration.seconds,
                audioPackagingSeconds: 0,
                audioAttached: false,
                conversionStart: conversionStart
            )
        }

        let audioStart = ProcessInfo.processInfo.systemUptime
        let mixedURL = try await Self.attachAudio(
            audioTrack: audioTrack,
            sourceTimelineOrigin: silentResult.sourceTimelineOrigin,
            toVideoAt: silentResult.url
        )
        let audioPackagingSeconds = ProcessInfo.processInfo.systemUptime - audioStart
        if Task.isCancelled {
            if mixedURL != silentResult.url {
                try? FileManager.default.removeItem(at: mixedURL)
            }
            throw CancellationError()
        }
        shouldRemoveSilentVideo = mixedURL != silentResult.url
        progress(1)
        return makeResult(
            url: mixedURL,
            silentResult: silentResult,
            assetLoadingSeconds: assetLoadingSeconds,
            sourceDurationSeconds: assetDuration.seconds,
            audioPackagingSeconds: audioPackagingSeconds,
            audioAttached: mixedURL != silentResult.url,
            conversionStart: conversionStart
        )
    }

    private func makeResult(
        url: URL,
        silentResult: SilentVideoResult,
        assetLoadingSeconds: TimeInterval,
        sourceDurationSeconds: TimeInterval,
        audioPackagingSeconds: TimeInterval,
        audioAttached: Bool,
        conversionStart: TimeInterval
    ) -> VideoConversionResult {
        let timing = silentResult.timing
        let metrics = VideoProcessingMetrics(
            totalSeconds: engineInitializationSeconds
                + ProcessInfo.processInfo.systemUptime
                - conversionStart,
            engineInitializationSeconds: engineInitializationSeconds,
            assetLoadingSeconds: assetLoadingSeconds,
            pipelineSetupSeconds: timing.setupSeconds,
            frameLoopSeconds: timing.frameLoopSeconds,
            frameReadSeconds: timing.frameReadSeconds,
            orientationAndScaleSeconds: timing.orientationAndScaleSeconds,
            depthInferenceSeconds: timing.depthInferenceSeconds,
            stereoRenderingSeconds: timing.stereoRenderingSeconds,
            outputLayoutSeconds: timing.outputLayoutSeconds,
            encodingWaitAndAppendSeconds: timing.encodingWaitAndAppendSeconds,
            encodingFinalizationSeconds: timing.encodingFinalizationSeconds,
            audioPackagingSeconds: audioPackagingSeconds,
            silentPipelineSeconds: timing.pipelineSeconds,
            sourceDurationSeconds: max(sourceDurationSeconds, 0),
            frameCount: timing.frameCount,
            depthInferenceCount: timing.depthInferenceCount,
            contentWidth: timing.contentWidth,
            contentHeight: timing.contentHeight,
            audioAttached: audioAttached
        )
        print("[DepthVision3D]\n\(metrics.report)")
        return VideoConversionResult(url: url, metrics: metrics)
    }

    private func convertSynchronously(
        asset: AVAsset,
        videoTrack: AVAssetTrack,
        sourceSize: CGSize,
        sourceTransform: CGAffineTransform,
        assetDuration: CMTime,
        strengthFraction: Float,
        convergence: Float,
        maxParallaxFraction: Float,
        depthCurve: Float,
        progress: @escaping (Double) -> Void
    ) throws -> SilentVideoResult {
        let pipelineStart = ProcessInfo.processInfo.systemUptime
        let transformedRect = CGRect(origin: .zero, size: sourceSize)
            .applying(sourceTransform)
            .standardized
        let orientedSize = CGSize(
            width: abs(transformedRect.width),
            height: abs(transformedRect.height)
        )
        let contentSize = View1SBSLayout.evenFittedContentSize(for: orientedSize)
        let contentWidth = Int(contentSize.width)
        let contentHeight = Int(contentSize.height)
        let eyeWidth = Int(View1SBSLayout.eyeSize.width)
        let eyeHeight = Int(View1SBSLayout.eyeSize.height)
        let outputWidth = eyeWidth * 2
        let outputHeight = eyeHeight

        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferMetalCompatibilityKey as String: true
            ]
        )
        readerOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(readerOutput) else {
            throw VideoConverterError.cannotStartReader
        }
        reader.add(readerOutput)

        guard let orientedFramePool = Self.makePixelBufferPool(
                  width: contentWidth,
                  height: contentHeight
              ),
              let stereoContentPool = Self.makePixelBufferPool(
                  width: contentWidth * 2,
                  height: contentHeight
              ) else {
            throw VideoConverterError.cannotCreateOutputBuffer
        }

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
                AVVideoWidthKey: outputWidth,
                AVVideoHeightKey: outputHeight,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: max(2_000_000, eyeWidth * eyeHeight * 8),
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
                ]
            ]
        )
        writerInput.expectsMediaDataInRealTime = false

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: outputWidth,
                kCVPixelBufferHeightKey as String: outputHeight,
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
        let pipelineSetupSeconds = ProcessInfo.processInfo.systemUptime - pipelineStart

        let rawDuration = assetDuration.seconds
        let duration = rawDuration.isFinite ? max(rawDuration, 0.001) : 0.001
        var frameIndex = 0
        var depthInferenceCount = 0
        var previousDepth: DepthFrame?
        var cachedDepth: DepthFrame?
        var firstPresentationTime: CMTime?
        var frameReadSeconds: TimeInterval = 0
        var orientationAndScaleSeconds: TimeInterval = 0
        var depthInferenceSeconds: TimeInterval = 0
        var stereoRenderingSeconds: TimeInterval = 0
        var outputLayoutSeconds: TimeInterval = 0
        var encodingWaitAndAppendSeconds: TimeInterval = 0

        let frameLoopStart = ProcessInfo.processInfo.systemUptime
        while true {
            let frameReadStart = ProcessInfo.processInfo.systemUptime
            guard let sample = readerOutput.copyNextSampleBuffer() else {
                frameReadSeconds += ProcessInfo.processInfo.systemUptime - frameReadStart
                break
            }
            frameReadSeconds += ProcessInfo.processInfo.systemUptime - frameReadStart
            try Task.checkCancellation()
            try autoreleasepool {
                guard let sourceBuffer = CMSampleBufferGetImageBuffer(sample) else { return }
                let sourceTime = CMSampleBufferGetPresentationTimeStamp(sample)
                if firstPresentationTime == nil { firstPresentationTime = sourceTime }
                let relativeTime = CMTimeSubtract(sourceTime, firstPresentationTime ?? .zero)

                let orientationStart = ProcessInfo.processInfo.systemUptime
                guard let orientedBuffer = Self.makePixelBuffer(from: orientedFramePool) else {
                    throw VideoConverterError.cannotCreateOutputBuffer
                }
                try renderOrientedFrame(
                    sourceBuffer,
                    transform: sourceTransform,
                    into: orientedBuffer
                )
                orientationAndScaleSeconds += ProcessInfo.processInfo.systemUptime
                    - orientationStart

                if frameIndex % 3 == 0 || cachedDepth == nil {
                    try Task.checkCancellation()
                    let depthStart = ProcessInfo.processInfo.systemUptime
                    let current = try estimator.predict(pixelBuffer: orientedBuffer)
                    let filtered = current.blended(with: previousDepth, currentWeight: 0.28)
                    previousDepth = filtered
                    cachedDepth = filtered
                    depthInferenceSeconds += ProcessInfo.processInfo.systemUptime - depthStart
                    depthInferenceCount += 1
                }
                guard let depth = cachedDepth,
                      let pool = adaptor.pixelBufferPool else {
                    throw VideoConverterError.cannotCreateOutputBuffer
                }

                let stereoStart = ProcessInfo.processInfo.systemUptime
                guard let stereoContentBuffer = Self.makePixelBuffer(from: stereoContentPool) else {
                    throw VideoConverterError.cannotCreateOutputBuffer
                }
                try renderer.render(
                    pixelBuffer: orientedBuffer,
                    depth: depth,
                    into: stereoContentBuffer,
                    strength: Float(contentWidth) * strengthFraction,
                    convergence: convergence,
                    maxParallaxFraction: maxParallaxFraction,
                    depthCurve: depthCurve
                )
                stereoRenderingSeconds += ProcessInfo.processInfo.systemUptime - stereoStart

                let layoutStart = ProcessInfo.processInfo.systemUptime
                guard let outputBuffer = Self.makePixelBuffer(from: pool) else {
                    throw VideoConverterError.cannotCreateOutputBuffer
                }
                renderStereoContent(
                    stereoContentBuffer,
                    contentSize: contentSize,
                    into: outputBuffer
                )
                outputLayoutSeconds += ProcessInfo.processInfo.systemUptime - layoutStart

                let encodingStart = ProcessInfo.processInfo.systemUptime
                while !writerInput.isReadyForMoreMediaData {
                    try Task.checkCancellation()
                    Thread.sleep(forTimeInterval: 0.002)
                }
                guard adaptor.append(outputBuffer, withPresentationTime: relativeTime) else {
                    throw writer.error ?? VideoConverterError.appendFailed
                }
                encodingWaitAndAppendSeconds += ProcessInfo.processInfo.systemUptime
                    - encodingStart

                frameIndex += 1
                progress(min(max(relativeTime.seconds / duration, 0), 0.99))
            }
        }
        let frameLoopSeconds = ProcessInfo.processInfo.systemUptime - frameLoopStart

        if reader.status == .failed {
            throw reader.error ?? VideoConverterError.cannotStartReader
        }

        let encodingFinalizationStart = ProcessInfo.processInfo.systemUptime
        writerInput.markAsFinished()
        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting { semaphore.signal() }
        while semaphore.wait(timeout: .now() + 0.05) == .timedOut {
            try Task.checkCancellation()
        }

        guard writer.status == .completed else {
            throw writer.error ?? VideoConverterError.appendFailed
        }
        let encodingFinalizationSeconds = ProcessInfo.processInfo.systemUptime
            - encodingFinalizationStart
        let pipelineSeconds = ProcessInfo.processInfo.systemUptime - pipelineStart
        shouldKeepOutput = true
        progress(1)
        return SilentVideoResult(
            url: outputURL,
            sourceTimelineOrigin: firstPresentationTime ?? .zero,
            timing: SilentVideoTiming(
                pipelineSeconds: pipelineSeconds,
                setupSeconds: pipelineSetupSeconds,
                frameLoopSeconds: frameLoopSeconds,
                frameReadSeconds: frameReadSeconds,
                orientationAndScaleSeconds: orientationAndScaleSeconds,
                depthInferenceSeconds: depthInferenceSeconds,
                stereoRenderingSeconds: stereoRenderingSeconds,
                outputLayoutSeconds: outputLayoutSeconds,
                encodingWaitAndAppendSeconds: encodingWaitAndAppendSeconds,
                encodingFinalizationSeconds: encodingFinalizationSeconds,
                frameCount: frameIndex,
                depthInferenceCount: depthInferenceCount,
                contentWidth: contentWidth,
                contentHeight: contentHeight
            )
        )
    }

    private func renderOrientedFrame(
        _ sourceBuffer: CVPixelBuffer,
        transform: CGAffineTransform,
        into destinationBuffer: CVPixelBuffer
    ) throws {
        var image = CIImage(cvPixelBuffer: sourceBuffer).transformed(by: transform)
        var extent = image.extent.standardized
        guard extent.width.isFinite, extent.height.isFinite,
              extent.width > 0, extent.height > 0 else {
            throw VideoConverterError.cannotCreateOutputBuffer
        }

        image = image.transformed(by: CGAffineTransform(
            translationX: -extent.minX,
            y: -extent.minY
        ))
        extent = image.extent.standardized

        let targetSize = CGSize(
            width: CVPixelBufferGetWidth(destinationBuffer),
            height: CVPixelBufferGetHeight(destinationBuffer)
        )
        let scale = min(targetSize.width / extent.width, targetSize.height / extent.height)
        image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        extent = image.extent.standardized
        image = image.transformed(by: CGAffineTransform(
            translationX: (targetSize.width - extent.width) * 0.5 - extent.minX,
            y: (targetSize.height - extent.height) * 0.5 - extent.minY
        ))

        let bounds = CGRect(origin: .zero, size: targetSize)
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1))
            .cropped(to: bounds)
        ciContext.render(
            image.composited(over: black),
            to: destinationBuffer,
            bounds: bounds,
            colorSpace: colorSpace
        )
    }

    private func renderStereoContent(
        _ stereoBuffer: CVPixelBuffer,
        contentSize: CGSize,
        into outputBuffer: CVPixelBuffer
    ) {
        let contentWidth = contentSize.width
        let contentHeight = contentSize.height
        let eyeWidth = View1SBSLayout.eyeSize.width
        let eyeHeight = View1SBSLayout.eyeSize.height
        let offsetX = (eyeWidth - contentWidth) * 0.5
        let offsetY = (eyeHeight - contentHeight) * 0.5

        let stereo = CIImage(cvPixelBuffer: stereoBuffer)
        let left = stereo
            .cropped(to: CGRect(x: 0, y: 0, width: contentWidth, height: contentHeight))
            .transformed(by: CGAffineTransform(translationX: offsetX, y: offsetY))
        let right = stereo
            .cropped(to: CGRect(
                x: contentWidth,
                y: 0,
                width: contentWidth,
                height: contentHeight
            ))
            .transformed(by: CGAffineTransform(
                translationX: eyeWidth + offsetX - contentWidth,
                y: offsetY
            ))

        let outputBounds = CGRect(origin: .zero, size: View1SBSLayout.outputSize)
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1))
            .cropped(to: outputBounds)
        let composed = left.composited(over: right.composited(over: black))
        ciContext.render(
            composed,
            to: outputBuffer,
            bounds: outputBounds,
            colorSpace: colorSpace
        )
    }

    private static func makePixelBufferPool(
        width: Int,
        height: Int
    ) -> CVPixelBufferPool? {
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(
            nil,
            nil,
            attributes as CFDictionary,
            &pool
        )
        return status == kCVReturnSuccess ? pool : nil
    }

    private static func makePixelBuffer(
        from pool: CVPixelBufferPool
    ) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        return status == kCVReturnSuccess ? buffer : nil
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
