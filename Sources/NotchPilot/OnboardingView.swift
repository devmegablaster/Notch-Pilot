import SwiftUI

/// Full-screen first-launch intro.
///
/// Sequence:
/// 1. Dark takeover backdrop fades in.
/// 2. Buddy pops up to 3× with a spring.
/// 3. Three lines of copy reveal one at a time.
/// 4. Skip button appears.
/// 5. Text fades. The buddy's eyes morph into a single shape that takes
///    the notch's exact proportions (flat top, rounded bottom corners).
/// 6. That shape flies up and shrinks into the real notch position,
///    leaving the normal notch panel in place underneath.
/// 7. Backdrop drops away.
///
/// Total runtime ≈ 8 seconds. Skip button short-circuits the whole thing.
struct OnboardingView: View {
    let notchWidth: CGFloat
    let notchHeight: CGFloat
    let onComplete: () -> Void

    @EnvironmentObject private var prefs: BuddyPreferences

    // Backdrop — two layered values so we can lighten the tint during
    // the morph without losing the frosted blur underlay.
    @State private var backdropOpacity: Double = 0
    @State private var backdropTintOpacity: Double = 0

    // Buddy (the SwiftUI BuddyFace with eyes)
    @State private var buddyScale: CGFloat = 0.0
    @State private var buddyOpacity: Double = 0

    // Copy reveal
    @State private var revealedLines: Int = 0
    @State private var textOpacity: Double = 0
    @State private var skipVisible = false

    // Morph bar — the shape that the eyes become. Starts roughly the
    // size and roundness of the buddy's eye pair, ends as the notch.
    @State private var morphOpacity: Double = 0
    @State private var morphWidth: CGFloat = 180
    @State private var morphHeight: CGFloat = 64
    @State private var morphTopRadius: CGFloat = 32
    @State private var morphBottomRadius: CGFloat = 32
    @State private var morphYOffset: CGFloat = 0

    // Inner content (mini buddy + "hi") that appears inside the morph
    // bar once it takes the notch's proportions.
    @State private var notchContentOpacity: Double = 0

    // Scripted blink control for the hero eyes. 0 = fully open, 1 =
    // fully closed. Driven by the animation timeline so we can do the
    // deliberate "blink-blink … blink-blink … boom" sequence right
    // before the morph starts.
    @State private var blinkProgress: CGFloat = 0
    @State private var naturalBlinkTask: Task<Void, Never>?

    @State private var finished = false

    private let copy = [
        "Hi, I'm Notch Pilot.",
        "I live in your notch now.",
        "Hover up to say hi.",
    ]

