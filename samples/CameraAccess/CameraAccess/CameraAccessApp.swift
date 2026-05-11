import AVFoundation
import Foundation
import MWDATCore
import SwiftUI
import UIKit

#if DEBUG
import MWDATMockDevice
#endif

@main
struct CameraAccessApp: App {
  #if DEBUG
  @StateObject private var debugMenuViewModel = DebugMenuViewModel(mockDeviceKit: MockDeviceKit.shared)
  #endif
  @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
  private let wearables: WearablesInterface
  @StateObject private var wearablesViewModel: WearablesViewModel
  private var silencioPlayer: AVAudioPlayer?

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
    setupBackgroundAudio()
  }

  private mutating func setupBackgroundAudio() {
    try? AVAudioSession.sharedInstance().setCategory(
      .playAndRecord,
      mode: .default,
      options: [.allowBluetooth, .mixWithOthers]
    )
    try? AVAudioSession.sharedInstance().setActive(true)
    reproducirSilencio()
  }

  private mutating func reproducirSilencio() {
    let sampleRate = 44100.0
    let numSamples = Int(sampleRate * 0.1)
    var silencio = [Float](repeating: 0.0, count: numSamples)
    let data = Data(bytes: &silencio, count: numSamples * 4)

    guard let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("silencio.wav") else { return }

    var wav = Data()
    let dataSize = UInt32(data.count)
    let sampleRateInt = UInt32(sampleRate)
    wav.append("RIFF".data(using: .ascii)!)
    wav.append(withUnsafeBytes(of: (36 + dataSize).littleEndian) { Data($0) })
    wav.append("WAVE".data(using: .ascii)!)
    wav.append("fmt ".data(using: .ascii)!)
    wav.append(withUnsafeBytes(of: UInt32(16).littleEndian) { Data($0) })
    wav.append(withUnsafeBytes(of: UInt16(3).littleEndian) { Data($0) })
    wav.append(withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) })
    wav.append(withUnsafeBytes(of: sampleRateInt.littleEndian) { Data($0) })
    wav.append(withUnsafeBytes(of: (sampleRateInt * 4).littleEndian) { Data($0) })
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
