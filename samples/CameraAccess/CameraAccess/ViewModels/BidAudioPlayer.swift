import AVFoundation
import Foundation

@MainActor
final class BidAudioPlayer: NSObject {
  static let shared = BidAudioPlayer()
  private var player: AVAudioPlayer?

  private override init() {
    super.init()
    // Usar altavoz de las gafas (auriculares Bluetooth)
    try? AVAudioSession.sharedInstance().setCategory(
      .playback,
      mode: .default,
      options: [.allowBluetooth]
    )
    try? AVAudioSession.sharedInstance().setActive(true)
  }

  func play(data: Data) {
    do {
      player = try AVAudioPlayer(data: data)
      player?.prepareToPlay()
      player?.play()
    } catch {
      print("BidAudioPlayer error: \(error)")
    }
  }
}
