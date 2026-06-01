import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Color Palette
extension Color {
    static let brandPrimary = Color(red: 0.36, green: 0.30, blue: 0.90) // Vibrant Indigo
    static let brandSecondary = Color(red: 0.08, green: 0.70, blue: 0.75) // Teal
    static let brandBackground = Color(red: 0.05, green: 0.05, blue: 0.10) // Deep Slate Black
    static let glassBackground = Color.white.opacity(0.06)
    
    static let statusSuccess = Color(red: 0.18, green: 0.80, blue: 0.44) // Bright Emerald
    static let statusWarning = Color(red: 0.95, green: 0.61, blue: 0.07) // Amber/Yellow
    static let statusDestructive = Color(red: 0.90, green: 0.30, blue: 0.26) // Premium Red
    
    #if canImport(UIKit)
    static let systemGroupedBackground = Color(UIColor.systemGroupedBackground)
    static let secondarySystemGroupedBackground = Color(UIColor.secondarySystemGroupedBackground)
    static let systemBackground = Color(UIColor.systemBackground)
    static let secondarySystemBackground = Color(UIColor.secondarySystemBackground)
    #else
    static let systemGroupedBackground = Color(NSColor.windowBackgroundColor)
    static let secondarySystemGroupedBackground = Color(NSColor.controlBackgroundColor)
    static let systemBackground = Color(NSColor.windowBackgroundColor)
    static let secondarySystemBackground = Color(NSColor.underPageBackgroundColor)
    #endif
    
    static let cardBackground = secondarySystemGroupedBackground
    static let listBackground = systemGroupedBackground
}

// MARK: - Glassmorphic Card Style
struct GlassCardModifier: ViewModifier {
    var cornerRadius: CGFloat = 16
    var borderColor: Color = Color.white.opacity(0.15)
    
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color.glassBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(borderColor, lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.2), radius: 8, x: 0, y: 4)
    }
}

extension View {
    func glassCardStyle(cornerRadius: CGFloat = 16, borderColor: Color = Color.white.opacity(0.15)) -> some View {
        self.modifier(GlassCardModifier(cornerRadius: cornerRadius, borderColor: borderColor))
    }
}

// MARK: - Premium Button Style
struct PremiumButtonStyle: ButtonStyle {
    var backgroundColor: Color = .brandPrimary
    var foregroundColor: Color = .white
    var cornerRadius: CGFloat = 12
    var isDisabled: Bool = false
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .padding()
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(backgroundColor.opacity(isDisabled ? 0.5 : (configuration.isPressed ? 0.85 : 1.0)))
            )
            .foregroundColor(foregroundColor.opacity(isDisabled ? 0.6 : 1.0))
            .scaleEffect(configuration.isPressed && !isDisabled ? 0.97 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.6, blendDuration: 0), value: configuration.isPressed)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    var borderColor: Color = .brandPrimary
    var foregroundColor: Color = .brandPrimary
    var cornerRadius: CGFloat = 12
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .padding()
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(borderColor, lineWidth: 2)
                    .background(Color.white.opacity(configuration.isPressed ? 0.1 : 0.0))
            )
            .foregroundColor(foregroundColor)
            .cornerRadius(cornerRadius)
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.6, blendDuration: 0), value: configuration.isPressed)
    }
}

// MARK: - Pill Badges
struct StatusBadge: View {
    let text: String
    let iconName: String?
    let color: Color
    
    var body: some View {
        HStack(spacing: 4) {
            if let icon = iconName {
                Image(systemName: icon)
                    .font(.caption2)
            }
            Text(text)
                .font(.caption)
                .bold()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.15))
        .foregroundColor(color)
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(color.opacity(0.3), lineWidth: 1)
        )
    }
}

// MARK: - Notification Banner
struct NotificationBanner: View {
    let message: String
    let style: BannerStyle
    
