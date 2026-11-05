import SwiftUI

/// Everything the sloth drawing needs for one frame.
struct SlothPose {
    var phase: Double = 0   // walk cycle position (repeats every 1.0)
    var walk: Double = 0    // 0 = standing still ... 1 = full stride
    var awake: Double = 1   // 0 = asleep ... 1 = awake
    var time: Double = 0    // seconds, drives blinking, breathing and the floating z's
}

/// Flat, minimal sloth walking on a belt, side view, facing right. Drawn in a fixed 320x210 design space.
enum SlothArt {
    static let designSize = CGSize(width: 320, height: 210)

    static let fur = Color(red: 0.70, green: 0.61, blue: 0.51)
    static let furDark = Color(red: 0.55, green: 0.47, blue: 0.39)
    static let face = Color(red: 0.94, green: 0.90, blue: 0.82)
    static let mask = Color(red: 0.27, green: 0.21, blue: 0.19)
    static let belt = Color(red: 0.05, green: 0.27, blue: 0.31)
    static let beltStripe = Color(red: 0.30, green: 0.78, blue: 0.45)

    static let strideAmplitude = 0.42
    /// Belt travel in design pixels per walk cycle, so stripes keep pace with the planted feet.
    static let beltPixelsPerCycle = 2 * strideAmplitude * 50 / 0.6

    /// Limb angle and foot lift for a cycle position: slow backward stance (60%), quick lifted swing (40%).
    static func limb(phase: Double, walk: Double) -> (angle: Double, lift: Double) {
        let p = phase - floor(phase)
        let a = strideAmplitude
        if p < 0.6 { return (a * (1 - 2 * p / 0.6) * walk, 0) }
        let q = (p - 0.6) / 0.4
        let eased = q * q * (3 - 2 * q)
        return (a * (-1 + 2 * eased) * walk, sin(.pi * q) * 9 * walk)
    }

    static func draw(_ ctx: inout GraphicsContext, size: CGSize, pose: SlothPose) {
        let scale = min(size.width / designSize.width, size.height / designSize.height)
        ctx.translateBy(x: (size.width - designSize.width * scale) / 2, y: (size.height - designSize.height * scale) / 2)
        ctx.scaleBy(x: scale, y: scale)

        drawBelt(&ctx, pose: pose)

        // Asleep: the sloth sinks down onto the belt (legs fold) and breathes slowly.
        let sag = 16 * (1 - pose.awake)
        let bob = sin(pose.phase * 4 * .pi) * 2.0 * pose.walk + sin(pose.time * 1.4) * 1.2 * (1 - pose.awake) + sag

        // Soft shadow on the belt.
        ctx.fill(Path(ellipseIn: CGRect(x: 60, y: 172, width: 190, height: 9)), with: .color(.black.opacity(0.18)))

        let frontPivot = CGPoint(x: 196, y: 126 + bob)
        let backPivot = CGPoint(x: 104, y: 128 + bob)
        let frontLength = 52 - sag, backLength = 50 - sag

        // Far-side limbs first (darker), then body, then near-side limbs.
        drawLimb(&ctx, pivot: backPivot, length: backLength, phase: pose.phase + 0.0, pose: pose, color: furDark, width: 16)
        drawLimb(&ctx, pivot: frontPivot, length: frontLength, phase: pose.phase + 0.5, pose: pose, color: furDark, width: 16)

        ctx.fill(Path(ellipseIn: CGRect(x: 65, y: 62 + bob, width: 150, height: 78)), with: .color(fur))

        drawLimb(&ctx, pivot: backPivot, length: backLength, phase: pose.phase + 0.5, pose: pose, color: fur, width: 17)
        drawLimb(&ctx, pivot: frontPivot, length: frontLength, phase: pose.phase + 0.0, pose: pose, color: fur, width: 17)

        drawHead(&ctx, pose: pose, bob: bob)
        if pose.awake < 0.5 { drawZs(&ctx, pose: pose) }
    }

    private static func drawBelt(_ ctx: inout GraphicsContext, pose: SlothPose) {
        let rect = CGRect(x: 18, y: 176, width: 284, height: 20)
        let path = Path(roundedRect: rect, cornerRadius: 10)
        ctx.fill(path, with: .color(belt))
        ctx.drawLayer { layer in
            layer.clip(to: path)
            let spacing = 36.0
            let offset = (-(pose.phase * beltPixelsPerCycle)).truncatingRemainder(dividingBy: spacing)
            var x = rect.minX + offset - spacing
            while x < rect.maxX + spacing {
                layer.fill(Path(CGRect(x: x, y: rect.minY, width: 12, height: rect.height)), with: .color(beltStripe.opacity(0.35)))
                x += spacing
            }
        }
    }

