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
    sessionManager.$hasActiveDevice
      .receive(on: DispatchQueue.main)
      .sink { active in
        if let url = URL(string: "https://bidjuanmi.com/bid-log?msg=hasActiveDevice-cambio-\(active)") {
          URLSession.shared.dataTask(with: url).resume()
        }
      }
      .store(in: &cancellables)
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
    if let url = URL(string: "https://bidjuanmi.com/bid-log?msg=startSession-inicio") {
      URLSession.shared.dataTask(with: url).resume()
    }
    if let url = URL(string: "https://bidjuanmi.com/bid-log?msg=hasActiveDevice-\(hasActiveDevice)-isReady-\(isDeviceSessionReady)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "") {
      URLSession.shared.dataTask(with: url).resume()
    }
    guard let deviceSession = await sessionManager.getSession() else {
      if let url = URL(string: "https://bidjuanmi.com/bid-log?msg=getSession-fallo") {
        URLSession.shared.dataTask(with: url).resume()
      }
      return
    }
    if let logUrl = URL(string: ("https://bidjuanmi.com/bid-log?msg=deviceState-\(deviceSession.state)").addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "") {
      URLSession.shared.dataTask(with: logUrl).resume()
    }
    guard deviceSession.state == .started else { return }
    let config = StreamSessionConfig(
      videoCodec: VideoCodec.raw,
      resolution: StreamingResolution.low,
      frameRate: 24
    )
    guard let stream = try? deviceSession.addStream(config: config) else {
      if let url = URL(string: "https://bidjuanmi.com/bid-log?msg=addStream-fallo") {
        URLSession.shared.dataTask(with: url).resume()
      }
      return
    }
    if let url = URL(string: "https://bidjuanmi.com/bid-log?msg=stream-arrancando") {
      URLSession.shared.dataTask(with: url).resume()
    }
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
    if let url = URL(string: ("https://bidjuanmi.com/bid-log?msg=streamState-\(state)").addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "") {
      URLSession.shared.dataTask(with: url).resume()
    }
    switch state {
    case .stopped:
      currentVideoFrame = nil
      streamingStatus = .stopped
    case .waitingForDevice, .starting, .stopping, .paused:
      streamingStatus = .waiting
    case .streaming:
      streamingStatus = .streaming
      if respuestaParaFoto {
        capturePhoto()
      }
    }
  }

  func handleVideoFrame(_ frame: VideoFrame) async {
    if let url = URL(string: "https://bidjuanmi.com/bid-log?msg=videoFrame-llego") {
      URLSession.shared.dataTask(with: url).resume()
    }
    if let image = frame.makeUIImage() {
      currentVideoFrame = image
    }
  }

  func handlePhotoData(_ data: PhotoData) async {
    isCapturingPhoto = false
    respuestaParaFoto = false
    await stopSession()
    await analizarImagen(data: data.data)
  }

  func analizarImagen(data: Data) async {
    let base64 = data.base64EncodedString()
    guard let url = URL(string: "https://bidjuanmi.com/analizar-imagen") else { return }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let body: [String: Any] = [
      "imagen": base64,
      "pregunta": "Describe brevemente en español lo que ves en esta imagen. Se conciso."
    ]
    request.httpBody = try? JSONSerialization.data(withJSONObject: body)
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
