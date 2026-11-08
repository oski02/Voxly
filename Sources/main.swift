import Cocoa
import AVFoundation
import Speech
import ApplicationServices

// MARK: - Dictado (Speech framework de Apple, en el dispositivo si es posible)

final class Dictation {
    private let engine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var latest = ""
    private var finished: ((String) -> Void)?
    var onLevel: ((Float) -> Void)?

    init() {
        let code = UserDefaults.standard.string(forKey: "locale") ?? Locale.current.identifier
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: code)) ?? SFSpeechRecognizer()
    }

    func setLocale(_ id: String) {
        UserDefaults.standard.set(id, forKey: "locale")
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: id))
    }

    func start() {
        guard let recognizer, recognizer.isAvailable else { return }
        latest = ""
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        request = req

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            if let result {
                self.latest = result.bestTranscription.formattedString
                if result.isFinal { self.deliver() }
            }
            if error != nil { self.deliver() }
        }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buf, _ in
            self?.request?.append(buf)
            if let ch = buf.floatChannelData?[0] {
                let n = Int(buf.frameLength)
                var sum: Float = 0
                for i in 0..<n { sum += ch[i] * ch[i] }
                let rms = n > 0 ? sqrt(sum / Float(n)) : 0
                let level = min(1, rms * 9)   // normalizado 0...1
                DispatchQueue.main.async { self?.onLevel?(level) }
            }
        }
        engine.prepare()
        do { try engine.start() } catch { NSLog("Audio engine error: \(error)") }
    }

    /// Detiene la grabación y llama a `completion` con el texto final.
    func stop(completion: @escaping (String) -> Void) {
        finished = completion
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        // Seguridad: si el reconocedor no responde, entregar lo que haya.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in self?.deliver() }
    }

    private func deliver() {
        DispatchQueue.main.async {
            guard let cb = self.finished else { return }
            self.finished = nil
            self.task?.cancel(); self.task = nil; self.request = nil
            cb(self.latest)
        }
    }
}

// MARK: - Insertar texto en la app activa (pegado simulado)

func insertText(_ text: String) {
    guard !text.isEmpty else { return }
    let pb = NSPasteboard.general
    let saved = pb.pasteboardItems?.map { item -> [NSPasteboard.PasteboardType: Data] in
        var d: [NSPasteboard.PasteboardType: Data] = [:]
        for t in item.types { if let data = item.data(forType: t) { d[t] = data } }
        return d
    } ?? []

    pb.clearContents()
    pb.setString(text, forType: .string)

    let src = CGEventSource(stateID: .combinedSessionState)
    let v: CGKeyCode = 9 // tecla V
    let down = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true)
    let up = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false)
    down?.flags = .maskCommand; up?.flags = .maskCommand
    down?.post(tap: .cgAnnotatedSessionEventTap)
    up?.post(tap: .cgAnnotatedSessionEventTap)

    // Restaurar el portapapeles original
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
        pb.clearContents()
        for item in saved {
            let n = NSPasteboardItem()
            for (t, d) in item { n.setData(d, forType: t) }
            pb.writeObjects([n])
        }
    }
}


// MARK: - Bola flotante con latido que reacciona a la voz

final class OrbView: NSView {
    let container = CALayer(), glow = CALayer(), core = CAGradientLayer(), ring = CALayer()
    private var smooth: CGFloat = 0
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        let d: CGFloat = 34, c = CGPoint(x: frame.midX, y: frame.midY)
        func circle(_ l: CALayer, _ size: CGFloat) {
            l.bounds = CGRect(x: 0, y: 0, width: size, height: size)
            l.position = c; l.cornerRadius = size / 2
        }
        container.bounds = bounds; container.position = c
        layer!.addSublayer(container)

        circle(glow, d * 1.9)
        glow.backgroundColor = NSColor(red: 0.35, green: 0.5, blue: 1, alpha: 0.35).cgColor
        glow.shadowColor = NSColor(red: 0.4, green: 0.45, blue: 1, alpha: 1).cgColor
        glow.shadowRadius = 14; glow.shadowOpacity = 0.9; glow.shadowOffset = .zero
        container.addSublayer(glow)

        circle(ring, d)
        ring.borderWidth = 2
        ring.borderColor = NSColor(red: 0.55, green: 0.6, blue: 1, alpha: 1).cgColor
        container.addSublayer(ring)

