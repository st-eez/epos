import SwiftUI

/// Shared accent colors used across the menu bar panel and the recording indicator.
/// Hoisted here so the two surfaces can't drift apart on the same semantic color.
enum SteezPalette {
    static let teal = Color(red: 0.22, green: 0.78, blue: 0.72)
    static let amber = Color(red: 0.86, green: 0.55, blue: 0.18)
    static let red = Color(red: 0.9, green: 0.28, blue: 0.3)
}
