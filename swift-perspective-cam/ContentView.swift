import SwiftUI
import AVFoundation
import CoreImage

struct ContentView: View {
    @StateObject private var camera = CameraManager()
    private let ciContext = CIContext()

    /// 四隅の位置。正規化座標（0...1）で、SwiftUI と同じ「原点＝左上、Yは下向き」の
    /// 見た目通りの意味で topLeft / topRight / bottomRight / bottomLeft を保持する。
    @State private var normalizedCorners: [CGPoint] = [
        CGPoint(x: 0.15, y: 0.15), // topLeft
        CGPoint(x: 0.85, y: 0.15), // topRight
        CGPoint(x: 0.85, y: 0.85), // bottomRight
        CGPoint(x: 0.15, y: 0.85), // bottomLeft
    ]

    var body: some View {
        HSplitView {
            rawPreviewPane
                .frame(minWidth: 400, minHeight: 420)
            correctedPreviewPane
                .frame(minWidth: 400, minHeight: 420)
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Picker("カメラ", selection: $camera.selectedDeviceID) {
                    ForEach(camera.availableDevices, id: \.uniqueID) { device in
                        Text(device.localizedName).tag(Optional(device.uniqueID))
                    }
                }
                .frame(minWidth: 180)
            }
        }
        .alert(
            "エラー",
            isPresented: Binding(
                get: { camera.errorMessage != nil },
                set: { if !$0 { camera.errorMessage = nil } }
            )
        ) {
            Button("OK") { camera.errorMessage = nil }
        } message: {
            Text(camera.errorMessage ?? "")
        }
        .onAppear {
            camera.requestAccessAndStart()
        }
        .padding()
    }

    // MARK: - 左ペイン：生映像 + ドラッグ可能な四隅

    private var rawPreviewPane: some View {
        VStack(alignment: .leading) {
            Text("① 元映像 — ハンドルをドラッグして平面の四隅を指定")
                .font(.headline)

            if let raw = camera.currentFrame {
                GeometryReader { geo in
                    let displaySize = fitSize(imageSize: raw.extent.size, in: geo.size)

                    ZStack(alignment: .topLeading) {
                        Image(nsImage: raw.nsImage(using: ciContext) ?? NSImage())
                            .resizable()
                            .frame(width: displaySize.width, height: displaySize.height)

                        quadOutline(displaySize: displaySize)

                        ForEach(0..<normalizedCorners.count, id: \.self) { index in
                            cornerHandle(index: index, displaySize: displaySize)
                        }
                    }
                    .frame(width: displaySize.width, height: displaySize.height)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                }
            } else {
                ProgressView("カメラ映像を待機中…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func quadOutline(displaySize: CGSize) -> some View {
        Path { path in
            let pts = normalizedCorners.map {
                CGPoint(x: $0.x * displaySize.width, y: $0.y * displaySize.height)
            }
            guard pts.count == 4 else { return }
            path.move(to: pts[0])
            path.addLine(to: pts[1])
            path.addLine(to: pts[2])
            path.addLine(to: pts[3])
            path.closeSubpath()
        }
        .stroke(Color.yellow, lineWidth: 2)
    }

    private func cornerHandle(index: Int, displaySize: CGSize) -> some View {
        let point = CGPoint(
            x: normalizedCorners[index].x * displaySize.width,
            y: normalizedCorners[index].y * displaySize.height
        )
        return Circle()
            .fill(Color.yellow)
            .overlay(Circle().stroke(Color.black.opacity(0.6), lineWidth: 1))
            .frame(width: 16, height: 16)
            .position(point)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let x = min(max(value.location.x, 0), displaySize.width)
                        let y = min(max(value.location.y, 0), displaySize.height)
                        normalizedCorners[index] = CGPoint(
                            x: x / displaySize.width,
                            y: y / displaySize.height
                        )
                    }
            )
    }

    // MARK: - 右ペイン：補正後プレビュー

    private var correctedPreviewPane: some View {
        VStack(alignment: .leading) {
            Text("② 補正後プレビュー（正面から見た平面）")
                .font(.headline)

            if let corrected = correctedImage {
                Image(nsImage: corrected)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("補正結果がここに表示されます")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// 現在のフレームに対して CIPerspectiveCorrection を適用した結果。
    /// 呼ばれるたびに計算するプロトタイプ実装（最適化は後回し）。
    private var correctedImage: NSImage? {
        guard let raw = camera.currentFrame, normalizedCorners.count == 4 else { return nil }
        let size = raw.extent.size

        // SwiftUI座標（原点左上・Y下向き）→ CIImage座標（原点左下・Y上向き）への変換
        func toCIImageSpace(_ p: CGPoint) -> CGPoint {
            CGPoint(x: p.x * size.width, y: (1 - p.y) * size.height)
        }

        let topLeft = toCIImageSpace(normalizedCorners[0])
        let topRight = toCIImageSpace(normalizedCorners[1])
        let bottomRight = toCIImageSpace(normalizedCorners[2])
        let bottomLeft = toCIImageSpace(normalizedCorners[3])

        guard let output = PerspectiveCorrector.correct(
            image: raw,
            topLeft: topLeft,
            topRight: topRight,
            bottomRight: bottomRight,
            bottomLeft: bottomLeft
        ) else { return nil }

        return output.nsImage(using: ciContext)
    }

    // MARK: - ユーティリティ

    private func fitSize(imageSize: CGSize, in boundingSize: CGSize) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0,
              boundingSize.width > 0, boundingSize.height > 0 else {
            return boundingSize
        }
        let scale = min(boundingSize.width / imageSize.width, boundingSize.height / imageSize.height)
        return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }
}

#Preview {
    ContentView()
}
