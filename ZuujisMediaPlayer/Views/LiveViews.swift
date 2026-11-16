// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Combine
import SwiftUI

// The parts of the main window that move while audio plays (the spectrum
// displays, the level bar, the scrubber) are drawn here with Core Animation
// layers in plain `NSView`s, not with SwiftUI.
//
// Measured, not assumed: a SwiftUI view that redraws inside the main window
// makes the window lay itself out again on every frame, about 17 ms a time.
// That held even with the view in its own `NSHostingView`, because a hosting
// view marks its ancestors as needing a constraints pass whenever it updates.
// The Now Playing spectrum (30 frames a second) and the scrubber (10) alone
// kept playback at 34% CPU with every card hidden. A layer whose frame changes
// touches neither SwiftUI nor Auto Layout.

// MARK: - Base view

/// A layer-backed view that follows the meters. `canvas` uses SwiftUI's
/// coordinates (origin top left). Subclasses build layers in `rebuild()` and
/// move them in `tick(_:)`, which runs 30 times a second only while audio is
/// flowing and the window can be seen.
class LiveMeterView: NSView {
    let engine: AudioEngine
    let player: PlayerEngine
    let canvas = CALayer()
    let smoother = SpectrumSmoother()
    private(set) var isLive = false
    private var timer: Timer?
    private var links: Set<AnyCancellable> = []
    private var builtSize = CGSize.zero
    /// Frames a second while live.
    var rate: Double { 30 }

    init(engine: AudioEngine, player: PlayerEngine) {
        self.engine = engine
        self.player = player
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        canvas.isGeometryFlipped = true
        layer?.addSublayer(canvas)
        // `@Published` reports the value about to be stored, so the new
        // values are taken from the publishers, not read back.
        engine.$isRunning.combineLatest(player.$state)
            .map { $0 || $1 == .playing }
            .removeDuplicates()
            .sink { [weak self] live in self?.setLive(live) }
            .store(in: &links)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    /// A display takes no clicks; the controls under it do.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        guard bounds.size != builtSize else { return }
        builtSize = bounds.size
        setNeedsRebuild()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTimer()
    }

    /// Lays the layers out again (size or configuration changed).
    func setNeedsRebuild() {
        Self.withoutAnimation {
            canvas.frame = bounds
            canvas.contentsScale = window?.backingScaleFactor ?? 2
            rebuild()
            tick(Date())
        }
    }

    func rebuild() {}
    func tick(_ date: Date) {}

    private func setLive(_ live: Bool) {
        isLive = live
        updateTimer()
        // Draw the change at once: the first frame, or the cleared display.
        Self.withoutAnimation { tick(Date()) }
    }

    private func updateTimer() {
        let wanted = isLive && window != nil
        if wanted, timer == nil {
            let timer = Timer(timeInterval: 1 / rate, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.fire() }
            }
            timer.tolerance = 0.2 / rate
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else if !wanted, let timer {
            timer.invalidate()
            self.timer = nil
        }
    }

    private func fire() {
        // A hidden, minimised or covered window draws nothing.
        guard let window, window.occlusionState.contains(.visible) else { return }
        let now = Date()
        if restsOnSilence {
            // Live but silent (EQ on, nothing playing anywhere): once the
            // bars and their peak caps have had time to fall, there is
            // nothing left to move, so no layer is touched until sound returns.
            if engine.meters.snapshot.hasSignal {
                silentSince = nil
            } else if let since = silentSince {
                if now.timeIntervalSince(since) > Self.settleTime { return }
            } else {
                silentSince = now
            }
        }
        Self.withoutAnimation { tick(now) }
    }

    /// Spectrum displays rest on silence. The once-a-second text and level
    /// views cost nothing and keep their own change checks.
    var restsOnSilence: Bool { rate > 1 }
    private var silentSince: Date?
    /// Longer than `SpectrumSmoother`'s slowest fall (peak caps, 0.22 a second).
    private static let settleTime: TimeInterval = 5

