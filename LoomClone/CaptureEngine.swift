import AVFoundation
import CoreGraphics
import Foundation
import QuartzCore
import ScreenCaptureKit
import SwiftUI

enum RecordingState: String {
    case idle
    case recording
    case paused
    case stopping
    case error
}

struct DisplayItem: Identifiable {
    let id: CGDirectDisplayID
    let display: SCDisplay
    let label: String
    let aspectRatio: CGFloat
}

final class PauseController {
    private let queue = DispatchQueue(label: "PauseController")
    private var startTime: CFTimeInterval?
    private var pauseStart: CFTimeInterval?
    private var totalPaused: CFTimeInterval = 0
    private var paused = false

    func start() {
        queue.sync {
            startTime = CACurrentMediaTime()
            pauseStart = nil
            totalPaused = 0
            paused = false
        }
    }

    func stop() {
        queue.sync {
            startTime = nil
            pauseStart = nil
            totalPaused = 0
            paused = false
        }
    }

    func pause() {
        queue.sync {
            guard !paused else { return }
            paused = true
            pauseStart = CACurrentMediaTime()
        }
    }

    func resume() {
        queue.sync {
            guard paused, let pauseStart else { return }
            let now = CACurrentMediaTime()
            totalPaused += now - pauseStart
            self.pauseStart = nil
            paused = false
        }
    }

    func shouldDropSamples() -> Bool {
        queue.sync { paused }
    }

    func currentOffset() -> CMTime {
        queue.sync {
            CMTimeMakeWithSeconds(totalPaused, preferredTimescale: 1_000_000_000)
        }
    }

    func currentTimelineSeconds() -> Double {
        queue.sync {
            guard let startTime else { return 0 }
            let now = CACurrentMediaTime()
            let pausedDuration = paused ? now - (pauseStart ?? now) : 0
            return max(0, now - startTime - totalPaused - pausedDuration)
        }
    }
}

struct BubbleEvent: Codable {
    let t: Double
    let x: Double
    let y: Double
    let radius: Double
}

struct RecordingMetadata: Codable {
    let version: Int
    let createdAt: String
    let events: [BubbleEvent]
}

final class MetadataLogger {
    private let queue = DispatchQueue(label: "MetadataLogger")
    private let pauseController: PauseController
    private var outputURL: URL?
    private var events: [BubbleEvent] = []

    init(pauseController: PauseController) {
        self.pauseController = pauseController
    }

    func start(outputURL: URL) {
        queue.sync {
            self.outputURL = outputURL
            events.removeAll()
        }
    }

    func logBubble(position: CGPoint, radius: CGFloat) {
        let timestamp = pauseController.currentTimelineSeconds()
        let event = BubbleEvent(
            t: timestamp,
            x: Double(position.x),
            y: Double(position.y),
            radius: Double(radius)
        )
        queue.async {
            self.events.append(event)
        }
    }

    func stop(completion: @escaping (Result<URL, Error>) -> Void) {
        queue.async {
            guard let url = self.outputURL else {
                completion(.success(URL(fileURLWithPath: "")))
                return
            }
            let formatter = ISO8601DateFormatter()
            let metadata = RecordingMetadata(
                version: 1,
                createdAt: formatter.string(from: Date()),
                events: self.events
            )
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(metadata)
                try data.write(to: url, options: [.atomic])
                completion(.success(url))
            } catch {
                completion(.failure(error))
            }
        }
    }
}

final class AppViewModel: ObservableObject {
    @Published var displays: [DisplayItem] = []
    @Published var selectedDisplayID: CGDirectDisplayID?
    @Published var state: RecordingState = .idle
    @Published var elapsedTime: TimeInterval = 0
    @Published var screenOutputURL: URL?
    @Published var cameraOutputURL: URL?
    @Published var metadataOutputURL: URL?
    @Published var errorMessage: String?
    @Published var needsScreenRecordingPermission = false
    @Published var bubblePosition = CGPoint(x: 0.8, y: 0.8)
    @Published var bubbleSize: CGFloat = 160

