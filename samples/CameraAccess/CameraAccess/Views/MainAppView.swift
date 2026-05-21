import AVFoundation
import CoreLocation
import MWDATCore
import SwiftUI
import WebKit
import UniformTypeIdentifiers

// MARK: - Geolocalización

class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    @Published var lat: Double = 0
    @Published var lon: Double = 0

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 200
        manager.requestAlwaysAuthorization()
        manager.startUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = true
        manager.pausesLocationUpdatesAutomatically = false
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        lat = loc.coordinate.latitude
        lon = loc.coordinate.longitude
        guard let url = URL(string: "https://bidjuanmi.com/ubicacion?lat=\(lat)&lon=\(lon)") else { return }
        URLSession.shared.dataTask(with: url).resume()
    }
}

// MARK: - Web View

struct BidWebKitView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.preferences.javaScriptEnabled = true
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        if webView.url?.absoluteString != url.absoluteString {
            webView.load(URLRequest(url: url))
        }
    }
}

// MARK: - Chat View

struct Mensaje: Identifiable {
    let id = UUID()
    let role: String
    let content: String
}

class ChatViewModel: ObservableObject {
    @Published var mensajes: [Mensaje] = []
    @Published var cargando = false
    @Published var textoEscrito = ""
    var locationManager: LocationManager?
    var borradoManualmente = false
    var cargadoUnaVez = false

    func cargarHistorial() {
        guard !borradoManualmente, !cargadoUnaVez else { return }
        cargadoUnaVez = true
        cargando = true
        guard let url = URL(string: "https://bidjuanmi.com/historial") else { return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            DispatchQueue.main.async {
                self.cargando = false
                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let msgs = json["mensajes"] as? [[String: Any]] else { return }
                self.mensajes = msgs.compactMap { m in
                    guard let role = m["role"] as? String,
                          var content = m["content"] as? String else { return nil }
                    if let range = content.range(of: "\\[SISTEMA:.*?\\]", options: .regularExpression) {
                        content.removeSubrange(range)
                    }
                    content = content.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !content.isEmpty else { return nil }
                    return Mensaje(role: role, content: content)
                }
            }
        }.resume()
    }

    func borrarHistorial() {
        borradoManualmente = true
        guard let url = URL(string: "https://bidjuanmi.com/historial") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        URLSession.shared.dataTask(with: request) { _, _, _ in
            DispatchQueue.main.async { self.mensajes = [] }
        }.resume()
    }

    func enviarMensaje() {
        let texto = textoEscrito.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !texto.isEmpty else { return }
        textoEscrito = ""
        mensajes.append(Mensaje(role: "user", content: texto))
        let lat = locationManager?.lat ?? 0
        let lon = locationManager?.lon ?? 0
        guard let encoded = texto.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://bidjuanmi.com/chat-stream?message=\(encoded)&lat=\(lat)&lon=\(lon)") else { return }
        var respuestaCompleta = ""
        URLSession.shared.dataTask(with: url) { data, _, _ in
            if let data = data, let texto = String(data: data, encoding: .utf8) {
                for linea in texto.components(separatedBy: "\n") {
                    if linea.hasPrefix("data: ") {
                        let json = String(linea.dropFirst(6))
                        if let data = json.data(using: .utf8),
                           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let fragment = obj["text"] as? String {
                            respuestaCompleta += fragment
                        }
                    }
                }
                DispatchQueue.main.async {
                    if !respuestaCompleta.isEmpty {
                        self.mensajes.append(Mensaje(role: "assistant", content: respuestaCompleta))
                    }
                }
            }
        }.resume()
    }
}

struct ChatView: View {
    @StateObject private var vm = ChatViewModel()
    @EnvironmentObject var locationManager: LocationManager
    @FocusState private var tecladoActivo: Bool

    var body: some View {
        ZStack {
            Color(red: 0.01, green: 0.03, blue: 0.06).ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Text("CHAT")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(Color(red: 0, green: 0.71, blue: 0.85))
                        .tracking(3)
                    Spacer()
                    Button { vm.borrarHistorial() } label: {
                        Image(systemName: "trash")
                            .foregroundColor(Color(red: 0, green: 0.71, blue: 0.85).opacity(0.6))
                    }
                    .padding(.trailing, 8)
                    Button {
                        vm.cargadoUnaVez = false
                        vm.borradoManualmente = false
                        vm.cargarHistorial()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .foregroundColor(Color(red: 0, green: 0.71, blue: 0.85).opacity(0.6))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color(red: 0.01, green: 0.05, blue: 0.1))

                if vm.cargando {
                    Spacer()
                    ProgressView().tint(Color(red: 0, green: 0.71, blue: 0.85))
                    Spacer()
                } else if vm.mensajes.isEmpty {
                    Spacer()
                    Text("Sin conversaciones")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(Color(red: 0, green: 0.71, blue: 0.85).opacity(0.3))
                    Spacer()
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 12) {
                                ForEach(vm.mensajes) { msg in
                                    HStack(alignment: .top, spacing: 8) {
                                        if msg.role == "assistant" {
                                            Text("BID")
                                                .font(.system(size: 9, design: .monospaced))
                                                .foregroundColor(Color(red: 0, green: 0.71, blue: 0.85))
                                                .padding(.top, 3)
                                                .frame(width: 28)
                                            Text(msg.content)
                                                .font(.system(size: 14))
                                                .foregroundColor(.white)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        } else {
                                            Spacer()
                                            Text(msg.content)
                                                .font(.system(size: 14))
                                                .foregroundColor(Color(red: 0, green: 0.71, blue: 0.85))
                                                .multilineTextAlignment(.trailing)
                                        }
                                    }
                                    .padding(.horizontal, 16)
                                    .id(msg.id)
                                }
                            }
                            .padding(.vertical, 12)
                        }
                        .onChange(of: vm.mensajes.count) { _ in
                            if let last = vm.mensajes.last {
                                withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                            }
                        }
                    }
                }

                HStack(spacing: 10) {
                    TextField("Escribe a Bid...", text: $vm.textoEscrito)
                        .font(.system(size: 14))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Color(red: 0.05, green: 0.1, blue: 0.18))
                        .cornerRadius(20)
                        .focused($tecladoActivo)
                        .onSubmit { vm.enviarMensaje() }
                    Button {
                        vm.enviarMensaje()
                        tecladoActivo = false
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 30))
                            .foregroundColor(Color(red: 0, green: 0.71, blue: 0.85))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color(red: 0.01, green: 0.05, blue: 0.1))
            }
        }
        .onAppear {
            vm.locationManager = locationManager
            vm.cargarHistorial()
        }
    }
}

