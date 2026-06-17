import SDWebImage
import SDWebImageWebPCoder
import SwiftUI

@main
struct TwizzApp: App {
  init() {
    SDImageCodersManager.shared.addCoder(SDImageWebPCoder.shared)
  }

  var body: some Scene {
    WindowGroup {
      HomeView()
    }
  }
}
