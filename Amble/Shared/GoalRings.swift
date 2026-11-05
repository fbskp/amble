import SwiftUI

/// Two rings (walks outside, minutes inside) with the sloth's face in the middle.
/// `diameter` is the outer ring's size; the stroke extends half a line width beyond it.
struct GoalRings: View {
    var walkProgress: Double
    var minuteProgress: Double
    var diameter: CGFloat = 150

    var body: some View {
        let line = diameter * 0.107
        ZStack {
            ring(progress: walkProgress, diameter: diameter, line: line, colors: [Theme.teal, Theme.green])
            ring(progress: minuteProgress, diameter: diameter * 0.747, line: line, colors: [Theme.textTeal, Theme.mint])
            SlothFaceView().frame(width: diameter * 0.293, height: diameter * 0.293)
        }
        .frame(width: diameter, height: diameter)
    }

    private func ring(progress: Double, diameter: CGFloat, line: CGFloat, colors: [Color]) -> some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.08), lineWidth: line)
            Circle()
                .trim(from: 0, to: max(progress, 0.001))
                .stroke(AngularGradient(colors: colors, center: .center, startAngle: .degrees(0), endAngle: .degrees(360 * max(progress, 0.05))),
                        style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .opacity(progress > 0 ? 1 : 0)   // a zero-length arc would still show its round caps
                .animation(.easeOut(duration: 0.6), value: progress)
        }
        .frame(width: diameter, height: diameter)
    }
}
