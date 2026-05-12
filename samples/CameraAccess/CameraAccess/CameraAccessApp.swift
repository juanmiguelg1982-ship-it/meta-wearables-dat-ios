import AVFoundation
import Foundation
import MWDATCore
import PushKit
import SwiftUI
import UIKit

#if DEBUG
import MWDATMockDevice
#endif

class AppDelegate: NSObject, UIApplicationDelegate, PKPushRegistryDelegate {
  var silencioPlayer: AVAudioPlayer?
  var voipRegistry: PKPushRegistry?
  var voipToken: String?

  func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
    configurarAudio()
    registrarVoIP()
    return true
  }

  func registrarVoIP() {
    voipRegistry = PKPushRegistry(queue: .main)
    voipRegistry?.delegate = self
    voipRegistry?.desiredPushTypes = [.voIP]
  }

  // MARK: - PKPushRegistryDelegate

  func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
    let token = pushCredentials.token.map { String(format: "%02x", $0) }.joined()
    voipToken = token
    print("[BID VoIP] Token: \(token)")
    // Enviar token al servidor
    guard let url = URL(string: "https://bidjuanmi.com/voip-token") else { return }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try? JSONSerialization.data(withJSONObject: ["token": token])
    URLSession.shared.dataTask(with: request).resume()
  }

  func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType, completion: @escaping () -> Void) {
    // iOS despierta la app — arrancar escucha
    DispatchQueue.main.async {
      BidEscuchaManager.instancia?.reanudar()
    }
    completion()
  }

  func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
    voipToken = nil
  }

  func applicationDidEnterBackground(_ application: UIApplication) {
    var bgTask: UIBackgroundTaskIdentifier = .invalid
    bgTask = UIApplication.shared.beginBackgroundTask {
      UIApplication.shared.endBackgroundTask(bgTask)
    }
    try? AVAudioSession.sharedInstance().setCategory(
      .playAndRecord,
      mode: .voiceChat,
      options: [.allowBluetoothHFP, .mixWithOthers]
    )
    try? AVAudioSession.sharedInstance().setActive(true)
    silencioPlayer?.play()
  }

  func applicationWillResignActive(_ application: UIApplication) {
    try? AVAudioSession.sharedInstance().setCategory(
      .playAndRecord,
      mode: .voiceChat,
      options: [.allowBluetoothHFP, .mixWithOthers]
    )
    try? AVAudioSession.sharedInstance().setActive(true)
    silencioPlayer?.play()
  }

  func applicationWillEnterForeground(_ application: UIApplication) {
    silencioPlayer?.play()
  }

  private func configurarAudio() {
    try? AVAudioSession.sharedInstance().setCategory(
      .playAndRecord,
      mode: .voiceChat,
      options: [.allowBluetoothHFP, .mixWithOthers]
    )
    try? AVAudioSession.sharedInstance().setActive(true)

    let sampleRate = 44100.0
    let numSamples = Int(sampleRate * 0.5)
    var silencio = [Float](repeating: 0.0, count: numSamples)
    let data = Data(bytes: &silencio, count: numSamples * 4)
    guard let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("silencio.wav") else { return }

    var wav = Data()
    let dataSize = UInt32(data.count)
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
    wav.append(data)
    try? wav.write(to: url)

    if let player = try? AVAudioPlayer(contentsOf: url) {
      player.numberOfLoops = -1
      player.volume = 0.0
      player.play()
      silencioPlayer = player
    }
  }
}

@main
struct CameraAccessApp: App {
  @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

  #if DEBUG
  @StateObject private var debugMenuViewModel = DebugMenuViewModel(mockDeviceKit: MockDeviceKit.shared)
  #endif
  private let wearables: WearablesInterface
  @StateObject private var wearablesViewModel: WearablesViewModel

  init() {
    do {
      try Wearables.configure()
    } catch {
      #if DEBUG
      NSLog("[BID] Error: \(error)")
      #endif
    }
    let wearables = Wearables.shared
    self.wearables = wearables
    self._wearablesViewModel = StateObject(wrappedValue: WearablesViewModel(wearables: wearables))
  }

  var body: some Scene {
    WindowGroup {
      MainAppView(wearables: Wearables.shared, viewModel: wearablesViewModel)
        .alert("Error", isPresented: $wearablesViewModel.showError) {
          Button("OK") { wearablesViewModel.dismissError() }
        } message: {
          Text(wearablesViewModel.errorMessage)
        }
        #if DEBUG
        .sheet(isPresented: $debugMenuViewModel.showDebugMenu) {
          MockDeviceKitView(viewModel: debugMenuViewModel.mockDeviceKitViewModel)
        }
        .overlay {
          DebugMenuView(debugMenuViewModel: debugMenuViewModel)
        }
        #endif
      RegistrationView(viewModel: wearablesViewModel)
    }
  }
}
