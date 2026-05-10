import MWDATCore
import SwiftUI

struct MainAppView: View {
  let wearables: WearablesInterface
  @ObservedObject private var viewModel: WearablesViewModel

  init(wearables: WearablesInterface, viewModel: WearablesViewModel) {
    self.wearables = wearables
    self.viewModel = viewModel
  }

  var body: some View {
    ZStack(alignment: .top) {
      if viewModel.registrationState == .registered {
        StreamSessionView(wearables: wearables, wearablesVM: viewModel)
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
  }
}
