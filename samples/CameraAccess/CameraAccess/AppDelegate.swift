import AVFoundation
import UIKit
class AppDelegate: NSObject, UIApplicationDelegate {
  func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
    configurarAudioBackground()
    return true
  }
  func applicationDidEnterBackground(_ application: UIApplication) {
    try? AVAudioSession.sharedInstance().setCategory(
      .playAndRecord,
      mode: .voiceChat,
      options: [.allowBluetoothHFP, .mixWithOthers]
    )
    try? AVAudioSession.sharedInstance().setActive(true)
  }
  func applicationWillResignActive(_ application: UIApplication) {
    try? AVAudioSession.sharedInstance().setCategory(
      .playAndRecord,
      mode: .voiceChat,
      options: [.allowBluetoothHFP, .mixWithOthers]
    )
    try? AVAudioSession.sharedInstance().setActive(true)
  }
  func applicationWillEnterForeground(_ application: UIApplication) {
  }
  private func configurarAudioBackground() {
    try? AVAudioSession.sharedInstance().setCategory(
      .playAndRecord,
      mode: .voiceChat,
      options: [.allowBluetoothHFP, .mixWithOthers]
    )
    try? AVAudioSession.sharedInstance().setActive(true)
  }
}