// MARK: - Pantalla BID

struct BidStatusView: View {
    @ObservedObject var viewModel: WearablesViewModel
    @EnvironmentObject var locationManager: LocationManager
    let cyan = Color(red: 0, green: 0.71, blue: 0.85)
    let fondo = Color(red: 0.01, green: 0.03, blue: 0.06)

    var body: some View {
        ZStack {
            fondo.ignoresSafeArea()
            VStack(spacing: 0) {
                Spacer()
                VStack(spacing: 16) {
                    ZStack {
                        Circle()
                            .stroke(cyan.opacity(0.2), lineWidth: 1)
                            .frame(width: 120, height: 120)
                        Circle()
                            .stroke(cyan.opacity(0.1), lineWidth: 1)
                            .frame(width: 90, height: 90)
                        Text("BID")
                            .font(.system(size: 36, weight: .thin, design: .monospaced))
                            .foregroundColor(cyan)
                            .tracking(8)
                    }
                    Text("ASISTENTE PERSONAL")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(cyan.opacity(0.4))
                        .tracking(4)
                }
                Spacer()
                Text(viewModel.bidStatus)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.yellow)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.5))
                    .cornerRadius(6)
                    .padding(.bottom, 20)

                // Botón activar/pausar Bid
                Button {
                    viewModel.toggleBidManual()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: viewModel.bidDebeEstarActivo ? "mic.fill" : "mic.slash.fill")
                        Text(viewModel.bidDebeEstarActivo ? "BID ACTIVO" : "ACTIVAR BID")
                            .font(.system(size: 13, design: .monospaced))
                            .tracking(2)
                    }
                    .foregroundColor(viewModel.bidDebeEstarActivo ? fondo : cyan)
                    .padding(.vertical, 14)
                    .padding(.horizontal, 32)
                    .background(viewModel.bidDebeEstarActivo ? cyan : cyan.opacity(0.15))
                    .cornerRadius(10)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(cyan.opacity(0.4), lineWidth: 1))
                }
                .padding(.bottom, 40)
            }
        }
    }
}

// MARK: - Gafas View

struct GafasView: View {
    @ObservedObject var viewModel: WearablesViewModel
    @ObservedObject var streamVM: StreamSessionViewModel
    let cyan = Color(red: 0, green: 0.71, blue: 0.85)
    let fondo = Color(red: 0.01, green: 0.03, blue: 0.06)

