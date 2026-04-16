import SwiftUI

// MARK: - User-pickable style + color

enum BuddyStyle: String, CaseIterable, Identifiable {
    case eyes
    case orb
    case bars
    case ghost
    case cat
    case bunny

    var id: String { rawValue }

    var label: String {
        switch self {
        case .eyes:  return "Eyes"
        case .orb:   return "Orb"
        case .bars:  return "Waves"
        case .ghost: return "Ghost"
        case .cat:   return "Cat"
        case .bunny: return "Bunny"
        }
    }
}

enum BuddyColor: String, CaseIterable, Identifiable {
    case orange
    case blue
    case green
    case purple
    case pink
    case cyan

    var id: String { rawValue }

    var label: String {
        switch self {
        case .orange: return "Claude"
        case .blue:   return "Blue"
        case .green:  return "Green"
        case .purple: return "Purple"
        case .pink:   return "Pink"
        case .cyan:   return "Cyan"
        }
    }

    var base: Color {
        switch self {
        case .orange: return Color(red: 0.80, green: 0.47, blue: 0.36) // #CC785C
        case .blue:   return Color(red: 0.35, green: 0.72, blue: 1.00) // #5AB8FF
        case .green:  return Color(red: 0.44, green: 0.83, blue: 0.42) // #70D46B
        case .purple: return Color(red: 0.66, green: 0.55, blue: 0.91) // #A88BE8
        case .pink:   return Color(red: 0.94, green: 0.38, blue: 0.57) // #EF6192
        case .cyan:   return Color(red: 0.30, green: 0.81, blue: 0.88) // #4DD0E1
        }
    }

    var glow: Color { base.opacity(0.85) }
}

// MARK: - BuddyFace dispatcher

struct BuddyFace: View {
    enum Mode: Equatable {
        case sleeping
        case idle
        case active
        case curious   // permission request / alert
        case content   // happy / done
        case focused   // concentrated editing
        case shocked   // dangerous action
    }

    let mode: Mode
    var size: CGFloat = 8
    var colorOverride: BuddyColor? = nil

    @EnvironmentObject private var prefs: BuddyPreferences

    private var effectiveColor: BuddyColor { colorOverride ?? prefs.color }

    var body: some View {
        Group {
            switch prefs.style {
            case .eyes:  EyesBuddy(mode: mode, size: size, color: effectiveColor)
            case .orb:   OrbBuddy(mode: mode, size: size, color: effectiveColor)
            case .bars:  BarsBuddy(mode: mode, size: size, color: effectiveColor)
            case .ghost: GhostBuddy(mode: mode, size: size, color: effectiveColor)
            case .cat:   CatBuddy(mode: mode, size: size, color: effectiveColor)
            case .bunny: BunnyBuddy(mode: mode, size: size, color: effectiveColor)
            }
        }
        .id(prefs.style)
    }
}

// MARK: - Shared helpers

/// Shared danger-red for the shocked state, overriding the user's accent.
private let shockColor = Color(red: 0.92, green: 0.28, blue: 0.22)

/// Standard body-color ramp based on mode. All character buddies use the
/// user's picked accent color; the ramp just dims it based on mood.
private func bodyColor(_ mode: BuddyFace.Mode, _ color: BuddyColor) -> Color {
    switch mode {
    case .active, .curious: return color.base
    case .focused:          return color.base.opacity(0.95)
    case .shocked:          return shockColor
    case .content:          return color.base.opacity(0.85)
    case .idle:             return color.base.opacity(0.9)
    case .sleeping:         return color.base.opacity(0.4)
    }
}

