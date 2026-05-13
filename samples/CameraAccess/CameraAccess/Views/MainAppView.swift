import MWDATCore
import SwiftUI
import WebKit

struct BidWebView: UIViewRepresentable {
    let url: URL
    
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.load(URLRequest(url: URL(string: "https://bidjuanmi.com?app_token=bid-app-token-juanmi")!))
        return webView
    }
    
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct MainAppView: View {
    let wearables: WearablesInterface
    @ObservedObject private var viewModel: WearablesViewModel
    
    init(wearables: WearablesInterface, viewModel: WearablesViewModel) {
        self.wearables = wearables
        self.viewModel = viewModel
        UITabBar.appearance().barTintColor = UIColor(red: 0.01, green: 0.03, blue: 0.06, alpha: 1)
        UITabBar.appearance().unselectedItemTintColor = UIColor(red: 0.2, green: 0.5, blue: 0.7, alpha: 1)
    }
    
    var body: some View {
        TabView {
            // Pestaña 1 — Gafas y escucha
            ZStack(alignment: .top) {
                if viewModel.registrationState == .registered {
                    StreamSessionView(wearables: wearables, wearablesVM: viewModel)
                        .onAppear {
                            viewModel.arrancarEscucha()
                        }
                } else {
                    HomeScreenView(viewModel: viewModel)
                }
                Text(viewModel.bidStatus)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.yellow)
                    .padding(6)
                    .background(Color.black.opacity(0.7))
                    .cornerRadius(6)
                    .padding(.top, 50)
            }
            .tabItem {
                Image(systemName: "waveform")
                Text("BID")
            }
            
            // Pestaña 2 — Panel web
            BidWebView(url: URL(string: "https://bidjuanmi.com")!)
                .ignoresSafeArea()
                .tabItem {
                    Image(systemName: "square.grid.2x2")
                    Text("PANEL")
                }
        }
        .accentColor(Color(red: 0, green: 0.71, blue: 0.85))
    }
}