    let screenPreview = ScreenPreviewModel()
    let screenRecorder = ScreenRecorder()
    let cameraController = CameraController()
    private let pauseController = PauseController()
    private let metadataLogger: MetadataLogger
    private let micCapture = MicAudioCapture()

    private var timer: Timer?
    private var didStart = false

    init() {
        metadataLogger = MetadataLogger(pauseController: pauseController)
        micCapture.onAudioSample = { [weak self] sampleBuffer in
            self?.screenRecorder.appendAudio(sampleBuffer)
        }
        micCapture.onError = { [weak self] error in
            DispatchQueue.main.async {
                self?.state = .error
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    func start() {
        guard !didStart else { return }
        didStart = true

        screenRecorder.onPreviewSample = { [weak self] sampleBuffer in
            self?.screenPreview.enqueue(sampleBuffer)
        }
        screenRecorder.onError = { [weak self] error in
            DispatchQueue.main.async {
                self?.state = .error
                self?.handleScreenCaptureError(error)
            }
        }
        cameraController.onError = { [weak self] error in
            DispatchQueue.main.async {
                self?.state = .error
                self?.errorMessage = error.localizedDescription
            }
        }

        AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async {
                if granted {
                    self.cameraController.startSession()
                } else {
                    self.state = .error
                    self.errorMessage = "Camera access was denied."
                }
            }
        }
        if ensureScreenCapturePermission() {
            Task {
                await self.reloadDisplays()
                await self.restartPreviewForSelection()
            }
        }
    }

    func reloadDisplays() async {
        do {
            let content = try await SCShareableContent.current
            let items = content.displays.map { display in
                let pixelWidth = CGDisplayPixelsWide(display.displayID)
                let pixelHeight = CGDisplayPixelsHigh(display.displayID)
                let label = "Display \(display.displayID) — \(pixelWidth)x\(pixelHeight)"
                let ratio = pixelHeight > 0 ? CGFloat(pixelWidth) / CGFloat(pixelHeight) : 16.0 / 9.0
                return DisplayItem(id: display.displayID, display: display, label: label, aspectRatio: ratio)
            }
            await MainActor.run {
                self.displays = items
                if self.selectedDisplayID == nil {
                    self.selectedDisplayID = items.first?.id
                }
            }
        } catch {
            await MainActor.run {
                self.state = .error
                self.handleScreenCaptureError(error)
            }
        }
    }

    func restartPreviewForSelection() async {
        guard let selectedID = selectedDisplayID,
              let display = displays.first(where: { $0.id == selectedID })?.display else {
            return
        }

        await screenRecorder.stopCapture()
        screenPreview.flush()

        do {
            try await screenRecorder.startCapture(display: display)
        } catch {
            await MainActor.run {
                self.state = .error
                self.handleScreenCaptureError(error)
            }
        }
    }

    func startRecording() {
        guard state == .idle else { return }
        errorMessage = nil

        let outputDir = outputDirectory()
        let timestamp = timestampString()
        let screenURL = outputDir.appendingPathComponent("screen_\(timestamp).mov")
        let cameraURL = outputDir.appendingPathComponent("camera_\(timestamp).mov")
        let metadataURL = outputDir.appendingPathComponent("meta_\(timestamp).json")

        screenOutputURL = screenURL
        cameraOutputURL = cameraURL
        metadataOutputURL = metadataURL

        pauseController.start()
        elapsedTime = 0
        metadataLogger.start(outputURL: metadataURL)
        startTimer()
        state = .recording

        screenRecorder.prepareRecording(outputURL: screenURL)
        cameraController.startRecording(outputURL: cameraURL, pauseController: pauseController)

        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                guard self.state == .recording || self.state == .paused else { return }
                if granted {
                    self.micCapture.start()
                } else {
                    self.errorMessage = "Microphone access was denied."
                }
                self.screenRecorder.startRecording(
                    outputURL: screenURL,
                    includeAudio: granted,
                    pauseController: self.pauseController
                )
            }
        }
    }

