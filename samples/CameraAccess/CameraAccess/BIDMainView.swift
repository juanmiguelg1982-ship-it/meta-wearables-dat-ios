import MWDATCore
import SwiftUI

struct BIDMainView: View {
  let wearables: WearablesInterface
  @ObservedObject var viewModel: WearablesViewModel

  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()
      VStack(spacing: 0) {
        HStack {
          Text("BID")
            .font(.system(size: 18, weight: .bold, design: .monospaced))
            .foregroundColor(.cyan)
            .kerning(8)
          Spacer()
          HStack(spacing: 6) {
            Circle()
              .fill(viewModel.devices.isEmpty ? Color.red : Color.cyan)
              .frame(width: 8, height: 8)
            Text(viewModel.devices.isEmpty ? "SIN GAFAS" : "GAFAS")
              .font(.system(size: 10, weight: .medium, design: .monospaced))
              .foregroundColor(viewModel.devices.isEmpty ? .red : .cyan)
              .kerning(2)
          }
        }
        .padding(.horizontal, 24)
        .padding(.top, 60)
        .padding(.bottom, 20)

        Spacer()

        Circle()
          .fill(Color.black)
          .overlay(Circle().stroke(Color.cyan, lineWidth: 2))
          .frame(width: 100, height: 100)
          .overlay(Text("🎤").font(.system(size: 36)))

        Spacer()

        if viewModel.registrationState != .registered {
          Button(action: { viewModel.connectGlasses() }) {
            Text(viewModel.registrationState == .registering ? "CONECTANDO..." : "CONECTAR GAFAS")
              .font(.system(size: 12, weight: .bold, design: .monospaced))
              .kerning(2)
              .foregroundColor(.black)
              .frame(maxWidth: .infinity)
              .padding(.vertical, 14)
              .background(Color.cyan)
              .cornerRadius(8)
          }
          .padding(.horizontal, 24)
          .padding(.bottom, 50)
        } else {
          Text("BID listo")
            .font(.system(size: 12, design: .monospaced))
            .foregroundColor(.cyan.opacity(0.7))
            .padding(.bottom, 50)
        }
      }
    }
    .preferredColorScheme(.dark)
  }
}
