import AppKit

// Frames are pre-rendered (logo plus the badge at each rotation) so the timer
// only swaps the displayed image.
@MainActor
final class TrayIconAnimator {
    private weak var button: NSStatusBarButton?
    private let idleImage: NSImage?
    private let frames: [NSImage]
    private var timer: Timer?
    private var frameIndex = 0

    init(button: NSStatusBarButton?, idleImage: NSImage?) {
        self.button = button
        self.idleImage = idleImage
        frames = TrayIconAnimator.makeSpinnerFrames(base: idleImage)
    }

    func setAnimating(_ animating: Bool) {
        if animating {
            start()
        } else {
            stop()
        }
    }

    private func start() {
        guard timer == nil, !frames.isEmpty else { return }
        frameIndex = 0
        button?.image = frames[0]
        let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.advance() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func advance() {
        guard !frames.isEmpty else { return }
        frameIndex = (frameIndex + 1) % frames.count
        button?.image = frames[frameIndex]
    }

    private func stop() {
        guard timer != nil else { return }
        timer?.invalidate()
        timer = nil
        button?.image = idleImage
    }

    private static func makeSpinnerFrames(base: NSImage?) -> [NSImage] {
        guard let base else {
            return []
        }
        let size = NSSize(width: 18, height: 18)
        let config = NSImage.SymbolConfiguration(pointSize: 8, weight: .heavy)
        guard
            let arrows = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "Working")?
                .withSymbolConfiguration(config)
        else {
            return []
        }
        let frameCount = 12
        return (0..<frameCount).map { index in
            // Negative angle so the arrows turn clockwise.
            badgedFrame(base: base, arrows: arrows, degrees: -CGFloat(index) / CGFloat(frameCount) * 360, size: size)
        }
    }

    private static func badgedFrame(base: NSImage, arrows: NSImage, degrees: CGFloat, size: NSSize) -> NSImage {
        let frame = NSImage(size: size)
        frame.lockFocus()
        base.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 1)

        let badgeDiameter: CGFloat = 11
        let badgeRect = NSRect(x: size.width - badgeDiameter, y: 0, width: badgeDiameter, height: badgeDiameter)
        NSColor.white.setFill()
        NSBezierPath(ovalIn: badgeRect).fill()

        let center = NSPoint(x: badgeRect.midX, y: badgeRect.midY)
        let transform = NSAffineTransform()
        transform.translateX(by: center.x, yBy: center.y)
        transform.rotate(byDegrees: degrees)
        transform.translateX(by: -center.x, yBy: -center.y)
        transform.concat()
        let arrowBox: CGFloat = 8
        arrows.draw(
            in: NSRect(x: center.x - arrowBox / 2, y: center.y - arrowBox / 2, width: arrowBox, height: arrowBox),
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: nil
        )

        frame.unlockFocus()
        frame.isTemplate = false
        return frame
    }
}