    func stopRecording() {
        guard state == .recording || state == .paused else { return }
        state = .stopping

        stopTimer()
        micCapture.stop()

        let group = DispatchGroup()
        var screenResult: Result<URL, Error>?
        var cameraResult: Result<URL, Error>?
        var metadataResult: Result<URL, Error>?

        group.enter()
        screenRecorder.stopRecording { result in
            DispatchQueue.main.async {
                screenResult = result
                group.leave()
            }
        }

        group.enter()
        cameraController.stopRecording { result in
            DispatchQueue.main.async {
                cameraResult = result
                group.leave()
            }
        }

        group.enter()
        metadataLogger.stop { result in
            DispatchQueue.main.async {
                metadataResult = result
                group.leave()
            }
        }

        group.notify(queue: .main) {
            self.pauseController.stop()
            if case let .failure(error) = screenResult {
                self.state = .error
                self.errorMessage = self.formatError(error)
                return
            }
            if case let .failure(error) = cameraResult {
                self.state = .error
                self.errorMessage = self.formatError(error)
                return
            }
            if case let .failure(error) = metadataResult {
                self.state = .error
                self.errorMessage = self.formatError(error)
                return
            }
            self.state = .idle
        }
    }

    func pauseRecording() {
        guard state == .recording else { return }
        pauseController.pause()
        screenRecorder.resetPendingVideoSample()
        state = .paused
    }

    func resumeRecording() {
        guard state == .paused else { return }
        pauseController.resume()
        state = .recording
    }

    func logBubbleEvent(radiusNormalized: CGFloat) {
        guard state == .recording || state == .paused else { return }
        metadataLogger.logBubble(position: bubblePosition, radius: radiusNormalized)
    }

    func formattedElapsedTime() -> String {
        let totalSeconds = Int(elapsedTime)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.elapsedTime = self.pauseController.currentTimelineSeconds()
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func outputDirectory() -> URL {
        let base = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let dir = base.appendingPathComponent("LoomClone", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private func timestampString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.string(from: Date())
    }

    private func ensureScreenCapturePermission() -> Bool {
        if CGPreflightScreenCaptureAccess() {
            needsScreenRecordingPermission = false
            return true
        }

        let granted = CGRequestScreenCaptureAccess()
        if granted {
            needsScreenRecordingPermission = false
            errorMessage = "Screen Recording permission was granted. Please quit and relaunch LoomClone."
        } else {
            needsScreenRecordingPermission = true
            errorMessage = "Screen Recording permission is required. Enable LoomClone in System Settings → Privacy & Security → Screen Recording, then relaunch."
        }
        return false
    }

    private func handleScreenCaptureError(_ error: Error) {
        let nsError = error as NSError
        if nsError.domain == SCStreamErrorDomain, nsError.code == -3801 {
            needsScreenRecordingPermission = true
            let bundlePath = Bundle.main.bundleURL.path
            errorMessage = "Screen Recording permission was denied for this app instance. Enable it in System Settings → Privacy & Security → Screen Recording, then quit and relaunch. App path: \(bundlePath)"
            return
        }
        needsScreenRecordingPermission = false
        errorMessage = formatError(error)
    }

    private func formatError(_ error: Error) -> String {
        let nsError = error as NSError
        var message = "\(nsError.localizedDescription) (\(nsError.domain) \(nsError.code))"
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            message += " → \(underlying.localizedDescription) (\(underlying.domain) \(underlying.code))"
        }
        return message
    }
}

final class ScreenPreviewModel: ObservableObject {
    private weak var view: ScreenPreviewLayerView?

    func attach(_ view: ScreenPreviewLayerView) {
        self.view = view
    }

    func detach(_ view: ScreenPreviewLayerView) {
        if self.view === view {
            self.view = nil
        }
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        DispatchQueue.main.async { [weak self] in
            self?.view?.enqueue(sampleBuffer)
        }
    }

