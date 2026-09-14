import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

extension Color {
    // Semantic surfaces support both appearance modes and system contrast settings.
    #if os(macOS)
    static let brandPrimary = Color(NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return dark
            ? NSColor(red: 0.30, green: 0.77, blue: 0.73, alpha: 1)
            : NSColor(red: 0.02, green: 0.43, blue: 0.42, alpha: 1)
    })
    #else
    static let brandPrimary = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.30, green: 0.77, blue: 0.73, alpha: 1)
            : UIColor(red: 0.02, green: 0.43, blue: 0.42, alpha: 1)
    })
    #endif
    static let brandButtonBackground = Color(red: 0.02, green: 0.43, blue: 0.42)
    static let statusSuccess = adaptive(light: (0.04, 0.43, 0.27), dark: (0.34, 0.83, 0.58))
    static let statusWarning = adaptive(light: (0.60, 0.32, 0.02), dark: (1.0, 0.73, 0.34))
    static let statusDestructive = adaptive(light: (0.75, 0.15, 0.19), dark: (1.0, 0.46, 0.48))

    private static func adaptive(light: (Double, Double, Double), dark: (Double, Double, Double)) -> Color {
        #if os(macOS)
        Color(NSColor(name: nil) { appearance in
            let c = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        })
        #else
        Color(UIColor { traits in
            let c = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        })
        #endif
    }

    #if os(macOS)
    static let systemGroupedBackground = Color(NSColor.windowBackgroundColor)
    static let secondarySystemGroupedBackground = Color(NSColor.controlBackgroundColor)
    static let systemBackground = Color(NSColor.windowBackgroundColor)
    static let secondarySystemBackground = Color(NSColor.controlBackgroundColor)
    #else
    static let systemGroupedBackground = Color(UIColor.systemGroupedBackground)
    static let secondarySystemGroupedBackground = Color(UIColor.secondarySystemGroupedBackground)
    static let systemBackground = Color(UIColor.systemBackground)
    static let secondarySystemBackground = Color(UIColor.secondarySystemBackground)
    #endif

    static let cardBackground = secondarySystemGroupedBackground
    static let listBackground = systemGroupedBackground
}

struct WorkspaceCard<Content: View>: View {
    private let content: Content
    private let padding: CGFloat

    init(padding: CGFloat = 18, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 18))
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
            }
    }
}

struct WorkspaceField<Content: View>: View {
    let title: String
    let hint: String?
    private let content: Content

    init(title: String, hint: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.hint = hint
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold))
            content.accessibilityLabel(title)
            if let hint {
                Text(hint)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct StatusBadge: View {
    let text: String
    var iconName: String? = nil
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            if let iconName {
                Image(systemName: iconName).accessibilityHidden(true)
            }
            Text(text)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .foregroundStyle(color)
        .background(color.opacity(0.12), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

struct EmptyState: View {
    let title: String
    let message: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title).font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .padding(.horizontal, 20)
    }
}

struct InlineNotice: View {
    let message: String
    var style: NoticeStyle = .info

    enum NoticeStyle {
        case success, error, info

        var color: Color {
            switch self {
            case .success: return .statusSuccess
            case .error: return .statusDestructive
            case .info: return .brandPrimary
            }
        }

        var icon: String {
            switch self {
            case .success: return "checkmark.circle.fill"
            case .error: return "exclamationmark.circle.fill"
            case .info: return "info.circle.fill"
            }
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: style.icon)
                .foregroundStyle(style.color)
                .accessibilityHidden(true)
            Text(message)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(style.color.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}

struct WorkspacePrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var backgroundColor: Color = .brandButtonBackground
    var foregroundColor: Color = .white
    var cornerRadius: CGFloat = 12
    var isDisabled: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 24)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .foregroundStyle(foregroundColor)
            .background(backgroundColor, in: RoundedRectangle(cornerRadius: cornerRadius))
            .opacity(!isEnabled || isDisabled ? 0.45 : configuration.isPressed ? 0.8 : 1)
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}

struct Clipboard {
    static func copy(text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #elseif canImport(AppKit)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        #endif
    }
}

enum CrossPlatformKeyboardType {
    case emailAddress, url, decimal, `default`
}

extension View {
    func workspaceInputStyle() -> some View {
        self
            .textFieldStyle(.plain)
            .padding(12)
            .frame(minHeight: 46)
            .background(Color.listBackground, in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
            }
    }

    @ViewBuilder
    func crossPlatformKeyboardType(_ type: CrossPlatformKeyboardType) -> some View {
        #if os(iOS) || os(visionOS)
        switch type {
        case .emailAddress: self.keyboardType(.emailAddress)
        case .url: self.keyboardType(.URL)
        case .decimal: self.keyboardType(.decimalPad)
        default: self
        }
        #else
        self
        #endif
    }

    @ViewBuilder
    func crossPlatformAutocapitalization() -> some View {
        #if os(iOS) || os(visionOS)
        self.textInputAutocapitalization(.never)
        #else
        self
        #endif
    }

    @ViewBuilder
    func crossPlatformNavigationBarTitleDisplayModeInline() -> some View {
        #if os(iOS) || os(visionOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

}
