final class BidAudioPlayer: NSObject, @unchecked Sendable {
  static let shared = BidAudioPlayer()
  private var player: AVAudioPlayer?

  private override init() {
    super.init()
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