    var body: some View {
        ZStack {
            fondo.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Text("GAFAS")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(cyan)
                        .tracking(3)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color(red: 0.01, green: 0.05, blue: 0.1))

                ScrollView {
                    VStack(spacing: 20) {

                        HStack {
                            Circle()
                                .fill(viewModel.registrationState == .registered ? cyan : Color.red)
                                .frame(width: 10, height: 10)
                            Text(viewModel.registrationState == .registered ? "GAFAS CONECTADAS" : "GAFAS NO CONECTADAS")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(viewModel.registrationState == .registered ? cyan : Color.red)
                                .tracking(2)
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 20)

                        if viewModel.registrationState != .registered {
                            Button {
                                viewModel.connectGlasses()
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "eyeglasses")
                                    Text(viewModel.registrationState == .registering ? "CONECTANDO..." : "CONECTAR GAFAS")
                                        .font(.system(size: 13, design: .monospaced))
                                        .tracking(2)
                                }
                                .foregroundColor(fondo)
                                .padding(.vertical, 14)
                                .padding(.horizontal, 28)
                                .background(cyan)
                                .cornerRadius(10)
                            }
                            .disabled(viewModel.registrationState == .registering)
                        } else {
                            Button {
                                viewModel.disconnectGlasses()
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "eyeglasses")
                                    Text("DESCONECTAR GAFAS")
                                        .font(.system(size: 13, design: .monospaced))
                                        .tracking(2)
                                }
                                .foregroundColor(Color.red)
                                .padding(.vertical, 14)
                                .padding(.horizontal, 28)
                                .background(Color.red.opacity(0.15))
                                .cornerRadius(10)
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.red.opacity(0.4), lineWidth: 1))
                            }
                        }

                        Rectangle()
                            .fill(cyan.opacity(0.1))
                            .frame(height: 1)
                            .padding(.horizontal, 16)

                        VStack(spacing: 12) {
                            Text("CAMARA GAFAS")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(cyan.opacity(0.5))
                                .tracking(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16)

                            ZStack {
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(cyan.opacity(0.3), lineWidth: 1)
                                    .frame(height: 220)
                                    .background(Color(red: 0.02, green: 0.06, blue: 0.12).cornerRadius(12))

                                if let frame = streamVM.currentVideoFrame {
                                    Image(uiImage: frame)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(height: 220)
                                        .clipShape(RoundedRectangle(cornerRadius: 12))
                                } else {
                                    VStack(spacing: 8) {
                                        Image(systemName: "video.slash")
                                            .font(.system(size: 36))
                                            .foregroundColor(cyan.opacity(0.3))
                                        Text(streamVM.streamingStatus == .waiting ? "Conectando..." : "Stream inactivo")
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundColor(cyan.opacity(0.3))
                                    }
                                }
                            }
                            .padding(.horizontal, 16)

                            HStack(spacing: 12) {
    if streamVM.streamingStatus != .stopped {
        Button {
            Task { await streamVM.stopSession() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "stop.fill")
                Text("PARAR")
                    .font(.system(size: 13, design: .monospaced))
            }
            .foregroundColor(Color.red)
            .padding(.vertical, 12)
            .padding(.horizontal, 24)
            .background(Color.red.opacity(0.15))
            .cornerRadius(10)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.red.opacity(0.4), lineWidth: 1))
        }
        Button {
            streamVM.capturePhoto()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "camera.fill")
                Text("FOTO")
                    .font(.system(size: 13, design: .monospaced))
            }
            .foregroundColor(fondo)
            .padding(.vertical, 12)
            .padding(.horizontal, 24)
            .background(cyan)
            .cornerRadius(10)
        }
        .disabled(streamVM.isCapturingPhoto)
    } else {
        Button {
            Task { await streamVM.handleStartStreaming() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "video.fill")
                Text("VER DESDE GAFAS")
                    .font(.system(size: 13, design: .monospaced))
            }
            .foregroundColor(fondo)
            .padding(.vertical, 12)
            .padding(.horizontal, 24)
            .background(viewModel.registrationState == .registered ? cyan : cyan.opacity(0.3))
            .cornerRadius(10)
        }
        .disabled(viewModel.registrationState != .registered)
    }
} 
                            }
                        }

                        Spacer(minLength: 40)
                    }
                    .padding(.top, 8)
                }
            }
        }
    }


// MARK: - Foto Análisis

class FotoAnalisisViewModel: ObservableObject {
    @Published var fotoSeleccionada: UIImage? = nil
    @Published var pregunta: String = ""
    @Published var respuesta: String = ""
    @Published var cargando: Bool = false
    @Published var mostrarCamara: Bool = false
    var locationManager: LocationManager?
    func subirFotoBid() async {
    guard let imagen = fotoSeleccionada,
          let jpegData = imagen.jpegData(compressionQuality: 0.7) else { return }
    let base64 = jpegData.base64EncodedString()
    await MainActor.run { cargando = true }
    guard let url = URL(string: "https://bidjuanmi.com/analizar-imagen") else { return }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let preguntaFinal = pregunta.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? "Juanmi te acaba de subir una foto. Confirmale brevemente que la tienes y preguntale que quiere saber sobre ella."
        : pregunta
    let body: [String: Any] = [
        "imagen": base64,
        "pregunta": preguntaFinal,
        "lat": locationManager?.lat ?? 0,
        "lon": locationManager?.lon ?? 0
    ]
    request.httpBody = try? JSONSerialization.data(withJSONObject: body)
    do {
        let (data, _) = try await URLSession.shared.data(for: request)
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let desc = json["descripcion"] as? String {
            await MainActor.run { cargando = false }
            guard var ttsComponents = URLComponents(string: "https://bidjuanmi.com/tts") else { return }
            ttsComponents.queryItems = [URLQueryItem(name: "text", value: desc)]
            if let audioUrl = ttsComponents.url {
                let (audioData, _) = try await URLSession.shared.data(from: audioUrl)
                BidAudioPlayer.shared.play(data: audioData)
                await withCheckedContinuation { continuation in
                    var observador: NSObjectProtocol?
                    var resumido = false
                    observador = NotificationCenter.default.addObserver(
                        forName: NSNotification.Name("BIDAudioTerminado"),
                        object: nil,
                        queue: .main
                    ) { _ in
                        guard !resumido else { return }
                        resumido = true
                        if let obs = observador { NotificationCenter.default.removeObserver(obs); observador = nil }
                        continuation.resume()
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 30.0) {
                        guard !resumido else { return }
                        resumido = true
                        if let obs = observador { NotificationCenter.default.removeObserver(obs); observador = nil }
                        continuation.resume()
                    }
                }
                await MainActor.run {
                    BidEscuchaManager.instancia?.enConversacion = true
                    BidEscuchaManager.instancia?.reanudar()
                }
            }
        }
    } catch {
        await MainActor.run { cargando = false }
    }
}
    func analizarFoto() async {
        guard let imagen = fotoSeleccionada,
              let jpegData = imagen.jpegData(compressionQuality: 0.7) else { return }
        let base64 = jpegData.base64EncodedString()
        let preguntaFinal = pregunta.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "¿Qué ves en esta imagen?"
            : pregunta
        await MainActor.run { cargando = true; respuesta = "" }
        guard let url = URL(string: "https://bidjuanmi.com/analizar-imagen") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "imagen": base64,
            "pregunta": preguntaFinal,
            "lat": locationManager?.lat ?? 0,
            "lon": locationManager?.lon ?? 0
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let desc = json["descripcion"] as? String {
                await MainActor.run {
                    self.respuesta = desc
                    self.cargando = false
                }
                await reproducirAudio(texto: desc)
            }
        } catch {
            await MainActor.run { cargando = false }
        }
    }

    func reproducirAudio(texto: String) async {
        guard var components = URLComponents(string: "https://bidjuanmi.com/tts") else { return }
        components.queryItems = [URLQueryItem(name: "text", value: texto)]
        guard let url = components.url else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            await MainActor.run {
                try? AVAudioSession.sharedInstance().setCategory(
                    .playAndRecord,
                    mode: .voiceChat,
                    options: [.allowBluetoothHFP, .mixWithOthers]
                )
                try? AVAudioSession.sharedInstance().setActive(true)
            }
            BidAudioPlayer.shared.play(data: data)
        } catch {}
    }
}

