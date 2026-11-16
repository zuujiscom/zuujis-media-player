// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Combine
import SwiftUI

// Synced lyrics, drawn with Core Animation layers for the same reason as the
// views in `LiveViews.swift`: as SwiftUI rows, every word that lit up and
// every frame of a line change re-rendered the whole main window (20-25% CPU
// with the card showing). Here a line change is one transaction of layer
// animations, which the window server runs by itself.

/// A layer that draws wrapped attributed text with the same engine that
/// measures it, so a line's height and its wrapping always agree.
private final class TextLayer: CALayer {
    var text = NSAttributedString() {
        didSet { if text != oldValue { setNeedsDisplay() } }
    }

    override init() {
        super.init()
        needsDisplayOnBoundsChange = true
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func action(forKey event: String) -> CAAction? {
        // New text appears at once; only opacity and geometry animate.
        event == "contents" ? NSNull() : super.action(forKey: event)
    }

    override func draw(in context: CGContext) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        text.draw(with: bounds, options: [.usesLineFragmentOrigin, .usesFontLeading])
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// The synced lyrics list. The line being sung is full size and lit in the
/// signal colours (word by word when the line has word times), the lines
/// around it fade with distance, and the list scrolls to keep it at the
/// reading position. Click a line to jump to it; scroll to look around.
final class SyncedLyricsView: NSView {
    private struct Row {
        let line: LyricLine
        let layer = CALayer()
        let dim = TextLayer()
        let lit = CAGradientLayer()
        let litMask = TextLayer()
        var height: CGFloat = 0
        var top: CGFloat = 0
    }

    private static let restingScale: CGFloat = 0.82
    private static let inset: CGFloat = 22
    private static let spacing: CGFloat = 10
    /// Where the current line sits, as a fraction of the box's height.
    private static let readingPosition: CGFloat = 0.36

    private let player: PlayerEngine
    private let store: LyricsStore
    private let canvas = CALayer()
    private let content = CALayer()
    private let fade = CAGradientLayer()
    private var rows: [Row] = []
    private var font = NSFont.boldSystemFont(ofSize: 20)

    private var current: Int?
    private var sung = 0
    private var hovered: Int?
    private var offset: CGFloat = 0
    private var contentHeight: CGFloat = 0
    private var builtSize = CGSize.zero
    private var playing = false
    private var timer: Timer?
    private var links: Set<AnyCancellable> = []
    private var area: NSTrackingArea?

    var lyrics: Lyrics? {
        didSet {
            guard lyrics != oldValue else { return }
            current = nil
            sung = 0
            offset = 0
            rebuild()
        }
    }

    init(player: PlayerEngine, store: LyricsStore) {
        self.player = player
        self.store = store
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        canvas.isGeometryFlipped = true
        canvas.masksToBounds = true
        canvas.mask = fade
        canvas.addSublayer(content)
        layer?.addSublayer(canvas)
        content.anchorPoint = .zero
        fade.colors = [CGColor.clear, CGColor.black, CGColor.black, CGColor.clear]
        fade.locations = [0, 0.12, 0.82, 1]
        fade.startPoint = CGPoint(x: 0.5, y: 0)
        fade.endPoint = CGPoint(x: 0.5, y: 1)

        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("Lyrics")

        player.$state
            .removeDuplicates()
            .sink { [weak self] state in
                guard let self else { return }
                self.playing = state == .playing
                self.updateTimer()
                DispatchQueue.main.async { [weak self] in self?.follow() }
            }
            .store(in: &links)
        player.timelineChanged
            .sink { [weak self] in self?.follow() }
            .store(in: &links)
        // Published before it is stored, so read it a turn later.
        store.$offset
            .sink { [weak self] _ in DispatchQueue.main.async { [weak self] in self?.follow() } }
            .store(in: &links)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override func accessibilityValue() -> Any? {
        current.flatMap { rows.indices.contains($0) ? rows[$0].line.text : nil }
            ?? lyrics?.lines.map(\.text).joined(separator: "\n")
    }

    // MARK: Building

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

    private func attributed(_ text: String, color: NSColor) -> NSMutableAttributedString {
        NSMutableAttributedString(string: text, attributes: [.font: font, .kern: -0.2, .foregroundColor: color])
    }

    private func display(_ line: LyricLine) -> String {
        if let words = line.words, !words.isEmpty { return words.map(\.text).joined(separator: " ") }
        return line.text.isEmpty ? "♪" : line.text
    }

    private func rebuild() {
        LiveMeterView.withoutAnimation {
            rows.forEach { $0.layer.removeFromSuperlayer() }
            rows = []
            canvas.frame = bounds
            fade.frame = bounds
            guard let lyrics, bounds.width > 2 * Self.inset + 20, bounds.height > 20 else { return }

            font = NSFont.systemFont(ofSize: min(26, max(15, bounds.width / 17)), weight: .bold)
            let width = bounds.width - 2 * Self.inset
            let scale = window?.backingScaleFactor ?? 2
            let ink = NSColor(Theme.ink)
            let signal = Theme.signalColors.map(\.cg)
            let glow = Theme.violet.cg

            rows = lyrics.lines.map { line in
                var row = Row(line: line)
                let text = attributed(display(line), color: ink)
                row.height = ceil(text.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                                    options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
                let frame = CGRect(x: 0, y: 0, width: width, height: row.height)
                row.layer.anchorPoint = .zero
                row.layer.bounds = frame
                row.layer.shadowColor = glow
                row.layer.shadowRadius = 10
                row.layer.shadowOffset = .zero
                row.layer.shadowOpacity = 0
                row.dim.frame = frame
                row.dim.contentsScale = scale
                row.dim.text = text
                row.lit.frame = frame
                row.lit.colors = signal
                row.lit.startPoint = CGPoint(x: 0, y: 0.5)
                row.lit.endPoint = CGPoint(x: 1, y: 0.5)
                row.lit.opacity = 0
                row.litMask.frame = frame
                row.litMask.contentsScale = scale
                row.lit.mask = row.litMask
                row.layer.addSublayer(row.dim)
                row.layer.addSublayer(row.lit)
                content.addSublayer(row.layer)
                return row
            }
            arrange(scrolling: true)
        }
        follow()
    }

    // MARK: Following the song

    private func updateTimer() {
        let wanted = playing && window != nil
        if wanted, timer == nil {
            let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let window = self.window,
                          window.occlusionState.contains(.visible) else { return }
                    self.follow()
                }
            }
            timer.tolerance = 0.01
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else if !wanted, let timer {
            timer.invalidate()
            self.timer = nil
        }
    }

    /// Finds the line and word being sung; touches the layers only on a change.
    private func follow() {
        guard let lyrics, !rows.isEmpty else { return }
        let time = store.time(for: player)
        let index = lyrics.currentIndex(at: time)
        let words = index.map { lyrics.lines[$0].wordsSung(at: time) } ?? 0
        guard index != current || words != sung else { return }
        let lineChanged = index != current
        current = index
        sung = words
        if lineChanged {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.5)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
            arrange(scrolling: true)
            CATransaction.commit()
        } else if let index {
            LiveMeterView.withoutAnimation { light(index) }
        }
    }

    /// Sets which words of the current line the gradient shows through.
    private func light(_ index: Int) {
        let row = rows[index]
        guard let words = row.line.words, !words.isEmpty else {
            row.litMask.text = attributed(display(row.line), color: .black)
            return
        }
        let text = attributed(display(row.line), color: .clear)
        let lit = words.prefix(sung).map(\.text).joined(separator: " ")
        text.addAttribute(.foregroundColor, value: NSColor.black, range: NSRange(location: 0, length: (lit as NSString).length))
        row.litMask.text = text
    }

    /// Places every row for the current line and, when asked, scrolls to it.
    private func arrange(scrolling: Bool) {
        var y = max(34, bounds.height * 0.36)
        for index in rows.indices {
            let active = index == current
            let scale = active ? 1 : Self.restingScale
            let near = abs(current.map { index - $0 } ?? (index + 1))
            let row = rows[index]
            rows[index].top = y
            row.layer.position = CGPoint(x: Self.inset, y: y)
            row.layer.transform = CATransform3DMakeScale(scale, scale, 1)
            row.layer.shadowOpacity = active ? 0.55 : 0
            let hasWords = !(row.line.words ?? []).isEmpty
            if active {
                light(index)
                row.dim.opacity = hasWords ? 0.42 : 0
                row.lit.opacity = 1
            } else {
                row.dim.opacity = index == hovered ? 0.8 : Float(max(0.16, 0.55 - 0.1 * Double(near)))
                row.lit.opacity = 0
            }
            y += row.height * scale + Self.spacing
        }
        contentHeight = y - Self.spacing + bounds.height * 0.55
        if scrolling {
            if let current, rows.indices.contains(current) {
                let row = rows[current]
                offset = row.top + (row.height - bounds.height) * Self.readingPosition
            } else {
                offset = 0
            }
        }
        scroll(to: offset)
    }

    private func scroll(to target: CGFloat) {
        offset = min(max(0, target), max(0, contentHeight - bounds.height))
        content.position = CGPoint(x: 0, y: -offset)
    }

    // MARK: Mouse

    private func row(at event: NSEvent) -> Int? {
        let point = convert(event.locationInWindow, from: nil)
        let y = bounds.height - point.y + offset
        return rows.firstIndex { row in
            let scale = row.line.id == current ? 1 : Self.restingScale
            return y >= row.top && y <= row.top + row.height * scale
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        self.area = area
    }

    private func hover(_ index: Int?) {
        guard index != hovered else { return }
        hovered = index
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.15)
        for index in rows.indices where index != current {
            let near = abs(current.map { index - $0 } ?? (index + 1))
            rows[index].dim.opacity = index == hovered ? 0.8 : Float(max(0.16, 0.55 - 0.1 * Double(near)))
        }
        CATransaction.commit()
    }

    override func mouseMoved(with event: NSEvent) { hover(row(at: event)) }
    override func mouseExited(with event: NSEvent) { hover(nil) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseUp(with event: NSEvent) {
        guard let index = row(at: event), let time = rows[index].line.time else { return }
        player.seek(to: time)
    }

    /// Looking around by hand; the next line change brings the list back.
    override func scrollWheel(with event: NSEvent) {
        guard !rows.isEmpty else { return }
        LiveMeterView.withoutAnimation { scroll(to: offset - event.scrollingDeltaY) }
        hover(row(at: event))
    }
}

/// The synced lyrics list, for `LyricsBox`.
struct SyncedLyrics: NSViewRepresentable {
    @EnvironmentObject private var player: PlayerEngine
    @EnvironmentObject private var store: LyricsStore
    let lyrics: Lyrics

    func makeNSView(context: Context) -> SyncedLyricsView {
        let view = SyncedLyricsView(player: player, store: store)
        view.lyrics = lyrics
        return view
    }

    func updateNSView(_ view: SyncedLyricsView, context: Context) { view.lyrics = lyrics }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SyncedLyricsView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 300, height: 300))
    }
}
