import AVKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case image = "图片"
        case video = "视频"
        var id: Self { self }
    }

    @StateObject private var model = AppViewModel()
    @StateObject private var cinemaSession = CinemaSession()
    @StateObject private var displayManager = ExternalDisplayManager()
    @State private var mode: Mode = .image
    @State private var photoItem: PhotosPickerItem?
    @State private var videoItem: PhotosPickerItem?
    @State private var showVideoImporter = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    header
                    Picker("模式", selection: $mode) {
                        ForEach(Mode.allCases) { item in
                            Text(item.rawValue).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)

                    settings
                    externalDisplayCard

                    if mode == .image {
                        imageWorkspace
                    } else {
                        videoWorkspace
                    }

                    statusCard
                }
                .padding()
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Depth Vision 3D")
            .alert("处理失败", isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )) {
                Button("好", role: .cancel) { model.errorMessage = nil }
            } message: {
                Text(model.errorMessage ?? "未知错误")
            }
            .onAppear {
                cinemaSession.bind(displayManager: displayManager)
                model.bindCinemaSession(cinemaSession)
                displayManager.start()
                if model.sourceImage == nil {
                    model.useDemoImage()
                }
                model.warmUpEngine()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "cube.transparent")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.cyan)
            VStack(alignment: .leading, spacing: 3) {
                Text("端侧 2D → 3D")
                    .font(.headline)
                Text("Depth Anything V2 + Metal SBS")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    private var settings: some View {
        VStack(spacing: 12) {
            HStack {
                Text("立体强度")
                Slider(value: $model.strength, in: 0.005...0.06)
                Text("\(model.strength * 100, specifier: "%.1f")%")
                    .monospacedDigit()
                    .frame(width: 48, alignment: .trailing)
            }
            HStack {
                Text("聚焦平面")
                Slider(value: $model.convergence, in: 0.15...0.85)
                Text("\(model.convergence, specifier: "%.2f")")
                    .monospacedDigit()
                    .frame(width: 48, alignment: .trailing)
            }
        }
        .font(.subheadline)
        .padding()
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private var externalDisplayCard: some View {
        HStack(spacing: 12) {
            Image(systemName: displayManager.info == nil
                  ? "display.trianglebadge.exclamationmark"
                  : "display.and.arrow.down")
                .font(.title2)
                .foregroundStyle(displayManager.info == nil ? Color.secondary : Color.cyan)

            VStack(alignment: .leading, spacing: 3) {
                Text("View1 眼镜输出")
                    .font(.subheadline.weight(.semibold))
                Text(displayManager.connectionNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if displayManager.info?.model == .unknownExternal {
                Button("确认为 View1") {
                    displayManager.confirmAsView1()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding()
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 16)
        )
    }

    private var imageWorkspace: some View {
        VStack(spacing: 14) {
            HStack {
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Label("选择图片", systemImage: "photo.on.rectangle")
                }
                .buttonStyle(.borderedProminent)
                .onChange(of: photoItem) { _, item in
                    model.loadPhotoItem(item)
                }

                Button("内置示例") { model.useDemoImage() }
                    .buttonStyle(.bordered)
            }

            if let stereo = model.stereoImage {
                PreviewCard(title: "左右眼 SBS 输出", image: stereo)
            } else if let image = model.sourceImage {
                PreviewCard(title: "待处理原图", image: image)
            } else {
                ContentUnavailableView(
                    "等待图片",
                    systemImage: "photo",
                    description: Text("模拟器中可直接使用内置示例。")
                )
                .frame(height: 220)
            }

            Button {
                model.convertImage()
            } label: {
                HStack(spacing: 10) {
                    if model.isWorking {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: "view.3d")
                    }
                    Text(model.isWorking ? "正在生成，请稍候…" : "生成立体图")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.sourceImage == nil || model.isWorking)

            if model.isWorking {
                VStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.large)
                    Text(model.status)
                        .font(.subheadline.weight(.medium))
                    #if targetEnvironment(simulator)
                    Text("模拟器使用 CPU 推理，首次运行可能需要较长时间；iPhone 真机会更快。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    #endif
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
            }

            if let depth = model.depthImage {
                PreviewCard(title: "Depth Anything V2 深度", image: depth)
            }
            if let stereo = model.stereoImage {
                ShareLink(item: Image(uiImage: stereo), preview: SharePreview("SBS 立体图", image: Image(uiImage: stereo))) {
                    Label("分享立体图", systemImage: "square.and.arrow.up")
                }

                if let source = model.sourceImage {
                    DisclosureGroup("查看原图") {
                        PreviewCard(title: "原图", image: source)
                    }
                }
            }
        }
    }

    private var videoWorkspace: some View {
        VStack(spacing: 16) {
            PhotosPicker(
                selection: $videoItem,
                matching: .videos,
                preferredItemEncoding: .current
            ) {
                Label("从图册选择视频并转换", systemImage: "photo.on.rectangle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.isWorking)
            .onChange(of: videoItem) { _, item in
                model.loadVideoItem(item)
                videoItem = nil
            }

            Button {
                showVideoImporter = true
            } label: {
                Label("从文件选择测试视频", systemImage: "folder")
            }
            .buttonStyle(.bordered)
            .disabled(model.isWorking)
            .fileImporter(
                isPresented: $showVideoImporter,
                allowedContentTypes: [.movie],
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let url = urls.first {
                    model.convertVideo(url: url)
                }
            }

            if model.isWorking && model.videoProgress > 0 {
                ProgressView(value: model.videoProgress) {
                    Text("逐帧估计深度并用 Metal 合成立体视频")
                }
            }

            if model.isVideoWorking {
                Button(role: .destructive) {
                    model.cancelVideoConversion()
                } label: {
                    Label(
                        model.isCancellingVideo ? "正在取消…" : "取消生成",
                        systemImage: "xmark.circle"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(model.isCancellingVideo)
            }

            if let url = model.exportedVideoURL {
                VideoPlayer(player: cinemaSession.player)
                    .frame(height: 230)
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                ShareLink(item: url) {
                    Label("分享 SBS 视频", systemImage: "square.and.arrow.up")
                }
            } else {
                ContentUnavailableView(
                    "等待视频",
                    systemImage: "video",
                    description: Text("演示版每 3 帧更新一次深度，并进行时序平滑。输出为有声 SBS MP4。")
                )
                .frame(height: 220)
            }
        }
    }

    private var statusCard: some View {
        HStack(spacing: 12) {
            if model.isWorking {
                ProgressView()
            } else {
                Image(systemName: model.errorMessage == nil ? "checkmark.circle" : "exclamationmark.triangle")
                    .foregroundStyle(model.errorMessage == nil ? .green : .orange)
            }
            Text(model.status)
                .font(.footnote)
            Spacer()
        }
        .padding()
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct PreviewCard: View {
    let title: String
    let image: UIImage

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)
                .background(Color.black.opacity(0.9))
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .padding()
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}