/// Mode-aware blink loop, shared by all character buddies.
///
/// Content mode holds the closed pose ~2× longer — reads as a happy squint
/// rather than a functional blink.
@MainActor
private func runBlinkLoop(
    mode: BuddyFace.Mode,
    setBlink: @escaping (Bool) -> Void
) async {
    // Shocked buddies don't blink — their eyes are wide with alarm.
    if mode == .shocked {
        setBlink(false)
        return
    }
    while !Task.isCancelled {
        let (mean, jitter): (UInt64, UInt64) = {
            switch mode {
            case .curious:  return (1_200_000_000, 600_000_000)
            case .active:   return (3_800_000_000, 1_400_000_000)
            case .focused:  return (4_800_000_000, 1_200_000_000)   // calm concentration
            case .content:  return (5_200_000_000, 1_800_000_000)
            case .idle:     return (4_200_000_000, 1_500_000_000)
            case .sleeping: return (5_000_000_000, 0)
            case .shocked:  return (9_000_000_000, 0)  // unreachable
            }
        }()
        let holdDur: UInt64 = mode == .content ? 260_000_000 : 130_000_000

        let delay = mean &+ UInt64.random(in: 0..<max(jitter, 1))
        try? await Task.sleep(nanoseconds: delay)
        if Task.isCancelled { return }
        withAnimation(.easeIn(duration: 0.09)) { setBlink(true) }
        try? await Task.sleep(nanoseconds: holdDur)
        if Task.isCancelled { return }
        withAnimation(.easeOut(duration: 0.12)) { setBlink(false) }
    }
}

// MARK: - Eyes (with look-around gaze)

private struct EyesBuddy: View {
    let mode: BuddyFace.Mode
    let size: CGFloat
    let color: BuddyColor

    @State private var blink = false
    @State private var pulse: CGFloat = 1.0
    @State private var breathe: CGFloat = 0
    @State private var gaze: CGSize = .zero
    @State private var blinkTask: Task<Void, Never>?
    @State private var gazeTask: Task<Void, Never>?

    private var eyeColor: Color {
        switch mode {
        case .shocked:          return shockColor
        case .active, .curious: return color.base
        case .focused:          return color.base.opacity(0.95)
        case .content:          return color.base.opacity(0.85)
        case .idle:             return .white.opacity(0.92)
        case .sleeping:         return .white.opacity(0.35)
        }
    }

    private var glowColor: Color {
        switch mode {
        case .shocked:  return shockColor.opacity(0.9)
        case .active:   return color.glow
        case .curious:  return color.glow.opacity(0.7)
        case .focused:  return color.glow.opacity(0.3)
        case .content:  return color.glow.opacity(0.35)
        case .idle:     return .white.opacity(0.25)
        case .sleeping: return .clear
        }
    }

    private var baseSize: CGFloat {
        switch mode {
        case .shocked: return size * 1.1    // subtle widening — red is the real tell
        case .curious: return size * 1.15
        case .active:  return size * 1.05
        case .focused: return size * 0.92   // narrowed focus
        default:       return size
        }
    }

    var body: some View {
        HStack(spacing: baseSize * 0.85) {
            eye
            eye
        }
        .scaleEffect(pulse)
        .offset(x: gaze.width, y: breathe + gaze.height)
        .onAppear { start() }
        .onDisappear {
            blinkTask?.cancel()
            gazeTask?.cancel()
        }
        .onChange(of: mode) { _, _ in start() }
    }

    @ViewBuilder
    private var eye: some View {
        if mode == .sleeping {
            Capsule()
                .fill(eyeColor)
                .frame(width: baseSize, height: max(1.5, baseSize * 0.2))
        } else {
            // Tighter glow radius in shocked mode so the red halo doesn't
            // overflow the notch's vertical extent.
            let glowRadius: CGFloat = mode == .shocked
                ? baseSize * 0.22
                : baseSize * 0.55
            Circle()
                .fill(eyeColor)
                .frame(
                    width: baseSize,
                    height: blink ? max(1.5, baseSize * 0.15) : baseSize
                )
                .shadow(color: glowColor, radius: glowRadius)
        }
    }

