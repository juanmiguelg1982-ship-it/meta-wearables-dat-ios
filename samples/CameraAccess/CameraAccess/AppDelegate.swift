import AVFoundation
import PushKit
import UIKit

class AppDelegate: NSObject, UIApplicationDelegate, PKPushRegistryDelegate {
    var silencioPlayer: AVAudioPlayer?
    private var bgTaskRenovable: UIBackgroundTaskIdentifier = .invalid
    private var voipRegistry: PKPushRegistry?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        configurarAudioBackground()
        iniciarSilencioLoop()
        configurarVoIPPush()
        return true
    }

   func applicationDidEnterBackground(_ application: UIApplication) {
    activarSesionAudio()
    silencioPlayer?.play()
    renovarBackgroundTask()
}

    func applicationWillResignActive(_ application: UIApplication) {
        activarSesionAudio()
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        activarSesionAudio()
        terminarBackgroundTask()
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        activarSesionAudio()
    }

    private func configurarAudioBackground() {
        activarSesionAudio()
    }

    func activarSesionAudio() {
        try? AVAudioSession.sharedInstance().setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.allowBluetoothHFP, .mixWithOthers]
        )
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
            NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
    if self?.silencioPlayer?.isPlaying == false {
        try? AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP, .mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        self?.silencioPlayer?.play()
    }
}
        } catch {}

        Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            if self?.silencioPlayer?.isPlaying == false {
                self?.silencioPlayer?.play()
            }
            try? AVAudioSession.sharedInstance().setActive(true)
            // Reiniciar Bid si el engine se ha muerto
            DispatchQueue.main.async {
                if WearablesViewModel.instancia?.bidDebeEstarActivo == true &&
                   BidEscuchaManager.instancia?.pausadoPorSistema == false &&
                   BidEscuchaManager.instancia?.engineActivo == false {
                    BidEscuchaManager.instancia?.iniciarEscuchaBID()
                }
            }
        }
    }

    // MARK: - VoIP Push — mantiene la app viva en background indefinidamente

    private func configurarVoIPPush() {
        voipRegistry = PKPushRegistry(queue: DispatchQueue.main)
        voipRegistry?.delegate = self
        voipRegistry?.desiredPushTypes = [.voIP]
    }

    func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        // Token VoIP registrado — no necesitamos mandarlo a ningún servidor
        // Solo necesitamos el registro para que iOS mantenga la app viva
    }

    func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType, completion: @escaping () -> Void) {
        // Cuando llega un push VoIP, reiniciamos Bid si es necesario
        DispatchQueue.main.async {
            if WearablesViewModel.instancia?.bidDebeEstarActivo == true {
                BidEscuchaManager.instancia?.iniciarEscuchaBID()
            }
        }
        completion()
    }

    func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        // Token invalidado — reconectar
        configurarVoIPPush()
    }

    // MARK: - Background Task

    private func renovarBackgroundTask() {
        terminarBackgroundTask()
        bgTaskRenovable = UIApplication.shared.beginBackgroundTask(withName: "BidBackground") { [weak self] in
            self?.terminarBackgroundTask()
            self?.renovarBackgroundTask()
        }
    }

    private func terminarBackgroundTask() {
        guard bgTaskRenovable != .invalid else { return }
        UIApplication.shared.endBackgroundTask(bgTaskRenovable)
        bgTaskRenovable = .invalid
    }
}
