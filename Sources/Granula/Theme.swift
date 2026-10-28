import AppKit
import SwiftUI

/// Warm Granola-like palette in orange tones, for light and dark mode.
enum Theme {
    static let background = dynamic(light: 0xFBF6F0, dark: 0x1E1A16)
    static let card = dynamic(light: 0xFFFFFF, dark: 0x29231E)
    static let line = dynamic(light: 0xEADFD3, dark: 0x3B332C)
    static let accent = dynamic(light: 0xE2701F, dark: 0xF08A45)
    static let tile = dynamic(light: 0xFCE9DA, dark: 0x3A2A1E)
    static let tileIcon = dynamic(light: 0xB4561A, dark: 0xF5B07E)

    static func serif(_ size: CGFloat) -> Font { .system(size: size, design: .serif) }

    /// The app icon's «Диалог» mark for the menu bar: two grains whose overlap stays empty.
    static let menuBarMark: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            let mark = NSBezierPath()
            mark.windingRule = .evenOdd
            for center in [NSPoint(x: 6.8, y: 7.8), NSPoint(x: 11.2, y: 10.2)] {
                let grain = NSBezierPath(ovalIn: NSRect(x: -5.8, y: -4.5, width: 11.6, height: 9))
                var place = AffineTransform(rotationByDegrees: -28)
                place.append(AffineTransform(translationByX: center.x, byY: center.y))
                grain.transform(using: place)
                mark.append(grain)
            }
            NSColor.black.setFill()
            mark.fill()
            return true
        }
        image.isTemplate = true
        return image
    }()

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                           green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}

/// Interface language: as in macOS, or one of the four Granula speaks.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system = "", ru, uk, en, es

    var id: String { rawValue }

    /// Language names are written in their own language, never translated.
    var name: String {
        switch self {
        case .system: return String(localized: "Как в системе")
        case .ru: return "Русский"     // not localized: autonym
        case .uk: return "Українська"  // not localized: autonym
        case .en: return "English"
        case .es: return "Español"
        }
    }

    /// The choice saved for Granula only (its own `AppleLanguages`), not the system-wide list.
    static var chosen: AppLanguage {
        let domain = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "") ?? [:]
        guard let first = (domain["AppleLanguages"] as? [String])?.first else { return .system }
        return AppLanguage(rawValue: String(first.prefix(2))) ?? .system
    }

    static func choose(_ language: AppLanguage) {
        if language == .system {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([language.rawValue], forKey: "AppleLanguages")
        }
    }

    /// The language the interface is shown in right now, for dates and month names.
    static var locale: Locale { Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en") }

    static func format(_ date: Date, template: String) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.setLocalizedDateFormatFromTemplate(template)
        return f.string(from: date)
    }
}