    private func start() {
        blinkTask?.cancel()
        gazeTask?.cancel()
        pulse = 1.0
        breathe = 0
        withAnimation(.easeOut(duration: 0.25)) { gaze = .zero }

        guard mode != .sleeping else { return }

        switch mode {
        case .active:
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                pulse = 1.1
            }
            withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) {
                breathe = -0.8
            }
        case .curious:
            withAnimation(.easeInOut(duration: 0.65).repeatForever(autoreverses: true)) {
                pulse = 1.06
            }
        case .focused:
            // Calm, steady — no breathing, subtle slow pulse
            withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) {
                pulse = 1.03
            }
        case .shocked:
            // Hold still, wide eyes, very subtle scale pop so we don't
            // overflow the notch height.
            withAnimation(.spring(response: 0.18, dampingFraction: 0.55)) {
                pulse = 1.05
            }
        case .content:
            withAnimation(.easeInOut(duration: 2.8).repeatForever(autoreverses: true)) {
                breathe = -0.5
            }
        case .idle, .sleeping:
            break
        }

        blinkTask = Task { @MainActor in
            await runBlinkLoop(mode: mode) { self.blink = $0 }
        }

        // Occasional look-around glance.
        gazeTask = Task { @MainActor in
            while !Task.isCancelled {
                let waitNs: UInt64 = {
                    switch mode {
                    case .curious: return UInt64.random(in: 300_000_000 ... 800_000_000)
                    case .active:  return UInt64.random(in: 2_500_000_000 ... 5_500_000_000)
                    case .content: return UInt64.random(in: 5_000_000_000 ... 9_000_000_000)
                    default:       return UInt64.random(in: 3_500_000_000 ... 7_000_000_000)
                    }
                }()
                try? await Task.sleep(nanoseconds: waitNs)
                if Task.isCancelled { return }

                let angle = Double.random(in: 0 ... 2 * .pi)
                let dist = size * 0.18
                let dx = CGFloat(cos(angle)) * dist
                let dy = CGFloat(sin(angle)) * dist * 0.55
                withAnimation(.easeOut(duration: 0.2)) {
                    gaze = CGSize(width: dx, height: dy)
                }
                try? await Task.sleep(
                    nanoseconds: UInt64.random(in: 400_000_000 ... 900_000_000)
                )
                if Task.isCancelled { return }
                withAnimation(.easeInOut(duration: 0.25)) {
                    gaze = .zero
                }
            }
        }
    }
}

// MARK: - Orb (inner spark + sonar ring)

private struct OrbBuddy: View {
    let mode: BuddyFace.Mode
    let size: CGFloat
    let color: BuddyColor

    @State private var pulse: CGFloat = 1.0
    @State private var breathe: CGFloat = 0
    @State private var sparkPulse: CGFloat = 1.0
    @State private var sonarScale: CGFloat = 0
    @State private var sonarOpacity: Double = 0
    @State private var sonarTask: Task<Void, Never>?

    private var fillColor: Color {
        switch mode {
        case .shocked:          return shockColor
        case .active, .curious: return color.base
        case .focused:          return color.base.opacity(0.88)
        case .content:          return color.base.opacity(0.78)
        case .idle:             return .white.opacity(0.88)
        case .sleeping:         return .white.opacity(0.25)
        }
    }

    private var glowColor: Color {
        switch mode {
        case .shocked: return shockColor.opacity(0.9)
        case .active:  return color.glow
        case .curious: return color.glow.opacity(0.65)
        case .focused: return color.glow.opacity(0.4)
        case .content: return color.glow.opacity(0.35)
        default:       return .clear
        }
    }

    var body: some View {
        let orbSize = size * 2.1

        ZStack {
            // Expanding sonar ring, only visible in active mode.
            if mode == .active {
                Circle()
                    .strokeBorder(color.base.opacity(0.8), lineWidth: 1.2)
                    .frame(width: orbSize, height: orbSize)
                    .scaleEffect(sonarScale)
                    .opacity(sonarOpacity)
            }

            // Main orb body.
            Circle()
                .fill(fillColor)
                .frame(width: orbSize, height: orbSize)
                .overlay(
                    // Inner highlight — fixed gradient for depth.
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [Color.white.opacity(0.38), .clear],
                                center: UnitPoint(x: 0.3, y: 0.28),
                                startRadius: 0,
                                endRadius: orbSize * 0.55
                            )
                        )
                        .blendMode(.plusLighter)
                )
                .shadow(color: glowColor, radius: orbSize * 0.5)

