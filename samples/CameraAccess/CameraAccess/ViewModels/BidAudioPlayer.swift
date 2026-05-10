final class BidAudioPlayer: NSObject, @unchecked Sendable {
  static let shared = BidAudioPlayer()
  private var player: AVPlayer?

  private override init() {
    super.init()
  }

  func play(data: Data) {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("bid_response.mp3")
    try? data.write(to: url)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
      let item = AVPlayerItem(url: url)
      self.player = AVPlayer(playerItem: item)
      self.player?.volume = 1.0
      self.player?.play()
    }
  }
}
