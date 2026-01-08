import AppKit
import AVFoundation
import SwiftUI

struct ContentView: View {
    @StateObject private var model = AppViewModel()
    @State private var dragStart: CGPoint?
    @State private var lastState: RecordingState = .idle

    var body: some View {
        VStack(spacing: 12) {
            controlsBar
            previewArea
            statusArea
        }
        .padding(12)
        .onAppear {
            model.start()
        }
        .onChange(of: model.selectedDisplayID) { _, _ in
            Task {
                await model.restartPreviewForSelection()
            }
        }
    }

    private var controlsBar: some View {
        HStack(spacing: 12) {
            Picker("Display", selection: $model.selectedDisplayID) {
                ForEach(model.displays) { display in
                    Text(display.label).tag(Optional(display.id))
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 280, alignment: .leading)
            .disabled(model.state != .idle)

            Spacer()

            Button("Record") {
                model.startRecording()
            }
            .disabled(model.state != .idle)

            Button("Pause") {
                model.pauseRecording()
            }
            .disabled(model.state != .recording)

            Button("Resume") {
                model.resumeRecording()
            }
            .disabled(model.state != .paused)

            Button("Stop") {
                model.stopRecording()
            }
            .disabled(model.state == .idle)
        }
    }

    private var previewArea: some View {
        ZStack {
            ScreenPreviewView(preview: model.screenPreview)
                .background(Color.black)

            GeometryReader { proxy in
                let bubbleSize = model.bubbleSize
                let center = bubbleCenter(in: proxy.size)

                CameraBubbleView(session: model.cameraController.session, size: bubbleSize)
                    .position(center)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                let startCenter = dragStart ?? center
                                if dragStart == nil {
                                    dragStart = startCenter
                                }
                                let newCenter = CGPoint(
                                    x: startCenter.x + value.translation.width,
                                    y: startCenter.y + value.translation.height
                                )
                                let clamped = clamp(center: newCenter, in: proxy.size, bubbleSize: bubbleSize)
                                model.bubblePosition = normalized(point: clamped, in: proxy.size)
                            }
                            .onEnded { _ in
                                dragStart = nil
                                logBubbleEvent(in: proxy.size)
                            }
                    )
                    .onChange(of: model.state) { _, newState in
                        if lastState == .idle && newState == .recording {
                            logBubbleEvent(in: proxy.size)
                        }
                        lastState = newState
                    }
            }
        }
        .aspectRatio(previewAspectRatio, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.black.opacity(0.12), lineWidth: 1)
        )
    }

    private var statusArea: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Status: \(model.state.rawValue.capitalized)")
                Spacer()
                Text("Elapsed: \(model.formattedElapsedTime())")
            }
            .font(.callout)

            if let screenURL = model.screenOutputURL {
                Text("Screen: \(screenURL.path)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if let cameraURL = model.cameraOutputURL {
                Text("Camera: \(cameraURL.path)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if let metadataURL = model.metadataOutputURL {
                Text("Meta: \(metadataURL.path)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            if model.needsScreenRecordingPermission {
                Button("Open Screen Recording Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .font(.caption)
            }
        }
    }

    private func bubbleCenter(in size: CGSize) -> CGPoint {
        guard size.width > 0, size.height > 0 else { return .zero }
        return CGPoint(x: model.bubblePosition.x * size.width, y: model.bubblePosition.y * size.height)
    }

    private func normalized(point: CGPoint, in size: CGSize) -> CGPoint {
        guard size.width > 0, size.height > 0 else { return .zero }
        return CGPoint(x: point.x / size.width, y: point.y / size.height)
    }

    private func clamp(center: CGPoint, in size: CGSize, bubbleSize: CGFloat) -> CGPoint {
        let half = bubbleSize / 2
        let minX = half
        let maxX = max(half, size.width - half)
        let minY = half
        let maxY = max(half, size.height - half)

        return CGPoint(
            x: min(max(center.x, minX), maxX),
            y: min(max(center.y, minY), maxY)
        )
    }

    private var previewAspectRatio: CGFloat {
        guard let selectedID = model.selectedDisplayID,
              let display = model.displays.first(where: { $0.id == selectedID }) else {
            return 16.0 / 9.0
        }
        return display.aspectRatio
    }

    private func logBubbleEvent(in size: CGSize) {
        let radius = (model.bubbleSize / 2) / max(1, min(size.width, size.height))
        model.logBubbleEvent(radiusNormalized: radius)
    }
}

struct ScreenPreviewView: NSViewRepresentable {
    let preview: ScreenPreviewModel

    func makeCoordinator() -> Coordinator {
        Coordinator(preview: preview)
    }

    func makeNSView(context: Context) -> ScreenPreviewLayerView {
        let view = ScreenPreviewLayerView()
        preview.attach(view)
        return view
    }

    func updateNSView(_ nsView: ScreenPreviewLayerView, context: Context) {}

    static func dismantleNSView(_ nsView: ScreenPreviewLayerView, coordinator: Coordinator) {
        coordinator.preview.detach(nsView)
    }

    final class Coordinator {
        let preview: ScreenPreviewModel

        init(preview: ScreenPreviewModel) {
            self.preview = preview
        }
    }
}

final class ScreenPreviewLayerView: NSView {
    private let displayLayer = AVSampleBufferDisplayLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
        layer = displayLayer
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        displayLayer.sampleBufferRenderer.enqueue(sampleBuffer)
    }

    func flush() {
        displayLayer.sampleBufferRenderer.flush()
    }
}

struct CameraBubbleView: View {
    let session: AVCaptureSession
    let size: CGFloat

    var body: some View {
        CameraPreviewView(session: session)
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay(
                Circle()
                    .stroke(Color.white.opacity(0.85), lineWidth: 2)
            )
            .shadow(color: Color.black.opacity(0.3), radius: 6, x: 0, y: 2)
    }
}

struct CameraPreviewView: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> CameraPreviewLayerView {
        CameraPreviewLayerView(session: session)
    }

    func updateNSView(_ nsView: CameraPreviewLayerView, context: Context) {}
}

final class CameraPreviewLayerView: NSView {
    private let previewLayer: AVCaptureVideoPreviewLayer

    init(session: AVCaptureSession) {
        self.previewLayer = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: .zero)
        wantsLayer = true
        previewLayer.videoGravity = .resizeAspectFill
        layer = previewLayer
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        previewLayer.frame = bounds
    }
}
