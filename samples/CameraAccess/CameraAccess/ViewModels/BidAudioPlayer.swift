final class BidAudioPlayer: NSObject, @unchecked Sendable {
  static let shared = BidAudioPlayer()
  private var player: AVPlayer?

  private override init() {
    super.init()
  }

  func play(data: Data) {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent("bid_response.mp3")
  try? data.write(to: url)
  
  // Forzar salida por Bluetooth
  try? AVAudioSession.sharedInstance().setCategory(
    .playback,
    mode: .default,
    options: [.allowBluetoothHFP]
  )
  try? AVAudioSession.sharedInstance().setActive(true)
  
  // Esperar a que Bluetooth esté listo
  DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
    let item = AVPlayerItem(url: url)
    self.player = AVPlayer(playerItem: item)
    self.player?.volume = 1.0
    self.player?.play()
  }
}
}
