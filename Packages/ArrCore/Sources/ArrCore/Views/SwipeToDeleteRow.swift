import SwiftUI

extension View {
    /// iOS swipe-to-delete for queue rows. The iOS queue is a ScrollView (not
    /// a List), so `.swipeActions` isn't available — this reveals a red trash
    /// action on a **left** swipe (the iOS-standard delete direction) and
    /// deletes when tapped. No-op on macOS (hover actions cover it there).
    @ViewBuilder
    func queueSwipeToDelete(onDelete: @escaping () -> Void) -> some View {
        #if os(iOS)
        modifier(SwipeToDeleteModifier(onDelete: onDelete))
        #else
        self
        #endif
    }
}

#if os(iOS)
private struct SwipeToDeleteModifier: ViewModifier {
    let onDelete: () -> Void

    /// Negative = revealed (row shifted left, trash showing on the right).
    @State private var offset: CGFloat = 0
    private let actionWidth: CGFloat = 84
    private let commitThreshold: CGFloat = 56

    func body(content: Content) -> some View {
        ZStack(alignment: .trailing) {
            // Trash revealed on the trailing edge during a left swipe.
            Button {
                close()
                onDelete()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: actionWidth)
                    .frame(maxHeight: .infinity)
            }
            .buttonStyle(.plain)
            .background(Color.red)
            .opacity(offset < -1 ? 1 : 0)

            content
                .background(Color(.systemBackground))
                .offset(x: offset)
                // Simultaneous so the ScrollView still owns vertical panning
                // and the row keeps its tap-to-detail gesture; we only react
                // to horizontally-dominant drags.
                .simultaneousGesture(
                    DragGesture(minimumDistance: 14)
                        .onChanged { v in
                            guard abs(v.translation.width) > abs(v.translation.height) else { return }
                            // Left swipe only (negative translation).
                            offset = min(0, max(-actionWidth, v.translation.width))
                        }
                        .onEnded { v in
                            let horizontal = abs(v.translation.width) > abs(v.translation.height)
                            withAnimation(.snappy(duration: 0.2)) {
                                offset = (horizontal && v.translation.width < -commitThreshold) ? -actionWidth : 0
                            }
                        }
                )
        }
        .clipped()
    }

    private func close() {
        withAnimation(.snappy(duration: 0.2)) { offset = 0 }
    }
}
#endif