    func flush() {
        DispatchQueue.main.async { [weak self] in
            self?.view?.flush()
        }
    }
}

final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    var onPreviewSample: ((CMSampleBuffer) -> Void)?
    var onError: ((Error) -> Void)?

    private let streamQueue = DispatchQueue(label: "ScreenRecorder.stream")
    private let stateQueue = DispatchQueue(label: "ScreenRecorder.state")
    private var stream: SCStream?
    private var writer: ScreenAssetWriter?
    private var currentOutputURL: URL?

    func startCapture(display: SCDisplay) async throws {
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = CGDisplayPixelsWide(display.displayID)
        config.height = CGDisplayPixelsHigh(display.displayID)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.queueDepth = 6
        config.showsCursor = true
        config.capturesAudio = false

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: streamQueue)
        } catch {
            throw error
        }

        try await stream.startCapture()

        stateQueue.sync {
            self.stream = stream
        }
    }

    func stopCapture() async {
        let stream = stateQueue.sync { self.stream }
        guard let stream else { return }
        try? await stream.stopCapture()
        stateQueue.sync {
            self.stream = nil
        }
    }

    func startRecording(outputURL: URL, includeAudio: Bool, pauseController: PauseController) {
        let writer = ScreenAssetWriter(outputURL: outputURL, includeAudio: includeAudio, pauseController: pauseController)
        stateQueue.sync {
            self.writer = writer
            self.currentOutputURL = outputURL
        }
    }

    func prepareRecording(outputURL: URL) {
        stateQueue.sync {
            self.currentOutputURL = outputURL
        }
    }

    func stopRecording(completion: @escaping (Result<URL, Error>) -> Void) {
        let (writer, outputURL) = stateQueue.sync { () -> (ScreenAssetWriter?, URL?) in
            defer { self.writer = nil }
            let url = self.currentOutputURL
            self.currentOutputURL = nil
            return (self.writer, url)
        }
        guard let writer else {
            completion(.success(outputURL ?? URL(fileURLWithPath: "")))
            return
        }
        writer.finish(completion: completion)
    }

    func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        let writer = stateQueue.sync { self.writer }
        writer?.appendAudio(sampleBuffer: sampleBuffer)
    }

    func resetPendingVideoSample() {
        let writer = stateQueue.sync { self.writer }
        writer?.resetPendingVideoSample()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }

        onPreviewSample?(sampleBuffer)

        let writer = stateQueue.sync { self.writer }
        writer?.appendVideo(sampleBuffer: sampleBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError?(error)
    }
}

final class MicAudioCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    var onAudioSample: ((CMSampleBuffer) -> Void)?
    var onError: ((Error) -> Void)?

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "MicAudioCapture.session")
    private let outputQueue = DispatchQueue(label: "MicAudioCapture.output")
    private var isConfigured = false

    func start() {
        sessionQueue.async {
            if !self.isConfigured {
                self.configureSession()
            }
            guard !self.session.isRunning else { return }
            self.session.startRunning()
        }
    }

    func stop() {
        sessionQueue.async {
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        onAudioSample?(sampleBuffer)
    }

    private func configureSession() {
        session.beginConfiguration()

        if let device = AVCaptureDevice.default(for: .audio) {
            do {
                let input = try AVCaptureDeviceInput(device: device)
                if session.canAddInput(input) {
                    session.addInput(input)
                }
            } catch {
                onError?(error)
            }
        }

        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: outputQueue)
        if session.canAddOutput(output) {
            session.addOutput(output)
        }

        session.commitConfiguration()
        isConfigured = true
    }
}