    static func withoutAnimation(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    /// The eased spectrum, advanced to `date`; zeros when nothing is live.
    func spectrum(at date: Date) -> [Float] {
        smoother.step(toward: engine.meters.snapshot.spectrum, at: date, live: isLive)
        return smoother.values
    }
}

extension Color {
    /// For layers. Resolved when the layers are built; a theme change
    /// rebuilds the window's views, so they are built again.
    var cg: CGColor { NSColor(self).cgColor }
}

/// Wraps a live view for SwiftUI. It observes nothing that changes during
/// playback, and reports the size it is offered so SwiftUI never measures it.
struct LiveMeter<V: LiveMeterView>: NSViewRepresentable {
    @EnvironmentObject private var engine: AudioEngine
    @EnvironmentObject private var player: PlayerEngine
    let make: (AudioEngine, PlayerEngine) -> V
    var update: (V) -> Void = { _ in }

    func makeNSView(context: Context) -> V { make(engine, player) }
    func updateNSView(_ view: V, context: Context) { update(view) }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: V, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 100, height: 20))
    }
}

// MARK: - Now Playing spectrum

/// The live spectrum as soft bars rising behind the Now Playing stage.
final class StageSpectrumView: LiveMeterView {
    private var bars: [CAGradientLayer] = []
    private let gap: CGFloat = 3

    override func rebuild() {
        bars.forEach { $0.removeFromSuperlayer() }
        let count = smoother.values.count
        let width = (bounds.width - gap * CGFloat(count - 1)) / CGFloat(count)
        bars = (0..<count).map { index in
            let tint = Theme.signalColor(at: Double(index) / Double(count - 1))
            let bar = CAGradientLayer()
            bar.colors = [tint.opacity(0.30).cg, tint.opacity(0).cg]
            bar.cornerRadius = max(0, min(3, width / 2))
            canvas.addSublayer(bar)
            return bar
        }
    }

    override func tick(_ date: Date) {
        let values = spectrum(at: date)
        guard bars.count == values.count, bounds.width > 0 else { return }
        let count = values.count
        let width = (bounds.width - gap * CGFloat(count - 1)) / CGFloat(count)
        let reach = bounds.height * 0.9
        for index in 0..<count {
            let level = CGFloat(min(1, max(0, values[index])))
            let bar = bars[index]
            guard isLive, level > 0.01, width > 0 else {
                if !bar.isHidden { bar.isHidden = true }
                continue
            }
            let height = max(2, level * reach)
            bar.isHidden = false
            bar.frame = CGRect(x: CGFloat(index) * (width + gap), y: bounds.height - height,
                               width: width, height: height)
        }
    }
}

/// The Now Playing spectrum, for `PlayerBar`.
struct StageSpectrum: View {
    var body: some View {
        LiveMeter { StageSpectrumView(engine: $0, player: $1) }
            .allowsHitTesting(false)
    }
}

// MARK: - Level behind the faders

/// A soft column of light behind each fader, as tall as the signal at that
/// band's frequency, so you can see what a fader is acting on. One view
/// behind the whole row: the faders themselves never follow the meters.
final class BandLevelView: LiveMeterView {
    struct Config: Equatable {
        var frequencies: [Double] = []
        var column: CGFloat = 0
        var spacing: CGFloat = 0
        var trackLength: CGFloat = 0
    }

    var config = Config() {
        didSet { if config != oldValue { setNeedsRebuild() } }
    }
    private var columns: [(body: CAGradientLayer, cap: CALayer, bin: Int)] = []

    override func rebuild() {
        columns.forEach { $0.body.removeFromSuperlayer(); $0.cap.removeFromSuperlayer() }
        let bins = smoother.values.count
        let total = config.frequencies.count
        columns = config.frequencies.enumerated().map { index, frequency in
            let t = Double(index) / Double(max(1, total - 1))
            let tint = t < 0.5 ? Theme.cyan.mix(with: Theme.violet, by: t * 2)
                               : Theme.violet.mix(with: Theme.pink, by: (t - 0.5) * 2)
            let body = CAGradientLayer()
            body.colors = [tint.opacity(0.34).cg, tint.opacity(0.03).cg]
            body.cornerRadius = 3
            let cap = CALayer()
            cap.backgroundColor = tint.opacity(0.75).cg
            cap.cornerRadius = 0.75
            canvas.addSublayer(body)
            canvas.addSublayer(cap)
            let position = log10(min(max(frequency, 20), 20_000) / 20) / 3
            return (body, cap, min(bins - 1, max(0, Int(position * Double(bins)))))
        }
    }

