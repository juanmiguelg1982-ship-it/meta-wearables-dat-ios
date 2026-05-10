import AVFoundation
import MWDATCore
import Speech
import SwiftUI

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

  // Wake word
  private var speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "es-ES"))
  private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
  private var recognitionTask: SFSpeechRecognitionTask?
  private var audioEngine = AVAudioEngine()
  private var escuchandoWakeWord = true
  private var grabandoRespuesta = false
  private var silenceTimer: Timer?
  private var grabacionBuffer = Data()
  private var streamSessionVM: StreamSessionViewModel?

  init(wearables: WearablesInterface) {
    self.wearables = wearables
    self.devices = wearables.devices
    self.registrationState = wearables.registrationState

    setupDeviceStreamTask = Task {
      await setupDeviceStream()
    }

    registrationTask = Task {
      for await registrationState in wearables.registrationStateStream() {
        let previousState = self.registrationState
        self.registrationState = registrationState
        if self.showGettingStartedSheet == false && registrationState == .registered && previousState == .registering {
          self.showGettingStartedSheet = true
        }
        // Arrancar escucha cuando se conectan las gafas
        if registrationState == .registered {
          self.arrancarEscucha()
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

    // Pedir permisos al arrancar
    SFSpeechRecognizer.requestAuthorization { _ in }
    AVAudioSession.sharedInstance().requestRecordPermission { _ in }
  }

  // MARK: - Wake Word "BID"

  func setStreamSessionVM(_ vm: StreamSessionViewModel) {
    self.streamSessionVM = vm
  }

  func arrancarEscucha() {
    guard !audioEngine.isRunning else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
      self.iniciarReconocimientoWakeWord()
    }
  }

  private func iniciarReconocimientoWakeWord() {
    pararReconocimiento()

    let session = AVAudioSession.sharedInstance()
    try? session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetooth, .defaultToSpeaker, .mixWithOthers])
    try? session.setActive(true)

    // Preferir micrófono de las gafas si están conectadas por Bluetooth
    if let btInput = session.availableInputs?.first(where: {
      $0.portType == .bluetoothHFP
    }) {
      try? session.setPreferredInput(btInput)
    }

    recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
    guard let recognitionRequest = recognitionRequest else { return }
    recognitionRequest.shouldReportPartialResults = true

    let inputNode = audioEngine.inputNode
    let formato = inputNode.outputFormat(forBus: 0)

    recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) { [weak self] result, error in
      guard let self = self else { return }

      if let result = result {
        let texto = result.bestTranscription.formattedString.lowercased()

        // Detectar palabra clave "bid"
        if self.escuchandoWakeWord && (texto.hasSuffix("bid") || texto.contains("bid ") || texto == "bid") {
          Task { @MainActor in
            self.wakeWordDetectado()
          }
        }
      }

      if error != nil {
        // Reiniciar si hay error
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
          self.iniciarReconocimientoWakeWord()
        }
      }
    }

    inputNode.installTap(onBus: 0, bufferSize: 1024, format: formato) { [weak self] buffer, _ in
      self?.recognitionRequest?.append(buffer)

      // Si estamos grabando respuesta, guardar también el audio
      if self?.grabandoRespuesta == true {
        let channelData = buffer.floatChannelData?[0]
        let frameLength = Int(buffer.frameLength)
        if let channelData = channelData {
          var bytes = [UInt8](repeating: 0, count: frameLength * 4)
          for i in 0..<frameLength {
            let sample = channelData[i]
            withUnsafeBytes(of: sample) { ptr in
              bytes[i*4..<i*4+4] = ArraySlice(ptr)
            }
          }
          self?.grabacionBuffer.append(contentsOf: bytes)
        }
      }
    }

    try? audioEngine.start()
    escuchandoWakeWord = true
    bidStatus = "Escuchando... di BID"
  }

  private func wakeWordDetectado() {
    guard !grabandoRespuesta else { return }
    grabandoRespuesta = true
    escuchandoWakeWord = false
    grabacionBuffer = Data()
    bidStatus = "🎤 Escuchando..."

    // Reproducir sonido de confirmación
    AudioServicesPlaySystemSound(1057)

    // Parar grabación automáticamente tras 5 segundos de silencio
    silenceTimer?.invalidate()
    silenceTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
      Task { @MainActor in
        await self?.pararYEnviarRespuesta()
      }
    }
  }

  private func pararYEnviarRespuesta() async {
    silenceTimer?.invalidate()
    grabandoRespuesta = false
    escuchandoWakeWord = true
    bidStatus = "Procesando..."

    // Guardar audio en fichero temporal
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("bid_wake.wav")
    try? grabacionBuffer.write(to: url)

    // Enviar a Whisper
    guard let transcripcion = await transcribirAudio(url: url),
          !transcripcion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      bidStatus = "No te he escuchado"
      DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
        self.bidStatus = "Escuchando... di BID"
        self.iniciarReconocimientoWakeWord()
      }
      return
    }

    bidStatus = "Tú: \(transcripcion)"

    // Enviar a Bid y reproducir respuesta
    if let vm = streamSessionVM {
      await vm.enviarMensajeABid(mensaje: transcripcion)
    } else {
      // Crear uno temporal si no hay StreamSessionVM
      let tempVM = StreamSessionViewModel(wearables: wearables)
      await tempVM.enviarMensajeABid(mensaje: transcripcion)
    }

    bidStatus = "Escuchando... di BID"
    iniciarReconocimientoWakeWord()
  }

  private func transcribirAudio(url: URL) async -> String? {
    guard let audioData = try? Data(contentsOf: url) else { return nil }

    var request = URLRequest(url: URL(string: "https://bidjuanmi.com/whisper")!)
    request.httpMethod = "POST"
    let boundary = "Boundary-\(UUID().uuidString)"
    request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

    var body = Data()
    body.append("--\(boundary)\r\n".data(using: .utf8)!)
    body.append("Content-Disposition: form-data; name=\"audio_file\"; filename=\"audio.wav\"\r\n".data(using: .utf8)!)
    body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
    body.append(audioData)
    body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
    request.httpBody = body

    guard let (data, _) = try? await URLSession.shared.data(for: request),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let texto = json["text"] as? String else { return nil }

    return texto
  }

  private func pararReconocimiento() {
    audioEngine.inputNode.removeTap(onBus: 0)
    audioEngine.stop()
    recognitionRequest?.endAudio()
    recognitionRequest = nil
    recognitionTask?.cancel()
    recognitionTask = nil
  }

  // MARK: - Device stream

  deinit {
    registrationTask?.cancel()
    deviceStreamTask?.cancel()
    setupDeviceStreamTask?.cancel()
  }

  private func setupDeviceStream() async {
    if let task = deviceStreamTask, !task.isCancelled {
      task.cancel()
    }
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
          Task { @MainActor in
            self.showError("Device '\(deviceName)' requires an update to work with this app")
          }
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
