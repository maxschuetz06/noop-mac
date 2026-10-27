import Foundation

/// A sidebar section. Raw values are persisted (stored selections, router requests) and must not change.
enum NavItem: String, CaseIterable, Identifiable, Hashable {
    case today = "Today"
    /// The former "Control Center" dashboard, kept as a detail view behind the new home.
    case dayDetails = "Day Details"
    case insightsHub = "What Moves You"
    case live = "Live"
    case breathe = "Breathe"
    case intervals = "Intervals"
    case explore = "Explore"
    case compare = "Compare"
    case insights = "Insights"
    case sleep = "Sleep"
    case trends = "Trends"
    case workouts = "Workouts"
    case health = "Health"
    case stress = "Stress"
    case labBook = "Lab Book"
    case rhythm = "Rhythm"
    case appleHealth = "Apple Health"
    case xiaomi = "Mi Band"
    case dataSources = "Data Sources"
    case fusedRecord = "Your Data, Fused"
    case devices = "Devices"
    case notifications = "Notifications"
    case automation = "Automations"
    case settings = "Settings"
    case about = "Support"

    var id: String { rawValue }

    /// Sections shown in the default (compact) sidebar, in display order.
    static let core: [NavItem] = main + tools

    /// The primary sidebar group (top), in display order.
    static let main: [NavItem] = [.today, .dayDetails, .sleep, .trends, .workouts, .health, .stress]
    /// The "Tools" sidebar group, in display order.
    static let tools: [NavItem] = [.live, .breathe, .dataSources, .devices, .settings]

    /// Everything else — listed under the collapsible "More" group, in `allCases` order.
    static var more: [NavItem] { allCases.filter { !core.contains($0) } }

    /// True for sections that live in the always-visible core list.
    var isCore: Bool { Self.core.contains(self) }

    /// The sidebar item a cross-screen `NavRouter` request opens.
    init(destination: NavRouter.Destination) {
        switch destination {
        case .devices: self = .devices
        case .insightsHub: self = .insightsHub
        case .labBook: self = .labBook
        case .fusedRecord: self = .fusedRecord
        case .rhythm: self = .rhythm
        case .trends: self = .trends
        }
    }

    /// Sidebar label (English source, translated in the String Catalog) and thin outline SF Symbol.
    struct Descriptor {
        let title: LocalizedStringResource
        let outlineIcon: String
    }

    var descriptor: Descriptor {
        switch self {
        case .today: return Descriptor(title: "Overview", outlineIcon: "house")
        case .dayDetails: return Descriptor(title: "Day Details", outlineIcon: "square.grid.2x2")
        case .insightsHub: return Descriptor(title: "What Moves You", outlineIcon: "sparkle")
        case .live: return Descriptor(title: "Live Pulse", outlineIcon: "waveform.path.ecg")
        case .breathe: return Descriptor(title: "Breathe", outlineIcon: "wind")
        case .intervals: return Descriptor(title: "Intervals", outlineIcon: "timer")
        case .explore: return Descriptor(title: "Explore", outlineIcon: "safari")
        case .compare: return Descriptor(title: "Compare", outlineIcon: "chart.line.uptrend.xyaxis")
        case .insights: return Descriptor(title: "Insights", outlineIcon: "lightbulb")
        case .sleep: return Descriptor(title: "Sleep", outlineIcon: "moon")
        case .trends: return Descriptor(title: "Trends", outlineIcon: "chart.bar")
        case .workouts: return Descriptor(title: "Training", outlineIcon: "figure.run")
        case .health: return Descriptor(title: "Health", outlineIcon: "heart.text.square")
        case .stress: return Descriptor(title: "Stress", outlineIcon: "gauge.with.dots.needle.33percent")
        case .labBook: return Descriptor(title: "Lab Book", outlineIcon: "book.closed")
        case .rhythm: return Descriptor(title: "Rhythm", outlineIcon: "waveform.path")
        case .appleHealth: return Descriptor(title: "Apple Health", outlineIcon: "heart")
        case .xiaomi: return Descriptor(title: "Mi Band", outlineIcon: "applewatch")
        case .dataSources: return Descriptor(title: "Data Sources", outlineIcon: "tray.and.arrow.down")
        case .fusedRecord: return Descriptor(title: "All Data", outlineIcon: "square.stack.3d.up")
        case .devices: return Descriptor(title: "Devices", outlineIcon: "dot.radiowaves.left.and.right")
        case .notifications: return Descriptor(title: "Notifications", outlineIcon: "bell")
        case .automation: return Descriptor(title: "Automations", outlineIcon: "wand.and.stars")
        case .settings: return Descriptor(title: "Settings", outlineIcon: "gearshape")
        case .about: return Descriptor(title: "About", outlineIcon: "info.circle")
        }
    }

    var title: LocalizedStringResource { descriptor.title }
    var outlineIcon: String { descriptor.outlineIcon }

    /// The sidebar label resolved for `locale`.
    func title(in locale: Locale) -> String {
        var resource = title
        resource.locale = locale
        return String(localized: resource)
    }

    /// Sidebar search: the localized title or the stable English raw value contains `query`.
    func matches(_ query: String, locale: Locale) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return title(in: locale).lowercased().contains(q) || rawValue.lowercased().contains(q)
    }
}
