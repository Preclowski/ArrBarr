import SwiftUI

/// Draws the posters around `position` for one mode, once per display tick while the Shelf moves.
struct ShelfScene: View {
    let mode: ShelfMode
    let entries: [LibraryEntry]
    let posters: ShelfPosters
    let position: Double
    /// Posters per second.
    let velocity: Double
    let time: Double
    let size: CGSize

    private static let shaders = ShaderLibrary.bundle(.module)

    /// The selected poster's width in every mode, so switching modes never resizes it.
    static func heroWidth(for size: CGSize) -> CGFloat {
        min(size.width * 0.66, size.height * 0.66 / 1.5)
    }

    private var width: CGFloat { Self.heroWidth(for: size) }
    private var height: CGFloat { width * 1.5 }
    private var center: CGPoint { CGPoint(x: size.width / 2, y: size.height * 0.39) }

    private func window(_ radius: Int) -> [Int] {
        guard !entries.isEmpty else { return [] }
        // Virtual indices: the library repeats, so neither end is clamped.
        return Array((Int(position.rounded(.down)) - radius)...(Int(position.rounded(.up)) + radius))
    }

    var body: some View {
        switch mode {
        case .coverFlow: coverFlow
        case .warp: warp
        case .morph: morph
        case .tunnel: tunnel
        case .globe: globe
        }
    }

    private func poster(_ i: Int, width w: CGFloat? = nil) -> some View {
        let entry = entries[i.shelfWrapped(into: entries.count)]
        return ShelfPoster(entry: entry, image: posters.image(for: entry.id), width: w ?? width)
    }

    private struct Placement {
        var x: CGFloat = 0
        var y: CGFloat = 0
        var yaw: Double = 0
        var tilt: Double = 0
        var pitch: Double = 0
        var scale: CGFloat = 1
        var opacity: Double = 1
        var depth: Double = 0
        var dim: Double = 0
    }

    // MARK: - Cover Flow

    private func coverFlowPlacement(_ i: Int) -> Placement {
        let d = Double(i) - position
        let a = abs(d)
        let side: Double = d < 0 ? -1 : 1
        var p = Placement()
        p.x = CGFloat(a < 1 ? d * 0.6 : side * (0.6 + (a - 1) * 0.15)) * width
        p.yaw = a < 1 ? -d * 60 : -side * 60
        p.scale = CGFloat(1 - min(a, 1) * 0.42)
        p.opacity = a > 6 ? max(0, 7 - a) : 1
        p.depth = -a
        return p
    }

    private func reflection(_ i: Int) -> some View {
        poster(i)
            .scaleEffect(x: 1, y: -1)
            .mask(LinearGradient(colors: [.white.opacity(0.25), .clear], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.3)))
            .offset(y: height + 3)
    }

    private var coverFlow: some View {
        ZStack {
            ForEach(window(7), id: \.self) { i in
                let p = coverFlowPlacement(i)
                poster(i)
                    .overlay(alignment: .top) {
                        if abs(Double(i) - position) < 3 { reflection(i) }
                    }
                    .rotation3DEffect(.degrees(p.yaw), axis: (x: 0, y: 1, z: 0), perspective: 0.4)
                    .scaleEffect(p.scale)
                    .offset(x: p.x)
                    .opacity(p.opacity)
                    .zIndex(p.depth)
            }
        }
        .position(center)
    }

    // MARK: - Warp

    private var warp: some View {
        let w = width
        let spacing = w * 1.04
        let smear = Float(max(-60, min(60, velocity * Double(spacing) / 60)))
        return ZStack {
            ForEach(window(4), id: \.self) { i in
                poster(i, width: w).offset(x: (Double(i) - position) * spacing)
            }
        }
        .position(center)
        .frame(width: size.width, height: size.height)
        .layerEffect(
            Self.shaders.shelfWarp(.float2(size), .float(Float(w / 2 + 6)), .float(smear), .float(Float(time))),
            maxSampleOffset: CGSize(width: 70, height: size.height)
        )
    }

    // MARK: - Morph

    private var morph: some View {
        let w = width
        let h = height
        let base = Int(position.rounded(.down))
        let next = base + 1
        let progress = min(max(position - Double(base), 0), 1)
        return Rectangle()
            .fill(.white)
            .frame(width: w, height: h)
            .colorEffect(Self.shaders.shelfMorph(
                .float2(CGSize(width: w, height: h)),
                .image(texture(base)), .image(texture(next)),
                .float(Float(progress)), .float(Float(time))
            ))
            .clipShape(RoundedRectangle(cornerRadius: w * 0.04, style: .continuous))
            .position(center)
    }

    private func texture(_ i: Int) -> Image {
        if !entries.isEmpty, let image = posters.image(for: entries[i.shelfWrapped(into: entries.count)].id) {
            return Image(platformImage: image)
        }
        return Image(size: CGSize(width: 2, height: 3)) { ctx in
            ctx.fill(Path(CGRect(x: 0, y: 0, width: 2, height: 3)), with: .color(Color(white: 0.18)))
        }
    }

    // MARK: - Tunnel

    private func tunnelPlacement(_ i: Int, ring: CGFloat) -> Placement? {
        let z = Double(i) - position
        guard z > -1.1 else { return nil }
        let scale = z >= 0 ? 1 / (1 + z * 0.32) : 1 + (-z) * 2.4
        let theta = Double(i) * 2.39996
        let spread = z >= 0 ? min(z, 1) : 1 + (-z) * 3
        var p = Placement()
        p.scale = CGFloat(scale)
        p.tilt = sin(theta) * 9 * min(abs(z), 1)
        p.x = CGFloat(cos(theta) * spread * scale) * ring
        p.y = CGFloat(sin(theta) * 0.8 * spread * scale) * ring
        p.opacity = z < 0 ? max(0, 1 + z) : min(1, (12 - z) / 4)
        p.depth = -z
        return p
    }

    private var tunnel: some View {
        let ring = size.width * 0.3
        let strength = Float(min(0.4, abs(velocity) * 0.016))
        return ZStack {
            ForEach(window(12).reversed(), id: \.self) { i in
                if let p = tunnelPlacement(i, ring: ring) {
                    poster(i)
                        .scaleEffect(p.scale)
                        .rotationEffect(.degrees(p.tilt))
                        .offset(x: p.x, y: p.y)
                        .opacity(p.opacity)
                        .zIndex(p.depth)
                }
            }
        }
        .position(center)
        .frame(width: size.width, height: size.height)
        .layerEffect(
            Self.shaders.shelfZoomBlur(.float2(center), .float(strength)),
            maxSampleOffset: .zero
        )
    }
}

