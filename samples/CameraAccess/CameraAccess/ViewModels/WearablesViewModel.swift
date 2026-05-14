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
  private var envioTimer: Timer?
  private var conversacionTimer: Timer?
  private var ultimoTexto = ""
  private var textoAnterior = ""
  private var faseEscucha = false
  private var enConversacion = false
  private var ultimoResultado: Date = Date()
  private var vigilanteTask: Task<Void, Never>?

  static var instancia: BidEscuchaManager?
  static func pausarEngine() { instancia?.pausar() }
  static func reanudarEngine() { instancia?.reanudar() }

  private let palabrasActivacion = ["oye"]
  private let palabrasTerminar = ["ok", "listo", "hecho"]

  init(onEstado: @escaping (String) -> Void, onPregunta: @escaping (String) async -> Void) {
    self.onEstado = onEstado
    self.onPregunta = onPregunta
    super.init()
    speechRecognizer?.delegate = self
    BidEscuchaManager.instancia = self
  }

  func comprobarYReiniciarSiNecesario() {
    guard !enConversacion, !grabandoRespuesta else { return }
    let segundos = Date().timeIntervalSince(ultimoResultado)
    if segundos > 30 {
        DispatchQueue.main.async {
            self.iniciarEscuchaBID()
        }
    }
}
  func arrancar() {
    try? AVAudioSession.sharedInstance().setCategory(
      .playAndRecord,
      mode: .voiceChat,
      options: [.allowBluetoothHFP, .mixWithOthers]
    )
    try? AVAudioSession.sharedInstance().setActive(true)

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(manejarInterrupcionAudio),
      name: AVAudioSession.interruptionNotification,
      object: nil
    )

    SFSpeechRecognizer.requestAuthorization { [weak self] status in
      guard status == .authorized else { return }
      DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
        self?.iniciarEscuchaBID()
      }
    }
  }

  func pausar() {
    // No pausar el engine — mantenerlo activo para background
  }

  @objc private func manejarInterrupcionAudio(_ notification: Notification) {
    guard let info = notification.userInfo,
          let tipoValor = info[AVAudioSessionInterruptionTypeKey] as? UInt,
          let tipo = AVAudioSession.InterruptionType(rawValue: tipoValor) else { return }

    if tipo == .ended {
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
        if let appDelegate = UIApplication.shared.delegate as? AppDelegate {
          appDelegate.silencioPlayer?.play()
        }
        if self.enConversacion {
          self.iniciarEscuchaPregunta()
        } else {
          self.iniciarEscuchaBID()
        }
      }
    }
  }

  // MARK: - Vigilante de silencio

  private func arrancarVigilante() {
    vigilanteTask?.cancel()
    ultimoResultado = Date()
    vigilanteTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 5_000_000_000) // 5 segundos
        guard let self = self, !self.enConversacion, !self.grabandoRespuesta else { continue }
        let segundosSinResultado = Date().timeIntervalSince(self.ultimoResultado)
        if segundosSinResultado > 30 {
          await MainActor.run {
            self.iniciarEscuchaBID()
          }
        }
      }
    }
  }

  // MARK: - Fase 1: Esperar "oye"

  private func iniciarEscuchaBID() {
    enConversacion = false
    faseEscucha = false
    conversacionTimer?.invalidate()
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

    ultimoResultado = Date()

    recognitionTask = speechRecognizer?.recognitionTask(with: req) { [weak self] result, error in
      guard let self = self, !self.faseEscucha else { return }
      if let result = result {
        self.ultimoResultado = Date()
        let texto = result.bestTranscription.formattedString.lowercased()
        if self.palabrasActivacion.contains(where: { texto.contains($0) }) {
          DispatchQueue.main.async { self.wakeWordDetectado() }
        }
      }
      if error != nil {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.iniciarEscuchaBID() }
      }
    }

    arrancarEngine()
    onEstado("Escuchando... di OYE")
    arrancarVigilante()
  }

  // MARK: - Wake word detectado

  private func wakeWordDetectado() {
    guard !grabandoRespuesta else { return }
    faseEscucha = true
    enConversacion = true
    vigilanteTask?.cancel()
    AudioServicesPlaySystemSound(1057)
    pararEngine()
    iniciarEscuchaPregunta()
  }

  // MARK: - Fase 2: Escuchar pregunta (en conversación)

  func reanudar() {
    guard !grabandoRespuesta else { return }
    if let appDelegate = UIApplication.shared.delegate as? AppDelegate {
      appDelegate.silencioPlayer?.play()
    }
    try? AVAudioSession.sharedInstance().setCategory(
      .playAndRecord,
      mode: .voiceChat,
      options: [.allowBluetoothHFP, .mixWithOthers]
    )
    try? AVAudioSession.sharedInstance().setActive(true)
    if self.enConversacion {
      self.iniciarEscuchaPregunta()
    } else {
      self.iniciarEscuchaBID()
    }
  }

  private func iniciarEscuchaPregunta() {
    grabandoRespuesta = true
    ultimoTexto = ""
    textoAnterior = ""
    onEstado("🎤 ...")
    pararEngine()

    recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
    guard let req = recognitionRequest else { return }
    req.shouldReportPartialResults = true

    recognitionTask = speechRecognizer?.recognitionTask(with: req) { [weak self] result, error in
      guard let self = self else { return }
      if let result = result {
        let texto = result.bestTranscription.formattedString
        let textoLower = texto.lowercased()

        if self.palabrasTerminar.contains(where: { textoLower == $0 || textoLower.hasSuffix(" \($0)") }) {
          DispatchQueue.main.async { self.terminarConversacion() }
          return
        }

        self.ultimoTexto = texto
        DispatchQueue.main.async { self.onEstado("🎤 \(texto)") }

        if texto != self.textoAnterior {
          self.textoAnterior = texto
          self.envioTimer?.invalidate()
          self.envioTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak self] _ in
            self?.pararYEnviar()
          }
        }

        if result.isFinal {
          DispatchQueue.main.async { self.pararYEnviar() }
        }
      }
      if error != nil && self.grabandoRespuesta {
        DispatchQueue.main.async { self.pararYEnviar() }
      }
    }

    arrancarEngine()
  }

  func pausarConversacionTimer() {
    conversacionTimer?.invalidate()
  }

  func reiniciarTimerConversacion() {
    conversacionTimer?.invalidate()
    conversacionTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: false) { [weak self] _ in
      self?.terminarConversacion()
    }
  }

  private func terminarConversacion() {
    envioTimer?.invalidate()
    conversacionTimer?.invalidate()
    grabandoRespuesta = false
    faseEscucha = false
    pararEngine()
    AudioServicesPlaySystemSound(1057)
    onEstado("Conversación terminada")
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
      self.iniciarEscuchaBID()
    }
  }

  private func pararYEnviar() {
    guard grabandoRespuesta else { return }
    envioTimer?.invalidate()
    pararEngine()
    grabandoRespuesta = false

    let transcripcion = ultimoTexto.trimmingCharacters(in: .whitespacesAndNewlines)

    guard !transcripcion.isEmpty else {
      onEstado("No te he escuchado")
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
        if self.enConversacion {
          self.iniciarEscuchaPregunta()
        } else {
          self.iniciarEscuchaBID()
        }
      }
      return
    }

    onEstado("Procesando...")

    Task {
      await onPregunta(transcripcion)
    }
  }

  private func pararEngine() {
    vigilanteTask?.cancel()
    envioTimer?.invalidate()
    recognitionTask?.cancel()
    recognitionTask = nil
    recognitionRequest?.endAudio()
    recognitionRequest = nil
    if audioEngine.isRunning {
      audioEngine.inputNode.removeTap(onBus: 0)
    }
  }

  private func arrancarEngine() {
    let inputNode = audioEngine.inputNode
    let formato = inputNode.outputFormat(forBus: 0)
    guard formato.sampleRate > 0 else { return }

    inputNode.installTap(onBus: 0, bufferSize: 1024, format: formato) { [weak self] buffer, _ in
      self?.recognitionRequest?.append(buffer)
    }

    if !audioEngine.isRunning {
      do {
        try audioEngine.start()
      } catch {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { self.iniciarEscuchaBID() }
      }
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
    var bgTaskPermanente: UIBackgroundTaskIdentifier = .invalid
    bgTaskPermanente = UIApplication.shared.beginBackgroundTask {
      UIApplication.shared.endBackgroundTask(bgTaskPermanente)
      bgTaskPermanente = UIApplication.shared.beginBackgroundTask { }
    }
    guard bidEscucha == nil else { return }
    bidEscucha = BidEscuchaManager { [weak self] estado in
      Task { @MainActor in self?.bidStatus = estado }
    } onPregunta: { [weak self] (texto: String) in
      guard let self = self else { return }
      var bgTask: UIBackgroundTaskIdentifier = .invalid
      bgTask = UIApplication.shared.beginBackgroundTask {
        UIApplication.shared.endBackgroundTask(bgTask)
      }
      await MainActor.run {
        self.bidStatus = "Tú: \(texto)"
        BidEscuchaManager.instancia?.pausarConversacionTimer()
      }
    let vm = StreamSessionViewModel(wearables: self.wearables)
    await vm.enviarMensajeABid(mensaje: texto)
    // Si la respuesta fue [FOTO], activar captura
    if vm.respuestaParaFoto {
    await vm.handleStartStreaming()
    try? await Task.sleep(nanoseconds: 3_000_000_000)
    vm.capturePhoto()
    try? await Task.sleep(nanoseconds: 2_000_000_000)
    await vm.stopSession()
}

      await withCheckedContinuation { continuation in
        var observador: NSObjectProtocol?
        var resumido = false
        observador = NotificationCenter.default.addObserver(
          forName: NSNotification.Name("BIDAudioTerminado"),
          object: nil,
          queue: .main
        ) { _ in
          guard !resumido else { return }
          resumido = true
          if let obs = observador {
            NotificationCenter.default.removeObserver(obs)
            observador = nil
          }
          continuation.resume()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30.0) {
          guard !resumido else { return }
          resumido = true
          if let obs = observador {
            NotificationCenter.default.removeObserver(obs)
            observador = nil
          }
          continuation.resume()
        }
      }

      await MainActor.run {
        self.bidStatus = "Escuchando..."
        BidEscuchaManager.instancia?.reiniciarTimerConversacion()
        BidEscuchaManager.instancia?.reanudar()
      }
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