        circle(core, d)
        core.colors = [NSColor(red: 0.62, green: 0.42, blue: 1, alpha: 1).cgColor,
                       NSColor(red: 0.15, green: 0.6, blue: 1, alpha: 1).cgColor]
        core.startPoint = CGPoint(x: 0, y: 1); core.endPoint = CGPoint(x: 1, y: 0)
        container.addSublayer(core)
    }
    required init?(coder: NSCoder) { fatalError() }

    func startAnimating() {
        // Latido tipo "lub-dub" de todo el conjunto
        let beat = CAKeyframeAnimation(keyPath: "transform.scale")
        beat.values = [1.0, 1.14, 1.0, 1.08, 1.0, 1.0]
        beat.keyTimes = [0, 0.12, 0.26, 0.38, 0.52, 1]
        beat.duration = 1.1; beat.repeatCount = .infinity
        container.add(beat, forKey: "beat")
        // Onda que se expande con cada latido
        let grow = CAKeyframeAnimation(keyPath: "transform.scale")
        grow.values = [1.0, 1.0, 2.1]; grow.keyTimes = [0, 0.05, 1]
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0.0, 0.8, 0.0]; fade.keyTimes = [0, 0.05, 1]
        let g = CAAnimationGroup()
        g.animations = [grow, fade]; g.duration = 1.1; g.repeatCount = .infinity
        ring.add(g, forKey: "wave")
    }
    func stopAnimating() { container.removeAllAnimations(); ring.removeAllAnimations() }

    func setLevel(_ l: Float) {
        // suavizado: sube rápido, baja despacio
        let target = CGFloat(l)
        smooth = target > smooth ? smooth * 0.4 + target * 0.6 : smooth * 0.85 + target * 0.15
        CATransaction.begin(); CATransaction.setAnimationDuration(0.06)
        core.transform = CATransform3DMakeScale(1 + smooth * 0.9, 1 + smooth * 0.9, 1)
        glow.opacity = Float(0.6 + smooth * 0.4)
        glow.transform = CATransform3DMakeScale(1 + smooth * 0.5, 1 + smooth * 0.5, 1)
        CATransaction.commit()
    }
}

final class OrbWindow {
    private let panel: NSPanel
    private let view = OrbView(frame: NSRect(x: 0, y: 0, width: 160, height: 160))
    init() {
        panel = NSPanel(contentRect: view.frame, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.level = .statusBar; panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = view
    }
    func show() {
        let f = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        panel.setFrameOrigin(NSPoint(x: f.midX - 80, y: f.minY + 30))
        panel.alphaValue = 0; panel.orderFrontRegardless()
        view.startAnimating()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }
    }
    func hide() {
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; panel.animator().alphaValue = 0 },
            completionHandler: { [weak self] in self?.panel.orderOut(nil); self?.view.stopAnimating() })
    }
    func level(_ l: Float) { view.setLevel(l) }
}

// MARK: - App de barra de menús

