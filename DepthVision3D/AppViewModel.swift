import AVFoundation
import CoreTransferable
import Foundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

private struct ImportedVideo: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { video in
            SentTransferredFile(video.url)
        } importing: { received in
            let fileExtension = received.file.pathExtension.isEmpty
                ? "mov"
                : received.file.pathExtension
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("selected-\(UUID().uuidString)")
                .appendingPathExtension(fileExtension)
            try FileManager.default.copyItem(at: received.file, to: destination)
            return ImportedVideo(url: destination)
        }
    }
}

@MainActor
final class AppViewModel: ObservableObject {
    @Published var sourceImage: UIImage?
    @Published var depthImage: UIImage?
    @Published var stereoImage: UIImage?
    @Published var strength: Double = 0.025
    @Published var convergence: Double = 0.50
    @Published var isWorking = false
    @Published var status = "选择一张图片，或使用内置示例开始。"
    @Published var videoProgress: Double = 0
    @Published var exportedVideoURL: URL?
    @Published var errorMessage: String?
    @Published private(set) var isVideoWorking = false
    @Published private(set) var isCancellingVideo = false
    private var didStartWarmUp = false
    private weak var cinemaSession: CinemaSession?
    private var videoConversionTask: Task<Void, Never>?

    func bindCinemaSession(_ session: CinemaSession) {
        cinemaSession = session
    }

    func warmUpEngine() {
        guard !didStartWarmUp else { return }
        didStartWarmUp = true

        Task(priority: .utility) {
            do {
                try await ProcessingService.shared.prepare()
                if !isWorking {
                    status = "Depth Anything V2 已就绪。"
                }
            } catch {
                present(error)
            }
        }
    }

    func useDemoImage() {
        sourceImage = DemoImageFactory.make()
        depthImage = nil
        stereoImage = nil
        status = "已载入内置示例。"
    }

    func loadPhotoItem(_ item: PhotosPickerItem?) {
        guard let item else { return }
        isWorking = true
        status = "正在读取图片…"

        Task {
            defer { isWorking = false }
            do {
                guard let data = try await item.loadTransferable(type: Data.self),
                      let image = UIImage(data: data) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                sourceImage = image
                depthImage = nil
                stereoImage = nil
                status = "图片已载入，点击“生成立体图”。"
            } catch {
                present(error)
            }
        }
    }

    func convertImage() {
        guard let sourceImage else { return }
        depthImage = nil
        stereoImage = nil
        errorMessage = nil
        isWorking = true
        status = "正在加载 Depth Anything V2 并估计深度…"

        Task {
            // Give SwiftUI one run-loop turn to render the progress state before
            // the first Core ML model load starts.
            await Task.yield()
            do {
                let result = try await ProcessingService.shared.convertImage(
                    sourceImage,
                    strengthFraction: Float(strength),
                    convergence: Float(convergence)
                )
                depthImage = result.depth
                stereoImage = result.stereo
                cinemaSession?.presentSBS(result.stereo)
                status = "完成：输出为左右眼并排（SBS）立体图。"
            } catch {
                present(error)
            }
            isWorking = false
        }
    }

    func convertVideo(url: URL) {
        beginVideoConversion()

        let accessed = url.startAccessingSecurityScopedResource()
        videoConversionTask = Task {
            defer {
                if accessed { url.stopAccessingSecurityScopedResource() }
                isVideoWorking = false
                isCancellingVideo = false
                isWorking = false
            }

            do {
                try await performVideoConversion(url: url)
            } catch {
                handleVideoConversionError(error)
            }
        }
    }

    func loadVideoItem(_ item: PhotosPickerItem?) {
        guard let item else { return }
        beginVideoConversion(status: "正在从图册读取视频…")

        videoConversionTask = Task {
            var importedURL: URL?
            defer {
                if let importedURL {
                    try? FileManager.default.removeItem(at: importedURL)
                }
                isVideoWorking = false
                isCancellingVideo = false
                isWorking = false
            }

            do {
                guard let imported = try await item.loadTransferable(type: ImportedVideo.self) else {
                    throw CocoaError(.fileReadUnknown)
                }
                importedURL = imported.url
                status = "视频已读取，正在准备转换…"
                try await performVideoConversion(url: imported.url)
            } catch {
                handleVideoConversionError(error)
            }
        }
    }

    func cancelVideoConversion() {
        guard isVideoWorking, !isCancellingVideo else { return }
        isCancellingVideo = true
        status = "正在取消视频生成…"
        videoConversionTask?.cancel()
    }

    private func beginVideoConversion(status: String = "正在准备视频…") {
        isWorking = true
        isVideoWorking = true
        isCancellingVideo = false
        videoProgress = 0
        exportedVideoURL = nil
        errorMessage = nil
        self.status = status
    }

    private func performVideoConversion(url: URL) async throws {
        let converter = try VideoConverter()
        let result = try await converter.convert(
            sourceURL: url,
            strengthFraction: Float(strength),
            convergence: Float(convergence)
        ) { [weak self] progress in
            Task { @MainActor in
                guard self?.isCancellingVideo == false else { return }
                self?.videoProgress = progress
                self?.status = "正在转换视频 \(Int(progress * 100))%"
            }
        }
        exportedVideoURL = result
        cinemaSession?.replaceVideo(url: result)
        videoProgress = 1
        status = "视频转换完成，可预览或分享 SBS 视频。"
    }

    private func handleVideoConversionError(_ error: Error) {
        if isCancellingVideo || error is CancellationError {
            videoProgress = 0
            status = "已取消视频生成。"
        } else {
            present(error)
        }
    }

    private func present(_ error: Error) {
        errorMessage = error.localizedDescription
        status = "处理失败"
    }
}
