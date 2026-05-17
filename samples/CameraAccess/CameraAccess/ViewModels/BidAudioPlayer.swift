final class BidAudioPlayer: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
    static let shared = BidAudioPlayer()
    private var player: AVAudioPlayer?
    private override init() {
        super.init()
    }
    func play(data: Data) {
        do {
            player = try AVAudioPlayer(data: data)
            player?.delegate = self
            player?.prepareToPlay()
            player?.play()
        } catch {
            print("BidAudioPlayer error: \(error)")
        }
    }
    func stop() {
        player?.stop()
        player = nil
        NotificationCenter.default.post(name: NSNotification.Name("BIDAudioTerminado"), object: nil)
    }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        NotificationCenter.default.post(name: NSNotification.Name("BIDAudioTerminado"), object: nil)
    }
}