final class AppDelegate: NSObject, NSApplicationDelegate {
    let dictation = Dictation()
    let orb = OrbWindow()
    var statusItem: NSStatusItem!
    var tap: CFMachPort?
    var fnDown = false

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        setIcon(recording: false)
        dictation.onLevel = { [weak self] l in self?.orb.level(l) }
        buildMenu()
        requestPermissions()
        installEventTap()
    }

    func setIcon(recording: Bool) {
        let name = recording ? "waveform.circle.fill" : "waveform"
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "Dictado")
        img?.isTemplate = !recording
        statusItem.button?.image = img
        statusItem.button?.contentTintColor = recording ? .systemRed : nil
    }

    func buildMenu() {
        let m = NSMenu()
        let okInput = CGPreflightListenEventAccess(), okAX = AXIsProcessTrusted()
        m.addItem(withTitle: "Mantén FN para dictar", action: nil, keyEquivalent: "")
        // Monitorización de entrada solo se pide si el tap no se pudo crear con Accesibilidad sola
        if okAX && tap == nil {
            m.addItem(withTitle: (okInput ? "✅" : "❌") + " Monitorización de entrada", action: okInput ? nil : #selector(openInputMonitoring), keyEquivalent: "").target = self
        }
        m.addItem(withTitle: (okAX ? "✅" : "❌") + " Accesibilidad (pegar texto)", action: okAX ? nil : #selector(openAccessibility), keyEquivalent: "").target = self
        let rc = m.addItem(withTitle: "Volver a comprobar permisos", action: #selector(recheck), keyEquivalent: ""); rc.target = self
        m.addItem(.separator())
        let lang = NSMenuItem(title: "Idioma", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let current = UserDefaults.standard.string(forKey: "locale") ?? Locale.current.identifier
        for (name, id) in [("Español (España)", "es-ES"), ("Español (México)", "es-MX"),
                           ("English (US)", "en-US"), ("English (UK)", "en-GB"),
                           ("Français", "fr-FR"), ("Deutsch", "de-DE"),
                           ("Italiano", "it-IT"), ("Português", "pt-PT")] {
            let it = NSMenuItem(title: name, action: #selector(pickLang(_:)), keyEquivalent: "")
            it.representedObject = id; it.target = self
            it.state = (id.replacingOccurrences(of: "-", with: "_") == current.replacingOccurrences(of: "-", with: "_")) ? .on : .off
            sub.addItem(it)
        }
        lang.submenu = sub
        m.addItem(lang)
        m.addItem(.separator())
        m.addItem(withTitle: "Acerca de Voxly", action: #selector(showAbout), keyEquivalent: "").target = self
        m.addItem(withTitle: "Salir", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = m
    }

    @objc func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        let style = NSMutableParagraphStyle(); style.alignment = .center
        let credits = NSAttributedString(string: "Creado por x25s", attributes: [
            .font: NSFont.systemFont(ofSize: 12), .paragraphStyle: style,
            .foregroundColor: NSColor.labelColor])
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Voxly", .applicationVersion: "1.0", .version: "",
            .credits: credits,
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): "© x25s"])
    }

    @objc func pickLang(_ s: NSMenuItem) {
        guard let id = s.representedObject as? String else { return }
        dictation.setLocale(id)
        buildMenu()
    }

    func requestPermissions() {
        SFSpeechRecognizer.requestAuthorization { _ in }
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.checkAccessibility() }
    }

    var axAlertShown = false, imAlertShown = false, tapFailures = 0

    /// Aviso claro con botón directo al ajuste, solo una vez por arranque.
    func permissionAlert(title: String, text: String, pane: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title; a.informativeText = text
        a.alertStyle = .informational
        a.addButton(withTitle: "Abrir Ajustes")
        a.addButton(withTitle: "Más tarde")
        if let icon = NSApp.applicationIconImage { a.icon = icon }
        if a.runModal() == .alertFirstButtonReturn { openSettings(pane) }
    }

    func checkAccessibility() {
        guard !AXIsProcessTrusted(), !axAlertShown else { return }
        axAlertShown = true
        permissionAlert(title: "Voxly necesita el permiso de Accesibilidad",
                        text: "Sirve para detectar la tecla FN y escribir el texto donde tengas el cursor.\n\nPulsa «Abrir Ajustes» y activa el interruptor de Voxly. Si ya aparece activado, quítalo con «–» y vuelve a añadirlo con «+».",
                        pane: "Privacy_Accessibility")
    }

    func openSettings(_ pane: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }
    @objc func openInputMonitoring() { openSettings("Privacy_ListenEvent") }
    @objc func openAccessibility() { openSettings("Privacy_Accessibility") }
    @objc func recheck() { requestPermissions(); installEventTap(); buildMenu() }

    // Detecta la tecla FN (modificador "secondary function") a nivel global
    func installEventTap() {
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        let cb: CGEventTapCallBack = { _, type, event, refcon in
            let me = Unmanaged<AppDelegate>.fromOpaque(refcon!).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let t = me.tap { CGEvent.tapEnable(tap: t, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            let isFn = event.flags.contains(.maskSecondaryFn)
            if isFn != me.fnDown {
                me.fnDown = isFn
                DispatchQueue.main.async { isFn ? me.beginDictation() : me.endDictation() }
            }
            return Unmanaged.passUnretained(event)
        }
        let created = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                options: .defaultTap, eventsOfInterest: mask,
                                callback: cb, userInfo: Unmanaged.passUnretained(self).toOpaque())
        if self.tap != nil { return }
        guard let tap = created else {
            // Aún sin permisos: reintentar hasta que se concedan
            if AXIsProcessTrusted() && !CGPreflightListenEventAccess() {
                CGRequestListenEventAccess()
                tapFailures += 1
                if tapFailures >= 3 && !imAlertShown {
                    imAlertShown = true
                    permissionAlert(title: "Voxly necesita Monitorización de entrada",
                                    text: "Tu versión de macOS exige también este permiso para detectar la tecla FN.\n\nPulsa «Abrir Ajustes» y activa el interruptor de Voxly.",
                                    pane: "Privacy_ListenEvent")
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.installEventTap(); self.buildMenu() }
            return
        }
        self.tap = tap
        buildMenu()
        let src = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func beginDictation() {
        NSSound(named: "Tink")?.play()
        setIcon(recording: true)
        orb.show()
        dictation.start()
    }

    func endDictation() {
        setIcon(recording: false)
        orb.hide()
        dictation.stop { text in
            NSSound(named: "Pop")?.play()
            insertText(text)
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
