import SwiftUI
import UIKit

// MARK: Themes
struct AppTheme: Identifiable {
    let id: String
    let name: String
    let color: Color
    static let all: [AppTheme] = [
        AppTheme(id: "default", name: "Blue", color: Color(red: 0.00, green: 0.48, blue: 1.00)),
        AppTheme(id: "ocean", name: "Ocean", color: Color(red: 0.00, green: 0.66, blue: 0.72)),
        AppTheme(id: "forest", name: "Forest", color: Color(red: 0.20, green: 0.62, blue: 0.36)),
        AppTheme(id: "sunset", name: "Sunset", color: Color(red: 1.00, green: 0.50, blue: 0.20)),
        AppTheme(id: "berry", name: "Berry", color: Color(red: 0.90, green: 0.25, blue: 0.50)),
        AppTheme(id: "grape", name: "Grape", color: Color(red: 0.55, green: 0.36, blue: 0.90)),
        AppTheme(id: "graphite", name: "Graphite", color: Color(red: 0.45, green: 0.47, blue: 0.52))
    ]
}

private struct AccentKey: EnvironmentKey { static let defaultValue = Color.blue }
extension EnvironmentValues {
    var appAccent: Color { get { self[AccentKey.self] } set { self[AccentKey.self] = newValue } }
}

/// Tints the screen background with the theme color.
struct Themed: ViewModifier {
    @Environment(\.appAccent) private var accent
    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(
                LinearGradient(colors: [accent.opacity(0.22), Color(.systemGroupedBackground)],
                               startPoint: .top, endPoint: .center).ignoresSafeArea()
            )
    }
}
extension View { func themed() -> some View { modifier(Themed()) } }

extension Store {
    var accent: Color {
        if themeID == "custom", customRGB.count == 3 {
            return Color(red: customRGB[0], green: customRGB[1], blue: customRGB[2])
        }
        return (AppTheme.all.first { $0.id == themeID } ?? AppTheme.all[0]).color
    }
    func setCustom(_ c: Color) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(c).getRed(&r, green: &g, blue: &b, alpha: &a)
        customRGB = [Double(r), Double(g), Double(b)]
        themeID = "custom"
    }
    /// The name shown for a class. The original HAC name is still used behind the scenes.
    func nm(_ original: String) -> String { nameOverrides[original] ?? original }
    func rename(_ original: String, to new: String) {
        let t = new.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || t == original { nameOverrides[original] = nil } else { nameOverrides[original] = t }
    }
}

struct ThemeSection: View {
    @EnvironmentObject var store: Store
    var body: some View {
        Section("Theme color") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 58), spacing: 10)], spacing: 12) {
                ForEach(AppTheme.all) { t in
                    Button { store.themeID = t.id } label: {
                        VStack(spacing: 4) {
                            Circle().fill(t.color).frame(width: 36, height: 36)
                                .overlay(Circle().stroke(Color.primary, lineWidth: store.themeID == t.id ? 3 : 0).padding(-3))
                                .padding(4)
                            Text(t.name).font(.caption2)
                        }
                    }.buttonStyle(.plain)
                }
            }.padding(.vertical, 4)
            ColorPicker("Custom color",
                        selection: Binding(get: { store.accent }, set: { store.setCustom($0) }),
                        supportsOpacity: false)
        }
    }
}