            // Inner spark: a smaller bright dot that pulses independently
            // of the outer pulse, giving the orb a second heartbeat.
            if mode != .sleeping {
                Circle()
                    .fill(Color.white.opacity(0.75))
                    .frame(width: orbSize * 0.18, height: orbSize * 0.18)
                    .offset(x: -orbSize * 0.08, y: -orbSize * 0.1)
                    .scaleEffect(sparkPulse)
                    .blur(radius: 0.5)
            }
        }
        .scaleEffect(pulse)
        .offset(y: breathe)
        .onAppear { start() }
        .onDisappear { sonarTask?.cancel() }
        .onChange(of: mode) { _, _ in start() }
    }

    private func start() {
        sonarTask?.cancel()
        pulse = 1.0
        breathe = 0
        sparkPulse = 1.0
        sonarScale = 0
        sonarOpacity = 0

        switch mode {
        case .active:
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                pulse = 1.13
            }
            withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) {
                breathe = -0.6
            }
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                sparkPulse = 1.3
            }
            sonarTask = Task { @MainActor in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 2_400_000_000)
                    if Task.isCancelled { return }
                    sonarScale = 0.95
                    sonarOpacity = 0.7
                    withAnimation(.easeOut(duration: 1.6)) {
                        sonarScale = 2.2
                        sonarOpacity = 0
                    }
                }
            }
        case .curious:
            withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) {
                pulse = 1.08
            }
            withAnimation(.easeInOut(duration: 0.45).repeatForever(autoreverses: true)) {
                sparkPulse = 1.4
            }
        case .focused:
            withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) {
                pulse = 1.05
            }
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                sparkPulse = 1.1
            }
        case .shocked:
            withAnimation(.spring(response: 0.2, dampingFraction: 0.5)) {
                pulse = 1.1
            }
            sparkPulse = 1.25
        case .content:
            withAnimation(.easeInOut(duration: 2.8).repeatForever(autoreverses: true)) {
                pulse = 1.04
            }
            withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) {
                sparkPulse = 1.15
            }
        case .idle:
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                sparkPulse = 1.2
            }
        case .sleeping:
            break
        }
    }
}

// MARK: - Bars (audio waveform)

private struct BarsBuddy: View {
    let mode: BuddyFace.Mode
    let size: CGFloat
    let color: BuddyColor

    private var barColor: Color {
        switch mode {
        case .shocked:          return shockColor
        case .active, .curious: return color.base
        case .focused:          return color.base.opacity(0.9)
        case .content:          return color.base.opacity(0.80)
        case .idle:             return .white.opacity(0.88)
        case .sleeping:         return .white.opacity(0.3)
        }
    }

    private var amplitude: CGFloat {
        switch mode {
        case .shocked:  return 0.45
        case .active:   return 0.55
        case .curious:  return 0.48
        case .focused:  return 0.22
        case .content:  return 0.18
        case .idle:     return 0.12
        case .sleeping: return 0
        }
    }

    private var speed: Double {
        switch mode {
        case .shocked:  return 9.0
        case .active:   return 4.5
        case .curious:  return 6.5
        case .focused:  return 1.8
        case .content:  return 1.6
        case .idle:     return 1.0
        case .sleeping: return 0
        }
    }

    var body: some View {
        let barWidth = size * 0.38
        let baseH = size * 0.95
        let maxH = baseH * (1 + amplitude)
        let minH = max(size * 0.25, baseH * (1 - amplitude))

        TimelineView(
            .animation(minimumInterval: 1.0 / 60, paused: mode == .sleeping)
        ) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: size * 0.32) {
                ForEach(0..<4, id: \.self) { i in
                    let phase = Double(i) * 0.9
                    let wave = sin(t * speed + phase)
                    let h = baseH + CGFloat(wave) * amplitude * baseH
                    Capsule()
                        .fill(barColor)
                        .frame(width: barWidth, height: clamp(h, min: minH, max: maxH))
                }
            }
        }
        .frame(height: maxH)
    }

    private func clamp(_ x: CGFloat, min lo: CGFloat, max hi: CGFloat) -> CGFloat {
        Swift.min(Swift.max(x, lo), hi)
    }
}

// MARK: - Ghost (sway, float, startle)

