import Foundation
import UIKit
import AVFoundation
import Combine
import PhotosUI
import SwiftUI

enum ExternalPresentation {
    case waiting
    case video
    case sbs(UIImage)
    case depthRelief(UIImage)
}

enum SamplePhoto: String, CaseIterable, Identifiable {
    case sceneA = "sample_photo"
    case sceneB = "sample_photo_2"
    case sceneC = "sample_photo_3"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sceneA: return "样例 A · 近景圆"
        case .sceneB: return "样例 B · 色块"
        case .sceneC: return "样例 C · 层次"
        }
    }

    func load() -> UIImage? {
        guard let url = Bundle.main.url(forResource: rawValue, withExtension: "png"),
              let data = try? Data(contentsOf: url),
              let image = UIImage(data: data) else { return nil }
        return image
    }
}

@MainActor
final class CinemaSession: ObservableObject {
    let player = AVPlayer()

    @Published var externalMode: ExternalPresentation = .waiting
    @Published var isPlaying = false
    @Published var duration: Double = 0
    @Published var currentTime: Double = 0
    @Published var thermalLabel = "Nominal"
    @Published var depthEnabled = true

    // SBS lane (isolated)
    @Published var sbsStatus = "Idle"
    @Published var lastStereoPreview: UIImage?
    @Published var selectedSBSSample: SamplePhoto = .sceneA

    // Depth-relief lane (isolated)
    @Published var reliefStatus = "Idle"
    @Published var lastReliefPreview: UIImage?
    @Published var selectedReliefSample: SamplePhoto = .sceneB

    /// What should be restored when an external display reconnects.
    private enum RequestedPresentation { case waiting, video, sbs, relief }
    private var requestedPresentation: RequestedPresentation = .waiting

    private var timeObserver: Any?
    private var thermalObserver: NSObjectProtocol?
    private var playbackEndObserver: NSObjectProtocol?
    private let depth = DepthProcessor()
    private weak var displayManager: ExternalDisplayManager?
    private var didBind = false

    func bind(displayManager: ExternalDisplayManager) {
        self.displayManager = displayManager
        displayManager.attachSession(self)
        guard !didBind else { return }
        didBind = true
        observePlayer()
        observeThermal()
        loadBundledVideoIfNeeded()
    }

    func loadBundledVideoIfNeeded() {
        guard let url = Bundle.main.url(forResource: "sample_video", withExtension: "mp4") else {
            sbsStatus = "Bundled sample_video.mp4 missing"
            return
        }
        replaceVideo(url: url)
    }

