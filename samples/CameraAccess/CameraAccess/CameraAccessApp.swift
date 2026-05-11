import AVFoundation
import Foundation
import MWDATCore
import SwiftUI
import UIKit

#if DEBUG
import MWDATMockDevice
#endif

class AppDelegate: NSObject, UIApplicationDelegate {
  var silencioPlayer: AVAudioPlayer?

  func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
    configurarAudioBackground()
    return true
  }

  func applicationDidEnterBackground(_ application: UIApplication) {
    silencioPlayer?.play()
  }

  func applicationWillEnterForeground(_ application: UIApplication) {
    silencioPlayer?.play()
  }

  private func configurarAudioBackground() {
    try? AVAudioSession.sharedInstance().setCategory(
      .playAndRecord,
      mode: .default,
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
          DebgeMenuView(debugMenuViewModel: debugMenuViewModel)
        }
        #endif
      RegistrationView(viewModel: wearablesViewModel)
    }
  }
}
