// StreamSessionViewModel.swift
import AVFoundation
import Combine
import MWDATCamera
import MWDATCore
import SwiftUI

enum StreamingStatus {
  case streaming
  case waiting
  case stopped
}

final class BidAudioPlayer: NSObject, @unchecked Sendable {
  static let shared = BidAudioPlayer()
  private var player: AVAudioPlayer?

  private override init() {
    super.init()
  }

  func play(data: Data) {
    BidEscuchaManager.pausarEngine()
    try? AVAudioSession.sharedInstance().setActive(true)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
      if let appDelegate = UIApplication.shared.delegate as? AppDelegate {
        appDelegate.silencioPlayer?.play()
      }
      do {
        self.player = try AVAudioPlayer(data: data)
        self.player?.delegate = self
        self.player?.prepareToPlay()
        self.player?.play()
      } catch {
        BidEscuchaManager.reanudarEngine()
      }
    }
  }
}

extension BidAudioPlayer: AVAudioPlayerDelegate {
  func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
    if let appDelegate = UIApplication.shared.delegate as? AppDelegate {
      appDelegate.silencioPlayer?.play()
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
      NotificationCenter.default.post(name: NSNotification.Name("BIDAudioTerminado"), object: nil)
      BidEscuchaManager.reanudarEngine()
    }
  }
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
  @Published var respuestaParaFoto = false

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
        showErrorMsg("Permission denied")
        return
      }
      await startSession()
    } catch {
      showErrorMsg("Permission error: \(error.description)")
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
      Task { @MainActor in await self?.handleStateChange(state) }
    }
    videoFrameListenerToken = stream.videoFramePublisher.listen { [weak self] frame in
      Task { @MainActor in await self?.handleVideoFrame(frame) }
    }
    errorListenerToken = stream.errorPublisher.listen { [weak self] error in
      Task { @MainActor in await self?.handleError(error) }
    }
    photoDataListenerToken = stream.photoDataPublisher.listen { [weak self] data in
      Task { @MainActor in await self?.handlePhotoData(data) }
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
    }
  }

  func handleVideoFrame(_ frame: VideoFrame) async {
    if let image = frame.makeUIImage() {
      currentVideoFrame = image
      if respuestaParaFoto {
        respuestaParaFoto = false
        if let jpegData = image.jpegData(compressionQuality: 0.7) {
          await stopSession()
          await analizarImagen(data: jpegData)
        }
      }
    }
  }

  func handlePhotoData(_ data: PhotoData) async {
    isCapturingPhoto = false
    if let image = UIImage(data: data.data) {
      capturedPhoto = image
      showPhotoPreview = true
      await analizarImagen(data: data.data)
    }
  }

  func analizarImagen(data: Data) async {
    guard let url = URL(string: "https://bidjuanmi.com/analizar-imagen") else { return }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
    request.httpBody = data
    do {
      let (responseData, _) = try await URLSession.shared.data(for: request)
      if let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
         let descripcion = json["descripcion"] as? String {
        await reproducirAudio(texto: descripcion)
      }
    } catch { return }
  }

  func handleError(_ error: StreamSessionError) async {
    let message = formatError(error)
    if message != errorMessage { showErrorMsg(message) }
  }

  func enviarMensajeABid(mensaje: String, lat: Double = 0, lon: Double = 0) async {
    guard var components = URLComponents(string: "https://bidjuanmi.com/chat-stream") else { return }
    var queryItems = [URLQueryItem(name: "message", value: mensaje)]
    if lat != 0 && lon != 0 {
      queryItems.append(URLQueryItem(name: "lat", value: String(lat)))
      queryItems.append(URLQueryItem(name: "lon", value: String(lon)))
    }
    components.queryItems = queryItems
    guard let url = components.url else { return }
    var textoCompleto = ""
    do {
      let (asyncBytes, _) = try await URLSession.shared.bytes(from: url)
      for try await line in asyncBytes.lines {
        if line.hasPrefix("data: ") {
          let json = String(line.dropFirst(6))
          if let data = json.data(using: .utf8),
             let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let texto = obj["text"] as? String { textoCompleto += texto }
            if let done = obj["done"] as? Bool, done { break }
          }
        }
      }
    } catch { return }
    if textoCompleto.trimmingCharacters(in: .whitespacesAndNewlines) == "[FOTO]" {
      respuestaParaFoto = true
    } else {
      respuestaParaFoto = false
      if !textoCompleto.isEmpty {
        await reproducirAudio(texto: textoCompleto)
      }
    }
  }

  func reproducirAudio(texto: String) async {
    guard var components = URLComponents(string: "https://bidjuanmi.com/tts") else { return }
    components.queryItems = [URLQueryItem(name: "text", value: texto)]
    guard let url = components.url else { return }
    do {
      let (data, _) = try await URLSession.shared.data(from: url)
      BidAudioPlayer.shared.play(data: data)
    } catch { return }
  }

  func showErrorMsg(_ message: String) {
    errorMessage = message
    showError = true
  }

  private func formatError(_ error: StreamSessionError) -> String {
    switch error {
    case .internalError: return "An internal error occurred. Please try again."
    case .deviceNotFound: return "Device not found. Please ensure your device is connected."
    case .deviceNotConnected: return "Device not connected. Please check your connection and try again."
    case .timeout: return "The operation timed out. Please try again."
    case .videoStreamingError: return "Video streaming failed. Please try again."
    case .permissionDenied: return "Camera permission denied. Please grant permission in Settings."
    case .hingesClosed: return "The hinges on the glasses were closed. Please open the hinges and try again."
    case .thermalCritical: return "Device is overheating. Streaming has been paused to protect the device."
    @unknown default: return "An unknown streaming error occurred."
    }
  }
}