final class CameraController: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    var onError: ((Error) -> Void)?

    private let sessionQueue = DispatchQueue(label: "CameraController.session")
    private let outputQueue = DispatchQueue(label: "CameraController.output")
    private let stateQueue = DispatchQueue(label: "CameraController.state")
    private var isConfigured = false
    private var writer: CameraAssetWriter?
    private var currentOutputURL: URL?

    func startSession() {
        sessionQueue.async {
            guard !self.session.isRunning else { return }
            if !self.isConfigured {
                self.configureSession()
            }
            self.session.startRunning()
        }
    }

    func stopSession() {
        sessionQueue.async {
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }

    func startRecording(outputURL: URL, pauseController: PauseController) {
        let writer = CameraAssetWriter(outputURL: outputURL, pauseController: pauseController)
        stateQueue.sync {
            self.writer = writer
            self.currentOutputURL = outputURL
        }
    }

    func stopRecording(completion: @escaping (Result<URL, Error>) -> Void) {
        let (writer, outputURL) = stateQueue.sync { () -> (CameraAssetWriter?, URL?) in
            defer { self.writer = nil }
            let url = self.currentOutputURL
            self.currentOutputURL = nil
            return (self.writer, url)
        }
        guard let writer else {
            completion(.success(outputURL ?? URL(fileURLWithPath: "")))
            return
        }
        writer.finish(completion: completion)
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        let writer = stateQueue.sync { self.writer }
        writer?.appendVideo(sampleBuffer: sampleBuffer)
    }

    private func configureSession() {
        session.beginConfiguration()
        session.sessionPreset = .high

        if let device = selectCameraDevice() {
            do {
                let input = try AVCaptureDeviceInput(device: device)
                if session.canAddInput(input) {
                    session.addInput(input)
                }
            } catch {
                onError?(error)
            }
        }

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: outputQueue)

        if session.canAddOutput(output) {
            session.addOutput(output)
        }

        session.commitConfiguration()
        isConfigured = true
    }

    private func selectCameraDevice() -> AVCaptureDevice? {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .front
        )
        if let device = discovery.devices.first {
            return device
        }
        return AVCaptureDevice.default(for: .video)
    }
}

final class ScreenAssetWriter {
    private struct AudioFormat {
        let sampleRate: Double
        let channels: Int
    }

    private let outputURL: URL
    private let includeAudio: Bool
    private let pauseController: PauseController
    private let queue = DispatchQueue(label: "ScreenAssetWriter")
    private let codec: AVVideoCodecType

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var didStartSession = false
    private var pendingVideoSample: CMSampleBuffer?
    private var audioFormat: AudioFormat?
    private var waitingForAudio = false
    private var audioWaitWorkItem: DispatchWorkItem?
    private let audioWaitDuration: TimeInterval = 0.4

    init(outputURL: URL, includeAudio: Bool, pauseController: PauseController, codec: AVVideoCodecType = .h264) {
        self.outputURL = outputURL
        self.includeAudio = includeAudio
        self.pauseController = pauseController
        self.codec = codec
    }

    func appendVideo(sampleBuffer: CMSampleBuffer) {
        queue.async {
            guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
            guard !self.pauseController.shouldDropSamples() else { return }

            if self.writer == nil {
                self.pendingVideoSample = sampleBuffer
                if self.includeAudio && self.audioFormat == nil && !self.waitingForAudio {
                    self.waitingForAudio = true
                    let work = DispatchWorkItem { [weak self] in
                        self?.queue.async {
                            self?.configureIfPossible(forceVideoOnly: true)
                            self?.waitingForAudio = false
                            self?.audioWaitWorkItem = nil
                        }
                    }
                    self.audioWaitWorkItem = work
                    self.queue.asyncAfter(deadline: .now() + self.audioWaitDuration, execute: work)
                    return
                }
                self.configureIfPossible(forceVideoOnly: false)
                return
            }

            self.appendVideoInternal(sampleBuffer)
        }
    }

    func appendAudio(sampleBuffer: CMSampleBuffer) {
        queue.async {
            guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
            guard !self.pauseController.shouldDropSamples() else { return }
            guard self.includeAudio else { return }

            if self.audioFormat == nil {
                self.audioFormat = Self.extractAudioFormat(sampleBuffer: sampleBuffer)
            }

            if self.waitingForAudio {
                self.audioWaitWorkItem?.cancel()
                self.audioWaitWorkItem = nil
                self.waitingForAudio = false
            }

            if self.writer == nil {
                self.configureIfPossible(forceVideoOnly: false)
                return
            }

            self.appendAudioInternal(sampleBuffer)
        }
    }

