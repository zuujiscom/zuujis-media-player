// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import WidgetKit

@main
struct ZuujisWidgetBundle: WidgetBundle {
    var body: some Widget {
        NowPlayingWidget()
        EqualizerWidget()
    }
}

/// The app's Midnight look, for widgets (which cannot read the app's theme).
enum WTheme {
    static let cyan = Color(red: 0.24, green: 0.86, blue: 1.00)
    static let violet = Color(red: 0.56, green: 0.44, blue: 1.00)
    static let pink = Color(red: 1.00, green: 0.33, blue: 0.64)
    static let mint = Color(red: 0.30, green: 0.94, blue: 0.66)
    static let amber = Color(red: 1.00, green: 0.68, blue: 0.26)
    static var signal: LinearGradient {
        LinearGradient(colors: [cyan, violet, pink], startPoint: .leading, endPoint: .trailing)
    }
    static var signalDiagonal: LinearGradient {
        LinearGradient(colors: [cyan, violet, pink], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// The widget's backdrop: deep blue-black with the signal colours bleeding
    /// in from the corners, and the cover, blurred, over it when there is one.
    static func background(art: NSImage?) -> some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.07, green: 0.075, blue: 0.115), Color(red: 0.028, green: 0.03, blue: 0.052)],
                           startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [cyan.opacity(0.22), .clear], center: .topLeading, startRadius: 0, endRadius: 260)
            RadialGradient(colors: [pink.opacity(0.18), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 280)
            if let art {
                Image(nsImage: art).resizable().scaledToFill()
                    .blur(radius: 40, opaque: true)
                    .saturation(1.4)
                    .opacity(0.42)
                    .mask(LinearGradient(colors: [.black, .black.opacity(0.2)], startPoint: .top, endPoint: .bottom))
            }
        }
    }
}

/// The cover the app saved, if any.
func loadArtwork() -> NSImage? {
    NSImage(contentsOf: WidgetFiles.art)
}