    enum BannerStyle {
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
            case .error: return "exclamationmark.triangle.fill"
            case .info: return "info.circle.fill"
            }
        }
    }
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: style.icon)
                .foregroundColor(style.color)
                .font(.title2)
            Text(message)
                .foregroundColor(.primary)
                .font(.subheadline)
                .multilineTextAlignment(.leading)
            Spacer()
        }
        .padding()
        .background(Color.systemBackground)
        .cornerRadius(12)
        .shadow(color: Color.black.opacity(0.1), radius: 10, x: 0, y: 5)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(style.color.opacity(0.3), lineWidth: 1)
        )
        .padding()
    }
}

// MARK: - Loading Overlay
struct LoadingOverlay: View {
    var message: String = "Loading..."
    
    var body: some View {
        ZStack {
            Color.black.opacity(0.4)
                .edgesIgnoringSafeArea(.all)
            
            VStack(spacing: 16) {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .brandPrimary))
                    .scaleEffect(1.5)
                
                Text(message)
                    .font(.headline)
                    .foregroundColor(.white)
            }
            .padding(32)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.systemBackground.opacity(0.85))
            )
            .shadow(radius: 20)
        }
    }
}

// MARK: - Standard Gradient Background
struct PremiumBackground: View {
    var body: some View {
        ZStack {
            Color.brandBackground
                .edgesIgnoringSafeArea(.all)
            
            // Subtle top-right glowing gradient sphere
            Circle()
                .fill(LinearGradient(colors: [.brandPrimary.opacity(0.25), .clear], startPoint: .top, endPoint: .bottom))
                .frame(width: 400, height: 400)
                .offset(x: 180, y: -250)
            
            // Subtle bottom-left glowing gradient sphere
            Circle()
                .fill(LinearGradient(colors: [.brandSecondary.opacity(0.2), .clear], startPoint: .bottom, endPoint: .top))
                .frame(width: 350, height: 350)
                .offset(x: -180, y: 350)
        }
    }
}

// MARK: - Clipboard Copy Utility
struct Clipboard {
    static func copy(text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #elseif os(macOS)
        let pasteboard = NSPasteboard.general
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString(text, forType: .string)
        #endif
    }
}

// MARK: - Cross-Platform View Modifiers
enum CrossPlatformKeyboardType {
    case emailAddress
    case url
    case decimal
    case `default`
}

extension View {
    @ViewBuilder
    func crossPlatformKeyboardType(_ type: CrossPlatformKeyboardType) -> some View {
        #if os(iOS)
        switch type {
        case .emailAddress:
            self.keyboardType(.emailAddress)
        case .url:
            self.keyboardType(.URL)
        case .decimal:
            self.keyboardType(.decimalPad)
        default:
            self
        }
        #else
        self
        #endif
    }
    
    @ViewBuilder
    func crossPlatformAutocapitalization() -> some View {
        #if os(iOS)
        self.autocapitalization(.none)
        #else
        self
        #endif
    }
    
    @ViewBuilder
    func crossPlatformListStyle() -> some View {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        self.listStyle(InsetGroupedListStyle())
        #else
        self.listStyle(InsetListStyle())
        #endif
    }

    @ViewBuilder
    func crossPlatformNavigationViewStyle() -> some View {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        self.navigationViewStyle(StackNavigationViewStyle())
        #else
        self.navigationViewStyle(.automatic)
        #endif
    }

    @ViewBuilder
    func crossPlatformNavigationBarTitleDisplayModeInline() -> some View {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    @ViewBuilder
    func crossPlatformNavigationBarHidden(_ hidden: Bool) -> some View {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        self.navigationBarHidden(hidden)
        #else
        self
        #endif
    }

    @ViewBuilder
    func crossPlatformToolbar(
        leading: AnyView? = nil,
        trailing: AnyView? = nil
    ) -> some View {
        self.toolbar {
            #if os(iOS) && !targetEnvironment(macCatalyst)
            if let leading = leading {
                ToolbarItem(placement: .navigationBarLeading) {
                    leading
                }
            }
            if let trailing = trailing {
                ToolbarItem(placement: .navigationBarTrailing) {
                    trailing
                }
            }
            #else
            if let leading = leading {
                ToolbarItem(placement: .navigation) {
                    leading
                }
            }
            if let trailing = trailing {
                ToolbarItem(placement: .primaryAction) {
                    trailing
                }
            }
            #endif
        }
    }
}
