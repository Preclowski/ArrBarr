import SwiftUI

/// Full-size artwork viewer: click a poster or a profile photo, see it big —
/// and pinch to zoom into it. The only place in the app that claims the
/// magnify gesture, so a pinch here zooms instead of falling through as a
/// stray click.
struct PosterLightbox: View {
    let url: URL?
    let title: String
    @Environment(\.dismiss) private var dismiss

    @State private var scale: CGFloat = 1
    /// Scale at the moment the current pinch started.
    @State private var baseScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var baseOffset: CGSize = .zero

    private let minScale: CGFloat = 1
    private let maxScale: CGFloat = 5
    private let size = CGSize(width: 560, height: 760)

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                if scale > 1 {
                    Text("\(Int(scale.rounded()))×")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)
                    Button { reset(animated: true) } label: { Text("Reset", bundle: .module) }
                }
                Button { dismiss() } label: { Text("Done", bundle: .module) }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)

            RemoteImage(url: url, contentMode: .fit)
                .frame(width: size.width, height: size.height)
                .scaleEffect(scale)
                .offset(offset)
                .frame(width: size.width, height: size.height)
                .clipped()
                .contentShape(Rectangle())
                .gesture(magnify)
                // Panning only makes sense once the art is bigger than the
                // window it sits in.
                .gesture(scale > 1 ? pan : nil)
                // Zoom is the pinch's job alone — a double-click toggle also
                // fired from the very click that opened this sheet, so it
                // came up already zoomed.
                .onTapGesture { if scale <= 1 { dismiss() } }
                .pointerStyle(scale > 1 ? .grabIdle : .zoomIn)
                .animation(.easeOut(duration: 0.15), value: scale)
        }
        .background(.black)
        .colorScheme(.dark)
    }

    private var magnify: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                scale = clampScale(baseScale * value.magnification)
            }
            .onEnded { _ in
                baseScale = scale
                if scale <= minScale { reset(animated: true) } else { clampOffset() }
            }
    }

    private var pan: some Gesture {
        DragGesture()
            .onChanged { value in
                offset = CGSize(width: baseOffset.width + value.translation.width,
                                height: baseOffset.height + value.translation.height)
            }
            .onEnded { _ in
                clampOffset()
                baseOffset = offset
            }
    }

    private func reset(animated: Bool) {
        func apply() {
            scale = 1
            baseScale = 1
            offset = .zero
            baseOffset = .zero
        }
        if animated { withAnimation(.easeOut(duration: 0.2)) { apply() } } else { apply() }
    }

    private func clampScale(_ value: CGFloat) -> CGFloat {
        min(max(value, minScale), maxScale)
    }

    /// Keep the artwork covering the frame — panning must not drag empty
    /// black in from the edges.
    private func clampOffset() {
        let slack = CGSize(width: size.width * (scale - 1) / 2,
                           height: size.height * (scale - 1) / 2)
        offset = CGSize(width: min(max(offset.width, -slack.width), slack.width),
                        height: min(max(offset.height, -slack.height), slack.height))
        baseOffset = offset
    }
}