    override func tick(_ date: Date) {
        let values = spectrum(at: date)
        let bottom = BandSlider.trackTop + config.trackLength - 7
        let reach = config.trackLength - 14
        let width = min(config.column - 2, 18)
        for (index, column) in columns.enumerated() {
            let level = CGFloat(min(1, max(0, values[column.bin])))
            guard isLive, level > 0.01, width > 0 else {
                if !column.body.isHidden {
                    column.body.isHidden = true
                    column.cap.isHidden = true
                }
                continue
            }
            let centre = CGFloat(index) * (config.column + config.spacing) + config.column / 2
            let height = level * reach
            column.body.isHidden = false
            column.cap.isHidden = false
            column.body.frame = CGRect(x: centre - width / 2, y: bottom - height, width: width, height: height)
            column.cap.frame = CGRect(x: centre - width / 2, y: bottom - height, width: width, height: 1.5)
        }
    }
}

/// The level columns, for `BandControlsView`.
struct BandLevelBackdrop: View {
    let frequencies: [Double]
    let column: CGFloat
    let spacing: CGFloat
    let trackLength: CGFloat

    var body: some View {
        let config = BandLevelView.Config(frequencies: frequencies, column: column,
                                          spacing: spacing, trackLength: trackLength)
        LiveMeter<BandLevelView>(make: { engine, player in
            let view = BandLevelView(engine: engine, player: player)
            view.config = config
            return view
        }, update: { $0.config = config })
        .allowsHitTesting(false)
    }
}

// MARK: - Spectrum under the response graph

/// The live spectrum under the response curve: a filled area in the signal
/// gradient, fading toward the floor, with a bright line and falling peaks.
final class ResponseSpectrumView: LiveMeterView {
    private let fill = CAGradientLayer()
    private let fade = CAGradientLayer()
    private let glow = CAGradientLayer()
    private let line = CAGradientLayer()
    private let peaks = CAShapeLayer()
    private let fillMask = CAShapeLayer()
    private let fadeMask = CAShapeLayer()
    private let glowMask = CAShapeLayer()
    private let lineMask = CAShapeLayer()
    private var plot = CGRect.zero

    override func rebuild() {
        if fill.superlayer == nil {
            for (layer, mask) in [(fill, fillMask), (fade, fadeMask), (glow, glowMask), (line, lineMask)] {
                layer.mask = mask
                canvas.addSublayer(layer)
            }
            canvas.addSublayer(peaks)
            for stroke in [glowMask, lineMask, peaks] {
                stroke.fillColor = nil
                stroke.lineJoin = .round
            }
            glowMask.strokeColor = .black
            lineMask.strokeColor = .black
            glowMask.lineWidth = 7
            lineMask.lineWidth = 1.6
            peaks.lineWidth = 1
        }
        plot = SpectrumGraphLayout(size: bounds.size, range: 12).plot
        let signal = Theme.signalColors.map(\.cg)
        // The gradients run across the plot, not the view, as the curve's do.
        let left = plot.minX / max(bounds.width, 1), right = plot.maxX / max(bounds.width, 1)
        for layer in [fill, glow, line] {
            layer.frame = bounds
            layer.colors = signal
            layer.startPoint = CGPoint(x: left, y: 0.5)
            layer.endPoint = CGPoint(x: right, y: 0.5)
        }
        fill.opacity = 0.42
        glow.opacity = 0.3
        // Fades the fill out toward the floor so the curve stays readable.
        fade.frame = bounds
        fade.colors = [Theme.well.opacity(0).cg, Theme.well.opacity(0.9).cg]
        fade.startPoint = CGPoint(x: 0.5, y: (plot.minY + plot.height * 0.35) / max(bounds.height, 1))
        fade.endPoint = CGPoint(x: 0.5, y: plot.maxY / max(bounds.height, 1))
        peaks.strokeColor = Theme.ink.opacity(0.26).cg
        for layer in [fillMask, fadeMask, glowMask, lineMask, peaks] { layer.frame = bounds }
    }

    override func tick(_ date: Date) {
        let values = spectrum(at: date)
        canvas.isHidden = !isLive
        guard isLive, plot.width > 0 else { return }
        let top = path(through: values)
        let area = top.mutableCopy() ?? CGMutablePath()
        area.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
        area.addLine(to: CGPoint(x: plot.minX, y: plot.maxY))
        area.closeSubpath()
        fillMask.path = area
        fadeMask.path = area
        glowMask.path = top
        lineMask.path = top
        peaks.path = path(through: smoother.peaks)
    }