struct GhostShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width
        let h = rect.height
        let waist = h * 0.78

        p.move(to: CGPoint(x: 0, y: waist))
        p.addQuadCurve(
            to: CGPoint(x: w / 2, y: 0),
            control: CGPoint(x: 0, y: 0)
        )
        p.addQuadCurve(
            to: CGPoint(x: w, y: waist),
            control: CGPoint(x: w, y: 0)
        )

        let bumpCount = 3
        let bumpW = w / CGFloat(bumpCount)
        for i in 0..<bumpCount {
            let idx = bumpCount - 1 - i
            let startX = CGFloat(idx + 1) * bumpW
            let endX = CGFloat(idx) * bumpW
            let midX = (startX + endX) / 2
            p.addQuadCurve(
                to: CGPoint(x: endX, y: waist),
                control: CGPoint(x: midX, y: h)
            )
        }
        p.closeSubpath()
        return p
    }
}

private struct GhostBuddy: View {
    let mode: BuddyFace.Mode
    let size: CGFloat
    let color: BuddyColor

    @State private var float: CGFloat = 0
    @State private var sway: CGFloat = 0
    @State private var startleScale: CGFloat = 1.0
    @State private var blink = false
    @State private var blinkTask: Task<Void, Never>?

    var body: some View {
        let w = size * 1.95
        let h = size * 2.35

        return ZStack {
            GhostShape()
                .fill(bodyColor(mode, color))
                .overlay(
                    GhostShape()
                        .fill(
                            LinearGradient(
                                colors: [.white.opacity(0.28), .clear],
                                startPoint: .top,
                                endPoint: .center
                            )
                        )
                        .blendMode(.plusLighter)
                )
                .shadow(
                    color: mode == .shocked ? shockColor.opacity(0.6)
                        : (mode == .active ? color.glow.opacity(0.5) : .clear),
                    radius: size * 0.5
                )
                .frame(width: w, height: h)

            HStack(spacing: size * 0.5) {
                eye
                eye
            }
            .offset(y: -size * 0.25)
        }
        .frame(width: w, height: h)
        .scaleEffect(startleScale)
        .offset(x: sway, y: float)
        .onAppear { start() }
        .onDisappear {
            blinkTask?.cancel()
            blinkTask = nil
        }
        .onChange(of: mode) { oldMode, newMode in
            if (newMode == .curious || newMode == .shocked) && oldMode != newMode {
                triggerStartle(intensity: newMode == .shocked ? 1.12 : 1.16)
            }
            start()
        }
    }

    @ViewBuilder
    private var eye: some View {
        if mode == .sleeping || blink {
            Capsule()
                .fill(.white)
                .frame(width: size * 0.32, height: 1.5)
        } else {
            Circle()
                .fill(.white)
                .frame(width: size * 0.36, height: size * 0.36)
        }
    }

    private func start() {
        blinkTask?.cancel()
        float = 0
        sway = 0
        guard mode != .sleeping else { return }

        // Shocked ghosts freeze in place — no float, no sway.
        if mode == .shocked {
            blinkTask = Task { @MainActor in
                await runBlinkLoop(mode: mode) { self.blink = $0 }
            }
            return
        }

        // Vertical float
        let floatAmt: CGFloat = mode == .active ? -2.6 : -1.4
        let floatDur: Double = {
            switch mode {
            case .active:  return 1.3
            case .curious: return 0.85
            case .focused: return 2.8     // slow, concentrated bob
            case .content: return 2.6
            default:       return 2.0
            }
        }()
        withAnimation(.easeInOut(duration: floatDur).repeatForever(autoreverses: true)) {
            float = floatAmt
        }

        // Horizontal sway (different period so they don't sync)
        let swayAmt: CGFloat = {
            switch mode {
            case .active:  return 2.2
            case .curious: return 2.8
            case .focused: return 0.6    // barely swaying
            case .content: return 1.2
            default:       return 1.6
            }
        }()
        let swayDur: Double = floatDur * 1.6
        withAnimation(.easeInOut(duration: swayDur).repeatForever(autoreverses: true)) {
            sway = swayAmt
        }

        blinkTask = Task { @MainActor in
            await runBlinkLoop(mode: mode) { self.blink = $0 }
        }
    }

