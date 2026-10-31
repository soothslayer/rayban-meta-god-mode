import SwiftUI
import AVFoundation

struct QRScanner: View {
    let onCode: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var authorized = false
    @State private var message = "Allow camera access to scan your Mac’s pairing code."

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if authorized { ScannerPreview(onCode: onCode, onError: { message = $0; authorized = false }).ignoresSafeArea() }
                else { ContentUnavailableView("Camera unavailable", systemImage: "qrcode.viewfinder", description: Text(message)) }
                VStack { Spacer(); Text("Point your camera at the QR code in the Mac’s terminal.").font(.callout).padding().background(.ultraThinMaterial, in: Capsule()).padding() }
            }.navigationTitle("Scan pairing code").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }.task {
            authorized = await AVCaptureDevice.requestAccess(for: .video)
            if !authorized { message = "Allow Camera in Settings, or enter the Mac address and token manually." }
        }
    }
}

private struct ScannerPreview: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    let onError: (String) -> Void
    func makeUIViewController(context: Context) -> ScannerController { ScannerController(onCode: onCode, onError: onError) }
    func updateUIViewController(_ uiViewController: ScannerController, context: Context) {}
    static func dismantleUIViewController(_ uiViewController: ScannerController, coordinator: ()) { uiViewController.stop() }
}

private final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "cj.qr-camera")
    private var preview: AVCaptureVideoPreviewLayer?
    private var delivered = false
    private let onCode: (String) -> Void
    private let onError: (String) -> Void

    init(onCode: @escaping (String) -> Void, onError: @escaping (String) -> Void) {
        self.onCode = onCode; self.onError = onError
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("Use init(onCode:onError:)") }

    override func viewDidLoad() {
        super.viewDidLoad()
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(layer); preview = layer
        queue.async { [weak self] in
            guard let self else { return }
            guard let device = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: device), self.session.canAddInput(input) else {
                DispatchQueue.main.async { self.onError("No camera is available. Use manual pairing on the simulator.") }; return
            }
            self.session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard self.session.canAddOutput(output) else { DispatchQueue.main.async { self.onError("QR scanning couldn’t start. Use manual pairing.") }; return }
            self.session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
            self.session.startRunning()
        }
    }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); preview?.frame = view.bounds }
    func stop() { queue.async { [session] in session.stopRunning() } }
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !delivered, let code = metadataObjects.first as? AVMetadataMachineReadableCodeObject, let value = code.stringValue else { return }
        delivered = true; stop(); onCode(value)
    }
}
