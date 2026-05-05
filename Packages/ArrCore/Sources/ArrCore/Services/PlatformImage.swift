import Foundation
import SwiftUI

#if os(macOS)
import AppKit
public typealias PlatformImage = NSImage
#else
import UIKit
public typealias PlatformImage = UIImage
#endif

extension Image {
    /// SwiftUI ships separate `Image(nsImage:)` / `Image(uiImage:)`
    /// initialisers per platform. This forwards to the right one so
    /// shared views can stay platform-neutral.
    init(platformImage: PlatformImage) {
        #if os(macOS)
        self.init(nsImage: platformImage)
        #else
        self.init(uiImage: platformImage)
        #endif
    }
}

extension Color {
    /// Cross-platform background colour matching the host window/scene.
    /// Maps to `NSColor.windowBackgroundColor` on macOS and
    /// `UIColor.systemBackground` on iOS. Used by shared views that need
    /// to render against the platform's primary surface.
    public static var platformWindowBackground: Color {
        #if os(macOS)
        return Color(nsColor: .windowBackgroundColor)
        #else
        return Color(uiColor: .systemBackground)
        #endif
    }
}
