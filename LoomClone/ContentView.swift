import AppKit
import AVFoundation
import SwiftUI

struct ContentView: View {
    @StateObject private var model = AppViewModel()
    @State private var lastState: RecordingState = .idle
    @State private var windowRef: NSWindow?

    var body: some View {
        previewArea
            .background(WindowAccessor(aspectRatio: 1, configure: configureWindow, onWindow: { windowRef = $0 }))
        .onAppear {
            model.bubblePosition = CGPoint(x: 0.5, y: 0.5)
            model.start()
        }
        .onChange(of: model.selectedDisplayID) { _, _ in
            Task {
                await model.restartPreviewForSelection()
            }
        }
    }

    private var previewArea: some View {
        ZStack {
            Color.black

            CameraPreviewView(session: model.cameraController.session)

            GeometryReader { proxy in
                let size = proxy.size
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let windowRadius = min(size.width, size.height) / 2
                let controlInset: CGFloat = 24
                let ringRadius = max(0, windowRadius - controlInset)

                ZStack {
                    timerOverlay(size: size, radius: max(0, windowRadius - 8))

                    Button(action: primaryControlAction) {
                        controlCircle(icon: primaryControlIcon)
                    }
                    .buttonStyle(.plain)
                    .position(clampControl(point: ringPoint(center: center, angleDegrees: 90, radius: ringRadius), in: size))

                    if model.state != .recording {
                        Button(action: { resizeWindow(by: -40) }) {
                            controlCircle(icon: "minus")
                        }
                        .buttonStyle(.plain)
                        .position(clampControl(point: ringPoint(center: center, angleDegrees: 0, radius: ringRadius), in: size))

                        Button(action: { resizeWindow(by: 40) }) {
                            controlCircle(icon: "plus")
                        }
                        .buttonStyle(.plain)
                        .position(clampControl(point: ringPoint(center: center, angleDegrees: -30, radius: ringRadius), in: size))
                    }

                    if model.state == .paused {
                        Button(action: { model.stopRecording() }) {
                            controlCircle(icon: "stop.fill")
                        }
                        .buttonStyle(.plain)
                        .position(clampControl(point: ringPoint(center: center, angleDegrees: 60, radius: ringRadius), in: size))

                        Button(action: { model.restartRecording() }) {
                            controlCircle(icon: "arrow.counterclockwise")
                        }
                        .buttonStyle(.plain)
                        .position(clampControl(point: ringPoint(center: center, angleDegrees: 30, radius: ringRadius), in: size))
                    }
                }
                .onChange(of: model.state) { _, newState in
                    if lastState == .idle && newState == .recording {
                        logBubbleEvent()
                    }
                    lastState = newState
                }
            }
        }
        .ignoresSafeArea()
        .clipShape(Circle())
        .contentShape(Circle())
        .overlay(alignment: .topLeading) { statusOverlay }
    }

    private var statusOverlay: some View {
        Group {
            if shouldShowStatusOverlay {
                VStack(alignment: .leading, spacing: 6) {
                    if let errorMessage = model.errorMessage {
                        Text(errorMessage)
                            .font(.caption2)
                            .foregroundColor(.red)
                    }

                    if model.needsScreenRecordingPermission {
                        Button("Open Screen Recording Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .font(.caption2)
                    }
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.black.opacity(0.55))
                )
                .foregroundColor(.white)
                .padding(8)
            }
        }
    }

    private func clampControl(point: CGPoint, in size: CGSize) -> CGPoint {
        let padding: CGFloat = 18
        return CGPoint(
            x: min(max(point.x, padding), max(padding, size.width - padding)),
            y: min(max(point.y, padding), max(padding, size.height - padding))
        )
    }

    private func ringPoint(center: CGPoint, angleDegrees: CGFloat, radius: CGFloat) -> CGPoint {
        let radians = angleDegrees * .pi / 180
        return CGPoint(
            x: center.x + cos(radians) * radius,
            y: center.y + sin(radians) * radius
        )
    }