    var body: some View {
        GeometryReader { geom in
            ZStack {
                // Takeover backdrop. Starts nearly opaque black for a
                // deep theater-curtain feel during the intro copy; then
                // lightens once the morph begins so the pure-black bar
                // (which matches the real notch) reads clearly against
                // the blur.
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .opacity(backdropOpacity)
                    .ignoresSafeArea()
                Color.black
                    .opacity(backdropTintOpacity)
                    .ignoresSafeArea()

                // Hero column: buddy + copy, both centered. Everything
                // above uses the same coordinate space so the morph
                // shape can start exactly where the buddy is rendered.
                VStack(spacing: 42) {
                    ZStack {
                        // Morph bar lives behind the buddy, invisible
                        // until the crossfade. Uses the same center as
                        // the buddy so the swap is seamless.
                        UnevenRoundedRectangle(
                            topLeadingRadius: morphTopRadius,
                            bottomLeadingRadius: morphBottomRadius,
                            bottomTrailingRadius: morphBottomRadius,
                            topTrailingRadius: morphTopRadius,
                            style: .continuous
                        )
                        .fill(Color.black)
                        .frame(width: morphWidth, height: morphHeight)
                        .overlay(
                            // Inner content: mini buddy + "hi" — appears
                            // once the shape is notch-shaped, so when
                            // the bar docks it's already showing the
                            // final state of the real notch panel.
                            HStack(spacing: 10) {
                                BuddyFace(mode: .content, size: 9)
                                    .frame(width: 38, height: 20)
                                Spacer(minLength: 0)
                                Text("hi")
                                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                                    .foregroundColor(.white.opacity(0.92))
                            }
                            .padding(.horizontal, 16)
                            .frame(width: morphWidth, height: morphHeight)
                            .opacity(notchContentOpacity)
                        )
                        .opacity(morphOpacity)
                        .offset(y: morphYOffset)
                        .shadow(
                            color: .black.opacity(morphOpacity * 0.5),
                            radius: 28, y: 8
                        )

                        OnboardingEyes(
                            size: 22,
                            color: prefs.color.base,
                            blinkProgress: blinkProgress
                        )
                        .frame(width: 120, height: 60)
                        .scaleEffect(buddyScale)
                        .opacity(buddyOpacity)
                    }

                    VStack(spacing: 10) {
                        ForEach(copy.indices, id: \.self) { idx in
                            Text(copy[idx])
                                .font(.system(size: 26, weight: .medium, design: .rounded))
                                .foregroundColor(.white)
                                .opacity(idx < revealedLines ? 1 : 0)
                                .offset(y: idx < revealedLines ? 0 : 14)
                                .animation(
                                    .spring(response: 0.55, dampingFraction: 0.85),
                                    value: revealedLines
                                )
                        }
                    }
                    .opacity(textOpacity)
                }

                // Skip affordance.
                VStack {
                    Spacer()
                    Button { skip() } label: {
                        HStack(spacing: 6) {
                            Text("Skip")
                            Image(systemName: "arrow.right")
                        }
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundColor(.white.opacity(0.5))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(Color.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                    .opacity(skipVisible ? 1 : 0)
                    .animation(.easeOut(duration: 0.4), value: skipVisible)
                    .padding(.bottom, 64)
                }
            }
            .onAppear { run(screenHeight: geom.size.height) }
        }
    }

    // MARK: - Animation timeline

    private func run(screenHeight: CGFloat) {
        // The y distance from the view's vertical center to the notch
        // center (which sits at notchHeight/2 from the top of the screen).
        let notchYOffset = -(screenHeight / 2) + (notchHeight / 2)

        // Phase 1 (0.0s): backdrop fades in. Dark enough for theatre
        // but leaves a hint of the desktop visible through the blur.
        withAnimation(.easeOut(duration: 0.8)) {
            backdropOpacity = 1.0
            backdropTintOpacity = 0.72
        }

        // Phase 2 (0.2s): buddy pops up with a spring.
        withAnimation(.spring(response: 0.95, dampingFraction: 0.68).delay(0.2)) {
            buddyScale = 3.0
            buddyOpacity = 1
        }

        // Kick off the natural blink loop so the eyes feel alive from
        // the moment they appear — through the text reveal and into
        // the hold. Stopped before the scripted blinks fire.
        startNaturalBlinks()

        Task { @MainActor in
            // Phase 3 (1.4s): text container fades in, lines reveal
            // with gentle spacing so they feel deliberate.
            try? await Task.sleep(for: .milliseconds(1400))
            withAnimation(.easeOut(duration: 0.35)) { textOpacity = 1 }

            for _ in copy.indices {
                try? await Task.sleep(for: .milliseconds(700))
                revealedLines += 1
            }

            // Phase 4: skip button appears after copy is all in.
            try? await Task.sleep(for: .milliseconds(600))
            skipVisible = true

            // Phase 5: hold so the user can actually read.
            try? await Task.sleep(for: .milliseconds(1600))
            if finished { return }

            // Phase 5.5: one deliberate blink-blink right before the
            // morph. Stop the natural loop first so the scripted pair
            // reads as intentional, not random.
            stopNaturalBlinks()
            await doubleBlink()
            try? await Task.sleep(for: .milliseconds(450))
            if finished { return }

            // Phase 6: text fades out first.
            withAnimation(.easeOut(duration: 0.5)) { textOpacity = 0 }
            try? await Task.sleep(for: .milliseconds(350))
            if finished { return }

            // Phase 7: crossfade — morph bar rises behind the buddy at
            // roughly eye-pair dimensions, buddy fades out. The user
            // perceives the eyes becoming a single dark rounded shape.
            // Simultaneously lighten the backdrop tint so the black bar
            // reads against it as it starts transforming.
            withAnimation(.easeInOut(duration: 0.6)) {
                morphOpacity = 1
                buddyOpacity = 0
                buddyScale = 1.0
                backdropTintOpacity = 0.38
            }
            try? await Task.sleep(for: .milliseconds(600))
            if finished { return }

            // Phase 8: the rounded shape takes on the notch aspect —
            // flat top, rounded bottom, widening and shortening. It's
            // still centered; only the shape is changing here.
            withAnimation(.spring(response: 0.9, dampingFraction: 0.85)) {
                morphWidth = notchWidth * 1.35
                morphHeight = notchHeight * 1.35
                morphTopRadius = 0
                morphBottomRadius = (notchHeight * 1.35) * 0.45
            }
            // Inner content (buddy + "hi") fades in slightly after the
            // shape reaches notch proportions so it feels like the
            // content "settles in" once the shape is right.
            try? await Task.sleep(for: .milliseconds(450))
            withAnimation(.easeOut(duration: 0.5)) {
                notchContentOpacity = 1
            }
            try? await Task.sleep(for: .milliseconds(550))
            if finished { return }

            // Phase 9: shape flies up to the notch position and shrinks
            // to match the notch's real dimensions exactly.
            withAnimation(.spring(response: 1.0, dampingFraction: 0.82)) {
                morphWidth = notchWidth
                morphHeight = notchHeight
                morphBottomRadius = notchHeight * 0.55
                morphYOffset = notchYOffset
            }
            try? await Task.sleep(for: .milliseconds(1000))
            if finished { return }

            // Phase 10: fade backdrop + morph shape out to reveal the
            // real notch panel underneath.
            withAnimation(.easeIn(duration: 0.55)) {
                backdropOpacity = 0
                backdropTintOpacity = 0
                morphOpacity = 0
            }

            try? await Task.sleep(for: .milliseconds(600))
            complete()
        }
    }

    private func skip() {
        guard !finished else { return }
        finished = true
        stopNaturalBlinks()
        withAnimation(.easeOut(duration: 0.3)) {
            backdropOpacity = 0
            backdropTintOpacity = 0
            buddyOpacity = 0
            textOpacity = 0
            morphOpacity = 0
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(320))
            complete()
        }
    }

    private func complete() {
        if !finished { finished = true }
        onComplete()
    }

    // MARK: - Blink choreography

    /// Runs one blink: close the eyes fast, pause a beat, reopen.
    @MainActor
    private func singleBlink() async {
        withAnimation(.easeOut(duration: 0.07)) { blinkProgress = 1 }
        try? await Task.sleep(for: .milliseconds(80))
        withAnimation(.easeIn(duration: 0.08)) { blinkProgress = 0 }
        try? await Task.sleep(for: .milliseconds(90))
    }

    /// A pair of quick blinks back to back — the "blink-blink" unit.
    @MainActor
    private func doubleBlink() async {
        await singleBlink()
        try? await Task.sleep(for: .milliseconds(60))
        await singleBlink()
    }

    /// Background loop that fires occasional natural blinks while the
    /// intro plays. Lets the eyes feel alive during text reveal and
    /// the read-pause. Cancelled before the scripted sequence.
    private func startNaturalBlinks() {
        naturalBlinkTask?.cancel()
        naturalBlinkTask = Task { @MainActor in
            // Initial offset so the first blink doesn't fire on top of
            // the buddy popping into existence.
            try? await Task.sleep(for: .milliseconds(900))
            while !Task.isCancelled {
                let waitMs = UInt64.random(in: 2400 ... 3800)
                try? await Task.sleep(for: .milliseconds(Int(waitMs)))
                if Task.isCancelled { return }
                await singleBlink()
            }
        }
    }

    private func stopNaturalBlinks() {
        naturalBlinkTask?.cancel()
        naturalBlinkTask = nil
    }
}

/// Custom hero eyes used only during onboarding. Mirrors the look of
/// `EyesBuddy` but exposes a `blinkProgress` input (0 = open, 1 = shut)
/// so the animation timeline can script blinks deliberately instead of
/// relying on the autonomous blink loop that `BuddyFace` runs.
private struct OnboardingEyes: View {
    let size: CGFloat
    let color: Color
    let blinkProgress: CGFloat

    var body: some View {
        HStack(spacing: size * 0.85) {
            eye
            eye
        }
    }

    private var eye: some View {
        let openHeight = size
        let closedHeight = max(1.5, size * 0.15)
        let height = openHeight - (openHeight - closedHeight) * blinkProgress
        return Circle()
            .fill(color)
            .frame(width: size, height: height)
            // Toned-down glow — the original was overpowering the
            // eye disks at 3× scale during the onboarding hero.
            .shadow(color: color.opacity(0.45), radius: size * 0.35)
    }
}