struct CamaraView: UIViewControllerRepresentable {
    @Binding var imagen: UIImage?
    @Environment(\.dismiss) var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CamaraView
        init(_ parent: CamaraView) { self.parent = parent }
        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            parent.imagen = info[.originalImage] as? UIImage
            parent.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

struct FotoAnalisisView: View {
    @StateObject private var vm = FotoAnalisisViewModel()
    @EnvironmentObject var locationManager: LocationManager
    @FocusState private var tecladoActivo: Bool
    @State private var mostrarGaleria = false
    let cyan = Color(red: 0, green: 0.71, blue: 0.85)
    let fondo = Color(red: 0.01, green: 0.03, blue: 0.06)

    var body: some View {
        ZStack {
            fondo.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Text("FOTO")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(cyan)
                        .tracking(3)
                    Spacer()
                    Button {
                        tecladoActivo = false
                        mostrarGaleria = true
                    } label: {
                        Image(systemName: "photo.on.rectangle")
                            .foregroundColor(cyan.opacity(0.7))
                            .font(.system(size: 18))
                    }
                    .padding(.trailing, 12)
                    Button {
                        tecladoActivo = false
                        vm.fotoSeleccionada = nil
                        vm.pregunta = ""
                        vm.respuesta = ""
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .foregroundColor(cyan.opacity(0.7))
                            .font(.system(size: 18))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color(red: 0.01, green: 0.05, blue: 0.1))

                ScrollView {
                    VStack(spacing: 20) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(cyan.opacity(0.3), lineWidth: 1)
                                .frame(height: 260)
                                .background(Color(red: 0.02, green: 0.06, blue: 0.12).cornerRadius(12))
                            if let img = vm.fotoSeleccionada {
                                Image(uiImage: img)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(height: 260)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                            } else {
                                VStack(spacing: 12) {
                                    Image(systemName: "camera")
                                        .font(.system(size: 40))
                                        .foregroundColor(cyan.opacity(0.4))
                                    Text("Toca para hacer una foto")
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundColor(cyan.opacity(0.4))
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .onTapGesture {
                            tecladoActivo = false
                            vm.mostrarCamara = true
                        }

                        HStack(spacing: 12) {
                            Button {
                                tecladoActivo = false
                                vm.mostrarCamara = true
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: vm.fotoSeleccionada == nil ? "camera.fill" : "camera.badge.ellipsis")
                                    Text(vm.fotoSeleccionada == nil ? "Hacer foto" : "Nueva foto")
                                        .font(.system(size: 14, design: .monospaced))
                                }
                                .foregroundColor(fondo)
                                .padding(.vertical, 12)
                                .padding(.horizontal, 20)
                                .background(cyan)
                                .cornerRadius(10)
                            }
                            Button {
                                tecladoActivo = false
                                mostrarGaleria = true
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "photo.on.rectangle")
                                    Text("Galeria")
                                        .font(.system(size: 14, design: .monospaced))
                                }
                                .foregroundColor(cyan)
                                .padding(.vertical, 12)
                                .padding(.horizontal, 20)
                                .background(cyan.opacity(0.15))
                                .cornerRadius(10)
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(cyan.opacity(0.4), lineWidth: 1))
                            }
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("QUE QUIERES SABER?")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(cyan.opacity(0.5))
                                .tracking(2)
                            TextField("Ej: Que marca es esto? Que pone aqui?", text: $vm.pregunta, axis: .vertical)
                                .font(.system(size: 14))
                                .foregroundColor(.white)
                                .padding(12)
                                .background(Color(red: 0.05, green: 0.1, blue: 0.18))
                                .cornerRadius(10)
                                .focused($tecladoActivo)
                                .lineLimit(3)
                        }
                        .padding(.horizontal, 16)
                        
