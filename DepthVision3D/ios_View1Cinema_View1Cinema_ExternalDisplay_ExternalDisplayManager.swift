import Foundation
import UIKit
import Combine
import SwiftUI

enum View1Model: String, Equatable {
    case view1Standard = "View1 Standard (1080p)"
    case view1Wide = "View1 Wide (3840×1080)"
    case unknownExternal = "Unknown external"
    case manualView1 = "View1 (manual)"
}

struct ExternalDisplayInfo: Equatable {
    let screenID: ObjectIdentifier
    let nativeWidth: CGFloat
    let nativeHeight: CGFloat
    let refreshRate: Int
    var model: View1Model

    var resolutionLabel: String {
        "\(Int(nativeWidth))×\(Int(nativeHeight)) @ \(refreshRate)Hz"
    }

    var isView1: Bool {
        switch model {
        case .view1Standard, .view1Wide, .manualView1: return true
        case .unknownExternal: return false
        }
    }
}

enum View1Identifier {
    static func identify(from screen: UIScreen) -> View1Model {
        let size = screen.nativeBounds.size
        let refreshRate = screen.maximumFramesPerSecond
        let candidates: [(CGSize, Int, View1Model)] = [
            (CGSize(width: 1920, height: 1080), 60, .view1Standard),
            (CGSize(width: 3840, height: 1080), 60, .view1Wide)
        ]
        for (cSize, cFPS, model) in candidates {
            if abs(size.width - cSize.width) < 10,
               abs(size.height - cSize.height) < 10,
               refreshRate == cFPS {
                return model
            }
        }
        return .unknownExternal
    }
}

@MainActor
final class ExternalDisplayManager: ObservableObject {
    @Published private(set) var info: ExternalDisplayInfo?
    @Published private(set) var connectionNote: String = "No external display"

    private var externalWindow: UIWindow?
    private var confirmTask: Task<Void, Never>?
    private weak var session: CinemaSession?
    private var didStart = false

    func attachSession(_ session: CinemaSession) {
        self.session = session
        refreshExternalRoot()
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenConnected),
            name: UIScreen.didConnectNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenDisconnected),
            name: UIScreen.didDisconnectNotification,
            object: nil
        )
        UIScreen.screens.filter { $0 != .main }.forEach { beginStableAttach(to: $0) }
    }

    func confirmAsView1() {
        guard var current = info else { return }
        current.model = .manualView1
        info = current
        connectionNote = "Manual View1 · \(current.resolutionLabel)"
        refreshExternalRoot()
    }

    @objc private func screenConnected(_ note: Notification) {
        guard let screen = note.object as? UIScreen else { return }
        beginStableAttach(to: screen)
    }

    @objc private func screenDisconnected(_ note: Notification) {
        guard let screen = note.object as? UIScreen else { return }
        if info?.screenID == ObjectIdentifier(screen) {
            tearDown()
        }
    }

    /// Require 3 confirmations within ~3s to ride out DP hot-plug chatter.
    private func beginStableAttach(to screen: UIScreen) {
        confirmTask?.cancel()
        connectionNote = "External display detected — confirming…"
        confirmTask = Task { [weak self] in
            var hits = 0
            for _ in 0..<3 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                if UIScreen.screens.contains(where: { $0 === screen }) {
                    hits += 1
                }
            }
            guard hits >= 3 else {
                await MainActor.run {
                    self?.connectionNote = "Connection unstable — reconnect View1"
                }
                return
            }
            await MainActor.run {
                self?.attach(screen)
            }
        }
    }

    private func attach(_ screen: UIScreen) {
        let model = View1Identifier.identify(from: screen)
        let size = screen.nativeBounds.size
        info = ExternalDisplayInfo(
            screenID: ObjectIdentifier(screen),
            nativeWidth: size.width,
            nativeHeight: size.height,
            refreshRate: screen.maximumFramesPerSecond,
            model: model
        )
        connectionNote = "\(model.rawValue) · \(Int(size.width))×\(Int(size.height)) @ \(screen.maximumFramesPerSecond)Hz"

        let window = UIWindow(frame: screen.bounds)
        window.screen = screen
        window.windowLevel = .normal
        window.isHidden = false
        externalWindow = window
        if let session {
            window.rootViewController = UIHostingController(
                rootView: ExternalRootView().environmentObject(session)
            )
            window.makeKeyAndVisible()
            session.presentLatestStillOnExternalIfNeeded()
        } else {
            let placeholder = UIViewController()
            placeholder.view.backgroundColor = .black
            window.rootViewController = placeholder
            window.makeKeyAndVisible()
        }
    }

    private func tearDown() {
        confirmTask?.cancel()
        confirmTask = nil
        externalWindow?.isHidden = true
        externalWindow = nil
        info = nil
        connectionNote = "No external display"
    }

    private func refreshExternalRoot() {
        guard let session, let window = externalWindow else { return }
        window.rootViewController = UIHostingController(
            rootView: ExternalRootView().environmentObject(session)
        )
        window.makeKeyAndVisible()
    }
}
