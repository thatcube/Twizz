import SDWebImage
import SDWebImageWebPCoder
import SwiftUI

@main
struct TwizzApp: App {
  @State private var deepLinkRouter = DeepLinkRouter()

  init() {
    SDImageCodersManager.shared.addCoder(SDImageWebPCoder.shared)
    ChatAppearanceMigration.runIfNeeded()
    #if DEBUG
    if #available(tvOS 26.0, *) {
      let ch = ProcessInfo.processInfo.environment["TWIZZ_CAPTION_SPIKE"] ?? "<nil>"
      LiveCaptionSpike.fileLog("APP LAUNCH env TWIZZ_CAPTION_SPIKE=\(ch)")
    }
    #endif
  }

  var body: some Scene {
    WindowGroup {
      HomeView(deepLinkRouter: deepLinkRouter)
        .onOpenURL { url in
          deepLinkRouter.handle(url)
        }
        .resolveGlassDisabled()
        #if DEBUG
        .modifier(CaptionSpikeAutoStart())
        #endif
    }
  }
}

#if DEBUG
/// DEBUG-only: when launched with the `TWIZZ_CAPTION_SPIKE=<channel>` environment
/// variable (e.g. via the Simulator), auto-presents the isolated caption spike
/// harness and starts transcribing that channel. Lets the spike be exercised
/// headlessly with no on-screen navigation. No effect in normal launches.
private struct CaptionSpikeAutoStart: ViewModifier {
  private let channel = ProcessInfo.processInfo.environment["TWIZZ_CAPTION_SPIKE"]

  func body(content: Content) -> some View {
    content.fullScreenCover(isPresented: .constant(channel?.isEmpty == false)) {
      if #available(tvOS 26.0, *), let channel {
        CaptionSpikeDebugView(autoStartChannel: channel)
      }
    }
  }
}
#endif