                        Button {
    tecladoActivo = false
    Task { await vm.subirFotoBid() }
} label: {
    HStack(spacing: 10) {
        if vm.cargando {
            ProgressView().tint(fondo)
        } else {
            Image(systemName: "arrow.up.circle")
        }
        Text("SUBIR A BID")
            .font(.system(size: 14, design: .monospaced))
    }
    .foregroundColor(cyan)
    .padding(.vertical, 12)
    .padding(.horizontal, 32)
    .background(vm.fotoSeleccionada == nil ? cyan.opacity(0.1) : cyan.opacity(0.15))
    .cornerRadius(10)
    .overlay(RoundedRectangle(cornerRadius: 10).stroke(vm.fotoSeleccionada == nil ? cyan.opacity(0.1) : cyan.opacity(0.4), lineWidth: 1))
}
.disabled(vm.fotoSeleccionada == nil || vm.cargando)

                        if !vm.respuesta.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("BID")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(cyan)
                                        .tracking(3)
                                    Spacer()
                                }
                                Text(vm.respuesta)
                                    .font(.system(size: 14))
                                    .foregroundColor(.white)
                                    .padding(12)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color(red: 0.02, green: 0.08, blue: 0.15))
                                    .cornerRadius(10)
                                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(cyan.opacity(0.2), lineWidth: 1))
                            }
                            .padding(.horizontal, 16)
                        }
                        Spacer(minLength: 40)
                    }
                    .padding(.top, 20)
                }
            }
        }
        .sheet(isPresented: $vm.mostrarCamara) {
            CamaraView(imagen: $vm.fotoSeleccionada)
        }
        .sheet(isPresented: $mostrarGaleria) {
            GaleriaView(imagen: $vm.fotoSeleccionada)
        }
        .onAppear {
            vm.locationManager = locationManager
        }
    }
}

struct GaleriaView: UIViewControllerRepresentable {
    @Binding var imagen: UIImage?
    @Environment(\.dismiss) var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: GaleriaView
        init(_ parent: GaleriaView) { self.parent = parent }
        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            parent.imagen = info[.originalImage] as? UIImage
            parent.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
// MARK: - Documentos View

class DocumentosViewModel: ObservableObject {
    @Published var archivoSeleccionado: URL? = nil
    @Published var nombreArchivo: String = ""
    @Published var pregunta: String = ""
    @Published var cargando: Bool = false
    @Published var mostrarPicker: Bool = false
    var locationManager: LocationManager?

    func subirDocumento() async {
    guard let url = archivoSeleccionado else { return }
    await MainActor.run { cargando = true }
    do {
        _ = url.startAccessingSecurityScopedResource()
        let data = try Data(contentsOf: url)
        url.stopAccessingSecurityScopedResource()
        let boundary = UUID().uuidString
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"archivo\"; filename=\"\(nombreArchivo)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n".data(using: .utf8)!)
        let preguntaFinal = pregunta.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Juanmi te acaba de subir un documento. Confirmale brevemente que lo tienes y preguntale que quiere saber sobre el."
            : pregunta
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"pregunta\"\r\n\r\n".data(using: .utf8)!)
        body.append(preguntaFinal.data(using: .utf8)!)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        guard let requestUrl = URL(string: "https://bidjuanmi.com/analizar-documento") else { return }
        var request = URLRequest(url: requestUrl)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer bid-app-token-juanmi", forHTTPHeaderField: "Authorization")
        request.httpBody = body
        let (responseData, _) = try await URLSession.shared.data(for: request)
        if let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] {
            // Error de formato
            if let error = json["error"] as? String {
                await MainActor.run { cargando = false }
                guard var ttsComponents = URLComponents(string: "https://bidjuanmi.com/tts") else { return }
                ttsComponents.queryItems = [URLQueryItem(name: "text", value: "No puedo leer ese archivo. \(error)")]
                if let audioUrl = ttsComponents.url {
                    let (audioData, _) = try await URLSession.shared.data(from: audioUrl)
                    BidAudioPlayer.shared.play(data: audioData)
                }
                return
            }
            // Flujo normal
            if let preguntaRespuesta = json["pregunta"] as? String {
                await MainActor.run { cargando = false }
                guard let ttsUrl = URL(string: "https://bidjuanmi.com/chat-stream?message=\(preguntaRespuesta.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")") else { return }
                let (ttsData, _) = try await URLSession.shared.data(from: ttsUrl)
                var respuestaCompleta = ""
                if let texto = String(data: ttsData, encoding: .utf8) {
                    for linea in texto.components(separatedBy: "\n") {
                        if linea.hasPrefix("data: "),
                           let d = linea.dropFirst(6).data(using: .utf8),
                           let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                           let fragment = obj["text"] as? String {
                            respuestaCompleta += fragment
                        }
                    }
                }
                if !respuestaCompleta.isEmpty {
                    guard var ttsComponents = URLComponents(string: "https://bidjuanmi.com/tts") else { return }
                    ttsComponents.queryItems = [URLQueryItem(name: "text", value: respuestaCompleta)]
                    if let audioUrl = ttsComponents.url {
                        let (audioData, _) = try await URLSession.shared.data(from: audioUrl)
                        BidAudioPlayer.shared.play(data: audioData)
                        await withCheckedContinuation { continuation in
                            var observador: NSObjectProtocol?
                            var resumido = false
                            observador = NotificationCenter.default.addObserver(
                                forName: NSNotification.Name("BIDAudioTerminado"),
                                object: nil,
                                queue: .main
                            ) { _ in
                                guard !resumido else { return }
                                resumido = true
                                if let obs = observador { NotificationCenter.default.removeObserver(obs); observador = nil }
                                continuation.resume()
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 30.0) {
                                guard !resumido else { return }
                                resumido = true
                                if let obs = observador { NotificationCenter.default.removeObserver(obs); observador = nil }
                                continuation.resume()
                            }
                        }
                        await MainActor.run {
                            BidEscuchaManager.instancia?.enConversacion = true
                            BidEscuchaManager.instancia?.reanudar()
                        }
                    }
                }
            }
        }
    } catch {
        await MainActor.run { cargando = false }
    }
}
}