    /// A smooth line through `values`, one point per spectrum bin.
    private func path(through values: [Float]) -> CGMutablePath {
        let path = CGMutablePath()
        guard values.count > 1 else { return path }
        func point(_ index: Int) -> CGPoint {
            let x = plot.minX + (CGFloat(index) + 0.5) / CGFloat(values.count) * plot.width
            let y = plot.maxY - CGFloat(min(1, max(0, values[index]))) * plot.height * 0.94
            return CGPoint(x: x, y: y)
        }
        let first = point(0)
        path.move(to: CGPoint(x: plot.minX, y: first.y))
        path.addLine(to: first)
        for index in 1..<values.count {
            let previous = point(index - 1)
            let current = point(index)
            let mid = CGPoint(x: (previous.x + current.x) / 2, y: (previous.y + current.y) / 2)
            path.addQuadCurve(to: mid, control: previous)
            if index == values.count - 1 {
                path.addQuadCurve(to: current, control: current)
            }
        }
        path.addLine(to: CGPoint(x: plot.maxX, y: point(values.count - 1).y))
        return path
    }
}

/// The spectrum under the response graph, for `SpectrumView`.
struct ResponseSpectrum: View {
    var body: some View {
        LiveMeter { ResponseSpectrumView(engine: $0, player: $1) }
            .allowsHitTesting(false)
    }
}

// MARK: - Level bar and latency

/// Output level as a slim bar: mint through amber to red at the top. It moves
/// when a meter reading arrives; there is no timer.
final class LevelBarView: LiveMeterView {
    private let track = CALayer()
    private let gradient = CAGradientLayer()
    private let reveal = CALayer()
    private var link: AnyCancellable?
    private var shown = -1.0

    override var rate: Double { 1 }

    override func rebuild() {
        if track.superlayer == nil {
            canvas.addSublayer(track)
            canvas.addSublayer(gradient)
            gradient.mask = reveal
            reveal.backgroundColor = .black
            reveal.anchorPoint = .zero
            link = engine.meters.$snapshot
                .map(\.level)
                .removeDuplicates()
                .sink { [weak self] in self?.show($0, animated: true) }
        }
        canvas.cornerRadius = bounds.height / 2
        canvas.masksToBounds = true
        track.frame = bounds
        track.backgroundColor = Theme.ink.opacity(0.08).cg
        gradient.frame = bounds
        gradient.colors = [Theme.mint.cg, Theme.mint.cg, Theme.amber.cg, Theme.red.cg]
        gradient.locations = [0, 0.6, 0.85, 1]
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        shown = -1
        show(engine.meters.snapshot.level, animated: false)
    }

    private func show(_ level: Double, animated: Bool) {
        let level = min(1, max(0, level))
        guard abs(level - shown) > 0.002 else { return }
        shown = level
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.07)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .linear))
        reveal.frame = CGRect(x: 0, y: 0, width: bounds.width * CGFloat(level), height: bounds.height)
        CATransaction.commit()
    }
}

/// The output level bar, for the Response card's header.
struct LiveLevelMeter: View {
    var body: some View {
        LiveMeter { LevelBarView(engine: $0, player: $1) }
            .allowsHitTesting(false)
    }
}

/// The route's output delay as text, redrawn only when the figure changes.
final class LatencyTextView: LiveMeterView {
    private let text = CATextLayer()
    private var link: AnyCancellable?

    override var rate: Double { 1 }

    override func rebuild() {
        if text.superlayer == nil {
            canvas.addSublayer(text)
            text.alignmentMode = .right
            link = engine.meters.$snapshot
                .map { ($0.latencyMs * 10).rounded() / 10 }
                .removeDuplicates()
                .sink { [weak self] in self?.show($0) }
        }
        let font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
        text.font = font
        text.fontSize = font.pointSize
        text.foregroundColor = Theme.ink.opacity(0.5).cg
        text.contentsScale = window?.backingScaleFactor ?? 2
        let height = ceil(font.ascender - font.descender + font.leading)
        text.frame = CGRect(x: 0, y: (bounds.height - height) / 2, width: bounds.width, height: height)
        show(engine.meters.snapshot.latencyMs)
    }

