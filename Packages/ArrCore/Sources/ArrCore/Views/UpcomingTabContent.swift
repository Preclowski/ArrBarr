import os
import SwiftUI

struct UpcomingTabContent: View {
    var viewModel: QueueViewModel
    @Environment(ConfigStore.self) var configStore
    /// Written every frame of a pull; only the drop and the offset read it, so this body isn't rebuilt mid-gesture.
    @State private var pull = PullTracker()

    private static let log = Logger(category: "Upcoming")

    private var past: PastCalendarFeed { viewModel.pastCalendar }

    var body: some View {
        let groups = groupedRows
        // A reader, not a bound `ScrollPosition`, which would re-pin its view on every change.
        ScrollViewReader { proxy in
        ScrollView {
            if past.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, minHeight: 32)
            }
            if groups.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "calendar")
                        .scaledFont(size: 24, weight: .light)
                        .foregroundStyle(.tertiary)
                    Text("common.nothingUpcoming.button", bundle: .module)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(groups) { group in
                        Text(group.label)
                            .scaledFont(size: 11, weight: .semibold)
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 12)
                            .padding(.top, group.id == groups.first?.id ? 8 : 14)
                            .padding(.bottom, 4)
                            .id(group.id)

                        ForEach(group.items) { item in
                            UpcomingRowView(item: item)
                        }
                    }
                }
                .padding(.bottom, 8)
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .onScrollGeometryChange(for: CGFloat.self) { geo in
            geo.contentOffset.y + geo.contentInsets.top
        } action: { _, fromTop in
            pull.atTop = fromTop <= 1
        }
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentInsets.top } action: { _, inset in
            pull.topInset = inset
        }
        .onScrollPhaseChange { _, new in
            if new == .interacting { pull.hasInteracted = true }
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .modifier(PullOffset(pull: pull))
        .clipped()
        .overlay(alignment: .top) {
            PullDropOverlay(pull: pull, isLoading: past.isLoading)
        }
        #if os(macOS)
        .background(PullHostProbe(pull: pull))
        #endif
        .frame(maxHeight: .infinity)
        .onAppear {
            scrollToToday(proxy)
            pull.onTear = { loadEarlier(proxy) }
            pull.onRelease = {
                guard let id = pull.pendingReveal else { return }
                pull.pendingReveal = nil
                proxy.scrollTo(id, anchor: .top)
            }
            #if os(macOS)
            pull.start()
            #endif
        }
        #if os(macOS)
        .onDisappear { pull.stop() }
        #endif
        // The calendar can land after the tab opened; start on today unless the reader already moved.
        .onChange(of: todayID) { if !pull.hasInteracted { scrollToToday(proxy) } }
        }
    }

    /// The first row of the upcoming calendar proper; earlier days sit above it.
    private var todayID: String? {
        viewModel.upcoming.first.map { UpcomingDayGroup.id(for: $0.airDate) }
    }

    private func scrollToToday(_ proxy: ScrollViewProxy) {
        guard let todayID else { return }
        proxy.scrollTo(todayID, anchor: .top)
    }

    private func loadEarlier(_ proxy: ScrollViewProxy) {
        guard !past.isLoading else { return }
        let oldFirst = groupedRows.first?.id
        Task {
            let added = await past.loadEarlier()
            Self.log.notice("loaded earlier calendar days, added rows \(added, privacy: .public)")
            // Land on the newest of the loaded days, so the pull visibly brought something.
            let groups = groupedRows
            guard added, let index = groups.firstIndex(where: { $0.id == oldFirst }), index > 0 else { return }
            let reveal = groups[index - 1].id
            // A scroll issued while the fingers are still down would fight the stretch.
            if pull.isTracking { pull.pendingReveal = reveal } else { proxy.scrollTo(reveal, anchor: .top) }
        }
    }

    private var groupedRows: [UpcomingDayGroup] {
        let upcomingIDs = Set(viewModel.upcoming.map(\.id))
        let earlier = past.items.filter { !upcomingIDs.contains($0.id) }
        let rows = (earlier + viewModel.upcoming).sorted { $0.airDate < $1.airDate }
        return UpcomingDayGroup.grouped(rows, locale: configStore.currentLocale)
    }
}

/// Pull-to-load state. The stretch comes from the trackpad's own deltas: the popover's scroll view
/// snaps its overscroll back every frame, so it never gets past a few points by itself.
@Observable
private final class PullTracker {
    static let tearDistance: CGFloat = 56

    var distance: CGFloat = 0
    var topInset: CGFloat = 0
    var torn = false
    @ObservationIgnored var atTop = true
    @ObservationIgnored var hasInteracted = false
    @ObservationIgnored var pendingReveal: String?
    @ObservationIgnored var onTear: () -> Void = {}
    @ObservationIgnored var onRelease: () -> Void = {}
    @ObservationIgnored private(set) var isTracking = false

    /// Diminishing returns, like the system rubber band.
    static func stretch(_ raw: CGFloat) -> CGFloat {
        let limit: CGFloat = 120
        return limit * (1 - 1 / (raw * 0.6 / limit + 1))
    }