struct DocumentPickerView: UIViewControllerRepresentable {
    @Binding var url: URL?
    @Binding var nombre: String
    @Environment(\.dismiss) var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [
            .pdf, .text,
            UTType(filenameExtension: "doc")!,
            UTType(filenameExtension: "docx")!,
            UTType(filenameExtension: "xls")!,
            UTType(filenameExtension: "xlsx")!
        ])
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: DocumentPickerView
        init(_ parent: DocumentPickerView) { self.parent = parent }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            parent.url = url
            parent.nombre = url.lastPathComponent
            parent.dismiss()
        }
    }
}

struct DocumentosView: View {
    @StateObject private var vm = DocumentosViewModel()
    @EnvironmentObject var locationManager: LocationManager
    @FocusState private var tecladoActivo: Bool
    let cyan = Color(red: 0, green: 0.71, blue: 0.85)
    let fondo = Color(red: 0.01, green: 0.03, blue: 0.06)

    var body: some View {
        ZStack {
            fondo.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Text("DOCUMENTOS")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(cyan)
                        .tracking(3)
                    Spacer()
                    Button {
                        vm.archivoSeleccionado = nil
                        vm.nombreArchivo = ""
                        vm.pregunta = ""
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .foregroundColor(cyan.opacity(0.7))
                            .font(.system(size: 18))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color(red: 0.01, green: 0.05, blue: 0.1))

                ScrollView {
                    VStack(spacing: 20) {
                        Button {
                            tecladoActivo = false
                            vm.mostrarPicker = true
                        } label: {
                            ZStack {
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(cyan.opacity(0.3), lineWidth: 1)
                                    .frame(height: 160)
                                    .background(Color(red: 0.02, green: 0.06, blue: 0.12).cornerRadius(12))
                                VStack(spacing: 12) {
                                    Image(systemName: vm.archivoSeleccionado == nil ? "doc.badge.plus" : "doc.fill")
                                        .font(.system(size: 44))
                                        .foregroundColor(vm.archivoSeleccionado == nil ? cyan.opacity(0.4) : cyan)
                                    if vm.nombreArchivo.isEmpty {
                                        Text("Toca para seleccionar archivo")
                                            .font(.system(size: 12, design: .monospaced))
                                            .foregroundColor(cyan.opacity(0.4))
                                        Text("PDF · Word · Excel · TXT")
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundColor(cyan.opacity(0.25))
                                    } else {
                                        Text(vm.nombreArchivo)
                                            .font(.system(size: 13, design: .monospaced))
                                            .foregroundColor(cyan)
                                            .multilineTextAlignment(.center)
                                            .padding(.horizontal, 16)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 16)

                        VStack(alignment: .leading, spacing: 8) {
                            Text("QUE QUIERES SABER? (OPCIONAL)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(cyan.opacity(0.5))
                                .tracking(2)
                            TextField("Ej: Resumeme esto, traduce al inglés...", text: $vm.pregunta, axis: .vertical)
                                .font(.system(size: 14))
                                .foregroundColor(.white)
                                .padding(12)
                                .background(Color(red: 0.05, green: 0.1, blue: 0.18))
                                .cornerRadius(10)
                                .focused($tecladoActivo)
                                .lineLimit(3)
                        }
                        .padding(.horizontal, 16)

                        Button {
                            tecladoActivo = false
                            Task { await vm.subirDocumento() }
                        } label: {
                            HStack(spacing: 10) {
                                if vm.cargando {
                                    ProgressView().tint(fondo)
                                } else {
                                    Image(systemName: "arrow.up.circle.fill")
                                }
                                Text(vm.cargando ? "Subiendo..." : "SUBIR A BID")
                                    .font(.system(size: 14, design: .monospaced))
                            }
                            .foregroundColor(fondo)
                            .padding(.vertical, 14)
                            .padding(.horizontal, 32)
                            .background(vm.archivoSeleccionado == nil ? cyan.opacity(0.3) : cyan)
                            .cornerRadius(10)
                        }
                        .disabled(vm.archivoSeleccionado == nil || vm.cargando)

                        Spacer(minLength: 40)
                    }
                    .padding(.top, 20)
                }
            }
        }
        .sheet(isPresented: $vm.mostrarPicker) {
            DocumentPickerView(url: $vm.archivoSeleccionado, nombre: $vm.nombreArchivo)
        }
        .onAppear {
            vm.locationManager = locationManager
        }
    }
}
// MARK: - Pantalla View

struct PantallaItem: Identifiable {
    let id = UUID()
    let titulo: String
    let contenido: String
    let ts: Double
}

class PantallaViewModel: ObservableObject {
    @Published var items: [PantallaItem] = []
    @Published var itemSeleccionado: PantallaItem? = nil
    private var timer: Timer?

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            self?.cargar()
        }
    }

    deinit {
        timer?.invalidate()
    }

    func cargar() {
        guard let url = URL(string: "https://bidjuanmi.com/pantalla-lista") else { return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = json["items"] as? [[String: Any]] else { return }
            DispatchQueue.main.async {
                self.items = items.compactMap { i in
                    guard let titulo = i["titulo"] as? String,
                          let contenido = i["contenido"] as? String,
                          let ts = i["ts"] as? Double else { return nil }
                    return PantallaItem(titulo: titulo, contenido: contenido, ts: ts)
                }.reversed()
            }
        }.resume()
    }
    
    func borrarTodo() {
        guard let url = URL(string: "https://bidjuanmi.com/pantalla-lista") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        URLSession.shared.dataTask(with: request) { _, _, _ in
            DispatchQueue.main.async { self.items = [] }
        }.resume()
    }
}

struct PantallaView: View {
    @StateObject private var vm = PantallaViewModel()
    let cyan = Color(red: 0, green: 0.71, blue: 0.85)
    let fondo = Color(red: 0.01, green: 0.03, blue: 0.06)
    