extension ShelfScene {
    // MARK: - Globe

    /// Posters ride a helix wound around a planet; scrolling rolls the planet so the current one faces you
    /// and lifts off the surface.
    private func globeAngles(_ x: Double) -> (lon: Double, lat: Double) {
        (x * 0.6283, 0.95 * sin(x * 2 * .pi / 23))
    }

    private func globePlacement(_ i: Int, radius r: CGFloat, poster w: CGFloat) -> Placement? {
        let here = globeAngles(position), there = globeAngles(Double(i))
        let lon = there.lon - here.lon
        let x = cos(there.lat) * sin(lon)
        let y = sin(there.lat)
        let z = cos(there.lat) * cos(lon)
        let y2 = y * cos(here.lat) - z * sin(here.lat)
        let z2 = y * sin(here.lat) + z * cos(here.lat)
        guard z2 > -0.15 else { return nil }
        let persp = 2.6 / (2.6 - z2)
        let lift = max(0, 1 - abs(Double(i) - position))
        // Lifted fully, the front poster (z = 1) reaches the shared hero width.
        let liftScale = Double(width / (w * 2.6 / 1.6))
        var p = Placement()
        p.x = CGFloat(x * persp) * r
        p.y = CGFloat(-y2 * persp) * r
        p.yaw = atan2(x, z2) * 180 / .pi * (1 - lift)
        p.pitch = -asin(max(-1, min(1, y2))) * 180 / .pi * (1 - lift)
        p.scale = CGFloat(persp * (1 + lift * (liftScale - 1)))
        // Fades toward the limb and toward the end of the drawn window, so nothing pops in or out.
        let limb = Self.smoothstep((z2 + 0.15) / 0.55)
        let reach = Self.smoothstep((18 - abs(Double(i) - position)) / 6)
        p.opacity = limb * reach
        p.dim = (1 - max(z2, 0)) * 0.5 * (1 - lift)
        p.depth = z2 + lift * 2
        return p
    }

    private static func smoothstep(_ x: Double) -> Double {
        let t = min(max(x, 0), 1)
        return t * t * (3 - 2 * t)
    }

    var globe: some View {
        let r = min(size.width, size.height) * 0.46
        let w = r * 0.42
        return ZStack {
            let here = globeAngles(position)
            // The silhouette of a unit sphere seen from 2.6 radii away spans 2.6 / √(2.6² − 1) ≈ 1.083 r.
            Circle()
                .fill(Color.black)
                .frame(width: r * 2.166, height: r * 2.166)
                .shadow(color: Color(red: 0.3, green: 0.55, blue: 1).opacity(0.55), radius: 30)
            Rectangle()
                .fill(.white)
                .frame(width: r * 2.2, height: r * 2.2)
                .colorEffect(Self.shaders.shelfEarth(.float(Float(r)), .float(Float(here.lon)), .float(Float(here.lat))))
            ForEach(window(20), id: \.self) { i in
                if let p = globePlacement(i, radius: r, poster: w) {
                    poster(i, width: w)
                        .overlay(Color.black.opacity(p.dim))
                        .rotation3DEffect(.degrees(p.yaw), axis: (x: 0, y: 1, z: 0), perspective: 0.4)
                        .rotation3DEffect(.degrees(p.pitch), axis: (x: 1, y: 0, z: 0), perspective: 0.4)
                        .scaleEffect(p.scale)
                        .offset(x: p.x, y: p.y)
                        .opacity(p.opacity)
                        .zIndex(p.depth)
                }
            }
        }
        .position(center)
    }
}

struct ShelfPoster: View {
    let entry: LibraryEntry
    let image: PlatformImage?
    let width: CGFloat

    var body: some View {
        ZStack {
            if let image {
                Image(platformImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(colors: [Color(white: 0.2), Color(white: 0.08)], startPoint: .top, endPoint: .bottom)
                Text(entry.title)
                    .font(.system(size: width * 0.09, weight: .bold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(width * 0.08)
            }
        }
        .frame(width: width, height: width * 1.5)
        .overlay(alignment: .topTrailing) {
            if entry.watched && ConfigStore.shared.showWatchedIndicator {
                // The detail hero's size (`RemotePoster`'s 12 pt ribbon), smaller on the far posters.
                WatchedCornerBadge(side: min(12 * 1.6, width * 0.14), flat: true)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: width * 0.04, style: .continuous))
    }
}