    private func triggerStartle(intensity: CGFloat) {
        withAnimation(.spring(response: 0.18, dampingFraction: 0.5)) {
            startleScale = intensity
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            withAnimation(.spring(response: 0.45, dampingFraction: 0.7)) {
                startleScale = 1.0
            }
        }
    }
}

// MARK: - Cat (twitches, alert-back, contentment squint)

struct TriangleShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

private struct CatBuddy: View {
    let mode: BuddyFace.Mode
    let size: CGFloat
    let color: BuddyColor

    @State private var leftEar: Double = 0
    @State private var rightEar: Double = 0
    @State private var blink = false
    @State private var blinkTask: Task<Void, Never>?
    @State private var twitchTask: Task<Void, Never>?

    var body: some View {
        let head = size * 1.95
        let earW = size * 0.72
        let earH = size * 0.78

        return ZStack {
            Circle()
                .fill(bodyColor(mode, color))
                .frame(width: head, height: head)

            TriangleShape()
                .fill(bodyColor(mode, color))
                .frame(width: earW, height: earH)
                .rotationEffect(.degrees(leftEar), anchor: .bottom)
                .offset(x: -head * 0.32, y: -head * 0.58)

            TriangleShape()
                .fill(bodyColor(mode, color))
                .frame(width: earW, height: earH)
                .rotationEffect(.degrees(rightEar), anchor: .bottom)
                .offset(x: head * 0.32, y: -head * 0.58)

            HStack(spacing: size * 0.52) {
                eye
                eye
            }
            .offset(y: -size * 0.08)

            TriangleShape()
                .fill(Color(red: 1.0, green: 0.78, blue: 0.84))
                .frame(width: size * 0.22, height: size * 0.18)
                .rotationEffect(.degrees(180))
                .offset(y: size * 0.45)
        }
        .frame(width: head + size * 0.4, height: head + earH * 0.9)
        .shadow(
            color: mode == .active ? color.glow.opacity(0.4) : .clear,
            radius: size * 0.3
        )
        .onAppear { start() }
        .onDisappear {
            blinkTask?.cancel()
            twitchTask?.cancel()
        }
        .onChange(of: mode) { _, _ in start() }
    }

    @ViewBuilder
    private var eye: some View {
        if mode == .sleeping || blink {
            Capsule()
                .fill(.white)
                .frame(width: size * 0.34, height: 1.5)
        } else {
            Circle()
                .fill(.white)
                .frame(width: size * 0.38, height: size * 0.38)
                .overlay(
                    Capsule()
                        .fill(.black)
                        .frame(
                            width: size * (mode == .curious ? 0.13 : 0.1),
                            height: size * 0.26
                        )
                )
        }
    }

    private func start() {
        blinkTask?.cancel()
        twitchTask?.cancel()
        leftEar = 0
        rightEar = 0
        guard mode != .sleeping else { return }

        // Shocked: ears pinned back, no twitches, no blinks.
        if mode == .shocked {
            withAnimation(.spring(response: 0.18, dampingFraction: 0.5)) {
                leftEar = -18
                rightEar = 18
            }
            return
        }

        // Focused: ears forward, no twitches.
        if mode == .focused {
            blinkTask = Task { @MainActor in
                await runBlinkLoop(mode: mode) { self.blink = $0 }
            }
            return
        }

        // Ear behavior: single twitches, occasional alert-back flip-both.
        twitchTask = Task { @MainActor in
            while !Task.isCancelled {
                let delay: UInt64 = {
                    switch mode {
                    case .curious: return UInt64.random(in: 1_400_000_000 ... 3_000_000_000)
                    case .active:  return UInt64.random(in: 2_500_000_000 ... 5_000_000_000)
                    default:       return UInt64.random(in: 4_000_000_000 ... 8_000_000_000)
                    }
                }()
                try? await Task.sleep(nanoseconds: delay)
                if Task.isCancelled { return }

                // In active mode, ~30% chance of both-ears-back alert pose.
                if mode == .active && Int.random(in: 0..<100) < 30 {
                    withAnimation(.easeOut(duration: 0.14)) {
                        leftEar = -10
                        rightEar = 10
                    }
                    try? await Task.sleep(nanoseconds: 380_000_000)
                    if Task.isCancelled { return }
                    withAnimation(.easeOut(duration: 0.22)) {
                        leftEar = 0
                        rightEar = 0
                    }
                } else {
                    // Single ear twitch
                    let useLeft = Bool.random()
                    withAnimation(.easeInOut(duration: 0.13)) {
                        if useLeft { leftEar = -12 } else { rightEar = 12 }
                    }
                    try? await Task.sleep(nanoseconds: 180_000_000)
                    if Task.isCancelled { return }
                    withAnimation(.easeInOut(duration: 0.18)) {
                        leftEar = 0
                        rightEar = 0
                    }
                }
            }
        }

        blinkTask = Task { @MainActor in
            await runBlinkLoop(mode: mode) { self.blink = $0 }
        }
    }
}