    private func logBubbleEvent() {
        model.logBubbleEvent(radiusNormalized: 0.5)
    }

    private var primaryControlIcon: String {
        if model.state == .recording {
            return "pause.fill"
        }
        return "play.fill"
    }

    private func primaryControlAction() {
        switch model.state {
        case .idle:
            model.startRecording()
        case .recording:
            model.pauseRecording()
        case .paused:
            model.resumeRecording()
        default:
            break
        }
    }

    private func controlCircle(icon: String) -> some View {
        Image(systemName: icon)
            .font(.system(size: 16, weight: .semibold))
            .foregroundColor(.black)
            .frame(width: 40, height: 40)
            .background(
                Circle()
                    .fill(Color.white.opacity(0.95))
                    .shadow(color: Color.black.opacity(0.25), radius: 6, x: 0, y: 2)
            )
    }

    @ViewBuilder
    private func timerOverlay(size: CGSize, radius: CGFloat) -> some View {
        if model.state == .idle {
            EmptyView()
        } else {
            TimelineView(.animation) { _ in
                let elapsed = model.currentTimelineSeconds()
                timerOverlayContent(elapsed: elapsed, size: size, radius: radius)
            }
        }
    }

    private func timerOverlayContent(elapsed: TimeInterval, size: CGSize, radius: CGFloat) -> some View {
        let progress = (elapsed / 60).truncatingRemainder(dividingBy: 1)
        let trailLength = 0.06
        let color = timerColor(for: elapsed)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let angle = Angle.degrees(progress * 360 - 90)
        let dotPoint = CGPoint(
            x: center.x + cos(angle.radians) * radius * 1.07,
            y: center.y + sin(angle.radians) * radius * 1.07
        )
        let segments = trailSegments(progress: progress, length: trailLength)

        return ZStack {
            ZStack {
                ForEach(segments.indices, id: \.self) { index in
                    let segment = segments[index]
                    Circle()
                        .trim(from: segment.start, to: segment.end)
                        .stroke(
                            AngularGradient(
                                gradient: Gradient(stops: [
                                    .init(color: color.opacity(0.0), location: 0),
                                    .init(color: color.opacity(0.35), location: 1)
                                ]),
                                center: .center,
                                startAngle: .degrees(segment.start * 360),
                                endAngle: .degrees(segment.end * 360)
                            ),
                            style: StrokeStyle(lineWidth: 4, lineCap: .round)
                        )
                }
            }
            .rotationEffect(.degrees(-90))

            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                .shadow(color: color.opacity(0.5), radius: 3)
                .position(dotPoint)
        }
    }

    private func trailSegments(progress: Double, length: Double) -> [(start: Double, end: Double)] {
        let start = progress - length
        if start >= 0 {
            return [(start, progress)]
        }
        return [(start + 1, 1), (0, progress)]
    }

    private func timerColor(for elapsed: TimeInterval) -> Color {
        let colors: [NSColor] = [
            .systemRed,
            .systemOrange,
            .systemYellow,
            .systemGreen,
            .systemTeal,
            .systemBlue,
            .systemPurple
        ]
        let minutes = max(0, elapsed / 60)
        let base = floor(minutes)
        let t = CGFloat(minutes - base)
        let index = Int(base) % colors.count
        let nextIndex = (index + 1) % colors.count
        return interpolateColor(colors[index], colors[nextIndex], t: t)
    }

