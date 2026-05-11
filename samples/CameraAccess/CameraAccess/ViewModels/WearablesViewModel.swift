import AVFoundation
import AudioToolbox
import MWDATCore
import Speech
import SwiftUI

final class BidEscuchaManager: NSObject, SFSpeechRecognizerDelegate {
  private let onEstado: (String) -> Void
  private let onPregunta: (String) async -> Void

  private var speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "es-ES"))
  private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
  private var recognitionTask: SFSpeechRecognitionTask?
  private var audioEngine = AVAudioEngine()
  private var grabandoRespuesta = false
  private var silenceTimer: Timer?
  private var grabacionURL: URL?
  private var audioRecorder: AVAudioRecorder?

  static var instancia: BidEscuchaManager?

  static func pausarEngine() {
    instancia?.pausar()
  }

  static func reanudarEngine() {
    instancia?.reanudar()
  }

  init(onEstado: @escaping (String) -> Void, onPregunta: @escaping (String) async -> Void) {
    self.onEstado = onEstado
    self.onPregunta = onPregunta
    super.init()
    speechRecognizer?.delegate = self
    BidEscuchaManager.instancia = self
  }

  func arrancar() {
    SFSpeechRecognizer.requestAuthorization { [weak self] status in
      guard status == .authorized else { return }
      DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
        self?.iniciarEscucha()
      }
    }
  }

  func pausar() {
    if audioEngine.isRunning {
      audioEngine.pause()
    }
  }

  func reanudar() {
    guard !grabandoRespuesta else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
      self.iniciarEscucha()
    }
  }

  private func iniciarEscucha() {
    recognitionTask?.cancel()
    recognitionTask = nil

    if audioEngine.isRunning {
      audioEngine.inputNode.removeTap(onBus: 0)
      audioEngine.stop()
    }

    try? AVAudioSession.sharedInstance().setCategory(
      .record,
      mode: .default,
      options: [.allowBluetooth]
    )
    try? AVAudioSession.sharedInstance().setActive(true)

    recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
    guard let recognitionRequest = recognitionRequest else { return }
    recognitionRequest.shouldReportPartialResults = true

    recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) { [weak self] result, error in
      guard let self = self else { return }
      if let result = result {
        let texto = result.bestTranscription.formattedString.lowercased()
        if !self.grabandoRespuesta && (
          texto.hasSuffix("bid") || texto.contains("bid ") || texto == "bid" ||
          texto.hasSuffix("david") || texto.contains("david") ||
          texto.hasSuffix("vid") || texto.hasSuffix("bit") ||
          texto.hasSuffix("beat") || texto.hasSuffix("pid") ||
          texto.contains("oye bid") || texto.contains("hey bid")
        ) {
          DispatchQueue.main.async { self.wakeWordDetectado() }
        }
      }
      if error != nil {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
          self.iniciarEscucha()
        }
      }
    }

    let inputNode = audioEngine.inputNode
    let formato = inputNode.outputFormat(forBus: 0)

    guard formato.sampleRate > 0 else {
      onEstado("Error formato audio")
      return
    }

    inputNode.installTap(onBus: 0, bufferSize: 1024, format: formato) { [weak self] buffer, _ in
      self?.recognitionRequest?.append(buffer)
    }

    do {
      try audioEngine.start()
      onEstado("Escuchando... di BID")
    } catch {
      onEstado("Error: \(error.localizedDescription)")
      DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
        self.iniciarEscucha()
      }
    }
  }

  private func wakeWordDetectado() {
  guard !grabandoRespuesta else { return }
  grabandoRespuesta = true

  // Cancelar reconocimiento para evitar detecciones repetidas
  recognitionTask?.cancel()
  recognitionTask = nil
  recognitionRequest?.endAudio()
  recognitionRequest = nil

  onEstado("🎤 Escuchando pregunta...")
  AudioServicesPlaySystemSound(1057)

  if audioEngine.isRunning {
    audioEngine.inputNode.removeTap(onBus: 0)
    audioEngine.stop()
  }

  let url = FileManager.default.temporaryDirectory.appendingPathComponent("bid_pregunta.m4a")
  grabacionURL = url

  let settings: [String: Any] = [
    AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
    AVSampleRateKey: 44100,
    AVNumberOfChannelsKey: 1,
    AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
  ]

  audioRecorder = try? AVAudioRecorder(url: url, settings: settings)
  audioRecorder?.record()

  silenceTimer?.invalidate()
  silenceTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
    self?.pararYEnviar()
  }
}

  private func pararYEnviar() {
    silenceTimer?.invalidate()
    audioRecorder?.stop()
    audioRecorder = nil
    grabandoRespuesta = false
    onEstado("Procesando...")

    guard let url = grabacionURL else { return }

    Task {
      guard let transcripcion = await transcribirAudio(url: url),
            !transcripcion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.iniciarEscucha() }
        return
      }
      await onPregunta(transcripcion)
      DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { self.iniciarEscucha() }
    }
  }

  private func transcribirAudio(url: URL) async -> String? {
    guard let audioData = try? Data(contentsOf: url) else { return nil }
    var request = URLRequest(url: URL(string: "https://bidjuanmi.com/whisper")!)
    request.httpMethod = "POST"
    let boundary = "Boundary-\(UUID().uuidString)"
    request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    var body = Data()
    body.append("--\(boundary)\r\n".data(using: .utf8)!)
    body.append("Content-Disposition: form-data; name=\"audio_file\"; filename=\"audio.m4a\"\r\n".data(using: .utf8)!)
    body.append("Content-Type: audio/m4a\r\n\r\n".data(using: .utf8)!)
    body.append(audioData)
    body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
    request.httpBody = body
    guard let (data, _) = try? await URLSession.shared.data(for: request),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let texto = json["text"] as? String else { return nil }
    return texto
  }
}