    var body: some View {
        ZStack {
            fondo.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Text("PANTALLA")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(cyan)
                        .tracking(3)
                    Spacer()
                    Button {
                        vm.cargar()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .foregroundColor(cyan.opacity(0.7))
                            .font(.system(size: 18))
                    }
                    .padding(.trailing, 12)
                    Button {
                        vm.borrarTodo()
                    } label: {
                        Image(systemName: "trash")
                            .foregroundColor(cyan.opacity(0.7))
                            .font(.system(size: 18))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color(red: 0.01, green: 0.05, blue: 0.1))
                
                if let item = vm.itemSeleccionado {
                    // Vista detalle
                    VStack(spacing: 0) {
                        HStack {
                            Button {
                                vm.itemSeleccionado = nil
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "chevron.left")
                                    Text("VOLVER")
                                        .font(.system(size: 11, design: .monospaced))
                                }
                                .foregroundColor(cyan)
                            }
                            Spacer()
                            Text(item.titulo)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(cyan.opacity(0.6))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(Color(red: 0.01, green: 0.05, blue: 0.1))
                        
                        ScrollView {
                            Text(item.contenido)
                                .font(.system(size: 15))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(16)
                                .lineSpacing(6)
                        }
                    }
                } else {
                    // Lista
                    if vm.items.isEmpty {
                        Spacer()
                        VStack(spacing: 12) {
                            Image(systemName: "rectangle.on.rectangle")
                                .font(.system(size: 40))
                                .foregroundColor(cyan.opacity(0.3))
                            Text("Sin contenido")
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundColor(cyan.opacity(0.3))
                        }
                        Spacer()
                    } else {
                        ScrollView {
                            VStack(spacing: 10) {
                                ForEach(vm.items) { item in
                                    Button {
                                        vm.itemSeleccionado = item
                                    } label: {
                                        VStack(alignment: .leading, spacing: 6) {
                                            Text(item.titulo)
                                                .font(.system(size: 12, design: .monospaced))
                                                .foregroundColor(cyan)
                                                .tracking(1)
                                            Text(item.contenido)
                                                .font(.system(size: 13))
                                                .foregroundColor(.white.opacity(0.7))
                                                .lineLimit(3)
                                                .multilineTextAlignment(.leading)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(14)
                                        .background(Color(red: 0.02, green: 0.08, blue: 0.15))
                                        .cornerRadius(10)
                                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(cyan.opacity(0.2), lineWidth: 1))
                                    }
                                }
                            }
                            .padding(16)
                        }
                    }
                }
            }
        }
        .onAppear { vm.cargar() }
    }
}
// MARK: - Web View

import WebKit

class WebViewModel: ObservableObject {
    @Published var urlActual: String = ""
    private var timer: Timer?
    static let shared = WebViewModel()

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.comprobarUrl()
        }
    }

    deinit { timer?.invalidate() }

    func comprobarUrl() {
        guard let url = URL(string: "https://bidjuanmi.com/web-url") else { return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let url = json["url"] as? String,
                  !url.isEmpty else { return }
            DispatchQueue.main.async { self.urlActual = url }
        }.resume()
    }

    func cargarUrl(_ urlString: String) {
        DispatchQueue.main.async { self.urlActual = urlString }
    }
}

struct WebTabView: View {
    @ObservedObject private var vm = WebViewModel.shared
    @State private var urlInput: String = ""
    @State private var webViewUrl: URL? = nil
    let cyan = Color(red: 0, green: 0.71, blue: 0.85)
    let fondo = Color(red: 0.01, green: 0.03, blue: 0.06)