    private func interpolateColor(_ a: NSColor, _ b: NSColor, t: CGFloat) -> Color {
        let aColor = a.usingColorSpace(.deviceRGB) ?? a
        let bColor = b.usingColorSpace(.deviceRGB) ?? b
        var ar: CGFloat = 0
        var ag: CGFloat = 0
        var ab: CGFloat = 0
        var aa: CGFloat = 0
        var br: CGFloat = 0
        var bg: CGFloat = 0
        var bb: CGFloat = 0
        var ba: CGFloat = 0
        aColor.getRed(&ar, green: &ag, blue: &ab, alpha: &aa)
        bColor.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
        let r = ar + (br - ar) * t
        let g = ag + (bg - ag) * t
        let b = ab + (bb - ab) * t
        let a = aa + (ba - aa) * t
        return Color(.sRGB, red: Double(r), green: Double(g), blue: Double(b), opacity: Double(a))
    }

    private func configureWindow(_ window: NSWindow, aspectRatio: CGFloat) {
        let clampedRatio = max(0.1, aspectRatio)
        let desiredStyle: NSWindow.StyleMask = [.borderless, .resizable]

        if window.styleMask != desiredStyle {
            window.styleMask = desiredStyle
        }

        window.hasShadow = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.contentAspectRatio = NSSize(width: clampedRatio, height: 1)
    }

    private func resizeWindow(by delta: CGFloat) {
        guard let window = resolveWindowForResize() else { return }
        let currentSize = window.frame.size
        let currentLength = min(currentSize.width, currentSize.height)
        let minSize: CGFloat = 180
        let maxSize: CGFloat = maxAllowedWindowSize(for: window)
        let newLength = min(max(currentLength + delta, minSize), maxSize)

        let center = CGPoint(x: window.frame.midX, y: window.frame.midY)
        let newFrame = CGRect(
            x: center.x - newLength / 2,
            y: center.y - newLength / 2,
            width: newLength,
            height: newLength
        )
        window.setFrame(newFrame, display: true, animate: true)
    }

    private func resolveWindowForResize() -> NSWindow? {
        if let windowRef {
            return windowRef
        }
        return NSApp.keyWindow ?? NSApp.mainWindow
    }

    private func maxAllowedWindowSize(for window: NSWindow) -> CGFloat {
        guard let screenFrame = window.screen?.visibleFrame else {
            return 1200
        }
        return min(screenFrame.width, screenFrame.height) * 0.9
    }

    private var shouldShowStatusOverlay: Bool {
        model.errorMessage != nil || model.needsScreenRecordingPermission
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

private struct WindowAccessor: NSViewRepresentable {
    let aspectRatio: CGFloat
    let configure: (NSWindow, CGFloat) -> Void
    let onWindow: (NSWindow) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            self.updateWindow(for: view, context: context)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        updateWindow(for: nsView, context: context)
    }

    private func updateWindow(for view: NSView, context: Context) {
        guard let window = view.window else { return }

        if context.coordinator.window !== window {
            context.coordinator.window = window
            context.coordinator.didWrapContent = false
            onWindow(window)
        }

        if !context.coordinator.didWrapContent {
            wrapContentView(in: window)
            context.coordinator.didWrapContent = true
        }

        if context.coordinator.lastAspectRatio != aspectRatio {
            configure(window, aspectRatio)
            context.coordinator.lastAspectRatio = aspectRatio
        }
    }

    private func wrapContentView(in window: NSWindow) {
        guard let contentView = window.contentView else { return }
        guard !(contentView is CircleHitTestView) else { return }

        let container = CircleHitTestView(frame: contentView.frame)
        container.autoresizingMask = [.width, .height]
        contentView.frame = container.bounds
        contentView.autoresizingMask = [.width, .height]
        container.addSubview(contentView)
        window.contentView = container
    }

    final class Coordinator {
        var window: NSWindow?
        var lastAspectRatio: CGFloat?
        var didWrapContent = false
    }
}

final class CircleHitTestView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let radius = min(bounds.width, bounds.height) / 2
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let dx = point.x - center.x
        let dy = point.y - center.y

        if (dx * dx + dy * dy) > (radius * radius) {
            return nil
        }

        return super.hitTest(point)
    }

    override var isOpaque: Bool {
        false
    }
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
