import AppKit
import SwiftUI

enum WorkspaceSemanticColorRole: String, CaseIterable, Sendable {
    case canvas
    case sidebarSurface
    case primarySurface
    case elevatedSurface
    case controlSurface
    case controlSurfaceHover
    case borderSubtle
    case borderFocused
    case textPrimary
    case textSecondary
    case textTertiary
    case accent
    case success
    case warning
    case danger
    case diffAddedBackground
    case diffRemovedBackground
    case diffAddedText
    case diffRemovedText
}

enum WorkspaceVisualStyle {
    static func color(_ role: WorkspaceSemanticColorRole) -> Color {
        switch role {
        case .diffAddedBackground:
            return Color(nsColor: .systemGreen).opacity(0.11)
        case .diffRemovedBackground:
            return Color(nsColor: .systemRed).opacity(0.10)
        case .controlSurfaceHover:
            return Color(nsColor: .selectedContentBackgroundColor).opacity(0.08)
        case .borderSubtle:
            return Color(nsColor: .separatorColor).opacity(0.72)
        case .borderFocused:
            return Color(nsColor: .separatorColor).opacity(0.9)
        default:
            return Color(nsColor: nsColor(role))
        }
    }

    static func nsColor(_ role: WorkspaceSemanticColorRole) -> NSColor {
        switch role {
        case .canvas: return .windowBackgroundColor
        case .sidebarSurface: return .underPageBackgroundColor
        case .primarySurface: return .textBackgroundColor
        case .elevatedSurface: return .controlBackgroundColor
        case .controlSurface, .controlSurfaceHover: return .controlBackgroundColor
        case .borderSubtle: return .separatorColor
        case .borderFocused: return .separatorColor
        case .accent: return .controlAccentColor
        case .textPrimary: return .labelColor
        case .textSecondary: return .secondaryLabelColor
        case .textTertiary: return .tertiaryLabelColor
        case .success, .diffAddedText, .diffAddedBackground: return .systemGreen
        case .warning: return .systemOrange
        case .danger, .diffRemovedText, .diffRemovedBackground: return .systemRed
        }
    }

    enum Spacing {
        static let x4: CGFloat = 4
        static let x8: CGFloat = 8
        static let x12: CGFloat = 12
        static let x16: CGFloat = 16
        static let x20: CGFloat = 20
        static let x24: CGFloat = 24
        static let x32: CGFloat = 32
    }

    enum Radius {
        static let control: CGFloat = 8
        static let artifactCard: CGFloat = 12
        static let humanReview: CGFloat = 14
        static let composer: CGFloat = 18
    }

    enum Typography {
        static let workspaceTitle = Font.title2.weight(.semibold)
        static let messageTitle = Font.headline
        static let body = Font.body
        static let metadata = Font.caption
        static let label = Font.caption.weight(.semibold)
        static let code = Font.system(.body, design: .monospaced)
        static let diff = Font.system(size: 12.5, weight: .regular, design: .monospaced)
    }
}
