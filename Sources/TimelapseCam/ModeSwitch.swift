import SwiftUI

/// Slider-style switch between Timelapse and Video.
/// Drag the pill across and it follows your finger, flipping at the midpoint with a tap.
/// Let go and it springs to the nearest side. A plain tap also switches sides.
struct ModeSwitch: View {
    @Binding var isVideo: Bool
    var disabled: Bool

    @State private var liveX: CGFloat?      // pill position while the finger is down
    @State private var grabbedX: CGFloat?   // pill position when the drag began

    private let width: CGFloat = 190
    private let height: CGFloat = 28
    private let inset: CGFloat = 3
    private var pillWidth: CGFloat { (width - inset * 2) / 2 }
    private var restX: CGFloat { isVideo ? pillWidth : 0 }
    private var isDragging: Bool { liveX != nil }

    var body: some View {
        let pillX = liveX ?? restX

        ZStack(alignment: .leading) {
            Capsule()
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(isDragging ? 0.3 : 0.2), radius: isDragging ? 8 : 4, y: 2)
                .frame(width: pillWidth + (isDragging ? 8 : 0), height: height)
                .offset(x: pillX - (isDragging ? 4 : 0))
                .animation(.spring(response: 0.3, dampingFraction: 0.65), value: isDragging)

            HStack(spacing: 0) {
                label("Timelapse", selected: !isVideo)
                label("Video", selected: isVideo)
            }
        }
        .frame(width: pillWidth * 2, height: height)
        .contentShape(Capsule())
        .gesture(drag)
        .padding(inset)
        .background(Capsule().fill(.primary.opacity(0.08)))
        .opacity(disabled ? 0.5 : 1)
        .disabled(disabled)
    }

    private func label(_ title: String, selected: Bool) -> some View {
        Text(title)
            .font(.callout.weight(.medium))
            .foregroundStyle(selected ? Color.primary : Color.secondary)
            .frame(width: pillWidth, height: height)
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let start = grabbedX ?? restX
                grabbedX = start
                let x = min(max(start + value.translation.width, 0), pillWidth)
                liveX = x   // follows the finger, no animation

                let wantVideo = x > pillWidth / 2
                if wantVideo != isVideo {
                    isVideo = wantVideo
                    Haptics.tap()
                }
            }
            .onEnded { value in
                // A tap (barely any movement) picks the side that was touched.
                if abs(value.translation.width) <= 4 {
                    let target = value.location.x > pillWidth
                    if target != isVideo {
                        isVideo = target
                        Haptics.tap()
                    }
                }
                grabbedX = nil
                // Spring the pill to whichever side it ended on.
                withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                    liveX = nil
                }
            }
    }
}