    func resetPendingVideoSample() {
        queue.async {
            self.pendingVideoSample = nil
            self.audioWaitWorkItem?.cancel()
            self.audioWaitWorkItem = nil
            self.waitingForAudio = false
        }
    }

    func finish(completion: @escaping (Result<URL, Error>) -> Void) {
        queue.async {
            guard let writer = self.writer else {
                completion(.success(self.outputURL))
                return
            }
            self.videoInput?.markAsFinished()
            self.audioInput?.markAsFinished()
            writer.finishWriting {
                if let error = writer.error {
                    completion(.failure(error))
                } else {
                    completion(.success(self.outputURL))
                }
            }
        }
    }

    private func configureIfPossible(forceVideoOnly: Bool) {
        guard writer == nil, let videoSample = pendingVideoSample else { return }
        if includeAudio && audioFormat == nil && !forceVideoOnly {
            return
        }

        do {
            let enableAudio = includeAudio && audioFormat != nil
            try configureWriter(videoSample: videoSample, enableAudio: enableAudio)
        } catch {
            return
        }

        appendVideoInternal(videoSample)
        pendingVideoSample = nil
    }

    private func configureWriter(videoSample: CMSampleBuffer, enableAudio: Bool) throws {
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)

        guard let formatDescription = CMSampleBufferGetFormatDescription(videoSample) else {
            throw NSError(domain: "ScreenAssetWriter", code: -1)
        }
        let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)

        let compression: [String: Any] = [
            AVVideoAverageBitRateKey: 12_000_000,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            AVVideoExpectedSourceFrameRateKey: 30,
            AVVideoMaxKeyFrameIntervalKey: 60
        ]

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: Int(dimensions.width),
            AVVideoHeightKey: Int(dimensions.height),
            AVVideoCompressionPropertiesKey: compression
        ]

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else {
            throw NSError(domain: "ScreenAssetWriter", code: -2)
        }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if enableAudio, let audioFormat {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: audioFormat.sampleRate,
                AVNumberOfChannelsKey: audioFormat.channels,
                AVEncoderBitRateKey: 128_000
            ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            }
        }

        self.writer = writer
        self.videoInput = videoInput
        self.audioInput = audioInput
    }

    private func appendVideoInternal(_ sampleBuffer: CMSampleBuffer) {
        guard let writer, let input = videoInput else { return }

        let offset = pauseController.currentOffset()
        if !didStartSession {
            writer.startWriting()
            let rawStart = CMTimeSubtract(CMSampleBufferGetPresentationTimeStamp(sampleBuffer), offset)
            let startTime = CMTimeCompare(rawStart, .zero) < 0 ? .zero : rawStart
            writer.startSession(atSourceTime: startTime)
            didStartSession = true
        }

        guard input.isReadyForMoreMediaData else { return }
        let adjusted = SampleBufferTiming.adjust(sampleBuffer, by: offset) ?? sampleBuffer
        input.append(adjusted)
    }

    private func appendAudioInternal(_ sampleBuffer: CMSampleBuffer) {
        guard didStartSession, let input = audioInput else { return }
        guard input.isReadyForMoreMediaData else { return }
        let offset = pauseController.currentOffset()
        let adjusted = SampleBufferTiming.adjust(sampleBuffer, by: offset) ?? sampleBuffer
        input.append(adjusted)
    }

    private static func extractAudioFormat(sampleBuffer: CMSampleBuffer) -> AudioFormat? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
        guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else { return nil }
        return AudioFormat(sampleRate: asbd.pointee.mSampleRate, channels: Int(asbd.pointee.mChannelsPerFrame))
    }
}

final class CameraAssetWriter {
    private let outputURL: URL
    private let pauseController: PauseController
    private let queue = DispatchQueue(label: "CameraAssetWriter")
    private let codec: AVVideoCodecType

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var didStartSession = false

