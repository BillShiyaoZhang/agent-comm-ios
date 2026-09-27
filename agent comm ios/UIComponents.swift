import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

extension Color {
    // Asset variants adapt to appearance and Increase Contrast on every platform.
    static let brandPrimary = Color("AccentColor")
    static let brandButtonBackground = Color("WorkspaceBrandButtonBackground")
    static let statusSuccess = Color("WorkspaceStatusSuccess")
    static let statusWarning = Color("WorkspaceStatusWarning")
    static let statusDestructive = Color("WorkspaceStatusDestructive")

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
    @Environment(\.colorSchemeContrast) private var contrast
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
                    .strokeBorder(Color.primary.opacity(contrast == .increased ? 0.4 : 0.07), lineWidth: 1)
            }
    }
}

/// Action rows and metadata become vertical when people request accessibility text sizes.
struct WorkspaceAdaptiveStack<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var spacing: CGFloat = 12
    @ViewBuilder var content: () -> Content

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: spacing))
            : AnyLayout(HStackLayout(alignment: .center, spacing: spacing))
        layout {
            content()
        }
        .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil, alignment: .leading)
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
            Text(title).font(.subheadline.weight(.semibold)).accessibilityHidden(true)
            content.accessibilityLabel(title).accessibilityHint(hint ?? "")
            if let hint {
                Text(hint)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityHidden(true)
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
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .workspaceTapTarget()
            .foregroundStyle(foregroundColor)
            .background(backgroundColor, in: RoundedRectangle(cornerRadius: cornerRadius))
            .opacity(!isEnabled || isDisabled ? 0.45 : configuration.isPressed ? 0.8 : 1)
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
            .workspaceHoverEffect()
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
    @ViewBuilder
    func workspaceScrollDismissesKeyboard() -> some View {
        #if os(iOS) || os(macOS)
        self.scrollDismissesKeyboard(.interactively)
        #else
        self
        #endif
    }

    @ViewBuilder
    func workspaceHoverEffect() -> some View {
        #if os(iOS) || os(visionOS)
        self.hoverEffect(.highlight)
        #else
        self
        #endif
    }

    /// Apply inside a control's label so the full region participates in hit testing.
    @ViewBuilder
    func workspaceTapTarget() -> some View {
        #if os(visionOS)
        self.frame(minWidth: 60, minHeight: 60).contentShape(Rectangle())
        #elseif os(iOS)
        self.frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
        #else
        self
        #endif
    }

    func workspaceInputStyle() -> some View {
        self
            .textFieldStyle(.plain)
            .padding(12)
            .frame(minHeight: 46)
            .workspaceTapTarget()
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
