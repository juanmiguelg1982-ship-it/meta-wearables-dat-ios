import AVFoundation
import PushKit
import UIKit

class AppDelegate: NSObject, UIApplicationDelegate, PKPushRegistryDelegate {
    var silencioPlayer: AVAudioPlayer?
    private var voipRegistry: PKPushRegistry?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        configurarAudioBackground()
        iniciarSilencioLoop()
        configurarVoIPPush()
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        try? AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP, .mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        silencioPlayer?.play()
    }

    func applicationWillResignActive(_ application: UIApplication) {
        try? AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP, .mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    func applicationWillEnterForeground(_ application: UIApplication) {}

    private func configurarAudioBackground() {
        try? AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP, .mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    func iniciarSilencioLoop() {
        let sampleRate: UInt32 = 44100
        let numSamples = Int(sampleRate)
        let samples = [Int16](repeating: 0, count: numSamples)
        var wav = Data()
        let dataSize = UInt32(numSamples * 2)
        wav.append("RIFF".data(using: .ascii)!)
        wav.append(withUnsafeBytes(of: (36 + dataSize).littleEndian) { Data($0) })
        wav.append("WAVE".data(using: .ascii)!)
        wav.append("fmt ".data(using: .ascii)!)
        wav.append(withUnsafeBytes(of: UInt32(16).littleEndian) { Data($0) })
        wav.append(withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) })
        wav.append(withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) })
        wav.append(withUnsafeBytes(of: sampleRate.littleEndian) { Data($0) })
        wav.append(withUnsafeBytes(of: (sampleRate * 2).littleEndian) { Data($0) })
        wav.append(withUnsafeBytes(of: UInt16(2).littleEndian) { Data($0) })
        wav.append(withUnsafeBytes(of: UInt16(16).littleEndian) { Data($0) })
        wav.append("data".data(using: .ascii)!)
        wav.append(withUnsafeBytes(of: dataSize.littleEndian) { Data($0) })
        wav.append(Data(bytes: samples, count: numSamples * 2))
        do {
            silencioPlayer = try AVAudioPlayer(data: wav)
            silencioPlayer?.numberOfLoops = -1
            silencioPlayer?.volume = 0.0
            silencioPlayer?.prepareToPlay()
            silencioPlayer?.play()
        } catch {}
    }

    private func configurarVoIPPush() {
        voipRegistry = PKPushRegistry(queue: DispatchQueue.main)
        voipRegistry?.delegate = self
        voipRegistry?.desiredPushTypes = [.voIP]
    }

    func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {}

    func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType, completion: @escaping () -> Void) {
        completion()
    }

    func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        configurarVoIPPush()
    }
}
