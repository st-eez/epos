import SwiftUI

struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white.opacity(configuration.isPressed ? 0.62 : 0.76))
            .frame(maxWidth: .infinity, minHeight: 32)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(.white.opacity(configuration.isPressed ? 0.1 : 0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(.white.opacity(0.08), lineWidth: 1)
            )
    }
}
