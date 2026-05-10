import Combine
import MWDATCamera
import MWDATCore
import SwiftUI

enum StreamingStatus {
  case streaming
  case waiting
  case stopped
}

@MainActor
final class StreamSessionViewModel: ObservableObject {
  @Published var currentVideoFrame: UIImage?
  @Published var hasReceivedFirstFrame: Bool = false
  @Published var streamingStatus: StreamingStatus = .stopped
  @Published var showError: Bool = false
  @Published var errorMessage: String = ""
  @Published var capturedPhoto: UIImage?
  @Published var showPhotoPreview: Bool = false
  @Published var showPhotoCaptureError: Bool = false
  @Published var isCapturingPhoto: Bool = false
  @Published var hasActiveDevice: Bool = false
  @Published var isDeviceSessionReady: Bool = false

  var isStreaming: Bool { streamingStatus != .stopped }

  private let sessionManager: DeviceSessionManager
  private let wearables: WearablesInterface
  private var streamSession: StreamSession?
  private var cancellables = Set<AnyCancellable>()
  private var stateListenerToken: AnyListenerToken?
  private var videoFrameListenerToken: AnyListenerToken?
  private var errorListenerToken: AnyListenerToken?
  private var photoDataListenerToken: AnyListenerToken?

  init(wearables: WearablesInterface) {
    self.wearables = wearables
    self.sessionManager = DeviceSessionManager(wearables: wearables)
    sessionManager.$hasActiveDevice
      .receive(on: DispatchQueue.main)
      .assign(to: &$hasActiveDevice)
    sessionManager.$isReady
      .receive(on: DispatchQueue.main)
      .assign(to: &$isDeviceSessionReady)
  }

  func handleStartStreaming() async {
    let permission = Permission.camera
    do {
      var status = try await wearables.checkPermissionStatus(permission)
      if status != .granted {
        status = try await wearables.requestPermission(permission)
      }
      guard status == .granted else {
        showError("Permission denied")
        return
      }
      await startSession()
    } catch {
      showError("Permission error: \(error.description)")
    }
  }

  func stopSession() async {
    guard let stream = streamSession else { return }
    streamSession = nil
    clearListeners()
    streamingStatus = .stopped
    currentVideoFrame = nil
    hasReceivedFirstFrame = false
    await stream.stop()
  }

  func capturePhoto() {
    guard !isCapturingPhoto, streamingStatus == .streaming else {
      showPhotoCaptureError = true
      return
    }
    isCapturingPhoto = true
    let success = streamSession?.capturePhoto(format: .jpeg) ?? false
    if !success {
      isCapturingPhoto = false
      showPhotoCaptureError = true
    }
  }

  func dismissError() {
    showError = false
    errorMessage = ""
  }

  func dismissPhotoCaptureError() {
    showPhotoCaptureError = false
  }

  func dismissPhotoPreview() {
    showPhotoPreview = false
    capturedPhoto = nil
  }

  private func startSession() async {
    guard let deviceSession = await sessionManager.getSession() else { return }
    guard deviceSession.state == .started else { return }
    let config = StreamSessionConfig(
      videoCodec: VideoCodec.raw,
      resolution: StreamingResolution.low,
      frameRate: 24
    )
    guard let stream = try? deviceSession.addStream(config: config) else { return }
    streamSession = stream
    streamingStatus = .waiting
    setupListeners(for: stream)
    await stream.start()
  }

  private func setupListeners(for stream: StreamSession) {
    stateListenerToken = stream.statePublisher.listen { [weak self] state in
      Task { @MainActor in
        await self?.handleStateChange(state)
      }
    }
    videoFrameListenerToken = stream.videoFramePublisher.listen { [weak self] frame in
      Task { @MainActor in
        await self?.handleVideoFrame(frame)
      }
    }
    errorListenerToken = stream.errorPublisher.listen { [weak self] error in
      Task { @MainActor in
        await self?.handleError(error)
      }
    }
    photoDataListenerToken = stream.photoDataPublisher.listen { [weak self] data in
      Task { @MainActor in
        await self?.handlePhotoData(data)
      }
    }
  }

  private func clearListeners() {
    stateListenerToken = nil
    videoFrameListenerToken = nil
    errorListenerToken = nil
    photoDataListenerToken = nil
  }