// MARK: - Bunny (squash-and-stretch hop, nose wiggle, ear perk)

private struct BunnyBuddy: View {
    let mode: BuddyFace.Mode
    let size: CGFloat
    let color: BuddyColor

    @State private var hop: CGFloat = 0
    @State private var scaleY: CGFloat = 1.0
    @State private var scaleX: CGFloat = 1.0
    @State private var earTilt: Double = 0
    @State private var noseOffset: CGFloat = 0
    @State private var blink = false
    @State private var blinkTask: Task<Void, Never>?
    @State private var hopTask: Task<Void, Never>?
    @State private var noseTask: Task<Void, Never>?

    // Curious mode tilts ears forward instead of sideways.
    private var leftEarTilt: Double {
        mode == .curious ? 22 : -earTilt
    }
    private var rightEarTilt: Double {
        mode == .curious ? -22 : earTilt
    }

    var body: some View {
        let headW = size * 1.8
        let headH = size * 1.55
        let earW = size * 0.34
        let earH = size * 1.0

        return ZStack {
            HStack(spacing: earW * 0.45) {
                Capsule()
                    .fill(bodyColor(mode, color))
                    .frame(width: earW, height: earH)
                    .overlay(
                        Capsule()
                            .fill(Color(red: 1.0, green: 0.78, blue: 0.84))
                            .frame(width: earW * 0.5, height: earH * 0.75)
                            .offset(y: earH * 0.05)
                    )
                    .rotationEffect(.degrees(leftEarTilt), anchor: .bottom)
                Capsule()
                    .fill(bodyColor(mode, color))
                    .frame(width: earW, height: earH)
                    .overlay(
                        Capsule()
                            .fill(Color(red: 1.0, green: 0.78, blue: 0.84))
                            .frame(width: earW * 0.5, height: earH * 0.75)
                            .offset(y: earH * 0.05)
                    )
                    .rotationEffect(.degrees(rightEarTilt), anchor: .bottom)
            }
            .offset(y: -headH * 0.7)

            Ellipse()
                .fill(bodyColor(mode, color))
                .frame(width: headW, height: headH)

            HStack(spacing: size * 0.55) {
                eye
                eye
            }
            .offset(y: -size * 0.05)

            // Pink nose
            Ellipse()
                .fill(Color(red: 1.0, green: 0.72, blue: 0.82))
                .frame(width: size * 0.22, height: size * 0.15)
                .offset(x: noseOffset, y: size * 0.32)
        }
        .frame(width: headW + size * 0.4, height: headH + earH * 0.85)
        .scaleEffect(x: scaleX, y: scaleY, anchor: .bottom)
        .offset(y: hop)
        .shadow(
            color: mode == .active ? color.glow.opacity(0.4) : .clear,
            radius: size * 0.3
        )
        .onAppear { start() }
        .onDisappear {
            blinkTask?.cancel()
            hopTask?.cancel()
            noseTask?.cancel()
        }
        .onChange(of: mode) { _, _ in start() }
    }