    #if os(macOS)
    @ObservationIgnored weak var host: NSView?
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var raw: CGFloat = 0

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, self.handle(event) else { return event }
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if isTracking { release() }
    }

    /// True when the event was spent on the stretch and must not also scroll the list.
    private func handle(_ event: NSEvent) -> Bool {
        // A wheel has no fingers to let go, and momentum is not a pull.
        guard event.hasPreciseScrollingDeltas, event.momentumPhase.isEmpty,
              let host, event.window === host.window,
              host.bounds.contains(host.convert(event.locationInWindow, from: nil)) else { return false }
        switch event.phase {
        case .began:
            raw = 0
            isTracking = atTop
            return false
        case .changed:
            if !isTracking, atTop, event.scrollingDeltaY > 0 {
                isTracking = true
                raw = 0
            }
            guard isTracking else { return false }
            raw += event.scrollingDeltaY
            guard raw > 0 else {
                // Pushed back up into the list: hand the gesture back to the scroll view.
                isTracking = false
                distance = 0
                return false
            }
            distance = Self.stretch(raw)
            if distance >= Self.tearDistance, !torn {
                withAnimation(.spring(duration: 0.25, bounce: 0.4)) { torn = true }
                onTear()
            }
            return true
        case .ended, .cancelled:
            if isTracking { release() }
            return false
        default:
            return false
        }
    }

    private func release() {
        isTracking = false
        raw = 0
        torn = false
        withAnimation(.spring(duration: 0.3)) { distance = 0 }
        onRelease()
    }
    #endif
}

#if os(macOS)
/// Sits behind the scroll view, so its bounds are the area a pull has to start in.
private struct PullHostProbe: NSViewRepresentable {
    let pull: PullTracker

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        pull.host = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}
#endif

/// Moves the list down by the stretch, so the drop has room above it.
private struct PullOffset: ViewModifier {
    let pull: PullTracker

    func body(content: Content) -> some View {
        content.offset(y: pull.distance)
    }
}

private struct PullDropOverlay: View {
    let pull: PullTracker
    let isLoading: Bool

    var body: some View {
        if pull.distance > 0, !pull.torn, !isLoading {
            PullDrop(distance: pull.distance)
                .frame(height: pull.distance)
                .padding(.top, pull.topInset)
                .allowsHitTesting(false)
                .transition(.scale(scale: 0.4, anchor: .top).combined(with: .opacity))
        }
    }
}

/// The old pull-to-refresh gum drop: a ball that grows with the pull, then draws a narrowing tail
/// out of its bottom, and tears at `PullTracker.tearDistance`.
private struct PullDrop: View {
    let distance: CGFloat

    var body: some View {
        let stretch = min(distance / PullTracker.tearDistance, 1)
        let head = GumDropShape.headRadius(height: distance, stretch: stretch)
        GumDropShape(stretch: stretch)
            .fill(Color.secondary.opacity(0.35))
            .overlay(alignment: .top) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(stretch * 270))
                    .scaleEffect(head / GumDropShape.maxHead)
                    .frame(width: head * 2, height: head * 2)
                    .padding(.top, GumDropShape.inset)
            }
            .frame(width: GumDropShape.maxHead * 2)
            .frame(maxWidth: .infinity)
    }
}

nonisolated private struct GumDropShape: Shape {
    static let maxHead: CGFloat = 14
    static let inset: CGFloat = 5
    var stretch: CGFloat

    /// Grows with the room until the ball is whole, shrinking a little as the pull nears the tear.
    static func headRadius(height: CGFloat, stretch: CGFloat) -> CGFloat {
        min(maxHead * (1 - stretch * 0.25), max(0, (height - 2 * inset) / 2))
    }

    func path(in rect: CGRect) -> Path {
        let head = Self.headRadius(height: rect.height, stretch: stretch)
        guard head > 0.5 else { return Path() }
        let cx = rect.midX
        let headY = rect.minY + Self.inset + head
        // The tail starts as the ball's own bottom half and pinches as it's drawn out.
        let room = max(0, rect.maxY - Self.inset - (headY + head))
        let tail = head * (1 - 0.7 * min(room / 40, 1))
        let tailY = rect.maxY - Self.inset - tail
        // Vertical tangents at both ends, so the sides leave and meet the arcs without a kink.
        let pull = (tailY - headY) * 0.45

        var p = Path()
        p.move(to: CGPoint(x: cx - head, y: headY))
        p.addArc(center: CGPoint(x: cx, y: headY), radius: head, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        p.addCurve(to: CGPoint(x: cx + tail, y: tailY),
                   control1: CGPoint(x: cx + head, y: headY + pull), control2: CGPoint(x: cx + tail, y: tailY - pull))
        p.addArc(center: CGPoint(x: cx, y: tailY), radius: tail, startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
        p.addCurve(to: CGPoint(x: cx - head, y: headY),
                   control1: CGPoint(x: cx - tail, y: tailY - pull), control2: CGPoint(x: cx - head, y: headY + pull))
        p.closeSubpath()
        return p
    }
}

/// One calendar day of the Upcoming list.
struct UpcomingDayGroup: Identifiable {
    let id: String
    let label: String
    let items: [UpcomingItem]

    static func id(for date: Date) -> String {
        let dc = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return "day-\(dc.year ?? 0)-\(dc.month ?? 0)-\(dc.day ?? 0)"
    }

    /// Consecutive rows of the same day; the caller sorts.
    static func grouped(_ items: [UpcomingItem], locale: Locale) -> [UpcomingDayGroup] {
        var groups: [UpcomingDayGroup] = []
        for item in items {
            let id = id(for: item.airDate)
            if let last = groups.last, last.id == id {
                groups[groups.count - 1] = UpcomingDayGroup(id: id, label: last.label, items: last.items + [item])
            } else {
                groups.append(UpcomingDayGroup(id: id, label: item.airDateFormatted(locale: locale), items: [item]))
            }
        }
        return groups
    }
}