    private func show(_ ms: Double) {
        LiveMeterView.withoutAnimation {
            text.string = ms > 0 ? String(format: "%.1f ms", ms) : "— ms"
        }
    }
}

/// The latency figure, for the Response card's header.
struct LatencyChip: View {
    var body: some View {
        LiveMeter { LatencyTextView(engine: $0, player: $1) }
            .allowsHitTesting(false)
    }
}

// MARK: - Scrubber

/// Elapsed time, the position slider and the time remaining. The position is
/// polled, not published: ten times a second while playing, and on a jump
/// (seek, track change, play, pause) otherwise.
final class ScrubberView: NSView {
    static let height: CGFloat = 18
    private static let knobSize: CGFloat = 12

    private let player: PlayerEngine
    private let canvas = CALayer()
    private let elapsed = CATextLayer()
    private let remaining = CATextLayer()
    private let slider = CALayer()
    private let track = CALayer()
    private let glow = CALayer()
    private let fill = CAGradientLayer()
    private let reveal = CALayer()
    private let knob = CALayer()

    private var timer: Timer?
    private var links: Set<AnyCancellable> = []
    private var playing = false
    private var hovering = false
    private var dragging = false
    private var dragValue = 0.0
    private var builtSize = CGSize.zero
    private var area: NSTrackingArea?

    init(player: PlayerEngine) {
        self.player = player
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        canvas.isGeometryFlipped = true
        layer?.addSublayer(canvas)
        for layer in [elapsed, remaining, slider] { canvas.addSublayer(layer) }
        for layer in [track, glow, fill, knob] { slider.addSublayer(layer) }
        fill.mask = reveal
        reveal.backgroundColor = .black
        reveal.anchorPoint = .zero
        elapsed.alignmentMode = .right
        remaining.alignmentMode = .left
        knob.backgroundColor = .white
        knob.cornerRadius = Self.knobSize / 2
        knob.shadowColor = .black
        knob.shadowOpacity = 0.45
        knob.shadowRadius = 3
        knob.shadowOffset = CGSize(width: 0, height: 1)
        knob.opacity = 0

        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        setAccessibilityLabel("Position")

        player.$state
            .removeDuplicates()
            .sink { [weak self] state in
                guard let self else { return }
                self.playing = state == .playing
                self.updateTimer()
                // The new state is stored after this returns.
                DispatchQueue.main.async { [weak self] in self?.refresh() }
            }
            .store(in: &links)
        player.$track
            .sink { [weak self] _ in DispatchQueue.main.async { [weak self] in self?.refresh() } }
            .store(in: &links)
        player.timelineChanged
            .sink { [weak self] in self?.refresh() }
            .store(in: &links)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        guard bounds.size != builtSize else { return }
        builtSize = bounds.size
        rebuild()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTimer()
        if window != nil { rebuild() }
    }

    private var trackFrame: CGRect {
        CGRect(x: 54, y: 0, width: max(0, bounds.width - 54 - 58), height: bounds.height)
    }

    private func rebuild() {
        LiveMeterView.withoutAnimation {
            canvas.frame = bounds
            let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            let scale = window?.backingScaleFactor ?? 2
            let lineHeight = ceil(font.ascender - font.descender + font.leading)
            let y = (bounds.height - lineHeight) / 2
            for text in [elapsed, remaining] {
                text.font = font
                text.fontSize = font.pointSize
                text.foregroundColor = Theme.ink.opacity(0.6).cg
                text.contentsScale = scale
            }
            elapsed.frame = CGRect(x: 0, y: y, width: 44, height: lineHeight)
            remaining.frame = CGRect(x: bounds.width - 48, y: y, width: 48, height: lineHeight)
            slider.frame = trackFrame
            track.backgroundColor = Theme.ink.opacity(0.12).cg
            fill.colors = Theme.signalColors.map(\.cg)
            fill.startPoint = CGPoint(x: 0, y: 0.5)
            fill.endPoint = CGPoint(x: 1, y: 0.5)
            glow.shadowOpacity = 0.5
            glow.shadowRadius = 5
            glow.shadowOffset = .zero
        }
        refresh()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        self.area = area
    }

