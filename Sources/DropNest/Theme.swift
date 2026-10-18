import SwiftUI
import AppKit

/// Visual language shared by the desktop panel and the settings window.
///
/// The palette follows macOS 27 "Golden Gate": a restrained jade accent over
/// layered, translucent surfaces. Geometry uses concentric radii so nested
/// controls step down consistently (26 → 18 → 12).
enum DropTheme {
    // MARK: Accent

    static let accent = Color(
        light: NSColor(srgbRed: 0.09, green: 0.47, blue: 0.36, alpha: 1),
        dark: NSColor(srgbRed: 0.31, green: 0.82, blue: 0.65, alpha: 1)
    )

    static let accentDeep = Color(
        light: NSColor(srgbRed: 0.05, green: 0.31, blue: 0.24, alpha: 1),
        dark: NSColor(srgbRed: 0.16, green: 0.63, blue: 0.49, alpha: 1)
    )

    static var accentGradient: LinearGradient {
        LinearGradient(colors: [accent, accentDeep], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    // MARK: Surfaces

    static let cardFill = Color(
        light: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.72),
        dark: NSColor(srgbRed: 0.18, green: 0.18, blue: 0.19, alpha: 0.62)
    )

    static let rowFill = Color(
        light: NSColor(srgbRed: 0.12, green: 0.16, blue: 0.14, alpha: 0.045),
        dark: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.055)
    )

    static let raisedFill = Color(
        light: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.55),
        dark: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.075)
    )

    static let border = Color(
        light: NSColor(srgbRed: 0.10, green: 0.15, blue: 0.12, alpha: 0.10),
        dark: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.12)
    )

    // MARK: Geometry

    static let panelRadius: CGFloat = 26
    static let cardRadius: CGFloat = 16
    static let rowRadius: CGFloat = 12
    static let controlRadius: CGFloat = 10

    static let settingsWidth: CGFloat = 880
    static let settingsHeight: CGFloat = 620
    static let settingsMinWidth: CGFloat = 800
    static let settingsMinHeight: CGFloat = 540
    static let sidebarWidth: CGFloat = 214

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.6.0"
    }
}

// MARK: - Dynamic colors

extension Color {
    init(light: NSColor, dark: NSColor) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

/// Snapshot rendering has no window server, so Liquid Glass cannot be
/// composited there. Falling back to materials keeps layout verification
/// faithful without affecting the running app.
enum DropSnapshotMode {
    static let enabled = ProcessInfo.processInfo.environment["DROPNEST_SNAPSHOT"] == "1"
        && NSClassFromString("XCTestCase") != nil
}

// MARK: - Glass surfaces

struct GlassPanelBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    var cornerRadius: CGFloat = DropTheme.panelRadius
    var tint: Color = DropTheme.accent.opacity(0.05)

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            shape.fill(.regularMaterial)
            shape.fill(LinearGradient(
                colors: colorScheme == .dark
                    ? [Color.white.opacity(0.07), Color.black.opacity(0.10)]
                    : [Color.white.opacity(0.34), Color.white.opacity(0.04)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            ))
            shape.fill(tint)
            if #available(macOS 26.0, *), !DropSnapshotMode.enabled {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .glassEffect(.regular.tint(tint), in: shape)
            }
        }
    }
}

struct GlassEdge: View {
    @Environment(\.colorScheme) private var colorScheme
    var cornerRadius: CGFloat = DropTheme.panelRadius

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(
                LinearGradient(
                    colors: colorScheme == .dark
                        ? [Color.white.opacity(0.30), Color.white.opacity(0.045)]
                        : [Color.white.opacity(0.92), Color.white.opacity(0.20)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ),
                lineWidth: 1
            )
    }
}

/// A soft, inset container used for the drop area on the panel and in the
/// invoice importer.
struct DropWellBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    var targeted: Bool
    var cornerRadius: CGFloat = 18

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            shape.fill(.thinMaterial)
            shape.fill(
                LinearGradient(
                    colors: targeted
                        ? [DropTheme.accent.opacity(colorScheme == .dark ? 0.30 : 0.20),
                           DropTheme.accent.opacity(0.06)]
                        : [Color.white.opacity(colorScheme == .dark ? 0.045 : 0.22),
                           Color.primary.opacity(colorScheme == .dark ? 0.03 : 0.012)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            )
            shape.strokeBorder(
                targeted ? DropTheme.accent.opacity(0.75) : DropTheme.border,
                lineWidth: targeted ? 1.5 : 1
            )
            if targeted {
                shape.strokeBorder(DropTheme.accent.opacity(0.35), lineWidth: 6)
                    .blur(radius: 7)
            }
        }
        .animation(.smooth(duration: 0.22), value: targeted)
    }
}

// MARK: - Buttons

struct GlassIconButton: View {
    let systemImage: String
    let help: String
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 26, height: 26)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(hovering ? Color.primary : Color.secondary)
        .background {
            ZStack {
                Circle().fill(.regularMaterial)
                Circle().fill(Color.primary.opacity(hovering ? 0.10 : 0.035))
                if #available(macOS 26.0, *), !DropSnapshotMode.enabled {
                    Color.clear.glassEffect(.regular.interactive(), in: Circle())
                }
            }
        }
        .overlay { Circle().strokeBorder(DropTheme.border, lineWidth: 1) }
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Cards

struct SettingsCard<Content: View>: View {
    private let title: String?
    private let systemImage: String?
    private let content: Content

    init(_ title: String? = nil, systemImage: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let title {
                Label {
                    Text(title).font(.system(size: 13, weight: .semibold))
                } icon: {
                    Image(systemName: systemImage ?? "circle")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DropTheme.accent)
                }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            let shape = RoundedRectangle(cornerRadius: DropTheme.cardRadius, style: .continuous)
            ZStack {
                shape.fill(.thinMaterial)
                shape.fill(DropTheme.cardFill)
                shape.strokeBorder(DropTheme.border, lineWidth: 1)
            }
        }
    }
}

struct SettingsCardDivider: View {
    var body: some View {
        Rectangle().fill(DropTheme.border).frame(height: 1)
    }
}

/// A grouped row inside a settings card. Nested radius = card radius − row
/// inset, keeping corners visually concentric.
struct InsetRow<Content: View>: View {
    private let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Fill only: a second border inside the card's border reads as clutter.
            .background(DropTheme.rowFill, in: RoundedRectangle(cornerRadius: DropTheme.rowRadius, style: .continuous))
    }
}

// MARK: - Page chrome

struct SettingsPageHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 22, weight: .bold))
            Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SettingsSearchField: View {
    @Binding var text: String
    var placeholder: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(focused ? DropTheme.accent : Color.secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focused)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .accessibilityLabel("清空搜索")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background {
            let shape = RoundedRectangle(cornerRadius: DropTheme.controlRadius + 1, style: .continuous)
            ZStack {
                shape.fill(.thinMaterial)
                shape.fill(DropTheme.raisedFill)
                shape.strokeBorder(focused ? DropTheme.accent.opacity(0.55) : DropTheme.border, lineWidth: 1)
            }
        }
        .animation(.smooth(duration: 0.16), value: focused)
    }
}

struct StatusDot: View {
    var active: Bool
    var body: some View {
        Circle()
            .fill(active ? DropTheme.accent : Color.secondary.opacity(0.5))
            .frame(width: 5, height: 5)
            .shadow(color: active ? DropTheme.accent.opacity(0.6) : .clear, radius: 3)
    }
}