// MARK: App icons
struct IconChoice: Identifiable {
    let id: String        // asset set name in Xcode; empty means the main AppIcon
    let name: String
    let c1: Color, c2: Color, bar: Color, star: Color
    static let all: [IconChoice] = [
        IconChoice(id: "", name: "Classic", c1: Color(red: 0.09, green: 0.13, blue: 0.36), c2: Color(red: 0.37, green: 0.26, blue: 0.84), bar: .white, star: Color(red: 1, green: 0.84, blue: 0.40)),
        IconChoice(id: "IconSunset", name: "Sunset", c1: Color(red: 1, green: 0.54, blue: 0.30), c2: Color(red: 0.84, green: 0.20, blue: 0.42), bar: .white, star: Color(red: 1, green: 0.93, blue: 0.60)),
        IconChoice(id: "IconForest", name: "Forest", c1: Color(red: 0.06, green: 0.36, blue: 0.27), c2: Color(red: 0.20, green: 0.66, blue: 0.43), bar: .white, star: Color(red: 1, green: 0.89, blue: 0.55)),
        IconChoice(id: "IconOcean", name: "Ocean", c1: Color(red: 0, green: 0.40, blue: 0.60), c2: Color(red: 0.13, green: 0.79, blue: 0.78), bar: .white, star: Color(red: 1, green: 0.96, blue: 0.67)),
        IconChoice(id: "IconMidnight", name: "Midnight", c1: Color(red: 0.04, green: 0.04, blue: 0.06), c2: Color(red: 0.16, green: 0.16, blue: 0.23), bar: .white, star: Color(red: 1, green: 0.80, blue: 0.27)),
        IconChoice(id: "IconLight", name: "Light", c1: Color(red: 0.97, green: 0.97, blue: 0.99), c2: Color(red: 0.88, green: 0.88, blue: 0.94), bar: Color(red: 0.37, green: 0.26, blue: 0.84), star: Color(red: 0.96, green: 0.67, blue: 0.12))
    ]
}

struct IconPreview: View {
    let choice: IconChoice
    var body: some View {
        Canvas { ctx, size in
            let s = size.width
            ctx.fill(Path(CGRect(origin: .zero, size: size)),
                     with: .linearGradient(Gradient(colors: [choice.c1, choice.c2]),
                                           startPoint: .zero, endPoint: CGPoint(x: s, y: s)))
            let bw = s * 0.1514, gap = s * 0.0513, base = s * 0.8032
            let hs = [0.1953 * s, 0.3296 * s, 0.4639 * s]
            let alphas = [0.43, 0.72, 1.0]
            let x0 = (s - (3 * bw + 2 * gap)) / 2
            for i in 0..<3 {
                let r = CGRect(x: x0 + CGFloat(i) * (bw + gap), y: base - hs[i], width: bw, height: hs[i])
                ctx.fill(Path(roundedRect: r, cornerRadius: bw / 2), with: .color(choice.bar.opacity(alphas[i])))
            }
            let cx = x0 + 2 * (bw + gap) + bw / 2, cy = base - hs[2] - 0.0806 * s
            let r = 0.0635 * s, k = 0.0146 * s
            var star = Path()
            star.addLines([CGPoint(x: cx, y: cy - r), CGPoint(x: cx + k, y: cy - k), CGPoint(x: cx + r, y: cy),
                           CGPoint(x: cx + k, y: cy + k), CGPoint(x: cx, y: cy + r), CGPoint(x: cx - k, y: cy + k),
                           CGPoint(x: cx - r, y: cy), CGPoint(x: cx - k, y: cy - k)])
            star.closeSubpath()
            ctx.fill(star, with: .color(choice.star))
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct IconSection: View {
    @State private var current = UIApplication.shared.alternateIconName ?? ""
    @State private var message = ""
    var body: some View {
        Section(header: Text("App icon"),
                footer: Text(message.isEmpty ? "Pick the icon for your home screen. iOS will show a confirmation." : message)) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 70), spacing: 12)], spacing: 12) {
                ForEach(IconChoice.all) { ch in
                    Button { choose(ch) } label: {
                        VStack(spacing: 4) {
                            IconPreview(choice: ch).frame(width: 62, height: 62)
                                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary, lineWidth: current == ch.id ? 3 : 0).padding(-3))
                                .padding(4)
                            Text(ch.name).font(.caption2)
                        }
                    }.buttonStyle(.plain)
                }
            }.padding(.vertical, 4)
        }
    }
    func choose(_ ch: IconChoice) {
        guard UIApplication.shared.supportsAlternateIcons else {
            message = "Alternate icons aren't set up in Xcode yet. Add the icon sets and the Alternate App Icon Sets build setting, then rebuild."
            return
        }
        UIApplication.shared.setAlternateIconName(ch.id.isEmpty ? nil : ch.id) { err in
            DispatchQueue.main.async {
                if let err { message = "Couldn't change the icon: \(err.localizedDescription)" }
                else { current = ch.id; message = "" }
            }
        }
    }
}