    var body: some View {
        ZStack {
            fondo.ignoresSafeArea()
            VStack(spacing: 0) {
                // Header
                HStack {
                    Text("WEB")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(cyan)
                        .tracking(3)
                    Spacer()
                    if webViewUrl != nil {
                        Button {
    webViewUrl = nil
    vm.urlActual = ""
    // Borrar también en Redis
    guard let url = URL(string: "https://bidjuanmi.com/web-url") else { return }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try? JSONSerialization.data(withJSONObject: ["url": ""])
    URLSession.shared.dataTask(with: request).resume()
} label: {
    Image(systemName: "xmark.circle")
        .foregroundColor(cyan.opacity(0.7))
        .font(.system(size: 18))
}
                    }
                }
                .padding(.horizontal, 16)
.padding(.vertical, 12)
.background(Color(red: 0.01, green: 0.05, blue: 0.1))

if let url = webViewUrl {
    BidWebKitView(url: url)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(edges: .bottom)
} else {
    // Pantalla vacía con input manual
    Spacer()
    VStack(spacing: 20) {
        Image(systemName: "globe")
            .font(.system(size: 50))
            .foregroundColor(cyan.opacity(0.3))
        Text("Bid abrirá páginas aquí")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(cyan.opacity(0.3))

                        // Input manual por si quieres abrir tú una URL
                        HStack(spacing: 8) {
                            TextField("https://...", text: $urlInput)
                                .font(.system(size: 13))
                                .foregroundColor(.white)
                                .padding(10)
                                .background(Color(red: 0.05, green: 0.1, blue: 0.18))
                                .cornerRadius(8)
                            Button {
                                if let url = URL(string: urlInput), !urlInput.isEmpty {
                                    webViewUrl = url
                                }
                            } label: {
                                Image(systemName: "arrow.right.circle.fill")
                                    .font(.system(size: 28))
                                    .foregroundColor(cyan)
                            }
                        }
                        .padding(.horizontal, 24)
                    }
                    Spacer()
                }
            }
        }
        .onChange(of: vm.urlActual) { nuevaUrl in
            if !nuevaUrl.isEmpty, let url = URL(string: nuevaUrl) {
                webViewUrl = url
            }
        }
        .onAppear {
    vm.comprobarUrl()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        if !vm.urlActual.isEmpty, let url = URL(string: vm.urlActual) {
            webViewUrl = url
        }
    }
}
    }
}


struct BidWebView: UIViewRepresentable {
    let url: URL
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        let webView = WKWebView(frame: .zero, configuration: config)
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        webView.load(request)
        return webView
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}


// MARK: - Main App View

struct MainAppView: View {
    let wearables: WearablesInterface
    @ObservedObject private var viewModel: WearablesViewModel
    @StateObject private var locationManager = LocationManager()
    @State private var pestañaActiva: String = "BID"

    let pestañas: [(id: String, icono: String, label: String)] = [
        ("BID",      "waveform",                    "BID"),
        ("CHAT",     "bubble.left.and.bubble.right", "CHAT"),
        ("FOTO",     "camera.fill",                  "FOTO"),
        ("DOCS",     "doc.fill",                     "DOCS"),
        ("PANTALLA", "rectangle.on.rectangle",       "PANTALLA"),
        ("GAFAS",    "eyeglasses",                   "GAFAS"),
        ("PANEL",    "square.grid.2x2",              "PANEL"),
        ("WEB",      "globe",                         "WEB")
    ]

    let cyan = Color(red: 0, green: 0.71, blue: 0.85)
    let fondo = Color(red: 0.01, green: 0.03, blue: 0.06)

    init(wearables: WearablesInterface, viewModel: WearablesViewModel) {
        self.wearables = wearables
        self.viewModel = viewModel
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            fondo.ignoresSafeArea()

            // Contenido
            Group {
                switch pestañaActiva {
                case "BID":
                    BidStatusView(viewModel: viewModel)
                        .onAppear { viewModel.arrancarEscucha() }
                        .onChange(of: locationManager.lat) { lat in
                            viewModel.ultimaLat = lat
                            viewModel.ultimaLon = locationManager.lon
                        }
                case "CHAT":
                    ChatView()
                case "FOTO":
                    FotoAnalisisView()
                case "DOCS":
                    DocumentosView()
                case "PANTALLA":
                    PantallaView()
                case "GAFAS":
                    GafasView(viewModel: viewModel, streamVM: viewModel.streamVM)
                case "PANEL":
                 BidWebView(url: URL(string: "https://bidjuanmi.com?app_token=bid-app-token-juanmi")!)
                    .ignoresSafeArea()
                case "WEB":
                     WebTabView()
                default:
                    BidStatusView(viewModel: viewModel)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.bottom, 60)

            // Barra inferior custom
            VStack(spacing: 0) {
                Rectangle()
                    .fill(cyan.opacity(0.15))
                    .frame(height: 1)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(pestañas, id: \.id) { tab in
                            Button {
                                pestañaActiva = tab.id
                            } label: {
                                VStack(spacing: 4) {
                                    Image(systemName: tab.icono)
                                        .font(.system(size: 18))
                                        .foregroundColor(pestañaActiva == tab.id ? cyan : cyan.opacity(0.35))
                                    Text(tab.label)
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundColor(pestañaActiva == tab.id ? cyan : cyan.opacity(0.35))
                                        .tracking(1)
                                }
                                .frame(width: 70)
                                .padding(.vertical, 8)
                                .background(
                                    pestañaActiva == tab.id
                                        ? cyan.opacity(0.08)
                                        : Color.clear
                                )
                                .overlay(
                                    Rectangle()
                                        .fill(pestañaActiva == tab.id ? cyan : Color.clear)
                                        .frame(height: 2),
                                    alignment: .top
                                )
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                }
                .frame(height: 56)
                .background(Color(red: 0.01, green: 0.04, blue: 0.08))
            }
        }
        .environmentObject(locationManager)
        .ignoresSafeArea(.keyboard)
    }
}
