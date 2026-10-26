import SwiftUI
import StrandDesign

struct RootView: View {
    // Observe only Repository (changes on data refresh, not the ~1 Hz HR/frame stream). The live
    // status pill is isolated into SidebarStatus so HR/frame ticks don't re-render the whole
    // NavigationSplitView shell + sidebar list.
    @EnvironmentObject var repo: Repository
    /// Cross-screen navigation requests (e.g. Live → "Manage devices"). Observed here so a screen can
    /// switch the sidebar selection without owning it — see `NavRouter`.
    @EnvironmentObject var router: NavRouter
    @State private var selection: NavItem? = .today
    /// Whether the "More" sidebar group is expanded. Persisted; collapsed by default.
    @AppStorage("nav.showAllSections") private var showAllSections = false

    /// Sidebar filter text; ⌘K focuses the field.
    @State private var search = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 228, ideal: 250, max: 290)
        } detail: {
            detail
                // Tab/section crossfade — README §Motion: "switching tabs uses a crossfade ~240ms",
                // global calm easing cubic-bezier(0.22,1,0.36,1). Opacity swap between detail roots
                // keyed on the selected nav item; restrained (no slide) for the desktop sidebar shell.
                .id(selection ?? .today)
                .transition(.opacity)
                .animation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.24), value: selection)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(StrandPalette.surfaceBase.ignoresSafeArea())
        }
        .environment(\.locale, AppLanguage.currentContentLocale)
        .task { await repo.refresh() }
        // Programmatic navigation (router requests, etc.) to a "More" item must reveal its row.
        .onChangeCompat(of: selection) { item in
            if let item, item.isRemoved {
                selection = .today
            } else if let item, !item.isCore, !showAllSections {
                showAllSections = true
            }
        }
        // Honour a cross-screen request to open a top-level destination (e.g. Live's "Manage devices"),
        // then clear it so the same tap can fire again later. Devices maps to the `.devices` sidebar item.
        .onChangeCompat(of: router.requestedDestination) { dest in
            guard let dest else { return }
            selection = NavItem(destination: dest).resolved
            router.requestedDestination = nil
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            brand
            searchField.padding(.horizontal, 14).padding(.bottom, 14)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if search.isEmpty {
                        ForEach(NavItem.main) { sidebarRow($0) }
                        sectionLabel("Tools").padding(.top, 22)
                        ForEach(NavItem.tools) { sidebarRow($0) }
                        moreHeader.padding(.top, 18)
                        if showAllSections {
                            ForEach(NavItem.more) { sidebarRow($0) }
                        }
                    } else {
                        let hits = searchHits
                        if hits.isEmpty {
                            Text("No matches")
                                .font(.system(size: 13)).foregroundStyle(StrandPalette.textTertiary)
                                .padding(.horizontal, 12).padding(.top, 6)
                        }
                        ForEach(hits) { sidebarRow($0) }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
            SidebarStatus { selection = .devices }
                .padding(.horizontal, 14).padding(.bottom, 14).padding(.top, 6)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(StrandPalette.surfaceSidebar)
        .overlay(alignment: .trailing) { Rectangle().fill(StrandPalette.hairline).frame(width: 1) }
        // ⌘K focuses the search field (an invisible button carries the shortcut).
        .background {
            Button("") { searchFocused = true }
                .keyboardShortcut("k", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }

    private var searchHits: [NavItem] {
        let locale = AppLanguage.currentContentLocale
        return (NavItem.core + NavItem.more).filter { $0.matches(search, locale: locale) }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(StrandPalette.textTertiary)
                .accessibilityHidden(true)
            TextField("Search", text: $search)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($searchFocused)
                .accessibilityLabel("Search sections")
                .onSubmit {
                    if let first = searchHits.first { selection = first; search = ""; searchFocused = false }
                }
                .onExitCommand { search = ""; searchFocused = false }
            Text("⌘K")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(StrandPalette.textTertiary)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .padding(.horizontal, 12).frame(height: 38)
        .background(StrandPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(StrandPalette.hairline, lineWidth: 1))
    }

    private func sidebarRow(_ item: NavItem) -> some View {
        SidebarRow(item: item, selected: (selection ?? .today) == item) {
            selection = item
            if !search.isEmpty { search = ""; searchFocused = false }
        }
    }

    private func sectionLabel(_ text: LocalizedStringKey) -> some View {
        Text(text).textCase(.uppercase)
            .font(.system(size: 11, weight: .medium)).tracking(0.8)
            .foregroundStyle(StrandPalette.textTertiary)
            .padding(.horizontal, 12).padding(.bottom, 6)
    }

    /// Collapsible "More" header: a full-width button with a rotating chevron.
    private var moreHeader: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { showAllSections.toggle() }
        } label: {
            HStack(spacing: 6) {
                Text("More").textCase(.uppercase).font(.system(size: 11, weight: .medium)).tracking(0.8)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .rotationEffect(.degrees(showAllSections ? 90 : 0))
            }
            .foregroundStyle(StrandPalette.textTertiary)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(DimPressButtonStyle())
        .accessibilityLabel(showAllSections ? "Hide more sections" : "Show more sections")
    }

    private var brand: some View {
        HStack(spacing: 10) {
            BrandMark(size: 26)
            Text("NOOP")
                .font(.system(size: 20, weight: .semibold)).tracking(-0.3)
                .foregroundStyle(StrandPalette.textPrimary)
            Spacer()
        }
        // Top padding clears the traffic-light controls (the window hides its title bar, so they sit
        // over the sidebar's top edge); the lockup sits just below them.
        .padding(.horizontal, 22).padding(.top, 40).padding(.bottom, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var detail: some View {
        switch selection ?? .today {
        case .today: HomeView(navigate: { selection = $0 })
        case .dayDetails: TodayView()
        // Removed sections never render; a stale selection shows Today.
        case .intelligence, .coach: TodayView()
        case .insightsHub: InsightsHubView()
        case .live: LiveView()
        case .breathe: BreathingView()
        case .intervals: IntervalTimerView()
        case .explore: MetricExplorerView()
        case .compare: CompareView()
        case .insights: InsightsView()
        case .sleep: SleepView()
        case .trends: TrendsView()
        case .workouts: WorkoutsView()
        case .health: HealthView()
        case .stress: StressView()
        case .labBook: LabBookView()
        case .rhythm: RhythmHost()
        case .appleHealth: AppleHealthView()
        case .xiaomi: XiaomiBandView()
        case .dataSources: DataSourcesView()
        case .fusedRecord: FusedRecordHost()
        case .devices: DevicesView()
        case .notifications: NotificationSettingsView()
        case .automation: AutomationsView()
        case .smartAlarm: SmartAlarmView()
        case .settings: SettingsView()
        case .about: AboutView()
        }
    }
}

/// The NOOP logo mark — an **open recovery ring** (~80% arc, round caps, starting at 12 o'clock)
/// with a **solid centre core dot** ("on-device core"), per the README logo system. Rendered in the
/// gold gradient and kept deliberately flat / low-glow for the v3 Titanium & Gold restraint. Drawn
/// purely from design tokens so it tracks the palette. Sized to optically x-height-match the wordmark.
struct BrandMark: View {
    var size: CGFloat = 22

    var body: some View {
        ZStack {
            // Open ring: leave ~20% of the circumference as a gap (trim 0 → 0.8), then rotate so the
            // gap sits at the top — the gold gradient sweeps clockwise from 12 o'clock.
            Circle()
                .trim(from: 0, to: 0.8)
                .stroke(
                    AngularGradient(gradient: StrandPalette.goldGradient,
                                    center: .center,
                                    angle: .degrees(-90)),
                    style: StrokeStyle(lineWidth: size * 0.16, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .frame(width: size * 0.84, height: size * 0.84)

            // Solid centre core dot — the "on-device core".
            Circle()
                .fill(LinearGradient(gradient: StrandPalette.goldGradient,
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: size * 0.26, height: size * 0.26)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Isolated strap-status card at the foot of the sidebar — owns the LiveState observation so the
/// rest of RootView (sidebar list + detail) does not re-render on the ~1 Hz HR / frame stream.
private struct SidebarStatus: View {
    @EnvironmentObject var live: LiveState
    var open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 11) {
                ZStack(alignment: .bottomTrailing) {
                    BrandMark(size: 26)
                    Circle().fill(statusColor).frame(width: 9, height: 9)
                        .overlay(Circle().stroke(StrandPalette.surfaceRaised, lineWidth: 2))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("WHOOP")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(StrandPalette.textPrimary)
                    detail
                        .font(.system(size: 11)).foregroundStyle(StrandPalette.textSecondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 2)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(StrandPalette.textSecondary)
                    .frame(width: 24, height: 24)
                    .background(StrandPalette.surfaceInset, in: Circle())
            }
            .padding(12)
            .background(StrandPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(StrandPalette.hairline, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(DimPressButtonStyle())
        .help("Open devices")
        .accessibilityLabel(Text("WHOOP, \(detail). Open devices"))
    }

    // Shares LiveState.connectionStatus* with the Settings strap card so the two never disagree (#266).
    private var statusColor: Color {
        live.connectionStatusIsActive ? StrandPalette.statusPositive
            : live.connectionStatusIsIdle ? StrandPalette.statusWarning
            : StrandPalette.statusCritical
    }
    private var detail: Text {
        let state = live.connected ? Text("Connected") : Text("Not connected")
        guard let b = live.batteryPct else { return state }
        return Text("\(state) · Battery \(Int(b)) %")
    }
}

/// One sidebar row: outline icon + localized label, soft filled pill when selected.
private struct SidebarRow: View {
    let item: NavItem
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: item.outlineIcon)
                    .font(.system(size: 15, weight: .regular))
                    .frame(width: 22)
                Text(item.title)
                    .font(.system(size: 14, weight: selected ? .medium : .regular))
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? StrandPalette.textPrimary : StrandPalette.textPrimary.opacity(0.78))
            .padding(.horizontal, 12).frame(height: 38)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(selected ? StrandPalette.surfaceInset : (hovering ? StrandPalette.surfaceInset.opacity(0.5) : .clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(DimPressButtonStyle())
        .onHover { hovering = $0 }
        .accessibilityLabel(Text(item.title))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