    init(outputURL: URL, pauseController: PauseController, codec: AVVideoCodecType = .h264) {
        self.outputURL = outputURL
        self.pauseController = pauseController
        self.codec = codec
    }

    func appendVideo(sampleBuffer: CMSampleBuffer) {
        queue.async {
            guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
            guard !self.pauseController.shouldDropSamples() else { return }

            do {
                try self.configureIfNeeded(sampleBuffer: sampleBuffer)
            } catch {
                return
            }
            guard let writer = self.writer, let input = self.videoInput else { return }

            let offset = self.pauseController.currentOffset()
            if !self.didStartSession {
                writer.startWriting()
                let rawStart = CMTimeSubtract(CMSampleBufferGetPresentationTimeStamp(sampleBuffer), offset)
                let startTime = CMTimeCompare(rawStart, .zero) < 0 ? .zero : rawStart
                writer.startSession(atSourceTime: startTime)
                self.didStartSession = true
            }

            guard input.isReadyForMoreMediaData else { return }
            let adjusted = SampleBufferTiming.adjust(sampleBuffer, by: offset) ?? sampleBuffer
            input.append(adjusted)
        }
    }

    func finish(completion: @escaping (Result<URL, Error>) -> Void) {
        queue.async {
            guard let writer = self.writer, let input = self.videoInput else {
                completion(.success(self.outputURL))
                return
            }
            input.markAsFinished()
            writer.finishWriting {
                if let error = writer.error {
                    completion(.failure(error))
                } else {
                    completion(.success(self.outputURL))
                }
            }
        }
    }

    private func configureIfNeeded(sampleBuffer: CMSampleBuffer) throws {
        guard writer == nil else { return }

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            throw NSError(domain: "CameraAssetWriter", code: -1)
        }
        let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)

        let compression: [String: Any] = [
            AVVideoAverageBitRateKey: 5_000_000,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            AVVideoExpectedSourceFrameRateKey: 30,
            AVVideoMaxKeyFrameIntervalKey: 60
        ]

        let settings: [String: Any] = [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: Int(dimensions.width),
            AVVideoHeightKey: Int(dimensions.height),
            AVVideoCompressionPropertiesKey: compression
        ]

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true

        guard writer.canAdd(input) else {
            throw NSError(domain: "CameraAssetWriter", code: -2)
        }
        writer.add(input)

        self.writer = writer
        self.videoInput = input
    }
}

enum SampleBufferTiming {
    static func adjust(_ sampleBuffer: CMSampleBuffer, by offset: CMTime) -> CMSampleBuffer? {
        if CMTimeCompare(offset, .zero) == 0 {
            return sampleBuffer
        }

        var timingCount: CMItemCount = 0
        let status = CMSampleBufferGetSampleTimingInfoArray(
            sampleBuffer,
            entryCount: 0,
            arrayToFill: nil,
            entriesNeededOut: &timingCount
        )
        guard status == noErr, timingCount > 0 else {
            return sampleBuffer
        }

        let count = Int(timingCount)
        var timingInfo = Array(repeating: CMSampleTimingInfo(), count: count)
        let status2 = CMSampleBufferGetSampleTimingInfoArray(
            sampleBuffer,
            entryCount: count,
            arrayToFill: &timingInfo,
            entriesNeededOut: &timingCount
        )
        guard status2 == noErr else {
            return sampleBuffer
        }

        for index in 0..<timingInfo.count {
            if timingInfo[index].decodeTimeStamp.isValid {
                timingInfo[index].decodeTimeStamp = CMTimeSubtract(timingInfo[index].decodeTimeStamp, offset)
            }
            if timingInfo[index].presentationTimeStamp.isValid {
                timingInfo[index].presentationTimeStamp = CMTimeSubtract(timingInfo[index].presentationTimeStamp, offset)
            }
        }

        var adjusted: CMSampleBuffer?
        let status3 = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: timingInfo.count,
            sampleTimingArray: &timingInfo,
            sampleBufferOut: &adjusted
        )
        guard status3 == noErr else {
            return sampleBuffer
        }
        return adjusted
    }
}