@MainActor
class WearablesViewModel: ObservableObject {
  @Published var devices: [DeviceIdentifier]
  @Published var registrationState: RegistrationState
  @Published var showGettingStartedSheet: Bool = false
  @Published var showError: Bool = false
  @Published var errorMessage: String = ""
  @Published var bidStatus: String = "Iniciando..."

  private var registrationTask: Task<Void, Never>?
  private var deviceStreamTask: Task<Void, Never>?
  private var setupDeviceStreamTask: Task<Void, Never>?
  private let wearables: WearablesInterface
  private var compatibilityListenerTokens: [DeviceIdentifier: AnyListenerToken] = [:]
  private var bidEscucha: BidEscuchaManager?

  init(wearables: WearablesInterface) {
    self.wearables = wearables
    self.devices = wearables.devices
    self.registrationState = wearables.registrationState

    setupDeviceStreamTask = Task { await setupDeviceStream() }

    registrationTask = Task {
      for await registrationState in wearables.registrationStateStream() {
        let previousState = self.registrationState
        self.registrationState = registrationState
        if self.showGettingStartedSheet == false && registrationState == .registered && previousState == .registering {
          self.showGettingStartedSheet = true
        }
      }
    }

    Task {
      bidStatus = "Conectando..."
      guard let url = URL(string: "https://bidjuanmi.com/chat-stream?message=AppArranc%C3%B3") else {
        bidStatus = "Error: URL invalida"
        return
      }
      do {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        bidStatus = "OK \(http?.statusCode ?? 0) - \(data.count) bytes"
      } catch {
        bidStatus = "Error: \(error.localizedDescription)"
      }
    }
  }

  deinit {
    registrationTask?.cancel()
    deviceStreamTask?.cancel()
    setupDeviceStreamTask?.cancel()
  }

  func arrancarEscucha() {
    guard bidEscucha == nil else { return }
    bidEscucha = BidEscuchaManager { [weak self] estado in
      Task { @MainActor in self?.bidStatus = estado }
    } onPregunta: { [weak self] (texto: String) in
      guard let self = self else { return }
      await MainActor.run { self.bidStatus = "Tú: \(texto)" }
      let vm = StreamSessionViewModel(wearables: self.wearables)
      await vm.enviarMensajeABid(mensaje: texto)
      await MainActor.run { self.bidStatus = "Escuchando... di BID" }
    }
    bidEscucha?.arrancar()
  }

  private func setupDeviceStream() async {
    if let task = deviceStreamTask, !task.isCancelled { task.cancel() }
    deviceStreamTask = Task {
      for await devices in wearables.devicesStream() {
        self.devices = devices
        monitorDeviceCompatibility(devices: devices)
      }
    }
  }

  private func monitorDeviceCompatibility(devices: [DeviceIdentifier]) {
    let deviceSet = Set(devices)
    compatibilityListenerTokens = compatibilityListenerTokens.filter { deviceSet.contains($0.key) }
    for deviceId in devices {
      guard compatibilityListenerTokens[deviceId] == nil else { continue }
      guard let device = wearables.deviceForIdentifier(deviceId) else { continue }
      let deviceName = device.nameOrId()
      let token = device.addCompatibilityListener { [weak self] compatibility in
        guard let self else { return }
        if compatibility == .deviceUpdateRequired {
          Task { @MainActor in self.showError("Device '\(deviceName)' requires an update to work with this app") }
        }
      }
      compatibilityListenerTokens[deviceId] = token
    }
  }

  func connectGlasses() {
    guard registrationState != .registering else { return }
    Task { @MainActor in
      do {
        try await wearables.startRegistration()
      } catch let error as RegistrationError {
        showError(error.description)
      } catch {
        showError(error.localizedDescription)
      }
    }
  }

  func disconnectGlasses() {
    Task { @MainActor in
      do {
        try await wearables.startUnregistration()
      } catch let error as UnregistrationError {
        showError(error.description)
      } catch {
        showError(error.localizedDescription)
      }
    }
  }

  func showError(_ error: String) {
    errorMessage = error
    showError = true
  }

  func dismissError() {
    showError = false
  }
}
