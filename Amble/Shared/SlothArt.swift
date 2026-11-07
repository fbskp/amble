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

    static func drawBelt(_ ctx: inout GraphicsContext, pose: SlothPose, pixelsPerCycle: Double = beltPixelsPerCycle) {
        let rect = CGRect(x: 18, y: 176, width: 284, height: 20)
        let path = Path(roundedRect: rect, cornerRadius: 10)
        ctx.fill(path, with: .color(belt))
        ctx.drawLayer { layer in
            layer.clip(to: path)
            let spacing = 36.0
            let offset = (-(pose.phase * pixelsPerCycle)).truncatingRemainder(dividingBy: spacing)
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

// MARK: - Companions

/// The animals that can walk on the belt. Raw values match `AnimalID` in AmbleCore, which decides what is unlocked;
/// this type lives here because the widgets draw the animal too and do not link AmbleCore.
enum Companion: String, CaseIterable, Identifiable {
    case sloth, snail, tortoise

    var id: String { rawValue }

    private static let key = "companion"
    private static var defaults: UserDefaults? { UserDefaults(suiteName: GoalsSnapshotStore.appGroup) }

    /// The animal chosen on the Awards tab, shared with the widgets through the App Group.
    static var current: Companion {
        get { defaults?.string(forKey: key).flatMap(Companion.init(rawValue:)) ?? .sloth }
        set { defaults?.set(newValue.rawValue, forKey: key) }
    }

    func draw(_ ctx: inout GraphicsContext, size: CGSize, pose: SlothPose) {
        switch self {
        case .sloth: SlothArt.draw(&ctx, size: size, pose: pose)
        case .snail: SnailArt.draw(&ctx, size: size, pose: pose)
        case .tortoise: TortoiseArt.draw(&ctx, size: size, pose: pose)
        }
    }

    func drawFace(_ ctx: inout GraphicsContext, size: CGSize) {
        switch self {
        case .sloth: SlothArt.drawFace(&ctx, size: size)
        case .snail: SnailArt.drawFace(&ctx, size: size)
        case .tortoise: TortoiseArt.drawFace(&ctx, size: size)
        }
    }
}

private func fit(_ ctx: inout GraphicsContext, size: CGSize) {
    let scale = min(size.width / SlothArt.designSize.width, size.height / SlothArt.designSize.height)
    ctx.translateBy(x: (size.width - SlothArt.designSize.width * scale) / 2, y: (size.height - SlothArt.designSize.height * scale) / 2)
    ctx.scaleBy(x: scale, y: scale)
}

private func blinking(_ pose: SlothPose) -> Bool { (pose.time / 4.5).truncatingRemainder(dividingBy: 1) < 0.035 }

private func sleepyEye(_ ctx: inout GraphicsContext, at p: CGPoint, color: Color) {
    var lid = Path()
    lid.move(to: CGPoint(x: p.x - 5, y: p.y))
    lid.addQuadCurve(to: CGPoint(x: p.x + 5, y: p.y), control: CGPoint(x: p.x, y: p.y + 4))
    ctx.stroke(lid, with: .color(color), style: StrokeStyle(lineWidth: 2, lineCap: .round))
}

/// Flat tortoise, side view, facing right. Short legs, a domed shell, and a head that tucks in while asleep.
enum TortoiseArt {
    static let shell = Color(red: 0.36, green: 0.47, blue: 0.28)
    static let shellDark = Color(red: 0.26, green: 0.36, blue: 0.20)
    static let rim = Color(red: 0.80, green: 0.74, blue: 0.55)
    static let skin = Color(red: 0.69, green: 0.72, blue: 0.46)
    static let skinDark = Color(red: 0.55, green: 0.59, blue: 0.36)
    static let ink = Color(red: 0.20, green: 0.18, blue: 0.14)

    static let legLength = 28.0
    /// Feet travel about 2 * legLength * sin(strideAmplitude) per cycle; the belt moves the same distance.
    static let beltPixelsPerCycle = 2 * legLength * sin(SlothArt.strideAmplitude)

    static func draw(_ ctx: inout GraphicsContext, size: CGSize, pose: SlothPose) {
        fit(&ctx, size: size)
        SlothArt.drawBelt(&ctx, pose: pose, pixelsPerCycle: beltPixelsPerCycle)

        let sag = 7 * (1 - pose.awake)
        let bob = sin(pose.phase * 4 * .pi) * 1.4 * pose.walk + sin(pose.time * 1.2) * 0.8 * (1 - pose.awake) + sag
        let length = legLength - sag
        let reach = 0.1 + 0.9 * pose.awake   // how far the head sticks out

        ctx.fill(Path(ellipseIn: CGRect(x: 60, y: 170, width: 190, height: 8)), with: .color(.black.opacity(0.18)))

        let frontPivot = CGPoint(x: 194, y: 144 + sag * 0.3)
        let backPivot = CGPoint(x: 106, y: 144 + sag * 0.3)
        drawLimb(&ctx, pivot: backPivot, length: length, phase: pose.phase, pose: pose, color: skinDark)
        drawLimb(&ctx, pivot: frontPivot, length: length, phase: pose.phase + 0.5, pose: pose, color: skinDark)

        // Tail and head, behind the shell so that a tucked-in head disappears into it.
        ctx.fill(Path(ellipseIn: CGRect(x: 58, y: 136 + bob, width: 26, height: 12)), with: .color(skin))
        let headCentre = CGPoint(x: 204 + 36 * reach, y: 120 + bob * 0.8 + (1 - reach) * 14)
        drawHead(&ctx, at: headCentre, pose: pose, neckFrom: CGPoint(x: 190, y: 128 + bob))

        // The near legs also go behind the shell, which then sits on top of them.
        drawLimb(&ctx, pivot: backPivot, length: length, phase: pose.phase + 0.5, pose: pose, color: skin)
        drawLimb(&ctx, pivot: frontPivot, length: length, phase: pose.phase, pose: pose, color: skin)

        drawShell(&ctx, bob: bob)

        if pose.awake < 0.5 { zs(&ctx, pose: pose) }
    }

    private static func drawShell(_ ctx: inout GraphicsContext, bob: Double) {
        // A dome with a flat base: the top of a tall ellipse, cut off where the rim starts.
        let dome = Path(ellipseIn: CGRect(x: 64, y: 58 + bob, width: 172, height: 150))
            .intersection(Path(CGRect(x: 0, y: 0, width: 320, height: 146 + bob)))
        ctx.fill(dome, with: .color(shell))
        ctx.drawLayer { layer in
            layer.clip(to: dome)
            let c = CGPoint(x: 150, y: 100 + bob)
            var hex = Path()
            for i in 0..<6 {
                let a = Double(i) * .pi / 3
                let p = CGPoint(x: c.x + 28 * cos(a), y: c.y + 24 * sin(a))
                i == 0 ? hex.move(to: p) : hex.addLine(to: p)
                var spoke = Path()
                spoke.move(to: p)
                spoke.addLine(to: CGPoint(x: c.x + 130 * cos(a), y: c.y + 110 * sin(a)))
                layer.stroke(spoke, with: .color(shellDark), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            }
            hex.closeSubpath()
            layer.fill(hex, with: .color(shellDark.opacity(0.55)))
            layer.stroke(hex, with: .color(shellDark), style: StrokeStyle(lineWidth: 3, lineJoin: .round))
        }
        // Lighter rim along the bottom edge.
        ctx.fill(Path(roundedRect: CGRect(x: 66, y: 136 + bob, width: 168, height: 14), cornerRadius: 7), with: .color(rim))
    }

    private static func drawLimb(_ ctx: inout GraphicsContext, pivot: CGPoint, length: Double, phase: Double,
                                 pose: SlothPose, color: Color) {
        let g = SlothArt.limb(phase: phase, walk: pose.walk)
        let foot = CGPoint(x: pivot.x + length * sin(g.angle), y: pivot.y + length * cos(g.angle) - g.lift)
        var path = Path()
        path.move(to: pivot)
        path.addLine(to: foot)
        ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 21, lineCap: .round))
    }

    private static func drawHead(_ ctx: inout GraphicsContext, at c: CGPoint, pose: SlothPose, neckFrom: CGPoint) {
        var neck = Path()
        neck.move(to: neckFrom)
        neck.addLine(to: c)
        ctx.stroke(neck, with: .color(skin), style: StrokeStyle(lineWidth: 24, lineCap: .round))
        ctx.fill(Path(ellipseIn: CGRect(x: c.x - 22, y: c.y - 17, width: 44, height: 34)), with: .color(skin))
        face(&ctx, at: c, pose: pose)
    }

    private static func face(_ ctx: inout GraphicsContext, at c: CGPoint, pose: SlothPose) {
        let eye = CGPoint(x: c.x + 8, y: c.y - 4)
        if pose.awake >= 0.5 && !blinking(pose) {
            ctx.fill(Path(ellipseIn: CGRect(x: eye.x - 3.5, y: eye.y - 3.5, width: 7, height: 7)), with: .color(ink))
            ctx.fill(Path(ellipseIn: CGRect(x: eye.x - 1.5, y: eye.y - 2.5, width: 2.4, height: 2.4)), with: .color(.white))
        } else {
            sleepyEye(&ctx, at: eye, color: ink)
        }
        var smile = Path()
        smile.move(to: CGPoint(x: c.x + 6, y: c.y + 7))
        smile.addQuadCurve(to: CGPoint(x: c.x + 18, y: c.y + 5), control: CGPoint(x: c.x + 12, y: c.y + 12))
        ctx.stroke(smile, with: .color(ink), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        ctx.fill(Path(ellipseIn: CGRect(x: c.x + 15, y: c.y - 6, width: 3, height: 2.2)), with: .color(ink.opacity(0.6)))
    }

    private static func zs(_ ctx: inout GraphicsContext, pose: SlothPose) {
        for i in 0..<3 {
            let t = (pose.time * 0.35 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
            let text = Text("z").font(.system(size: 11 + t * 11, weight: .bold, design: .rounded))
                .foregroundStyle(SlothArt.beltStripe.opacity(sin(.pi * t) * 0.9))
            ctx.draw(text, at: CGPoint(x: 252 + t * 26, y: 70 - t * 38))
        }
    }

    static func drawFace(_ ctx: inout GraphicsContext, size: CGSize) {
        let scale = min(size.width, size.height) / 78
        ctx.translateBy(x: size.width / 2 + 5 * scale, y: size.height / 2 + 2 * scale)
        ctx.scaleBy(x: scale, y: scale)
        // The shell dome behind, the head in front of it.
        let dome = Path(ellipseIn: CGRect(x: -38, y: -32, width: 58, height: 54))
        ctx.fill(dome, with: .color(shell))
        ctx.drawLayer { layer in
            layer.clip(to: dome)
            var hex = Path()
            for i in 0..<6 {
                let a = Double(i) * .pi / 3
                let p = CGPoint(x: -14 + 11 * cos(a), y: -8 + 10 * sin(a))
                i == 0 ? hex.move(to: p) : hex.addLine(to: p)
            }
            hex.closeSubpath()
            layer.stroke(hex, with: .color(shellDark), style: StrokeStyle(lineWidth: 3, lineJoin: .round))
        }
        ctx.fill(Path(ellipseIn: CGRect(x: -10, y: -8, width: 42, height: 34)), with: .color(skin))
        face(&ctx, at: CGPoint(x: 11, y: 9), pose: SlothPose(phase: 0, walk: 0, awake: 1, time: 1))
    }
}

/// Flat snail, side view, facing right. It glides on a rippling foot and its eye stalks droop when it sleeps.
enum SnailArt {
    static let shell = Color(red: 0.82, green: 0.47, blue: 0.30)
    static let swirl = Color(red: 0.62, green: 0.31, blue: 0.21)
    static let skin = Color(red: 0.83, green: 0.77, blue: 0.60)
    static let skinDark = Color(red: 0.70, green: 0.63, blue: 0.47)
    static let ink = Color(red: 0.22, green: 0.17, blue: 0.14)

    static let rippleSpacing = 22.0
    static let beltPixelsPerCycle = rippleSpacing

    static func draw(_ ctx: inout GraphicsContext, size: CGSize, pose: SlothPose) {
        fit(&ctx, size: size)
        SlothArt.drawBelt(&ctx, pose: pose, pixelsPerCycle: beltPixelsPerCycle)

        let sag = 4 * (1 - pose.awake)
        let sway = sin(pose.phase * 2 * .pi) * 1.5 * pose.walk
        let rise = sin(pose.time * 1.2) * 0.8 * (1 - pose.awake)

        ctx.fill(Path(ellipseIn: CGRect(x: 56, y: 171, width: 196, height: 8)), with: .color(.black.opacity(0.18)))

        // Foot, with ripples running along it while it moves.
        let foot = Path(roundedRect: CGRect(x: 62, y: 150 + sag, width: 186, height: 22 - sag), cornerRadius: 11)
        ctx.fill(foot, with: .color(skin))
        ctx.drawLayer { layer in
            layer.clip(to: foot)
            var x = 62 - rippleSpacing + (pose.phase * rippleSpacing).truncatingRemainder(dividingBy: rippleSpacing)
            while x < 250 {
                var arc = Path()
                arc.move(to: CGPoint(x: x, y: 152 + sag))
                arc.addQuadCurve(to: CGPoint(x: x, y: 172), control: CGPoint(x: x + 7 * pose.walk, y: 162))
                layer.stroke(arc, with: .color(skinDark.opacity(0.55 * pose.walk)), style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
                x += rippleSpacing
            }
        }

        // Neck and head.
        let head = CGPoint(x: 242 + sway, y: 118 + sag + rise)
        var neck = Path()
        neck.move(to: CGPoint(x: 220, y: 160 + sag))
        neck.addQuadCurve(to: head, control: CGPoint(x: 246, y: 150))
        ctx.stroke(neck, with: .color(skin), style: StrokeStyle(lineWidth: 26, lineCap: .round))
        ctx.fill(Path(ellipseIn: CGRect(x: head.x - 15, y: head.y - 14, width: 34, height: 28)), with: .color(skin))
        drawStalks(&ctx, head: head, pose: pose)
        var smile = Path()
        smile.move(to: CGPoint(x: head.x + 5, y: head.y + 6))
        smile.addQuadCurve(to: CGPoint(x: head.x + 16, y: head.y + 4), control: CGPoint(x: head.x + 10, y: head.y + 11))
        ctx.stroke(smile, with: .color(ink), style: StrokeStyle(lineWidth: 2, lineCap: .round))

        drawShell(&ctx, centre: CGPoint(x: 136, y: 108 + sag + rise))
        if pose.awake < 0.5 { zs(&ctx, pose: pose) }
    }

    private static func drawStalks(_ ctx: inout GraphicsContext, head: CGPoint, pose: SlothPose) {
        let len = 10 + 28 * pose.awake
        for (i, dx) in [-2.0, 11.0].enumerated() {
            let base = CGPoint(x: head.x + dx, y: head.y - 10)
            let wobble = sin(pose.time * 1.6 + Double(i)) * 2 * pose.awake
            // Awake: stalks point up and slightly forward; asleep: they flop forward and down.
            let tip = CGPoint(x: base.x + 8 + 14 * (1 - pose.awake) + wobble, y: base.y - len * pose.awake + 8 * (1 - pose.awake))
            var stalk = Path()
            stalk.move(to: base)
            stalk.addQuadCurve(to: tip, control: CGPoint(x: base.x + 2, y: (base.y + tip.y) / 2))
            ctx.stroke(stalk, with: .color(skin), style: StrokeStyle(lineWidth: 5, lineCap: .round))
            ctx.fill(Path(ellipseIn: CGRect(x: tip.x - 6, y: tip.y - 6, width: 12, height: 12)), with: .color(skin))
            if pose.awake >= 0.5 && !blinking(pose) {
                ctx.fill(Path(ellipseIn: CGRect(x: tip.x - 1.5, y: tip.y - 3.5, width: 6.5, height: 6.5)), with: .color(ink))
            } else {
                sleepyEye(&ctx, at: tip, color: ink)
            }
        }
    }

    private static func drawShell(_ ctx: inout GraphicsContext, centre c: CGPoint) {
        ctx.fill(Path(ellipseIn: CGRect(x: c.x - 52, y: c.y - 50, width: 104, height: 100)), with: .color(shell))
        var spiral = Path()
        var t = 0.0
        while t < 9.2 {
            let r = 3 + t * 4.6
            let p = CGPoint(x: c.x + r * cos(t + 0.6), y: c.y + r * sin(t + 0.6))
            t == 0 ? spiral.move(to: p) : spiral.addLine(to: p)
            t += 0.15
        }
        ctx.stroke(spiral, with: .color(swirl), style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
    }

    private static func zs(_ ctx: inout GraphicsContext, pose: SlothPose) {
        for i in 0..<3 {
            let t = (pose.time * 0.35 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
            let text = Text("z").font(.system(size: 11 + t * 11, weight: .bold, design: .rounded))
                .foregroundStyle(SlothArt.beltStripe.opacity(sin(.pi * t) * 0.9))
            ctx.draw(text, at: CGPoint(x: 262 + t * 26, y: 52 - t * 38))
        }
    }

    static func drawFace(_ ctx: inout GraphicsContext, size: CGSize) {
        let scale = min(size.width, size.height) / 70
        ctx.translateBy(x: size.width / 2, y: size.height / 2 + 6 * scale)
        ctx.scaleBy(x: scale, y: scale)
        ctx.fill(Path(ellipseIn: CGRect(x: -26, y: -16, width: 52, height: 42)), with: .color(skin))
        drawStalks(&ctx, head: CGPoint(x: -2, y: 4), pose: SlothPose(phase: 0, walk: 0, awake: 0.9, time: 1))
        var smile = Path()
        smile.move(to: CGPoint(x: -9, y: 12))
        smile.addQuadCurve(to: CGPoint(x: 9, y: 12), control: CGPoint(x: 0, y: 21))
        ctx.stroke(smile, with: .color(ink), style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
    }
}
