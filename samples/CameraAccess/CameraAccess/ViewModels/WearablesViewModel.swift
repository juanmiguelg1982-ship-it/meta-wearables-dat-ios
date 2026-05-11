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
  private var ultimoTexto = ""
  private var faseEscucha = false

  static var instancia: BidEscuchaManager?
  static func pausarEngine() { instancia?.pausar() }
  static func reanudarEngine() { instancia?.reanudar() }

  init(onEstado: @escaping (String) -> Void, onPregunta: @escaping (String) async -> Void) {
    self.onEstado = onEstado
    self.onPregunta = onPregunta
    super.init()
    speechRecognizer?.delegate = self
    BidEscuchaManager.instancia = self
  }

  func arrancar() {
    try? AVAudioSession.sharedInstance().setCategory(
      .playAndRecord,
      mode: .voiceChat,
      options: [.allowBluetoothHFP, .mixWithOthers]
    )
    try? AVAudioSession.sharedInstance().setActive(true)

    SFSpeechRecognizer.requestAuthorization { [weak self] status in
      guard status == .authorized else { return }
      DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
        self?.iniciarEscuchaBID()
      }
    }
  }

  func pausar() {
    if audioEngine.isRunning { audioEngine.pause() }
  }

  func reanudar() {
    guard !grabandoRespuesta else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
      self.iniciarEscuchaBID()
    }
  }

  private func iniciarEscuchaBID() {
    faseEscucha = false
    pararEngine()

    try? AVAudioSession.sharedInstance().setCategory(
      .playAndRecord,
      mode: .voiceChat,
      options: [.allowBluetoothHFP, .mixWithOthers]
    )
    try? AVAudioSession.sharedInstance().setActive(true)

    recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
    guard let req = recognitionRequest else { return }
    req.shouldReportPartialResults = true

    recognitionTask = speechRecognizer?.recognitionTask(with: req) { [weak self] result, error in
      guard let self = self, !self.faseEscucha else { return }
      if let result = result {
        let texto = result.bestTranscription.formattedString.lowercased()
        if texto.contains("bid") || texto.contains("david") ||
           texto.hasSuffix("vid") || texto.hasSuffix("bit") ||
           texto.contains("oye bid") || texto.contains("hey bid") {
          DispatchQueue.main.async { self.wakeWordDetectado() }
        }
      }
      if error != nil {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.iniciarEscuchaBID() }
      }
    }

    arrancarEngine()
    onEstado("Escuchando... di BID")
  }

  private func wakeWordDetectado() {
    guard !grabandoRespuesta else { return }
    faseEscucha = true
    grabandoRespuesta = true
    ultimoTexto = ""

    onEstado("🎤 ...")
    AudioServicesPlaySystemSound(1057)
    pararEngine()

    recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
    guard let req = recognitionRequest else { return }
    req.shouldReportPartialResults = true

    recognitionTask = speechRecognizer?.recognitionTask(with: req) { [weak self] result, error in
      guard let self = self else { return }
      if let result = result {
        let texto = result.bestTranscription.formattedString
        self.ultimoTexto = texto
        DispatchQueue.main.async { self.onEstado("🎤 \(texto)") }
        if result.isFinal {
          DispatchQueue.main.async { self.pararYEnviar() }
        }
      }
      if error != nil && self.grabandoRespuesta {
        DispatchQueue.main.async { self.pararYEnviar() }
      }
    }

    arrancarEngine()

    silenceTimer?.invalidate()
    silenceTimer = Timer.scheduledTimer(withTimeInterval: 8.0, repeats: false) { [weak self] _ in
      self?.pararYEnviar()
    }
  }

  private func pararYEnviar() {
    guard grabandoRespuesta else { return }
    silenceTimer?.invalidate()
    pararEngine()
    grabandoRespuesta = false
    faseEscucha = false

    let transcripcion = ultimoTexto.trimmingCharacters(in: .whitespacesAndNewlines)

    guard !transcripcion.isEmpty else {
      onEstado("No te he escuchado")
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.iniciarEscuchaBID() }
      return
    }

    onEstado("Procesando...")

    Task {
      await onPregunta(transcripcion)
      DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { self.iniciarEscuchaBID() }
    }
  }

  private func pararEngine() {
    recognitionTask?.cancel()
    recognitionTask = nil
    recognitionRequest?.endAudio()
    recognitionRequest = nil
    if audioEngine.isRunning {
      audioEngine.inputNode.removeTap(onBus: 0)
      audioEngine.stop()
    }
  }

  private func arrancarEngine() {
    let inputNode = audioEngine.inputNode
    let formato = inputNode.outputFormat(forBus: 0)
    guard formato.sampleRate > 0 else { return }

    inputNode.installTap(onBus: 0, bufferSize: 1024, format: formato) { [weak self] buffer, _ in
      self?.recognitionRequest?.append(buffer)
    }

    do {
      try audioEngine.start()
    } catch {
      DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { self.iniciarEscuchaBID() }
    }
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

      var bgTask: UIBackgroundTaskIdentifier = .invalid
      bgTask = UIApplication.shared.beginBackgroundTask {
        UIApplication.shared.endBackgroundTask(bgTask)
      }

      await MainActor.run { self.bidStatus = "Tú: \(texto)" }
      let vm = StreamSessionViewModel(wearables: self.wearables)
      await vm.enviarMensajeABid(mensaje: texto)
      await MainActor.run { self.bidStatus = "Escuchando... di BID" }

      UIApplication.shared.endBackgroundTask(bgTask)
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
