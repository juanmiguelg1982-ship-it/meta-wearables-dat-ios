import CoreLocation
import MWDATCore
import SwiftUI
import WebKit

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
    // Mandar al servidor cuando hay cambio de ubicación
    guard let url = URL(string: "https://bidjuanmi.com/ubicacion?lat=\(lat)&lon=\(lon)") else { return }
    URLSession.shared.dataTask(with: url).resume()
}
}

// MARK: - Web View

struct BidWebView: UIViewRepresentable {
    let url: URL
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        let webView = WKWebView(frame: .zero, configuration: config)
        var request = URLRequest(url: URL(string: "https://bidjuanmi.com?app_token=bid-app-token-juanmi")!)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        webView.load(request)
        return webView
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
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
            DispatchQueue.main.async {
                self.mensajes = []
            }
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
                    Button {
                        vm.borrarHistorial()
                    } label: {
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

    var body: some View {
        ZStack {
            Color(red: 0.01, green: 0.03, blue: 0.06).ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                VStack(spacing: 16) {
                    ZStack {
                        Circle()
                            .stroke(Color(red: 0, green: 0.71, blue: 0.85).opacity(0.2), lineWidth: 1)
                            .frame(width: 120, height: 120)
                        Circle()
                            .stroke(Color(red: 0, green: 0.71, blue: 0.85).opacity(0.1), lineWidth: 1)
                            .frame(width: 90, height: 90)
                        Text("BID")
                            .font(.system(size: 36, weight: .thin, design: .monospaced))
                            .foregroundColor(Color(red: 0, green: 0.71, blue: 0.85))
                            .tracking(8)
                    }

                    Text("ASISTENTE PERSONAL")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Color(red: 0, green: 0.71, blue: 0.85).opacity(0.4))
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
                    .padding(.bottom, 40) 
            }
        }
    }
}

// MARK: - Main App View

struct MainAppView: View {
    let wearables: WearablesInterface
    @ObservedObject private var viewModel: WearablesViewModel
    @StateObject private var locationManager = LocationManager()

    init(wearables: WearablesInterface, viewModel: WearablesViewModel) {
        self.wearables = wearables
        self.viewModel = viewModel
        UITabBar.appearance().barTintColor = UIColor(red: 0.01, green: 0.03, blue: 0.06, alpha: 1)
        UITabBar.appearance().unselectedItemTintColor = UIColor(red: 0.2, green: 0.5, blue: 0.7, alpha: 1)
    }

    var body: some View {
        TabView {
            BidStatusView(viewModel: viewModel)
                .onAppear { viewModel.arrancarEscucha() }
                .tabItem {
                    Image(systemName: "waveform")
                    Text("BID")
                }

            ChatView()
                .tabItem {
                    Image(systemName: "bubble.left.and.bubble.right")
                    Text("CHAT")
                }

            BidWebView(url: URL(string: "https://bidjuanmi.com?app_token=bid-app-token-juanmi")!)
                .ignoresSafeArea()
                .tabItem {
                    Image(systemName: "square.grid.2x2")
                    Text("PANEL")
                }
        }
        .accentColor(Color(red: 0, green: 0.71, blue: 0.85))
        .environmentObject(locationManager)
    }
}
