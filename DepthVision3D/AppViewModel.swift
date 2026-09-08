import AVFoundation
import Foundation
import PhotosUI
import SwiftUI

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
    private var didStartWarmUp = false

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
                status = "完成：输出为左右眼并排（SBS）立体图。"
            } catch {
                present(error)
            }
            isWorking = false
        }
    }

    func convertVideo(url: URL) {
        isWorking = true
        videoProgress = 0
        exportedVideoURL = nil
        status = "正在准备视频…"

        let accessed = url.startAccessingSecurityScopedResource()
        Task {
            defer {
                if accessed { url.stopAccessingSecurityScopedResource() }
                isWorking = false
            }

            do {
                let converter = try VideoConverter()
                let result = try await converter.convert(
                    sourceURL: url,
                    strengthFraction: Float(strength),
                    convergence: Float(convergence)
                ) { [weak self] progress in
                    Task { @MainActor in
                        self?.videoProgress = progress
                        self?.status = "正在转换视频 \(Int(progress * 100))%"
                    }
                }
                exportedVideoURL = result
                videoProgress = 1
                status = "视频转换完成，可预览或分享 SBS 视频。"
            } catch {
                present(error)
            }
        }
    }

    private func present(_ error: Error) {
        errorMessage = error.localizedDescription
        status = "处理失败"
    }
}
