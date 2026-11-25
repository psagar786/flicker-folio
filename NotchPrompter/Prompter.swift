import AppKit
import Combine
import CoreMedia
import QuartzCore
import SwiftUI
import NotchPrompterKit

final class PrompterPanel: NSPanel {
    weak var controller: Prompter?
    override var canBecomeKey: Bool { true }
    // Allow the window to sit over the menu bar / notch area.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, controller?.handleKey(event) == true { return }
        super.sendEvent(event)
    }
}

/// The panel's content view: edge and corner resizing, clicks on words, file drops, hover.
final class RootView: NSView {
    weak var controller: Prompter?

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL])?.first
        else { return false }
        return controller?.importAndShow(url) ?? false
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self))
    }
    override func mouseEntered(with event: NSEvent) { controller?.hovering = true }
    override func mouseExited(with event: NSEvent) {
        controller?.hovering = false
        if drag == nil { NSCursor.arrow.set() }
    }

    // MARK: Resize by dragging the left, right or bottom edge, or a bottom corner

    /// side: -1 = left edge, 1 = right edge, 0 = neither. bottom: the bottom edge.
    struct Grip { var side: CGFloat; var bottom: Bool }
    private let edgeSize: CGFloat = 7
    private let cornerSize: CGFloat = 22
    private var drag: (grip: Grip, start: NSPoint, width: Double, height: Double)?

    private func grip(at p: NSPoint) -> Grip? {
        let w = bounds.width
        if p.y < cornerSize && p.x < cornerSize { return Grip(side: -1, bottom: true) }
        if p.y < cornerSize && p.x > w - cornerSize { return Grip(side: 1, bottom: true) }
        if p.x < edgeSize { return Grip(side: -1, bottom: false) }
        if p.x > w - edgeSize { return Grip(side: 1, bottom: false) }
        if p.y < edgeSize { return Grip(side: 0, bottom: true) }
        return nil
    }

    // Claim clicks on the edges and on the text, so we can resize and jump to a word.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if bounds.contains(local), grip(at: local) != nil { return self }
        let hit = super.hitTest(point)
        if let c = controller, hit === c.text || hit === c.scroll || hit === c.scroll.contentView { return self }
        return hit
    }
    override func scrollWheel(with event: NSEvent) {
        guard let controller else { return }
        controller.scroll.scrollWheel(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        guard drag == nil else { return }
        guard let g = grip(at: convert(event.locationInWindow, from: nil)) else { NSCursor.arrow.set(); return }
        let position: NSCursor.FrameResizePosition
        switch (g.side, g.bottom) {
        case (-1, true): position = .bottomLeft
        case (1, true): position = .bottomRight
        case (-1, false): position = .left
        case (1, false): position = .right
        default: position = .bottom
        }
        NSCursor.frameResize(position: position, directions: .all).set()
    }

    override func mouseDown(with event: NSEvent) {
        guard let c = controller else { return }
        guard let g = grip(at: convert(event.locationInWindow, from: nil)) else { c.clickText(event); return }
        drag = (g, NSEvent.mouseLocation, c.settings.width, c.settings.height)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let d = drag, let c = controller else { return }
        let dx = NSEvent.mouseLocation.x - d.start.x
        let dy = NSEvent.mouseLocation.y - d.start.y
        // The panel stays centred under the camera, so width changes by twice the drag distance.
        if d.grip.side != 0 {
            c.settings.width = (d.width + c.widthPercentDelta(points: 2 * dx * d.grip.side)).rounded().clamped(to: AppSettings.widthRange)
        }
        if d.grip.bottom {
            c.settings.height = (d.height - Double(dy)).rounded().clamped(to: AppSettings.heightRange)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if drag != nil { controller?.finishDocumentResize() }
        drag = nil
    }
    override func layout() { super.layout(); controller?.layoutViews() }
}

final class ControlButton: NSButton {
    private let onClick: () -> Void
    private let pointSize: CGFloat

    init(_ symbol: String, _ tip: String, size: CGFloat = 12, width: CGFloat = 24, _ onClick: @escaping () -> Void) {
        self.onClick = onClick
        self.pointSize = size
        super.init(frame: .zero)
        toolTip = tip
        setAccessibilityLabel(tip)
        isBordered = false
        imagePosition = .imageOnly
        contentTintColor = ControlButton.normalTint
        setSymbol(symbol)
        target = self
        action = #selector(fire)
        widthAnchor.constraint(equalToConstant: width).isActive = true
        heightAnchor.constraint(equalToConstant: 22).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    static let normalTint = NSColor(white: 1, alpha: 0.85)

    func setSymbol(_ name: String) {
        image = NSImage(systemSymbolName: name, accessibilityDescription: toolTip)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: .semibold))
    }
    @objc private func fire() { onClick() }
    /// Optional: what a right-click (or Control-click) does.
    var onRightClick: (() -> Void)?
    override func rightMouseDown(with event: NSEvent) {
        if let onRightClick { onRightClick() } else { super.rightMouseDown(with: event) }
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The teleprompter that hangs from the notch.
final class Prompter: NSObject, NSPopoverDelegate {
    let settings: AppSettings
    let library: ScriptLibrary
    /// Called when the user wants to edit scripts (pencil button, empty script).
    var onOpenEditor: () -> Void = {}
    /// Opens the Settings window ("All Settings…" in the popovers).
    var onOpenSettings: () -> Void = {}
    var onSwitchScript: () -> Void = {}

    let panel: PrompterPanel
    let root = RootView()
    let scroll: NSScrollView
    let text: NSTextView
    private let hud = NSTextField(labelWithString: "")
    private let countdownLabel = NSTextField(labelWithString: "")
    private let fade = CAGradientLayer()
    private let captureIndicator = NSImageView()
    private let readingMarker = CALayer()
    private let readingLabel = NSTextField(labelWithString: "")
    private let footerHeight: CGFloat = 25
    private let listeningColor = NSColor(srgbRed: 0.52, green: 0.91, blue: 0.86, alpha: 1)
    private var screen: NSScreen
    private var notchHeight: CGFloat
    private var subscriptions = Set<AnyCancellable>()

    private var offset: CGFloat = 0
    private var lastTick = CACurrentMediaTime()
    private var lastDisplayFrame = 0.0
    private var displayLink: CADisplayLink?
    private var playbackFallback: Timer?
    private var documentViewport = NSSize.zero
    private var layoutWork: DispatchWorkItem?
    private var queuedViewport: NSSize?
    private var pendingTimedProgress: Double?
    private var fontWork: DispatchWorkItem?
    private var adjustingScroll = false
    private var timedPacing = TimedPacing()
    private var conversationalPacing = ConversationalPacing()
    private var readingStarted = false
    private var readingFinished = false
    private var hudHideWork: DispatchWorkItem?
    private let bar = NSStackView()
    private let barBackground = NSView()
    private var playButton: ControlButton!
    private var micButton: ControlButton!
    private var activeReadingMode = ReadingMode.timed
    private var microphoneReady = false
    private var lastManualScroll = -Double.infinity
    private var pacing: ScrollPacing?
    private var pacingViewport = NSSize.zero
    private var settingsButton: ControlButton!
    var hovering = false { didSet { updateBar() } }
    private(set) var playing = false { didSet { updateBar() } }
    private var countdownWork: [DispatchWorkItem] = []
    private var countingDown: Bool { !countdownWork.isEmpty }

    // Recording
    private let recorder = Recorder()
    private let screenRecorder = ScreenRecorder()
    private var recordButton: ControlButton!
    /// The chevron beside the record button: camera, recording mode and screen light.
    private var recordOptionsButton: ControlButton!
    private let recordPopover = NSPopover()
    private let recLabel = NSTextField(labelWithString: "")
    private let cameraPreview = CameraPreviewPanel()
    private let screenLight = ScreenLightPanel()
    /// The movies of the last take, so a bad one can be played or thrown away right after.
    let lastTake = LastTake()
    /// Filming: the camera movie, the screen movie, or both are being saved.
    var isRecording: Bool { recorder.isRecording || screenRecorder.isRecording }
    private var liveRecordingStart: Date? {
        [recorder.isWriting ? recorder.startedAt : nil,
         screenRecorder.isWriting ? screenRecorder.startedAt : nil].compactMap { $0 }.min()
    }
    private var finishingTake = false
    private var finishCallbacks: [() -> Void] = []

    // Voice-follow
    private let voice = VoiceListener()
    private var shownLevel: CGFloat = 0
    private var matcher = VoiceMatcher()
    private var shownScriptID: UUID?
    private var shownText = ""
    private var shownSource = ""
    private var skippingBlankLines = false
    private var markup = NoteMarkup("")
    private var sentenceStops: [Int] = []
    private var sentenceViewport = NSSize.zero
    private var sentenceIndex = 0
    private var sentenceElapsed = 0.0
    private var lastAdvance = CACurrentMediaTime()
    private var lostHintShown = false
    private(set) var listening = false {
        didSet {
            updateBar()
            updateProgress()
            layoutViews()
        }
    }

    var isVisible: Bool { panel.isVisible }

    init(settings: AppSettings = .shared, library: ScriptLibrary = .shared) {
        self.settings = settings
        self.library = library
        screen = NSScreen.forPrompter(settings.display) ?? NSScreen.screens[0]
        notchHeight = screen.safeAreaInsets.top
        panel = PrompterPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        scroll = NSTextView.scrollableTextView()
        text = scroll.documentView as! NSTextView
        super.init()

        panel.controller = self
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.setAccessibilityLabel(String(localized: "Teleprompter"))

        root.controller = self
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.black.cgColor
        root.layer?.cornerRadius = 20
        readingMarker.backgroundColor = NSColor(srgbRed: 1, green: 0.67, blue: 0.32, alpha: 1).cgColor
        readingMarker.cornerRadius = 1.5
        root.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]  // round bottom only
        root.registerForDraggedTypes([.fileURL])
        panel.contentView = root

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .legacy
        scroll.appearance = NSAppearance(named: .darkAqua)
        scroll.autohidesScrollers = false
        scroll.verticalScroller?.controlSize = .regular
        scroll.verticalScroller?.knobStyle = .light
        scroll.hasHorizontalScroller = false
        scroll.wantsLayer = true
        fade.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        fade.locations = [0, 0.12, 0.8, 1]
        scroll.layer?.mask = fade
        root.addSubview(scroll)
        captureIndicator.imageScaling = .scaleProportionallyDown
        captureIndicator.contentTintColor = .systemRed
        captureIndicator.isHidden = true
        root.addSubview(captureIndicator)
        root.layer?.addSublayer(readingMarker)

        _ = text.layoutManager   // use TextKit 1: we need word positions and temporary colours
        text.isVerticallyResizable = false
        text.isHorizontallyResizable = false
        text.autoresizingMask = []
        text.textContainer?.widthTracksTextView = false
        text.textContainer?.heightTracksTextView = false
        scroll.contentView.postsBoundsChangedNotifications = true
        text.isEditable = false
        text.isSelectable = false
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 18, height: 6)
        text.unregisterDraggedTypes()

        hud.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        hud.textColor = NSColor(white: 1, alpha: 0.6)
        hud.alignment = .center
        hud.wantsLayer = true
        hud.layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.94).cgColor
        hud.layer?.cornerRadius = 5
        hud.alphaValue = 0
        root.addSubview(hud)

        countdownLabel.font = .monospacedDigitSystemFont(ofSize: 44, weight: .bold)
        countdownLabel.textColor = .white
        countdownLabel.alignment = .center
        countdownLabel.isHidden = true
        root.addSubview(countdownLabel)


        let openAll = { [unowned self] in
            recordPopover.performClose(nil)
            onOpenSettings()
        }
        recordPopover.contentViewController = NSHostingController(rootView: RecordingPopoverView(
            settings: settings, lastTake: lastTake,
            play: { [unowned self] in playLastTake() },
            trash: { [unowned self] in trashLastTake() },
            openAll: openAll))
        recordPopover.behavior = .transient
        recordPopover.appearance = NSAppearance(named: .darkAqua)
        recordPopover.delegate = self

        voice.onWords = { [unowned self] task, heard in
            if matcher.follow(heard, task: task) {
                lastAdvance = CACurrentMediaTime()
                lostHintShown = false
                updateProgress()
            }
        }
        voice.onStatus = { [unowned self] msg in showHUD(msg, for: 3) }
        voice.onStopped = { [unowned self] in
            listening = false
            if activeReadingMode == .conversational { playing = false; microphoneReady = false }
            if activeReadingMode == .followWords, isRecording {
                showHUD("Speech following stopped. Scroll manually or use Timed mode.", for: 5)
            }
        }
        voice.onPermissionProblem = { [unowned self] message, url in
            showPermissionAlert(String(localized: "Allow access for this reading mode"),
                                message + "\n\n" + String(localized: "You can switch to Timed mode without microphone access."), url)
        }
        voice.onNeedsDictation = {
            let alert = NSAlert()
            alert.messageText = String(localized: "Turn on Dictation to follow your voice on this Mac")
            alert.informativeText = String(localized: "Flicker Folio recognises speech on your Mac, so your voice never leaves it. macOS only allows this when Dictation is on.\n\nTurn on Dictation in System Settings → Keyboard, then press the microphone again. Or use Timed or Conversational mode.")
            alert.addButton(withTitle: String(localized: "Open Keyboard Settings"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            NSApp.activate()
            switch alert.runModal() {
            case .alertFirstButtonReturn: NSWorkspace.shared.open(VoiceListener.dictationSettings)
            default: break
            }
        }
        // With the camera, its movie is the take; the screen movie only reports problems.
        screenRecorder.onFinished = { [unowned self] url, problem in
            if discardTake { url.map { try? FileManager.default.removeItem(at: $0) }; return }
            if takeMode.usesCamera {
                lastTake.screen = url
                if let problem { showHUD(problem, for: 5) }
            } else {
                takeFinished(url, problem)
            }
        }
        recorder.onFinished = { [unowned self] url, problem in takeFinished(url, problem) }

        readingLabel.font = .systemFont(ofSize: 11, weight: .medium)
        readingLabel.lineBreakMode = .byTruncatingTail
        root.addSubview(readingLabel)
        recLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        recLabel.alignment = .right
        root.addSubview(recLabel)

        buildBar()
        observe()
        placeWindow()

        let link = panel.displayLink(target: self, selector: #selector(displayTick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in
            guard let self, panel.isVisible, CACurrentMediaTime() - lastDisplayFrame > 0.12 else { return }
            tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        playbackFallback = timer
    }

    private func takeFinished(_ url: URL?, _ problem: String?) {
        updateBar()
        layoutViews()
        if discardTake { url.map { try? FileManager.default.removeItem(at: $0) }; return }
        if !isRecording && !pendingRecording {
            pauseReading()
            voice.useExternalAudio = false
            hideTakeWindows()
        }
        if let problem { showHUD(problem, for: 5); return }
        guard let url else { return }
        if takeMode.usesCamera { lastTake.camera = url } else { lastTake.screen = url }
        if settings.saveTranscripts { TakeTranscriber.transcribe(url, locale: voiceLocale, hints: voice.hints) }
        // The first time, show where takes go. After that, a short note is enough.
        let key = "hasRevealedRecording"
        if !UserDefaults.standard.bool(forKey: key) {
            UserDefaults.standard.set(true, forKey: key)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        showHUD(String(localized: "Saved in Movies › Flicker Folio. ⌘⌫ moves it to the Trash.",
                       comment: "Use the Finder name of the Movies folder in this language"), for: 4)
    }

    /// Open the last take's movie (the camera one, when there are two) in the movie player.
    func playLastTake() {
        guard !isRecording, let url = lastTake.movies.first else { return }
        NSWorkspace.shared.open(url)
    }

    /// Move the last take's movies to the Trash, for a quick retake.
    func trashLastTake() {
        guard !isRecording, !pendingRecording else { return }
        let movies = lastTake.movies
        guard !movies.isEmpty else { return }
        let files = movies + movies.map(TakeTranscriber.transcript(for:))
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        do {
            for url in files { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
            lastTake.clear()
            showHUD(String(localized: "Moved the take to the Trash"), for: 3)
        } catch {
            showHUD(String(localized: "Couldn't move the take to the Trash: \(error.localizedDescription)",
                           comment: "The placeholder is the system's error message"), for: 5)
        }
    }

    private func observe() {
        // Publishers fire before the property changes, so use the value they send.
        settings.$fontSize.combineLatest(settings.$textColor, settings.$fontStyle)
            .dropFirst().sink { [weak self] _, _, _ in
                guard let self else { return }
                fontWork?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    fontWork = nil
                    placeWindow()
                    renderText()
                    restoreReadingPosition()
                }
                fontWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.09, execute: work)
            }.store(in: &subscriptions)
        settings.$showReadingLine.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.renderText()
                self?.layoutViews()
            }
        }.store(in: &subscriptions)
        settings.$readingMode.dropFirst().sink { [weak self] mode in
            guard let self else { return }
            if mode != activeReadingMode, playing || listening || (countingDown && !pendingRecording) {
                pauseReading()
            }
            updatePromptSpacing(for: mode)
        }.store(in: &subscriptions)
        settings.$width.combineLatest(settings.$height).sink { [weak self] w, h in
            self?.placeWindow(width: w, height: h)
        }.store(in: &subscriptions)
        settings.$hideFromScreenSharing.sink { [weak self] hide in
            self?.panel.sharingType = hide ? .none : .readOnly
        }.store(in: &subscriptions)
        settings.$screenLight.combineLatest(settings.$recordingMode).sink { [weak self] light, mode in
            DispatchQueue.main.async { self?.previewScreenLight(light, mode) }
        }.store(in: &subscriptions)
        // During a take the voice hears the take's microphone, which is chosen when the take starts.
        settings.$microphoneID.dropFirst().removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, !isRecording, !pendingRecording else { return }
                restartVoiceIfListening()
            }
        }.store(in: &subscriptions)
        settings.$voiceLanguage.dropFirst().removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.restartVoiceIfListening() }
        }.store(in: &subscriptions)
        // Follow screens as they come and go: a closed lid, a projector, a dock.
        settings.$display.dropFirst().removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateScreen() }
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.updateScreen() }
            .store(in: &subscriptions)
        library.$scripts.combineLatest(library.$activeID).sink { [weak self] _, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.show(self.library.active)
            }
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSView.boundsDidChangeNotification, object: scroll.contentView)
            .sink { [weak self] _ in
                guard let self, !adjustingScroll,
                      abs(scroll.contentView.bounds.origin.y - offset) > 0.5 else { return }
                manualScrollDidMove()
            }.store(in: &subscriptions)
    }

    // MARK: Showing and hiding

    func showPanel() {
        placeWindow()
        panel.orderFrontRegardless()
    }

    func hidePanel() {
        if !isRecording && !pendingRecording { pauseReading() }
        recordPopover.performClose(nil)
        panel.orderOut(nil)
    }

    func togglePanel() {
        if isVisible { hidePanel() }
        else { showPanel(); panel.makeKey() }
    }

    /// Stop scrolling, listening and recording.
    func stopAll() {
        pauseReading()
        if isRecording || pendingRecording { stopRecording() }
    }

    func showPermissionAlert(_ title: String, _ message: String, _ url: URL) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: String(localized: "Open System Settings"))
        alert.addButton(withTitle: String(localized: "Not Now"))
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(url) }
    }

    // MARK: Layout

    private func updateScreen() {
        guard let new = NSScreen.forPrompter(settings.display) else { return }
        screen = new
        notchHeight = new.safeAreaInsets.top
        placeWindow()
        layoutViews()
    }

    private func placeWindow(width: Double? = nil, height: Double? = nil) {
        let sf = screen.visibleFrame
        let w = min(sf.width, max(260, sf.width * (width ?? settings.width) / 100))
        let minimumHeight = notchHeight + footerHeight + CGFloat(settings.fontSize) * 1.5 + 44
        let h = max(CGFloat(height ?? settings.height), minimumHeight)
        let top = notchHeight > 0 ? screen.frame.maxY : sf.maxY
        panel.setFrame(NSRect(x: sf.midX - w / 2, y: top - h, width: w, height: h), display: true)
    }

    func widthPercentDelta(points: CGFloat) -> Double {
        Double(points / max(1, screen.visibleFrame.width)) * 100
    }

    private var hudShowing = false

    func layoutViews() {
        let b = root.bounds
        let margin: CGFloat = 12
        let readingTop = b.height - notchHeight
        captureIndicator.frame = NSRect(x: margin, y: readingTop - 17, width: 14, height: 12)
        adjustingScroll = true
        scroll.frame = NSRect(x: 0, y: footerHeight, width: b.width, height: max(0, readingTop - footerHeight - 20))
        adjustingScroll = false
        scheduleDocumentResize()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        fade.frame = scroll.bounds
        let markerHeight = CGFloat(settings.fontSize) * 0.9
        readingMarker.frame = CGRect(x: 9, y: scroll.frame.maxY - readingAnchor - markerHeight - 2,
                                     width: 3, height: markerHeight)
        readingMarker.isHidden = !settings.showReadingLine || isEmpty
        CATransaction.commit()
        let barSize = bar.fittingSize
        barBackground.frame = NSRect(x: (b.width - barSize.width) / 2, y: footerHeight + 3,
                                     width: barSize.width, height: barSize.height)
        bar.frame = barBackground.bounds
        updateFade()
        countdownLabel.sizeToFit()
        countdownLabel.frame.origin = NSPoint(x: (b.width - countdownLabel.frame.width) / 2,
                                               y: scroll.frame.midY - countdownLabel.frame.height / 2)

        readingLabel.frame = NSRect(x: margin, y: 5, width: max(0, b.width * 0.62 - margin), height: 16)
        recLabel.frame = NSRect(x: b.width * 0.62, y: 5, width: max(0, b.width * 0.38 - margin), height: 16)

        hud.preferredMaxLayoutWidth = max(32, b.width - margin * 4)
        hud.maximumNumberOfLines = 2
        let hudSize = hud.fittingSize
        let hudWidth = max(0, min(b.width - margin * 2, hudSize.width + 16))
        hud.frame = NSRect(x: (b.width - hudWidth) / 2, y: footerHeight + (barVisible ? barSize.height + 7 : 3),
                           width: hudWidth, height: hudSize.height + 4)
    }

    // MARK: Button bar

    private func buildBar() {
        // Tooltips name the key that does the same; the keys are the same in every language.
        let restartButton = ControlButton("backward.end.fill", String(localized: "Back to the top (R)")) { [unowned self] in
            restart()
        }
        micButton = ControlButton("mic.fill", Self.micTip, size: 14, width: 30) { [unowned self] in
            toggleVoice()
        }
        recordButton = ControlButton("record.circle", Self.recordTip, size: 13) { [unowned self] in
            toggleRecording()
        }
        recordOptionsButton = ControlButton("chevron.down", String(localized: "Camera and recording options"), size: 8, width: 12) {
            [unowned self] in toggleRecordOptions()
        }
        recordButton.onRightClick = { [unowned self] in toggleRecordOptions() }
        playButton = ControlButton("play.fill", String(localized: "Play or pause selected pacing (Space)")) { [unowned self] in
            togglePlay()
        }
        let switchScript = ControlButton("list.bullet.rectangle", "Switch script (S)") { [unowned self] in onSwitchScript() }
        let edit = ControlButton("pencil", String(localized: "Edit scripts (E)")) { [unowned self] in onOpenEditor() }
        settingsButton = ControlButton("slider.horizontal.3", String(localized: "Text size, speed and voice (⌘,)")) {
            [unowned self] in toggleSettings()
        }
        let hide = ControlButton("xmark", String(localized: "Hide the prompter (\(Self.showShortcut))"), size: 10, width: 20) { [unowned self] in
            hidePanel()
            showHideTipOnce()
        }

        bar.orientation = .horizontal
        bar.spacing = 2
        bar.edgeInsets = NSEdgeInsets(top: 2, left: 6, bottom: 2, right: 6)
        // A plain view draws the pill: a stack view's own layer background isn't reliably drawn.
        barBackground.wantsLayer = true
        barBackground.layer?.backgroundColor = NSColor(white: 0.16, alpha: 1).cgColor
        barBackground.layer?.cornerRadius = 13
        barBackground.layer?.shadowColor = NSColor.black.cgColor
        barBackground.layer?.shadowOpacity = 1
        barBackground.layer?.shadowRadius = 10
        for v in [restartButton, micButton!, recordButton!, recordOptionsButton!, playButton!, switchScript, edit, settingsButton!, hide] { bar.addArrangedSubview(v) }
        bar.setCustomSpacing(10, after: restartButton)
        bar.setCustomSpacing(0, after: recordButton)
        bar.setCustomSpacing(8, after: settingsButton)
        barBackground.addSubview(bar)
        root.addSubview(barBackground, positioned: .below, relativeTo: hud)
        updateBar()
    }

    private func updateBar() {
        guard playButton != nil else { return }
        playButton.setSymbol(playing || listening || countingDown ? "pause.fill" : "play.fill")
        // Reserve red for recording. Mic activity uses the listening accent.
        micButton.wantsLayer = true
        micButton.layer?.cornerRadius = 9
        micButton.layer?.backgroundColor = listening ? listeningColor.withAlphaComponent(0.22).cgColor : NSColor.clear.cgColor
        micButton.contentTintColor = listening ? listeningColor : ControlButton.normalTint
        micButton.toolTip = listening ? String(localized: "Stop following my voice (V)") : Self.micTip
        micButton.setAccessibilityLabel(micButton.toolTip)
        recordButton.setSymbol(isRecording ? "stop.circle.fill" : "record.circle")
        recordButton.contentTintColor = liveRecordingStart != nil && !finishingTake
            ? .systemRed : NSColor(srgbRed: 1, green: 0.55, blue: 0.55, alpha: 1)
        recordButton.toolTip = isRecording ? String(localized: "Stop recording (C)") : Self.recordTip
        recordButton.setAccessibilityLabel(recordButton.toolTip)
        // Options are for before a take: the camera and mode can't change while filming.
        let takeRunning = isRecording || pendingRecording
        if recordOptionsButton.isHidden != takeRunning {
            recordOptionsButton.isHidden = takeRunning
            layoutViews()
        }
        let visible = hovering || (!playing && !listening && !countingDown) || recordPopover.isShown
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            barBackground.animator().alphaValue = visible ? 1 : 0
        }
        barVisible = visible
        refreshStatus()
        layoutViews()
    }

    private var barVisible = true
    private static let micTip = String(localized: "Follow my voice (V)")
    /// Brings the prompter back: from any app, or only from this one when those shortcuts are off.
    private static var showShortcut: String {
        AppSettings.shared.globalShortcuts ? GlobalShortcuts.Action.showPrompter.keys : "⇧⌘P"
    }
    private static let recordTip = String(localized: "Record video of yourself (C)")

    /// Fade the text out above the bar while it shows, so the bar never covers a line you need.
    /// The mask's gradient runs from the top (0) to the bottom (1).
    private func updateFade() {
        let h = max(scroll.bounds.height, 1)
        let hidden = barVisible ? min(0.5, (barBackground.frame.maxY - scroll.frame.minY + 2) / h) : 0
        fade.locations = [0, 0.045, 0.86 - hidden, 1 - hidden].map { NSNumber(value: Double($0)) }
    }

    /// The first time the prompter is hidden, say how to get it back.
    private func showHideTipOnce() {
        let key = "hasSeenHideTip"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        let alert = NSAlert()
        alert.messageText = String(localized: "The prompter is hidden")
        alert.informativeText = String(localized: "To bring it back, click the Flicker Folio icon in the menu bar, click the app in the Dock, or press \(Self.showShortcut).",
                                       comment: "The placeholder is a keyboard shortcut, e.g. ⌃⌥P")
        NSApp.activate()
        alert.runModal()
    }

    func toggleSettings() {
        recordPopover.close()
        onOpenSettings()
    }

    func toggleRecordOptions() {
        guard !isRecording, !pendingRecording else { return }
        toggle(recordPopover, under: recordButton)
    }

    private func toggle(_ shown: NSPopover, under button: NSView) {
        if shown.isShown { shown.performClose(nil); return }
        NSApp.activate()   // so a click elsewhere closes the popover
        shown.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        updateBar()
    }

    func popoverDidShow(_ notification: Notification) { previewScreenLight() }

    func popoverDidClose(_ notification: Notification) {
        previewScreenLight()
        updateBar()
    }

    /// While the recording options are open, show the screen light, so the camera preview shows
    /// how a take will look. `light` and `mode` are the new values while a setting changes.
    private func previewScreenLight(_ light: ScreenLight? = nil, _ mode: RecordingMode? = nil) {
        guard !isRecording, !pendingRecording else { return }
        let light = light ?? settings.screenLight, mode = mode ?? settings.recordingMode
        if recordPopover.isShown, mode == .camera, let screen = panel.screen {
            screenLight.show(light, on: screen)
        } else {
            screenLight.hide()
        }
    }

    // MARK: Text

    private static let emptyHint = String(localized: "This script is empty.\nClick the pencil below to write it.")

    private func show(_ script: Script?) {
        let newScript = script?.id != shownScriptID
        let source = script?.text ?? ""
        guard newScript || source != shownSource else { return }
        shownScriptID = script?.id
        shownSource = source
        if newScript {
            pendingTimedProgress = nil
            pacing = nil
            matcher.cursor = 0
            readingStarted = false
            readingFinished = false
            pauseReading()
        }
        updatePromptSpacing(for: settings.readingMode, force: true)
        if newScript { scrollTo(0) }
    }

    private func updatePromptSpacing(for mode: ReadingMode, force: Bool = false) {
        let compact = mode == .followWords
        guard force || compact != skippingBlankLines else { return }
        skippingBlankLines = compact
        markup = NoteMarkup(shownSource, skipBlankLines: compact)
        shownText = markup.text
        matcher.setText(shownText)
        let spokenText = shownText as NSString
        let candidates = matcher.words.map { spokenText.substring(with: $0.range) }
        let names = candidates.filter { $0.count >= 4 && $0.first?.isUppercase == true }
        var seen = Set<String>()
        voice.hints = Array((names + candidates.filter { $0.count >= 6 })
            .lazy.filter { seen.insert($0.lowercased()).inserted }.prefix(100))
        renderText()
        if !force, !isEmpty { scrollTo(lineOffset(forWord: matcher.cursor)) }
    }

    private var isEmpty: Bool { matcher.words.isEmpty }

    private var promptColor: NSColor {
        switch settings.textColor {
        case .white: .white
        case .amber: NSColor(srgbRed: 1, green: 0.86, blue: 0.48, alpha: 1)
        case .mint: NSColor(srgbRed: 0.64, green: 1, blue: 0.86, alpha: 1)
        case .ice: NSColor(srgbRed: 0.68, green: 0.88, blue: 1, alpha: 1)
        case .rose: NSColor(srgbRed: 1, green: 0.76, blue: 0.85, alpha: 1)
        }
    }

    private func renderText() {
        if let pacing { pendingTimedProgress = pacing.progress(at: offset) }
        pacing = nil
        sentenceStops = []
        text.textContainerInset.height = readingAnchor
        let size = CGFloat(settings.fontSize)
        let p = NSMutableParagraphStyle()
        p.alignment = .center
        p.lineSpacing = size * 0.20
        p.paragraphSpacing = size * (skippingBlankLines ? 0.10 : 0.6)
        let font = NSFont.systemFont(ofSize: size, weight: .semibold)
        let design: NSFontDescriptor.SystemDesign
        switch settings.fontStyle {
        case .system: design = .default
        case .rounded: design = .rounded
        case .serif: design = .serif
        }
        let designedFont = font.fontDescriptor.withDesign(design).flatMap { NSFont(descriptor: $0, size: size) } ?? font
        let attrs: [NSAttributedString.Key: Any] = [
            .font: designedFont,
            .foregroundColor: isEmpty ? NSColor(white: 1, alpha: 0.6) : promptColor,
            .paragraphStyle: p,
        ]
        let body = isEmpty ? Self.emptyHint : shownText
        let styled = NSMutableAttributedString(string: body, attributes: attrs)
        if !isEmpty {
            for run in markup.runs {
                if run.style.contains(.underline) { styled.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: run.range) }
                let emphasized = run.style.contains(.heading) || run.style.contains(.bold)
                let styledSize = run.style.contains(.heading) ? min(size * 1.13, AppSettings.fontSizeRange.upperBound) : size
                var font = NSFont(descriptor: designedFont.fontDescriptor, size: styledSize) ?? designedFont
                if emphasized { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
                if run.style.contains(.italic) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
                styled.addAttribute(.font, value: font, range: run.range)
            }
        }
        // Stage directions: quieter and in italics, so it's clear they aren't read out.
        let italic = NSFontManager.shared.convert(NSFont.systemFont(ofSize: size * 0.85, weight: .medium), toHaveTrait: .italicFontMask)
        for cue in matcher.cues where !isEmpty {
            styled.addAttributes([.font: italic, .foregroundColor: NSColor(white: 1, alpha: 0.5)], range: cue)
        }
        text.textStorage?.setAttributedString(styled)
        sizeDocument(force: true)
        updateProgress()
    }

    /// Dim the words already said.
    private func updateProgress() {
        guard let lm = text.layoutManager, let length = text.textStorage?.length else { return }
        lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: 0, length: length))
        if playing, activeReadingMode == .sentence, !isEmpty, sentenceStops.indices.contains(sentenceIndex) {
            let start = matcher.words[sentenceStops[sentenceIndex]].range.location
            let next = sentenceIndex + 1
            let end = next < sentenceStops.count ? matcher.words[sentenceStops[next]].range.location : shownText.utf16.count
            let muted = promptColor.withAlphaComponent(0.37)
            lm.addTemporaryAttribute(.foregroundColor, value: muted, forCharacterRange: NSRange(location: 0, length: start))
            lm.addTemporaryAttribute(.foregroundColor, value: muted, forCharacterRange: NSRange(location: end, length: length - end))
            return
        }
        guard listening, matcher.cursor > 0, !isEmpty else { return }
        let end = matcher.saidEnd(in: shownText as NSString)
        lm.addTemporaryAttribute(.foregroundColor, value: promptColor.withAlphaComponent(0.42),
                                 forCharacterRange: NSRange(location: 0, length: end))
    }

    // MARK: Scrolling

    private func scheduleDocumentResize() {
        let viewport = scroll.contentView.bounds.size
        guard viewport.width > 0, viewport.height > 0 else { return }
        if viewport == documentViewport {
            layoutWork?.cancel()
            layoutWork = nil
            queuedViewport = nil
            return
        }
        if documentViewport == .zero || !panel.isVisible {
            finishDocumentResize()
            return
        }
        guard queuedViewport != viewport else { return }
        queuedViewport = viewport
        layoutWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.finishDocumentResize() }
        layoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.09, execute: work)
    }

    func finishDocumentResize() {
        layoutWork?.cancel()
        layoutWork = nil
        queuedViewport = nil
        sizeDocument()
        restoreReadingPosition()
    }

    private func restoreReadingPosition() {
        if listening && !isEmpty {
            pendingTimedProgress = nil
            scrollTo(lineOffset(forWord: matcher.cursor))
        } else if activeReadingMode == .sentence, readingStarted, !isEmpty {
            pendingTimedProgress = nil
            let elapsed = sentenceElapsed
            prepareSentenceStops()
            sentenceElapsed = elapsed
        } else if let progress = pendingTimedProgress {
            pendingTimedProgress = nil
            scrollTo(scrollPacing().offset(at: progress))
        }
    }

    private func sizeDocument(force: Bool = false) {
        let viewport = scroll.contentView.bounds.size
        guard viewport.width > 0, viewport.height > 0,
              force || documentViewport != viewport,
              let layout = text.layoutManager, let container = text.textContainer else { return }
        if let pacing { pendingTimedProgress = pacing.progress(at: offset) }
        documentViewport = viewport
        adjustingScroll = true
        let inset = text.textContainerInset
        container.containerSize = NSSize(width: max(1, viewport.width - inset.width * 2),
                                         height: CGFloat.greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container).maxY + inset.height * 2
        // Extra space after the final line lets it reach the fixed reading marker.
        text.setFrameSize(NSSize(width: viewport.width, height: ceil(used + viewport.height)))
        adjustingScroll = false
        pacing = nil
        sentenceStops = []
        scrollTo(offset)
    }

    @objc private func displayTick(_ link: CADisplayLink) {
        lastDisplayFrame = CACurrentMediaTime()
        tick()
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = CGFloat(min(now - lastTick, 0.1))
        lastTick = now
        guard panel.isVisible else { return }
        refreshStatus()
        guard queuedViewport == nil, fontWork == nil else { return }
        updateMicLevel(dt: dt)

        if listening {
            guard now - lastManualScroll > 0.35 else { return }
            if shownLevel < 0.3 { quietSince = now }
            let atEnd = !isEmpty && matcher.cursor >= matcher.words.count
            // Talking for a while without the text moving: explain how to get back on track.
            if !lostHintShown, !atEnd, now - lastAdvance > 6, now - quietSince > 2.5 {
                lostHintShown = true
                showHUD(String(localized: "Lost? Click the word you're on"), for: 4)
            }
            let target = lineOffset(forWord: matcher.cursor)
            let next = SpeechFollowMotion.offset(from: offset, to: target, dt: dt,
                                               reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
            if next != offset { scrollTo(next) }
            if atEnd && abs(offset - min(target, max(0, text.frame.height - scroll.contentView.bounds.height))) <= 0.6 {
                readingFinished = true
                pauseReading()
                showHUD("Script complete", for: 3)
            }
            return
        }
        guard playing, !hoverPausesPlayback else { return }
        if activeReadingMode == .sentence {
            tickSentence(dt)
            return
        }
        var activity = 1.0
        if activeReadingMode == .conversational {
            guard microphoneReady else { return }
            activity = conversationalPacing.advance(level: voice.level, sensitivity: settings.voiceSensitivity, dt: dt)
        }

        let words = timedPacing.advance(wpm: settings.speed, dt: dt) * activity
        guard words > 0 else { return }
        let pace = scrollPacing()
        scrollTo(pace.advance(from: offset, by: words))
        if offset >= pace.endOffset {
            readingFinished = true
            pauseReading()
            showHUD("■ The end")
        }
    }

    private func prepareSentenceStops() {
        let viewport = scroll.contentView.bounds.size
        guard sentenceStops.isEmpty || sentenceViewport != viewport else { return }
        sentenceViewport = viewport
        let readableHeight = max(CGFloat(settings.fontSize) * 0.95, viewport.height - readingAnchor - settings.fontSize * 1.8)
        let words = matcher.words.map(\.range)
        sentenceStops = ScrollPacing.sentenceStarts(in: shownText, words: words,
                                                   readableHeight: readableHeight, lineOffset: lineOffset(forWord:))
        sentenceIndex = sentenceStops.lastIndex(where: { $0 <= matcher.cursor }) ?? 0
        sentenceElapsed = 0
        scrollTo(lineOffset(forWord: sentenceStops[sentenceIndex]))
        if playing { updateProgress() }
    }

    private func tickSentence(_ dt: Double) {
        prepareSentenceStops()
        let next = sentenceIndex + 1
        let ends = next < sentenceStops.count ? sentenceStops[next] : matcher.words.count
        let words = ends - sentenceStops[sentenceIndex]
        sentenceElapsed += dt
        guard sentenceElapsed >= ScrollPacing.sentenceDuration(words: words, speed: settings.speed) else { return }
        if next < sentenceStops.count {
            sentenceIndex = next
            sentenceElapsed = 0
            matcher.cursor = sentenceStops[next]
            scrollTo(lineOffset(forWord: matcher.cursor))
            updateProgress()
        } else {
            readingFinished = true
            pauseReading()
        }
    }

    private func scrollPacing() -> ScrollPacing {
        sizeDocument()
        let viewport = scroll.contentView.bounds.size
        if let pacing, pacingViewport == viewport { return pacing }
        guard let layout = text.layoutManager, let container = text.textContainer else {
            return ScrollPacing(stops: [])
        }
        layout.ensureLayout(for: container)
        var stops = [ScrollPacing.Stop(words: 0, offset: 0)]
        for (index, word) in matcher.words.enumerated() where index > 0 {
            let glyphs = layout.glyphRange(forCharacterRange: word.range, actualCharacterRange: nil)
            let y = offsetForLine(layout.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil).minY)
            if y > (stops.last?.offset ?? 0) + 0.5 {
                stops.append(.init(words: Double(index), offset: y))
            }
        }
        let maxOffset = max(0, text.frame.height - viewport.height)
        let end = min(maxOffset, (stops.last?.offset ?? 0) + settings.fontSize * 1.35)
        if end > (stops.last?.offset ?? 0) {
            stops.append(.init(words: Double(matcher.words.count), offset: end))
        }
        let pace = ScrollPacing(stops: stops)
        pacing = pace
        pacingViewport = viewport
        return pace
    }

    private var quietSince = CACurrentMediaTime()
    #if DEBUG
    var debugLevel: CGFloat?
    #endif

    private func scrollTo(_ y: CGFloat) {
        offset = min(max(0, y), max(0, text.frame.height - scroll.contentView.bounds.height))
        adjustingScroll = true
        scroll.contentView.scroll(to: NSPoint(x: 0, y: offset))
        scroll.reflectScrolledClipView(scroll.contentView)
        adjustingScroll = false
    }

    /// Scroll offset that puts the line with a word just below the top fade.
    private func lineOffset(forWord index: Int) -> CGFloat {
        guard let lm = text.layoutManager, let tc = text.textContainer, !isEmpty else { return 0 }
        let range = matcher.words[min(index, matcher.words.count - 1)].range
        let glyphs = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        lm.ensureLayout(for: tc)
        return offsetForLine(lm.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil).minY)
    }

    private func offsetForLine(_ y: CGFloat) -> CGFloat {
        max(0, y + text.textContainerOrigin.y - readingAnchor)
    }

    private var readingAnchor: CGFloat { settings.showReadingLine ? 12 : 6 }

    func manualScrollDidMove() {
        lastManualScroll = CACurrentMediaTime()
        offset = scroll.contentView.bounds.origin.y
        guard !isEmpty else { return }
        var lower = 0
        var upper = matcher.words.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if lineOffset(forWord: middle) < offset - settings.fontSize * 0.55 {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        matcher.cursor = min(lower, matcher.words.count - 1)
        if playing, activeReadingMode == .sentence {
            sentenceIndex = sentenceStops.lastIndex(where: { $0 <= matcher.cursor }) ?? 0
            sentenceElapsed = 0
        }
        matcher.resetHeard()
        if listening { lastAdvance = lastManualScroll }
        updateProgress()
    }

    private func nudge(_ direction: CGFloat) {
        scrollTo(offset + direction * settings.fontSize * 1.45)
        manualScrollDidMove()
    }

    // MARK: Voice-follow

    private var voiceLocale: String {
        settings.voiceLanguage == AppSettings.automaticLanguage
            ? VoiceListener.detectLocale(for: shownText) : settings.voiceLanguage
    }

    func toggleVoice() {
        guard !pendingRecording else { return }
        if listening || (countingDown && settings.readingMode == .followWords) {
            pauseReading()
            showHUD("Voice paused")
        } else {
            if settings.readingMode == .followWords { pauseReading() }
            settings.readingMode = .followWords
            togglePlay()
        }
    }

    func startVoice() {
        guard !isEmpty else { onOpenEditor(); return }
        pauseReading()
        updatePromptSpacing(for: .followWords)
        if activeReadingMode != .followWords, offset > 1 { manualScrollDidMove() }
        activeReadingMode = .followWords
        readingStarted = true
        readingFinished = false
        showPanel()
        listening = true
        matcher.resetHeard()
        lastAdvance = CACurrentMediaTime()
        lostHintShown = false
        voice.onDeviceOnly = settings.onDeviceOnly
        voice.inputDeviceUID = settings.microphoneID
        let locale = voiceLocale
        matcher.numberLocale = locale
        voice.start(locale: locale)
    }

    private func restartVoiceIfListening() {
        guard listening else { return }
        voice.stop()
        matcher.resetHeard()
        voice.onDeviceOnly = settings.onDeviceOnly
        voice.inputDeviceUID = settings.microphoneID
        let locale = voiceLocale
        matcher.numberLocale = locale
        voice.start(locale: locale)
    }

    /// A click on a word makes it the next word to say (voice) or the top line (play).
    func clickText(_ e: NSEvent) {
        if isEmpty { onOpenEditor(); return }
        let index = text.characterIndexForInsertion(at: text.convert(e.locationInWindow, from: nil))
        guard let word = matcher.wordIndex(atCharacter: index) else { return }
        matcher.cursor = word
        if listening {
            matcher.resetHeard()
            lastAdvance = CACurrentMediaTime()
            updateProgress()
            showHUD(String(localized: "From here", comment: "After clicking a word: voice-follow continues from here"))
        } else {
            scrollTo(lineOffset(forWord: word))
        }
    }

    func pauseOrResume() { togglePlay() }

    func readScript(_ script: Script) {
        guard !pendingRecording else { return }
        library.activeID = script.id
        show(script)
        pauseReading()
        restart()
        showPanel()
        panel.makeKey()
        togglePlay()
    }

    func prepareVoiceCheck() -> Bool {
        guard !pendingRecording, !isRecording, !finishingTake else { return false }
        pauseReading()
        return true
    }

    private func pauseReading() {
        if !pendingRecording { cancelCountdown() }
        playing = false
        listening = false
        updateProgress()
        microphoneReady = false
        voice.stop()
        refreshStatus()
    }

    // MARK: Play mode

    func togglePlay() {
        if playing || listening || countingDown {
            guard !pendingRecording else { return }
            pauseReading()
            showHUD("❚❚ Paused")
            return
        }
        guard !isEmpty else { onOpenEditor(); return }
        showPanel()
        if queuedViewport != nil { finishDocumentResize() }
        if readingFinished || (settings.readingMode != .followWords && offset >= scrollPacing().endOffset - 1) { restart() }
        if settings.countdown { startCountdown(then: startSelectedMode) }
        else { startSelectedMode() }
    }

    private func startSelectedMode() {
        let mode = settings.readingMode
        if mode == .followWords {
            startVoice()
            return
        }
        if mode == .sentence {
            manualScrollDidMove()
            sentenceStops = []
            prepareSentenceStops()
        }
        activeReadingMode = mode
        readingStarted = true
        readingFinished = false
        playing = true
        updateProgress()
        timedPacing.reset(wpm: settings.speed)
        conversationalPacing = ConversationalPacing()
        if activeReadingMode == .conversational {
            showHUD("Speak to scroll · \(Int(settings.speed)) WPM")
            voice.startMeter { [weak self] ready in
                guard let self, playing, activeReadingMode == .conversational else { return }
                microphoneReady = ready
                if !ready { playing = false }
            }
        } else {
            showHUD("▶ \(Int(settings.speed)) WPM")
        }
    }

    private func startCountdown(then action: @escaping () -> Void = {}) {
        for (i, n) in ["3", "2", "1"].enumerated() {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                countdownLabel.stringValue = n
                countdownLabel.isHidden = false
                if settings.countdownSound && !isRecording {
                    if let sound = NSSound(named: "Tink") { sound.play() }
                    else { NSSound.beep() }
                }
                layoutViews()
            }
            countdownWork.append(work)
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i), execute: work)
        }
        let go = DispatchWorkItem { [weak self] in
            guard let self else { return }
            countdownWork = []
            countdownLabel.isHidden = true
            action()
        }
        countdownWork.append(go)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: go)
        updateBar()
    }

    private func cancelCountdown() {
        countdownWork.forEach { $0.cancel() }
        countdownWork = []
        countdownLabel.isHidden = true
        updateBar()
    }

    // MARK: Recording

    func toggleRecording() {
        guard !finishingTake else { return }
        if isRecording || pendingRecording { stopRecording(); return }
        guard !isEmpty else { onOpenEditor(); return }
        let mode = settings.recordingMode
        // Pending from the first press: a second press while macOS asks for access cancels,
        // instead of starting a second take.
        pendingRecording = true
        discardTake = false
        updateBar()
        // The screen light it may show stays on for the take, or goes when the take can't start.
        recordPopover.close()
        Recorder.requestAccess(camera: mode.usesCamera) { [weak self] problem in
            guard let self, pendingRecording else { return }
            if let problem {
                pendingRecording = false
                screenLight.hide()
                return showPermissionAlert(String(localized: "Allow access to record"), problem.message, problem.url)
            }
            if mode.usesScreen && !ScreenRecorder.requestAccess() {
                pendingRecording = false
                screenLight.hide()
                return showPermissionAlert(String(localized: "Allow screen recording"),
                    String(localized: "Turn on Flicker Folio in System Settings → Privacy & Security → Screen & System Audio Recording, then reopen Flicker Folio. Or choose to record only the camera in Settings → Recording."),
                    ScreenRecorder.settingsURL)
            }
            cancelCountdown()
            pauseReading()
            showPanel()
            takeMode = mode
            // Voice-follow hears the recording's microphone, so only one part of the app reads it:
            // the camera recorder, or the screen capture when there is no camera.
            let onAudio: (CMSampleBuffer) -> Void = { [weak listener = voice] in listener?.append($0) }
            recorder.onAudio = mode.usesCamera ? onAudio : nil
            screenRecorder.onAudio = mode.usesCamera ? nil : onAudio
            // Wake the camera first, so filming starts exactly when the countdown ends.
            showHUD(mode.usesCamera ? String(localized: "Starting camera…") : String(localized: "Starting screen recording…"))
            prepareAll(mode) { [weak self] problem in
                guard let self else { return }
                // Stopped while the camera was waking up: turn it off again.
                guard pendingRecording else { recorder.stop(); screenRecorder.stop(); hideTakeWindows(); return }
                if let problem {
                    pendingRecording = false
                    recorder.stop(); screenRecorder.stop(); hideTakeWindows()
                    showHUD(problem, for: 5); updateBar(); return
                }
                voice.useExternalAudio = true
                let startFiles = { [weak self] in
                    guard let self, pendingRecording, !isRecording else { return }
                    lastTake.clear()
                    let name = Recorder.takeName()
                    if mode.usesScreen {
                        screenRecorder.record(name: mode.usesCamera
                            ? String(localized: "\(name) Screen", comment: "File name of the screen movie that goes with a take")
                            : name)
                    }
                    if mode.usesCamera {
                        recorder.record(name: name) { [weak self] problem in
                            guard let self else { return }
                            if let problem { showHUD(problem, for: 5) }
                            updateBar()
                            layoutViews()
                        }
                    }
                }
                let go = { [weak self] in
                    guard let self, pendingRecording else { return }
                    startFiles()
                    pendingRecording = false
                    startSelectedMode()
                    updateBar()
                }
                if settings.countdown {
                    startCountdown(then: go)
                } else {
                    go()
                }
            }
        }
    }

    private var pendingRecording = false
    /// The take was stopped during the countdown: its movies were only just started, so delete them.
    private var discardTake = false
    /// What the current (or last) take records.
    private var takeMode = RecordingMode.camera

    /// Wake the camera and the screen capture that `mode` needs. `ready` gets the first problem, if any.
    private func prepareAll(_ mode: RecordingMode, ready: @escaping (String?) -> Void) {
        let screenPart = { [weak self] in
            guard let self else { return }
            guard mode.usesScreen else { return ready(nil) }
            // Leave the prompter (when hidden from recordings) and the camera preview out of the screen movie.
            var hidden = [cameraPreview.windowNumber]
            if settings.hideFromScreenSharing { hidden.append(panel.windowNumber) }
            let mic = mode.usesCamera ? nil : Recorder.microphone(settings.microphoneID)?.uniqueID
            screenRecorder.prepare(screen: panel.screen, hiddenWindows: hidden, microphone: mic, ready: ready)
        }
        guard mode.usesCamera else { return screenPart() }
        recorder.prepare(cameraID: settings.cameraID, microphoneID: settings.microphoneID) { [weak self] problem in
            guard let self else { return }
            guard problem == nil else { return ready(problem) }
            // Show the camera during the countdown, so you can check how you look before it films.
            if settings.showCameraPreview, let screen = panel.screen {
                cameraPreview.show(recorder.session, beside: panel.frame, on: screen)
            }
            // The light would cover what a screen movie films, so it is only for camera takes.
            if mode == .camera, let screen = panel.screen {
                screenLight.show(settings.screenLight, on: screen)
            }
            screenPart()
        }
    }

    private func hideTakeWindows() {
        cameraPreview.hide()
        screenLight.hide()
    }

    /// Stop the take; the movie file is finished a moment later.
    func stopRecording(completion: (() -> Void)? = nil) {
        if let completion { finishCallbacks.append(completion) }
        guard !finishingTake else { return }
        if pendingRecording { discardTake = true }
        pendingRecording = false
        finishingTake = true
        cancelCountdown()
        pauseReading()
        voice.useExternalAudio = false
        hideTakeWindows()
        var left = 2
        let done = { [self] in
            left -= 1
            guard left == 0 else { return }
            finishingTake = false
            updateBar()
            let callbacks = finishCallbacks
            finishCallbacks.removeAll()
            callbacks.forEach { $0() }
        }
        recorder.stop(completion: done)
        screenRecorder.stop(completion: done)
        updateBar()
    }

    private func updateMicLevel(dt: CGFloat) {
        guard voice.running else { return }
        var raw = voice.level
        #if DEBUG
        if let debugLevel { raw = debugLevel }
        #endif
        shownLevel += (raw - shownLevel) * (1 - exp(-dt * (raw > shownLevel ? 30 : 11)))
    }

    private var hoverPausesPlayback: Bool {
        guard settings.pauseOnHover, hovering else { return false }
        let mouse = root.convert(panel.mouseLocationOutsideOfEventStream, from: nil)
        return scroll.frame.contains(mouse) && !barBackground.frame.contains(mouse)
    }

    private func refreshStatus() {
        let micLive = voice.running
        let reading: String
        if playing && hoverPausesPlayback { reading = "Paused on hover" }
        else if micLive && activeReadingMode == .conversational {
            reading = conversationalPacing.isSpeaking ? "Speaking · scrolling" : "Waiting for speech"
        }
        else if micLive { reading = "Listening" }
        else if listening || (playing && activeReadingMode == .conversational) { reading = "Starting mic…" }
        else if playing {
            let label = activeReadingMode == .sentence ? "Sentence pacing" : "Auto-scroll"
            reading = "\(label) · \(Int(settings.speed)) WPM"
        }
        else if countingDown { reading = "Get ready" }
        else if readingFinished { reading = "Script complete" }
        else if readingStarted { reading = "Paused" }
        else { reading = "Ready" }

        let recording: String
        if finishingTake { recording = "Saving…" }
        else if let start = liveRecordingStart {
            let seconds = Int(max(0, Date().timeIntervalSince(start)))
            recording = String(format: "● REC %d:%02d", seconds / 60, seconds % 60)
        } else if pendingRecording || isRecording { recording = "Starting REC…" }
        else { recording = "" }

        updateCaptureIndicator(micLive: micLive)
        guard readingLabel.stringValue != reading || recLabel.stringValue != recording else {
            return
        }
        readingLabel.stringValue = reading
        readingLabel.textColor = micLive ? listeningColor : NSColor(white: 0.72, alpha: 1)
        recLabel.stringValue = recording
        let recordingLive = liveRecordingStart != nil && !finishingTake
        recLabel.textColor = recordingLive
            ? NSColor(srgbRed: 1, green: 0.35, blue: 0.43, alpha: 1) : NSColor(white: 0.72, alpha: 1)
        recordButton?.contentTintColor = recordingLive
            ? .systemRed : NSColor(srgbRed: 1, green: 0.55, blue: 0.55, alpha: 1)
        layoutViews()
    }

    private func updateCaptureIndicator(micLive: Bool) {
        let label: String?
        let symbol: String
        if recorder.isWriting && !finishingTake {
            label = "Camera recording"
            symbol = "video.fill"
        } else if screenRecorder.isWriting && !finishingTake {
            label = "Screen recording"
            symbol = "record.circle.fill"
        } else if micLive {
            label = "Microphone active for pacing"
            symbol = "mic.circle.fill"
        } else {
            label = nil
            symbol = ""
        }
        guard captureIndicator.toolTip != label else { return }
        captureIndicator.toolTip = label
        captureIndicator.setAccessibilityLabel(label)
        captureIndicator.image = label.flatMap { NSImage(systemSymbolName: symbol, accessibilityDescription: $0) }
        captureIndicator.isHidden = label == nil
    }

    func restart() {
        pendingTimedProgress = nil
        matcher.cursor = 0
        sentenceIndex = 0
        sentenceElapsed = 0
        readingFinished = false
        updateProgress()
        scrollTo(0)
        refreshStatus()
        if listening { matcher.resetHeard(); lastAdvance = CACurrentMediaTime() }
        showHUD(String(localized: "⟲ Top", comment: "Back at the top of the script"))
    }

    func changeSpeed(_ d: Double) {
        settings.speed = (settings.speed + d).clamped(to: AppSettings.speedRange)
        showHUD("\(Int(settings.speed)) WPM")
    }

    func changeFontSize(_ d: Double) {
        settings.fontSize = (settings.fontSize + d).clamped(to: AppSettings.fontSizeRange)
        showHUD(String(localized: "Text size \(Int(settings.fontSize))"))
    }

    @discardableResult
    func importAndShow(_ url: URL) -> Bool {
        guard let script = try? library.importFile(at: url) else { showHUD(String(localized: "Can't read that file")); return false }
        library.activeID = script.id
        showHUD(script.displayTitle)
        return true
    }

    // MARK: Keys (when the prompter has keyboard focus)

    func handleKey(_ e: NSEvent) -> Bool {
        let cmd = e.modifierFlags.contains(.command)
        let shift = e.modifierFlags.contains(.shift)
        let ch = e.charactersIgnoringModifiers?.lowercased() ?? ""

        if cmd {
            switch ch {
            case ",": toggleSettings()
            case _ where e.keyCode == 51: trashLastTake()   // ⌘⌫, like Move to Trash in the Finder
            case "=", "+": changeFontSize(2)
            case "-": changeFontSize(-2)
            default: return false   // let the main menu handle it
            }
            return true
        }

        switch e.keyCode {
        case 49: togglePlay()
        case 53:
            if recordPopover.isShown {
                recordPopover.performClose(nil)
            } else {
                stopAll()
            }
        case 126 where shift: changeSpeed(5)
        case 125 where shift: changeSpeed(-5)
        case 126: nudge(-1)
        case 125: nudge(1)
        case 123: settings.width = (settings.width - 5).clamped(to: AppSettings.widthRange)
        case 124: settings.width = (settings.width + 5).clamped(to: AppSettings.widthRange)
        default:
            switch ch {
            case "r": restart()
            case "s": onSwitchScript()
            case "v": toggleVoice()
            case "c": toggleRecording()
            case "e": onOpenEditor()
            case "h":
                settings.pauseOnHover.toggle()
                showHUD(settings.pauseOnHover ? String(localized: "Hover pauses: on") : String(localized: "Hover pauses: off"))
            case "=", "+": changeFontSize(2)
            case "-": changeFontSize(-2)
            default: return false
            }
        }
        return true
    }

    func showHUD(_ msg: String, for seconds: Double = 1.4) {
        hud.stringValue = msg
        hudShowing = true
        layoutViews()
        hud.alphaValue = 1
        hudHideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.4
                self?.hud.animator().alphaValue = 0
            } completionHandler: {
                self?.hudShowing = false
                self?.layoutViews()
            }
        }
        hudHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}

/// The camera and screen movies of the last take. Files moved away in the Finder are left out.
final class LastTake: ObservableObject {
    @Published var camera: URL?
    @Published var screen: URL?

    var movies: [URL] {
        [camera, screen].compactMap { $0 }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }
    var name: String? { movies.first?.deletingPathExtension().lastPathComponent }

    func clear() { camera = nil; screen = nil }
}

#if DEBUG
/// Puts the prompter in a fixed state for screenshots, without the microphone.
extension Prompter {
    enum DebugStage { case idle, reading(word: Int), playing }

    func debugStage(_ stage: DebugStage, hud message: String? = nil) {
        stopAll()
        hovering = false
        switch stage {
        case .idle:
            matcher.cursor = 0
            scrollTo(0)
        case .reading(let word):
            matcher.cursor = word
            debugLevel = 0.75
            listening = true
            lostHintShown = true
            scrollTo(lineOffset(forWord: word))
        case .playing:
            playing = true
            hovering = true   // shows the bar with the speed buttons, and pauses scrolling
            scrollTo(lineOffset(forWord: 30))
        }
        updateProgress()
        hud.alphaValue = 0; hudShowing = false; layoutViews()
        if let message { showHUD(message, for: 60) }
    }
}
#endif
