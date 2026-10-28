import AVFoundation
import CoreMedia
import Foundation

/// Raw microphone capture from the current default input device through
/// AVCaptureSession (no voice processing, so other apps' audio is not ducked).
/// Not AVAudioEngine: on macOS 26.6 its `inputNode` can hang after a
/// Bluetooth headset disconnects.
public final class MicCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    public enum CaptureError: Error, CustomStringConvertible {
        case notAuthorized
        case noDevice
        case cannotAddInput
        case cannotAddOutput

        public var description: String {
            switch self {
            case .notAuthorized: return String(localized: "нет доступа к микрофону")
            case .noDevice: return String(localized: "микрофон не найден")
            case .cannotAddInput: return String(localized: "микрофон не подключается")
            case .cannotAddOutput: return String(localized: "не создаётся выход захвата")
            }
        }
    }

    public var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    public private(set) var deviceName: String?
    public private(set) var isRunning = false

    private var session: AVCaptureSession?
    private let queue = DispatchQueue(label: "ai.nahornyi.granula.mic", qos: .userInteractive)
    private var observers: [NSObjectProtocol] = []

    public static var isAuthorized: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }

    /// Explicit request: on macOS 26 a capture without it records silence.
    public static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    public func start() throws {
        guard !isRunning else { return }
        guard Self.isAuthorized else { throw CaptureError.notAuthorized }
        guard let device = AVCaptureDevice.default(for: .audio) else { throw CaptureError.noDevice }
        let input = try AVCaptureDeviceInput(device: device)
        let session = AVCaptureSession()
        session.beginConfiguration()
        guard session.canAddInput(input) else { throw CaptureError.cannotAddInput }
        session.addInput(input)
        let output = AVCaptureAudioDataOutput()
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: TrackWriter.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw CaptureError.cannotAddOutput }
        session.addOutput(output)
        session.commitConfiguration()

        observers.append(NotificationCenter.default.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error
            Log.event("mic.runtime_error", error.map { String(describing: $0) } ?? "")
        })
        session.startRunning()
        self.session = session
        deviceName = device.localizedName
        isRunning = true
        Log.event("mic.started", "device=\(device.localizedName)")
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        session?.stopRunning()
        session = nil
        Log.event("mic.stopped")
    }

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                              from connection: AVCaptureConnection) {
        guard let onBuffer, let buffer = Self.pcmBuffer(from: sampleBuffer) else { return }
        onBuffer(buffer)
    }

    static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let format = AVAudioFormat(streamDescription: asbd) else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }
}