    // MARK: Drawing

    private var duration: Double { max(player.track?.duration ?? 0, 0.001) }
    private var isEnabled: Bool { player.track != nil && player.state != .stopped }
    private var position: Double { dragging ? dragValue : min(player.currentTime(), duration) }

    private func updateTimer() {
        let wanted = playing && window != nil
        if wanted, timer == nil {
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let window = self.window,
                          window.occlusionState.contains(.visible) else { return }
                    self.refresh()
                }
            }
            timer.tolerance = 0.03
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else if !wanted, let timer {
            timer.invalidate()
            self.timer = nil
        }
    }

    private func refresh() {
        guard bounds.width > 0 else { return }
        let duration = duration, position = position
        let frame = trackFrame
        let fraction = CGFloat(min(1, max(0, position / duration)))
        let x = Self.knobSize / 2 + max(0, frame.width - Self.knobSize) * fraction
        let thick: CGFloat = hovering || dragging ? 5 : 4
        let lit = isEnabled && fraction > 0.001
        let top = (frame.height - thick) / 2

        LiveMeterView.withoutAnimation {
            let before = Self.format(position), after = "-" + Self.format(max(0, duration - position))
            if elapsed.string as? String != before { elapsed.string = before }
            if remaining.string as? String != after { remaining.string = after }

            slider.opacity = isEnabled ? 1 : 0.45
            track.frame = CGRect(x: 0, y: top, width: frame.width, height: thick)
            track.cornerRadius = thick / 2
            // The gradient spans the whole track and the fill reveals it, so
            // a colour always sits at the same position.
            fill.frame = track.frame
            fill.cornerRadius = thick / 2
            reveal.frame = CGRect(x: 0, y: 0, width: lit ? x : 0, height: thick)
            glow.frame = fill.frame
            glow.shadowColor = Theme.signalColor(at: Double(fraction)).cg
            glow.shadowPath = lit ? CGPath(roundedRect: CGRect(x: 0, y: 0, width: max(x, thick), height: thick),
                                           cornerWidth: thick / 2, cornerHeight: thick / 2, transform: nil) : nil
            knob.frame = CGRect(x: x - Self.knobSize / 2, y: (frame.height - Self.knobSize) / 2,
                                width: Self.knobSize, height: Self.knobSize)
        }
        // The knob fades in under the pointer; this one change is animated.
        let knobOpacity: Float = (hovering || dragging) && isEnabled ? 1 : 0
        if knob.opacity != knobOpacity { knob.opacity = knobOpacity }
    }

    private static func format(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    // MARK: Mouse

    private func value(at event: NSEvent) -> Double {
        let x = convert(event.locationInWindow, from: nil).x - trackFrame.minX
        let usable = max(1, trackFrame.width - Self.knobSize)
        let fraction = Double(min(max((x - Self.knobSize / 2) / usable, 0), 1))
        return fraction * duration
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isEnabled, let superview else { return nil }
        return trackFrame.contains(convert(point, from: superview)) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        dragging = true
        dragValue = value(at: event)
        refresh()
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging else { return }
        dragValue = value(at: event)
        refresh()
    }

    override func mouseUp(with event: NSEvent) {
        guard dragging else { return }
        dragValue = value(at: event)
        player.seek(to: dragValue)
        dragging = false
        refresh()
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        refresh()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        refresh()
    }

    // MARK: Accessibility

    override func accessibilityValue() -> Any? {
        "\(Self.format(position)) of \(Self.format(duration))"
    }

    override func isAccessibilityEnabled() -> Bool { isEnabled }

    override func accessibilityPerformIncrement() -> Bool { nudge(1) }
    override func accessibilityPerformDecrement() -> Bool { nudge(-1) }

    private func nudge(_ direction: Double) -> Bool {
        guard isEnabled else { return false }
        player.seek(to: min(duration, max(0, position + direction * duration / 20)))
        return true
    }
}

/// The scrubber, for `PlayerBar`.
struct Scrubber: NSViewRepresentable {
    @EnvironmentObject private var player: PlayerEngine

    func makeNSView(context: Context) -> ScrubberView { ScrubberView(player: player) }
    func updateNSView(_ view: ScrubberView, context: Context) {}
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ScrubberView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 300, height: ScrubberView.height)
    }
}