  func handleStateChange(_ state: StreamSessionState) async {
    switch state {
    case .stopped:
      currentVideoFrame = nil
      streamingStatus = .stopped
    case .waitingForDevice, .starting, .stopping, .paused:
      streamingStatus = .waiting
    case .streaming:
      streamingStatus = .streaming
      await enviarMensajeABid(mensaje: "Streaming iniciado desde las gafas Ray-Ban Meta")
    }
  }

  func handleVideoFrame(_ frame: VideoFrame) async {
    if let image = frame.makeUIImage() {
      currentVideoFrame = image
      if !hasReceivedFirstFrame {
        hasReceivedFirstFrame = true
        await enviarFrameABid(image: image)
      }
    }
  }

  func handlePhotoData(_ data: PhotoData) async {
    isCapturingPhoto = false
    if let image = UIImage(data: data.data) {
      capturedPhoto = image
      showPhotoPreview = true
      await enviarFotoABid(data: data.data)
    }
  }

  func handleError(_ error: StreamSessionError) async {
    let message = formatError(error)
    if message != errorMessage {
      showError(message)
    }
  }

  func enviarMensajeABid(mensaje: String) async {
    guard var components = URLComponents(string: "https://bidjuanmi.com/chat-stream") else { return }
    components.queryItems = [URLQueryItem(name: "message", value: mensaje)]
    guard let url = components.url else { return }

    // Leer respuesta SSE línea a línea
    var textoCompleto = ""
    do {
      let (asyncBytes, _) = try await URLSession.shared.bytes(from: url)
      for try await line in asyncBytes.lines {
        if line.hasPrefix("data: ") {
          let json = String(line.dropFirst(6))
          if let data = json.data(using: .utf8),
             let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let texto = obj["text"] as? String {
              textoCompleto += texto
            }
            if let done = obj["done"] as? Bool, done {
              break
            }
          }
        }
      }
    } catch {
      return
    }

    // Reproducir respuesta por los auriculares
    if !textoCompleto.isEmpty {
      await reproducirAudio(texto: textoCompleto)
    }
  }

  func reproducirAudio(texto: String) async {
    guard var components = URLComponents(string: "https://bidjuanmi.com/tts") else { return }
    components.queryItems = [URLQueryItem(name: "text", value: texto)]
    guard let url = components.url else { return }

    do {
      let (data, _) = try await URLSession.shared.data(from: url)
      await MainActor.run {
        BidAudioPlayer.shared.play(data: data)
      }
    } catch {
      return
    }
  }

  func enviarFrameABid(image: UIImage) async {
    await enviarMensajeABid(mensaje: "Que ves en esta imagen de mis gafas?")
  }

  func enviarFotoABid(data: Data) async {
    await enviarMensajeABid(mensaje: "Foto capturada desde mis gafas Ray-Ban Meta")
  }

  func showError(_ message: String) {
    errorMessage = message
    showError = true
  }

  func enviarFrameABid(image: UIImage) async {
    guard var components = URLComponents(string: "https://bidjuanmi.com/chat-stream") else { return }
    components.queryItems = [URLQueryItem(name: "message", value: "Que ves en esta imagen de mis gafas?")]
    guard let url = components.url else { return }
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    _ = try? await URLSession.shared.data(for: request)
  }

  func enviarFotoABid(data: Data) async {
    guard var components = URLComponents(string: "https://bidjuanmi.com/chat-stream") else { return }
    components.queryItems = [URLQueryItem(name: "message", value: "Foto capturada desde mis gafas Ray-Ban Meta")]
    guard let url = components.url else { return }
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    _ = try? await URLSession.shared.data(for: request)
  }

  func showError(_ message: String) {
    errorMessage = message
    showError = true
  }

  private func formatError(_ error: StreamSessionError) -> String {
    switch error {
    case .internalError:
      return "An internal error occurred. Please try again."
    case .deviceNotFound:
      return "Device not found. Please ensure your device is connected."
    case .deviceNotConnected:
      return "Device not connected. Please check your connection and try again."
    case .timeout:
      return "The operation timed out. Please try again."
    case .videoStreamingError:
      return "Video streaming failed. Please try again."
    case .permissionDenied:
      return "Camera permission denied. Please grant permission in Settings."
    case .hingesClosed:
      return "The hinges on the glasses were closed. Please open the hinges and try again."
    case .thermalCritical:
      return "Device is overheating. Streaming has been paused to protect the device."
    @unknown default:
      return "An unknown streaming error occurred."
    }
  }
}
