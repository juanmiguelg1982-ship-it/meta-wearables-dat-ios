import AVFoundation
import AudioToolbox
import CoreBluetooth
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
  var enConversacion = false
  private var ultimoResultado: Date = Date()
  private var vigilanteTask: Task<Void, Never>?
  private var escuchandoOk = false
  var pausadoPorSistema = false

  static var instancia: BidEscuchaManager?
  static func pausarEngine() { instancia?.pausar() }
  static func reanudarEngine() { instancia?.reanudar() }

  private let palabrasActivacion = ["oye"]
  private let palabrasTerminar = ["ok"]

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
      DispatchQueue.main.async { self.iniciarEscuchaBID() }
    }
  }

  func arrancar() {
    try? AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP, .mixWithOthers])
    try? AVAudioSession.sharedInstance().setActive(true)
    NotificationCenter.default.addObserver(self, selector: #selector(manejarInterrupcionAudio), name: AVAudioSession.interruptionNotification, object: nil)
    SFSpeechRecognizer.requestAuthorization { [weak self] status in
      guard status == .authorized else { return }
      DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { self?.iniciarEscuchaBID() }
    }
  }

  func pausarPorSistema() {
    guard !pausadoPorSistema else { return }
    pausadoPorSistema = true
    pararEngine()
    try? AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothHFP, .mixWithOthers])
    try? AVAudioSession.sharedInstance().setActive(true)
    onEstado("⏸ Bid pausado")
}

  func reanudarPorSistema() {
    guard pausadoPorSistema else { return }
    pausadoPorSistema = false
    reanudar()
  }

  func pausar() {
    guard !escuchandoOk else { return }
    escuchandoOk = true
    pararEngine()

    recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
    guard let req = recognitionRequest else { return }
    req.shouldReportPartialResults = true

    recognitionTask = speechRecognizer?.recognitionTask(with: req) { [weak self] result, error in
      guard let self = self else { return }
      if let result = result {
        let texto = result.bestTranscription.formattedString.lowercased()
        if texto.contains("ok") {
          DispatchQueue.main.async {
            self.escuchandoOk = false
            BidAudioPlayer.shared.stop()
          }
        }
      }
      if error != nil {
        self.escuchandoOk = false
      }
    }
    arrancarEngine()
  }

  @objc private func manejarInterrupcionAudio(_ notification: Notification) {
    guard let info = notification.userInfo,
          let tipoValor = info[AVAudioSessionInterruptionTypeKey] as? UInt,
          let tipo = AVAudioSession.InterruptionType(rawValue: tipoValor) else { return }
    if tipo == .began {
      // Llamada entrante — pausar Bid para liberar el audio
      pararEngine()
    } else if tipo == .ended {
      // Llamada terminada — reanudar Bid
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
        try? AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP, .mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        if self.pausadoPorSistema { return }
        if self.enConversacion { self.iniciarEscuchaPregunta() }
        else { self.iniciarEscuchaBID() }
      }
    }
  }

  private func arrancarVigilante() {
    vigilanteTask?.cancel()
    ultimoResultado = Date()
    vigilanteTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        guard let self = self, !self.enConversacion, !self.grabandoRespuesta else { continue }
        if Date().timeIntervalSince(self.ultimoResultado) > 25 {
          await MainActor.run {
            self.speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "es-ES"))
            self.speechRecognizer?.delegate = self
            self.iniciarEscuchaBID()
          }
        }
      }
    }
  }

  private func iniciarEscuchaBID() {
    guard !pausadoPorSistema else { return }
    let msg = "engine:\(audioEngine.isRunning) conv:\(enConversacion) grab:\(grabandoRespuesta)"
    let msgEnc = msg.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? msg
    URLSession.shared.dataTask(with: URL(string: "https://bidjuanmi.com/bid-log?msg=\(msgEnc)")!).resume()

    enConversacion = false
    faseEscucha = false
    conversacionTimer?.invalidate()
    pararEngine()

    try? AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP, .mixWithOthers])
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
        guard !self.faseEscucha, !self.enConversacion else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
          guard !self.enConversacion, !self.grabandoRespuesta else { return }
          self.iniciarEscuchaBID()
        }
      }
    }

    arrancarEngine()
    onEstado("Escuchando... di OYE")
    arrancarVigilante()
  }