    @ViewBuilder
    private var eye: some View {
        if mode == .sleeping || blink {
            Capsule()
                .fill(.white)
                .frame(width: size * 0.3, height: 1.5)
        } else {
            Circle()
                .fill(.white)
                .frame(width: size * 0.32, height: size * 0.32)
        }
    }

    private func start() {
        blinkTask?.cancel()
        hopTask?.cancel()
        noseTask?.cancel()
        hop = 0
        scaleY = 1.0
        scaleX = 1.0
        earTilt = 0
        noseOffset = 0

        guard mode != .sleeping else { return }

        // Shocked: freeze in place, ears flat, wide eyes.
        if mode == .shocked {
            withAnimation(.spring(response: 0.2, dampingFraction: 0.55)) {
                scaleY = 0.9
                scaleX = 1.15
            }
            return
        }

        // Focused: standing still, no hops.
        if mode == .focused {
            blinkTask = Task { @MainActor in
                await runBlinkLoop(mode: mode) { self.blink = $0 }
            }
            return
        }

        // Ear sway (sideways, subtle). Curious mode overrides this via
        // fixed forward tilt in leftEarTilt/rightEarTilt.
        if mode != .curious {
            let tiltAmt: Double = 4.5
            let tiltDur: Double = 2.8
            withAnimation(.easeInOut(duration: tiltDur).repeatForever(autoreverses: true)) {
                earTilt = tiltAmt
            }
        }

        // Squash-and-stretch hop loop — keyframed manually via a Task that
        // chains withAnimation steps. This gives us: (1) crouch, (2) jump
        // up with stretch, (3) land with squash, (4) pause on ground.
        hopTask = Task { @MainActor in
            let hopAmt: CGFloat = {
                switch mode {
                case .active:  return 2.8
                case .curious: return 1.8
                case .content: return 1.1
                default:       return 1.6
                }
            }()
            let pauseMs: UInt64 = {
                switch mode {
                case .active:  return 120_000_000
                case .curious: return 60_000_000
                case .content: return 900_000_000
                default:       return 450_000_000
                }
            }()

            while !Task.isCancelled {
                // (1) Tiny crouch before jumping — anticipation.
                withAnimation(.easeOut(duration: 0.1)) {
                    scaleY = 0.92
                    scaleX = 1.08
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
                if Task.isCancelled { return }

                // (2) Jump up with stretch.
                withAnimation(.easeOut(duration: 0.22)) {
                    hop = -hopAmt
                    scaleY = 1.14
                    scaleX = 0.9
                }
                try? await Task.sleep(nanoseconds: 220_000_000)
                if Task.isCancelled { return }

                // (3) Fall back down.
                withAnimation(.easeIn(duration: 0.18)) {
                    hop = 0
                    scaleY = 1.0
                    scaleX = 1.0
                }
                try? await Task.sleep(nanoseconds: 180_000_000)
                if Task.isCancelled { return }

                // (4) Squash on impact.
                withAnimation(.easeOut(duration: 0.08)) {
                    scaleY = 0.88
                    scaleX = 1.12
                }
                try? await Task.sleep(nanoseconds: 80_000_000)
                if Task.isCancelled { return }

                // (5) Recover to neutral.
                withAnimation(.easeOut(duration: 0.15)) {
                    scaleY = 1.0
                    scaleX = 1.0
                }
                try? await Task.sleep(nanoseconds: 150_000_000)
                if Task.isCancelled { return }

                // (6) Pause before next hop.
                try? await Task.sleep(nanoseconds: pauseMs)
            }
        }

        // Nose wiggle: always present, but more noticeable in content mode.
        if mode == .content || mode == .curious {
            noseTask = Task { @MainActor in
                while !Task.isCancelled {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        noseOffset = 0.5
                    }
                    try? await Task.sleep(nanoseconds: 180_000_000)
                    if Task.isCancelled { return }
                    withAnimation(.easeInOut(duration: 0.18)) {
                        noseOffset = -0.5
                    }
                    try? await Task.sleep(nanoseconds: 180_000_000)
                    if Task.isCancelled { return }
                }
            }
        }

        blinkTask = Task { @MainActor in
            await runBlinkLoop(mode: mode) { self.blink = $0 }
        }
    }
}