    private static func drawLimb(_ ctx: inout GraphicsContext, pivot: CGPoint, length: Double, phase: Double,
                                 pose: SlothPose, color: Color, width: Double) {
        let g = limb(phase: phase, walk: pose.walk)
        let foot = CGPoint(x: pivot.x + length * sin(g.angle), y: pivot.y + length * cos(g.angle) - g.lift)
        var path = Path()
        path.move(to: pivot)
        path.addLine(to: foot)
        ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round))
        // Three little claws.
        for i in -1...1 {
            var claw = Path()
            claw.move(to: CGPoint(x: foot.x + Double(i) * 3.5, y: foot.y + 3))
            claw.addLine(to: CGPoint(x: foot.x + Double(i) * 3.5 + 2.5, y: foot.y + 10))
            ctx.stroke(claw, with: .color(mask), style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
        }
    }

    static func drawHead(_ ctx: inout GraphicsContext, pose: SlothPose, bob: Double) {
        var h = ctx
        let sag = 16 * (1 - pose.awake)
        // bob already contains the sag; the head follows the body fully down but bobs less.
        h.translateBy(x: 224, y: 80 + (bob - sag) * 0.6 + sag)
        let nod = sin(pose.phase * 2 * .pi) * 0.03 * pose.walk + (1 - pose.awake) * 0.2
        h.rotate(by: .radians(nod))

        h.fill(Path(ellipseIn: CGRect(x: -32, y: -32, width: 64, height: 64)), with: .color(fur))
        h.fill(Path(ellipseIn: CGRect(x: -12, y: -20, width: 50, height: 44)), with: .color(face))

        // Eye mask, tilted like a sloth's.
        var m = h
        m.translateBy(x: 10, y: -5)
        m.rotate(by: .degrees(-22))
        m.fill(Path(ellipseIn: CGRect(x: -13, y: -6.5, width: 26, height: 13)), with: .color(mask))

        let blinking = (pose.time / 4.5).truncatingRemainder(dividingBy: 1) < 0.035
        if pose.awake >= 0.5 && !blinking {
            h.fill(Path(ellipseIn: CGRect(x: 10, y: -9.5, width: 6, height: 6)), with: .color(face))
        } else {
            var lid = Path()
            lid.move(to: CGPoint(x: 6, y: -6))
            lid.addQuadCurve(to: CGPoint(x: 19, y: -6), control: CGPoint(x: 12.5, y: -1.5))
            h.stroke(lid, with: .color(face), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        }

        h.fill(Path(ellipseIn: CGRect(x: 29, y: 2, width: 11, height: 8)), with: .color(mask))
        var smile = Path()
        smile.move(to: CGPoint(x: 20, y: 17))
        smile.addQuadCurve(to: CGPoint(x: 33, y: 14), control: CGPoint(x: 26, y: 22))
        h.stroke(smile, with: .color(mask), style: StrokeStyle(lineWidth: 2, lineCap: .round))
    }

    private static func drawZs(_ ctx: inout GraphicsContext, pose: SlothPose) {
        for i in 0..<3 {
            let t = (pose.time * 0.35 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
            let point = CGPoint(x: 262 + t * 26, y: 52 - t * 38)
            let text = Text("z")
                .font(.system(size: 11 + t * 11, weight: .bold, design: .rounded))
                .foregroundStyle(beltStripe.opacity(sin(.pi * t) * 0.9))
            ctx.draw(text, at: point)
        }
    }

    /// Just the head, centred and scaled to fit `size`; used for small icons (Live Activity, Dynamic Island).
    static func drawFace(_ ctx: inout GraphicsContext, size: CGSize, pose: SlothPose = SlothPose(phase: 0, walk: 0, awake: 1, time: 1)) {
        let scale = min(size.width, size.height) / 78
        ctx.translateBy(x: size.width / 2 - 4 * scale, y: size.height / 2)
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -224, y: -80)   // drawHead positions the head at (224, 80)
        drawHead(&ctx, pose: pose, bob: 0)
    }
}