private func reproducirPitido() {
    let sampleRate = 44100.0
    let duracion = 0.12
    let frecuencia = 880.0
    let numSamples = Int(sampleRate * duracion)
    
    var samples = [Float](repeating: 0, count: numSamples)
    for i in 0..<numSamples {
        let t = Double(i) / sampleRate
        let envelope = min(Double(i) / 100.0, 1.0) * min(Double(numSamples - i) / 100.0, 1.0)
        samples[i] = Float(sin(2.0 * Double.pi * frecuencia * t) * envelope * 0.3)
    }
    
    let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(numSamples))!
    buffer.frameLength = AVAudioFrameCount(numSamples)
    memcpy(buffer.floatChannelData![0], samples, numSamples * 4)
    
    let data = NSMutableData()
    // Convertir a WAV y reproducir con BidAudioPlayer
    var wav = Data()
    let dataSize = UInt32(numSamples * 4)
    let sr = UInt32(sampleRate)
    wav.append("RIFF".data(using: .ascii)!)
    wav.append(withUnsafeBytes(of: (36 + dataSize).littleEndian) { Data($0) })
    wav.append("WAVE".data(using: .ascii)!)
    wav.append("fmt ".data(using: .ascii)!)
    wav.append(withUnsafeBytes(of: UInt32(16).littleEndian) { Data($0) })
    wav.append(withUnsafeBytes(of: UInt16(3).littleEndian) { Data($0) })
    wav.append(withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) })
    wav.append(withUnsafeBytes(of: sr.littleEndian) { Data($0) })
    wav.append(withUnsafeBytes(of: (sr * 4).littleEndian) { Data($0) })
    wav.append(withUnsafeBytes(of: UInt16(4).littleEndian) { Data($0) })
    wav.append(withUnsafeBytes(of: UInt16(32).littleEndian) { Data($0) })
    wav.append("data".data(using: .ascii)!)
    wav.append(withUnsafeBytes(of: dataSize.littleEndian) { Data($0) })
    wav.append(Data(bytes: samples, count: numSamples * 4))
    
    BidAudioPlayer.shared.play(data: wav)
}
  private func wakeWordDetectado() {
    guard !grabandoRespuesta else { return }
    faseEscucha = true
    enConversacion = true
    vigilanteTask?.cancel()
    AudioServicesPlaySystemSound(1057)
    pararEngine()
    iniciarEscuchaPregunta()
  }

  func reanudar() {
    guard !grabandoRespuesta, !pausadoPorSistema else { return }
    try? AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP, .mixWithOthers])
    try? AVAudioSession.sharedInstance().setActive(true)
    if enConversacion { iniciarEscuchaPregunta() }
    else { iniciarEscuchaBID() }
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
          self.envioTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            self?.pararYEnviar()
          }
        }
        if result.isFinal { DispatchQueue.main.async { self.pararYEnviar() } }
      }
      if error != nil && self.grabandoRespuesta {
        DispatchQueue.main.async { self.pararYEnviar() }
      }
    }
    arrancarEngine()
  }

  func pausarConversacionTimer() { conversacionTimer?.invalidate() }

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
    reproducirPitido()
    onEstado("Conversacion terminada")
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.iniciarEscuchaBID() }
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
        if self.enConversacion { self.iniciarEscuchaPregunta() }
        else { self.iniciarEscuchaBID() }
      }
      return
    }
    onEstado("Procesando...")
    Task { await onPregunta(transcripcion) }
  }

  private func pararEngine() {
    vigilanteTask?.cancel()
    envioTimer?.invalidate()
    recognitionTask?.cancel()
    recognitionTask = nil
    recognitionRequest?.endAudio()
    recognitionRequest = nil
    if audioEngine.isRunning { audioEngine.inputNode.removeTap(onBus: 0) }
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
        audioEngine.inputNode.removeTap(onBus: 0)
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
  @Published var bidActivadoManual: Bool = false
  @Published var pantallEncendida: Bool = true
  @Published var teslaBluetoothConectado: Bool = false

  private var registrationTask: Task<Void, Never>?
  private var deviceStreamTask: Task<Void, Never>?
  private var setupDeviceStreamTask: Task<Void, Never>?
  private let wearables: WearablesInterface
  private var compatibilityListenerTokens: [DeviceIdentifier: AnyListenerToken] = [:]
  private var bidEscucha: BidEscuchaManager?
  var streamVM: StreamSessionViewModel
  var ultimaLat: Double = 0
  var ultimaLon: Double = 0
  

  init(wearables: WearablesInterface) {
    self.wearables = wearables
    self.devices = wearables.devices
    self.registrationState = wearables.registrationState
    self.streamVM = StreamSessionViewModel(wearables: wearables)
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

    // Bluetooth para detectar Tesla
      }

  
  deinit {
    registrationTask?.cancel()
    deviceStreamTask?.cancel()
    setupDeviceStreamTask?.cancel()
  }

  var bidDebeEstarActivo: Bool {
    if teslaBluetoothConectado { return false }
    if !pantallEncendida { return true }
    return bidActivadoManual
  }

  func toggleBidManual() {
    bidActivadoManual.toggle()
    actualizarEstadoBid()
  }

  func actualizarEstadoBid() {
    if bidDebeEstarActivo {
      BidEscuchaManager.instancia?.reanudarPorSistema()
    } else {
      BidEscuchaManager.instancia?.pausarPorSistema()
    }
  }

  func pantallaEncendida() {
    pantallEncendida = true
    bidActivadoManual = false
    BidEscuchaManager.instancia?.pausadoPorSistema = false
    actualizarEstadoBid()
}

  func pantallaApagada() {
    pantallEncendida = false
    actualizarEstadoBid()
  }

  func arrancarEscucha() {
    var bgTaskPermanente: UIBackgroundTaskIdentifier = .invalid
    bgTaskPermanente = UIApplication.shared.beginBackgroundTask {
      UIApplication.shared.endBackgroundTask(bgTaskPermanente)
      bgTaskPermanente = UIApplication.shared.beginBackgroundTask { }
    }
    if streamVM == nil {
      streamVM = StreamSessionViewModel(wearables: wearables)
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
        self.bidStatus = "Tu: \(texto)"
        BidEscuchaManager.instancia?.pausarConversacionTimer()
      }
      let vm = self.streamVM ?? StreamSessionViewModel(wearables: self.wearables)
      await vm.enviarMensajeABid(mensaje: texto, lat: self.ultimaLat, lon: self.ultimaLon)
      if vm.respuestaParaFoto {
        await vm.handleStartStreaming()
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
          if let obs = observador { NotificationCenter.default.removeObserver(obs); observador = nil }
          continuation.resume()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 300.0) {
          guard !resumido else { return }
          resumido = true
          if let obs = observador { NotificationCenter.default.removeObserver(obs); observador = nil }
          continuation.resume()
        }
      }
      await MainActor.run {
        self.bidStatus = "Escuchando..."
        BidEscuchaManager.instancia?.reanudar()
      }
    }

    Task {
      while true {
        try? await Task.sleep(nanoseconds: 5_000_000_000)
        await comprobarVozPendiente()
      }
    }

    bidEscucha?.arrancar()

    Task {
      try? await Task.sleep(nanoseconds: 3_000_000_000)
      await comprobarVozPendiente()
    }

    // Observar pantalla encendida/apagada
    
    NotificationCenter.default.addObserver(
    forName: UIApplication.didBecomeActiveNotification,
    object: nil,
    queue: .main
) { [weak self] _ in
    Task { @MainActor in self?.pantallaEncendida() }
}
NotificationCenter.default.addObserver(
    forName: UIApplication.protectedDataWillBecomeUnavailableNotification,
    object: nil,
    queue: .main
) { [weak self] _ in
    Task { @MainActor in self?.pantallaApagada() }
}

    // Bluetooth
    configurarBluetooth()

    // Estado inicial — pantalla encendida al arrancar
    actualizarEstadoBid()
  }

  func comprobarVozPendiente() async {
    guard let url = URL(string: "https://bidjuanmi.com/bid-voz-pendiente") else { return }
    do {
      let (data, _) = try await URLSession.shared.data(from: url)
      guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let mensaje = json["mensaje"] as? String,
            !mensaje.isEmpty else { return }
      let vm = self.streamVM
      await vm.reproducirAudio(texto: mensaje)
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
          if let obs = observador { NotificationCenter.default.removeObserver(obs); observador = nil }
          continuation.resume()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30.0) {
          guard !resumido else { return }
          resumido = true
          if let obs = observador { NotificationCenter.default.removeObserver(obs); observador = nil }
          continuation.resume()
        }
      }
      await MainActor.run {
        BidEscuchaManager.instancia?.enConversacion = true
        BidEscuchaManager.instancia?.reanudar()
      }
    } catch {}
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
  func configurarBluetooth() {
    BluetoothMonitor.shared.onTeslaConectado = { [weak self] conectado in
      Task { @MainActor in
        self?.teslaBluetoothConectado = conectado
        self?.actualizarEstadoBid()
      }
    }
    BluetoothMonitor.shared.iniciar()
  }
   }
  class BluetoothMonitor: NSObject, CBCentralManagerDelegate {
  static let shared = BluetoothMonitor()
  var onTeslaConectado: ((Bool) -> Void)?
  private var central: CBCentralManager?
  private let teslaNames = ["Model 3", "Tesla", "MODEL 3"]

  func iniciar() {
    central = CBCentralManager(delegate: self, queue: nil)
  }

  func centralManagerDidUpdateState(_ central: CBCentralManager) {}

  func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    let nombre = peripheral.name ?? ""
    if teslaNames.contains(where: { nombre.contains($0) }) {
      onTeslaConectado?(true)
    }
  }

  func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
    let nombre = peripheral.name ?? ""
    if teslaNames.contains(where: { nombre.contains($0) }) {
      onTeslaConectado?(false)
    }
  }
}