    func replaceVideo(url: URL) {
        configureAudioPlayback()
        player.pause()
        isPlaying = false
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        requestedPresentation = .video
        externalMode = displayManager?.info != nil ? .video : .waiting
        duration = 0
        currentTime = 0
        if let playbackEndObserver {
            NotificationCenter.default.removeObserver(playbackEndObserver)
        }
        playbackEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isPlaying = false
            }
        }
    }

    func playPause() {
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            requestedPresentation = .video
            switch externalMode {
            case .sbs, .depthRelief:
                if displayManager?.info != nil {
                    externalMode = .video
                }
            default:
                if displayManager?.info != nil {
                    externalMode = .video
                }
            }
            player.play()
            isPlaying = true
        }
    }

    func seek(to seconds: Double) {
        let t = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: t)
        currentTime = seconds
    }

    func showWaitingOnExternal() {
        player.pause()
        isPlaying = false
        externalMode = .waiting
        requestedPresentation = .waiting
    }

    // MARK: - SBS

    func runSBSSample() {
        guard let image = selectedSBSSample.load() else {
            sbsStatus = "Sample missing: \(selectedSBSSample.rawValue)"
            return
        }
        Task { await processPhotoSBS(image) }
    }

    func processPickedPhotoSBS(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        do {
            if let data = try await item.loadTransferable(type: Data.self),
               let image = UIImage(data: data) {
                await processPhotoSBS(image)
            }
        } catch {
            sbsStatus = "Failed to load photo: \(error.localizedDescription)"
        }
    }

    func processPhotoSBS(_ image: UIImage) async {
        guard depthEnabled else {
            sbsStatus = "Depth disabled (thermal) — showing flat"
            presentSBS(image, engineLabel: "Depth disabled (thermal)")
            return
        }
        sbsStatus = "Running SBS…"
        player.pause()
        isPlaying = false
        let result = await depth.makeStereoSBS(from: image)
        presentSBS(result.sbs, engineLabel: result.engineLabel)
    }

    // MARK: - Depth relief

    func runReliefSample() {
        guard let image = selectedReliefSample.load() else {
            reliefStatus = "Sample missing: \(selectedReliefSample.rawValue)"
            return
        }
        Task { await processPhotoDepthRelief(image) }
    }

    func processPickedPhotoDepthRelief(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        do {
            if let data = try await item.loadTransferable(type: Data.self),
               let image = UIImage(data: data) {
                await processPhotoDepthRelief(image)
            }
        } catch {
            reliefStatus = "Failed to load photo: \(error.localizedDescription)"
        }
    }

    func processPhotoDepthRelief(_ image: UIImage) async {
        guard depthEnabled else {
            reliefStatus = "Depth disabled (thermal) — showing flat"
            presentDepthRelief(image, engineLabel: "Depth disabled (thermal)")
            return
        }
        reliefStatus = "Running 立体增强…"
        player.pause()
        isPlaying = false
        let result = await depth.makeDepthRelief(from: image)
        presentDepthRelief(result.sbs, engineLabel: result.engineLabel)
    }

    func presentLatestStillOnExternalIfNeeded() {
        guard displayManager?.info != nil else { return }
        switch requestedPresentation {
        case .relief:
            if let relief = lastReliefPreview {
                externalMode = .depthRelief(relief)
                reliefStatus = "立体增强已投到 View1"
            }
        case .sbs:
            if let sbs = lastStereoPreview {
                externalMode = .sbs(sbs)
                sbsStatus = "SBS 已投到 View1"
            }
        case .video:
            externalMode = player.currentItem == nil ? .waiting : .video
        case .waiting:
            externalMode = .waiting
        }
    }

    /// Publishes an SBS image that was already generated by the phone's V2
    /// pipeline. This avoids running Core ML a second time for the glasses.
    func presentSBS(_ image: UIImage, engineLabel: String = "Depth Anything V2") {
        player.pause()
        isPlaying = false
        lastStereoPreview = image
        requestedPresentation = .sbs
        if displayManager?.info != nil {
            externalMode = .sbs(image)
            sbsStatus = "\(engineLabel) · SBS 已投到 View1"
        } else {
            sbsStatus = "\(engineLabel) · SBS 已生成（连接 View1 后自动投屏）"
        }
    }

    func presentDepthRelief(
        _ image: UIImage,
        engineLabel: String = "Depth Anything V2 · Relief"
    ) {
        player.pause()
        isPlaying = false
        lastReliefPreview = image
        requestedPresentation = .relief
        if displayManager?.info != nil {
            externalMode = .depthRelief(image)
            reliefStatus = "\(engineLabel) · 立体增强已投到 View1"
        } else {
            reliefStatus = "\(engineLabel) · 立体增强已生成（连接 View1 后自动投屏）"
        }
    }

    private func observePlayer() {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.currentTime = time.seconds
                if let d = self.player.currentItem?.duration.seconds, d.isFinite {
                    self.duration = d
                }
            }
        }
    }

    private func observeThermal() {
        applyThermal(ProcessInfo.processInfo.thermalState)
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.applyThermal(ProcessInfo.processInfo.thermalState)
            }
        }
    }

    private func configureAudioPlayback() {
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.playback, mode: .moviePlayback)
            try audioSession.setActive(true)
        } catch {
            sbsStatus = "Audio route unavailable: \(error.localizedDescription)"
        }
    }

    private func applyThermal(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal:
            thermalLabel = "Nominal"
            depthEnabled = true
            depth.throttle = false
        case .fair:
            thermalLabel = "Fair"
            depthEnabled = true
            depth.throttle = false
        case .serious:
            thermalLabel = "Serious — depth throttled"
            depthEnabled = true
            depth.throttle = true
        case .critical:
            thermalLabel = "Critical — depth off"
            depthEnabled = false
            depth.throttle = true
        @unknown default:
            thermalLabel = "Unknown"
        }
    }
}
