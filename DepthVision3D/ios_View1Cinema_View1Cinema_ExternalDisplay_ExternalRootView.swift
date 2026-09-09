import SwiftUI
import AVKit

struct ExternalRootView: View {
    @EnvironmentObject private var session: CinemaSession

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch session.externalMode {
            case .waiting:
                VStack(spacing: 12) {
                    Text("View1 Cinema")
                        .font(.system(size: 42, weight: .semibold, design: .rounded))
                        .foregroundColor(.white)
                    Text("Waiting for playback")
                        .font(.title3)
                        .foregroundColor(.white.opacity(0.7))
                }
            case .video:
                VideoPlayer(player: session.player)
                    .ignoresSafeArea()
            case .sbs(let image):
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .ignoresSafeArea()
            case .depthRelief(let image):
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .ignoresSafeArea()
            }
        }
    }
}
