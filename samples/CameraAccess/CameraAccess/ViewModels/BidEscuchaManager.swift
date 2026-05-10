import AVFoundation
import Foundation
import Speech

final class BidEscuchaManager: NSObject {
  private let onEstado: (String) -> Void
  private let onPregunta: (String) async -> Void

  private var speechRecognizer: SFSpeechRecognizer?
  private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
  private var recognitionTask: SFSpeechRecognitionTask?
  private var audioEngine = AVAudioEngine()
  private var escuchandoWakeWord = true
  private var grabandoRespuesta = false
  private var silenceTimer: Timer?
  private var grabacionBuffer = Data()

  init(onEstado: @escaping (String) -> Void, onPregunta: @escaping (String) async -> Void) {
    self.onEstado = onEstado
    self.onPregunta = onPregunta
    super.init()
  }

  func arrancar() {
    SFSpeechRecognizer.requestAuthorization { [weak self] status in
      guard status == .authorized else { return }
      AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
        guard granted else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
          self?.iniciar()
        }
      }
    }
  }

  private func iniciar() {
    parar()

    speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "es-ES"))

    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetooth, .defaultToSpeaker, .mixWithOthers])
      try session.setActive(true, options: .notifyOthersOnDeactivation)

      if let btInput = session.availableInputs?.first(where: { $0.portType == .bluetoothHFP }) {
        try session.setPreferredInput(btInput)
      }
    } catch {
      onEstado("Error audio: \(error.localizedDescription)")
      return
    }

    recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
    guard let recognitionRequest = recognitionRequest else { return }
    recognitionRequest.shouldReportPartialResults = true

    let inputNode = audioEngine.inputNode
    let formato = inputNode.outputFormat(forBus: 0)

    guard formato.sampleRate > 0 else {
      onEstado("Error: formato audio inválido")
      return
    }

    recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) { [weak self] result, error in
      guard let self = self else { return }

      if let result = result {
        let texto = result.bestTranscription.formattedString.lowercased()
        if self.escuchandoWakeWord && (texto.hasSuffix("bid") || texto.contains("bid ") || texto == "bid") {
          DispatchQueue.main.async {
            self.wakeWordDetectado()
          }
        }
      }

      if error != nil && !self.grabandoRespuesta {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
          self.iniciar()
        }
      }
    }

    inputNode.installTap(onBus: 0, bufferSize: 1024, format: formato) { [weak self] buffer, _ in
      self?.recognitionRequest?.append(buffer)

      guard self?.grabandoRespuesta == true else { return }
      let channelData = buffer.floatChannelData?[0]
      let frameLength = Int(buffer.frameLength)
      if let channelData = channelData {
        var bytes = [UInt8](repeating: 0, count: frameLength * 4)
        for i in 0..<frameLength {
          withUnsafeBytes(of: channelData[i]) { ptr in
            bytes[i*4..<i*4+4] = ArraySlice(ptr)
          }
        }
        self?.grabacionBuffer.append(contentsOf: bytes)
      }
    }

    do {
      try audioEngine.start()
      escuchandoWakeWord = true
      onEstado("Escuchando... di BID")
    } catch {
      onEstado("Error iniciando audio: \(error.localizedDescription)")
      DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
        self.iniciar()
      }
    }
  }

  private func wakeWordDetectado() {
    guard !grabandoRespuesta else { return }
    grabandoRespuesta = true
    escuchandoWakeWord = false
    grabacionBuffer = Data()
    onEstado("🎤 Escuchando pregunta...")

    AudioServicesPlaySystemSound(1057)

    silenceTimer?.invalidate()
    silenceTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
      self?.pararYEnviar()
    }
  }

  private func pararYEnviar() {
    silenceTimer?.invalidate()
    grabandoRespuesta = false
    escuchandoWakeWord = true
    onEstado("Procesando...")

    let url = FileManager.default.temporaryDirectory.appendingPathComponent("bid_wake.wav")
    try? grabacionBuffer.write(to: url)

    Task {
      guard let transcripcion = await transcribirAudio(url: url),
            !transcripcion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
          self.iniciar()
        }
        return
      }
      await onPregunta(transcripcion)
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

  private func parar() {
    if audioEngine.isRunning {
      audioEngine.inputNode.removeTap(onBus: 0)
      audioEngine.stop()
    }
    recognitionRequest?.endAudio()
    recognitionRequest = nil
    recognitionTask?.cancel()
    recognitionTask = nil
  }
}
