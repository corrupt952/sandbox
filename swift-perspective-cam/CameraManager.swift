import AVFoundation
import CoreImage
import Combine

/// AVCaptureSession をラップして、選択したカメラデバイスの映像フレームを
/// CIImage として @Published プロパティに流し込むだけの、最小限のマネージャ。
///
/// 注意: これはプロトタイプ用の簡易実装です。スレッド安全性やエラーハンドリングは
/// 最小限に留めています。本格的に作り込む際は要見直しです。
final class CameraManager: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    /// 最新のカメラフレーム（CIImage の座標系は原点が左下、Y が上向き）
    @Published var currentFrame: CIImage?

    /// 選択可能なカメラデバイス一覧（内蔵 / 外付け / Continuity Camera など）
    @Published var availableDevices: [AVCaptureDevice] = []

    /// 現在選択中のデバイス ID
    @Published var selectedDeviceID: String? {
        didSet {
            guard let id = selectedDeviceID, id != oldValue else { return }
            switchToDevice(id: id)
        }
    }

    @Published var errorMessage: String?

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.perspectivecam.session")
    private let videoOutput = AVCaptureVideoDataOutput()
    private var currentInput: AVCaptureDeviceInput?

    override init() {
        super.init()
        refreshDevices()
    }

    // MARK: - デバイス一覧

    func refreshDevices() {
        var deviceTypes: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
        if #available(macOS 14.0, *) {
            deviceTypes.append(.external)
            deviceTypes.append(.continuityCamera)
        } else if #available(macOS 13.0, *) {
            deviceTypes.append(.continuityCamera)
            deviceTypes.append(.externalUnknown)
        } else {
            deviceTypes.append(.externalUnknown)
        }

        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .video,
            position: .unspecified
        )

        DispatchQueue.main.async {
            self.availableDevices = discovery.devices
            if self.selectedDeviceID == nil, let first = discovery.devices.first {
                self.selectedDeviceID = first.uniqueID
            }
        }
    }

    // MARK: - パーミッション & 起動

    func requestAccessAndStart() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            startSessionIfNeeded()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                if granted {
                    self?.startSessionIfNeeded()
                } else {
                    self?.publishError("カメラへのアクセスが許可されませんでした。システム設定 > プライバシーとセキュリティ > カメラ から許可してください。")
                }
            }
        default:
            publishError("カメラへのアクセスが許可されていません。システム設定 > プライバシーとセキュリティ > カメラ から許可してください。")
        }
    }

    private func startSessionIfNeeded() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.configureOutputIfNeeded()
            if !self.session.isRunning {
                self.session.startRunning()
            }
        }
    }

    private func configureOutputIfNeeded() {
        guard session.outputs.isEmpty else { return }
        session.beginConfiguration()
        session.sessionPreset = .high
        videoOutput.setSampleBufferDelegate(self, queue: sessionQueue)
        videoOutput.alwaysDiscardsLateVideoFrames = true
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }
        session.commitConfiguration()

        if let id = selectedDeviceID {
            switchToDevice(id: id)
        }
    }

    // MARK: - デバイス切り替え

    private func switchToDevice(id: String) {
        guard let device = AVCaptureDevice(uniqueID: id) else { return }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            if let existing = self.currentInput {
                self.session.removeInput(existing)
                self.currentInput = nil
            }
            do {
                let input = try AVCaptureDeviceInput(device: device)
                if self.session.canAddInput(input) {
                    self.session.addInput(input)
                    self.currentInput = input
                }
            } catch {
                self.publishError("カメラの切り替えに失敗しました: \(error.localizedDescription)")
            }
            self.session.commitConfiguration()

            if !self.session.isRunning {
                self.session.startRunning()
            }
        }
    }

    private func publishError(_ message: String) {
        DispatchQueue.main.async {
            self.errorMessage = message
        }
    }

    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        DispatchQueue.main.async { [weak self] in
            self?.currentFrame = image
        }
    }
}
