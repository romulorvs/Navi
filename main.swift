import Cocoa
import Carbon
import ServiceManagement
import Darwin
import ScreenCaptureKit

private let kAXWindowNumberAttribute = "AXWindowNumber"
private let axTrustedPromptKey = "AXTrustedCheckOptionPrompt"

private enum Config {
    static let gridColumns = 5
    static let gridMaxRows = 4
    static let thumbnailMaxRows = 3
    static let listMaxItems = 16
    static let itemPadding: CGFloat = 8
    static let itemSpacing: CGFloat = 8
    static let windowItemCornerRadius: CGFloat = 12
    static let gridItemSize = NSSize(width: 200, height: 160)
    static let gridIconSize: CGFloat = 120
    static let thumbGridIconSize: CGFloat = 210
    static let listItemSize = NSSize(width: 600, height: 32)
}
extension WindowManager: @unchecked Sendable {}
extension HotkeyManager: @unchecked Sendable {}

enum ViewMode: String {
    case grid
    case thumbnails
    case list
}

var currentViewMode: ViewMode = {
    if let saved = UserDefaults.standard.string(forKey: "viewMode"),
       let mode = ViewMode(rawValue: saved) {
        return mode
    }
    return .grid
}()

enum ScreenMode: String {
    case allScreens
    case activeScreen
    case mouseScreen
}

var currentScreenMode: ScreenMode = {
    if let saved = UserDefaults.standard.string(forKey: "screenMode"),
       let mode = ScreenMode(rawValue: saved) {
        return mode
    }
    return .allScreens
}()

struct ShortcutConfig {
    var baseModifiers: CGEventFlags
    var baseKey: Int64
    var forwardModifiers: CGEventFlags
    var forwardKey: Int64
    var backwardModifiers: CGEventFlags
    var backwardKey: Int64
    
    static let `default` = ShortcutConfig(
        baseModifiers: [.maskCommand], baseKey: 0,
        forwardModifiers: [], forwardKey: 48,
        backwardModifiers: [.maskShift], backwardKey: 48
    )
    
    var forwardShortcutString: String { shortcutString(forwardModifiers, forwardKey) }
    
    var conflictsWithSystemShortcuts: Bool {
        let cmdOnly = CGEventFlags.maskCommand, cmdShift = cmdOnly.union(.maskShift)
        let fwd = baseModifiers.union(forwardModifiers), bwd = baseModifiers.union(backwardModifiers)
        let fwdConflict = forwardKey == 48 && (fwd.rawValue == cmdOnly.rawValue || fwd.rawValue == cmdShift.rawValue)
        let bwdConflict = backwardKey == 48 && (bwd.rawValue == cmdOnly.rawValue || bwd.rawValue == cmdShift.rawValue)
        return fwdConflict || bwdConflict
    }
    
    var menuTitle: String {
        let prefix = conflictsWithSystemShortcuts ? "⚠️ " : ""
        return "\(prefix)\(forwardShortcutString) to switch windows"
    }
    
    func save() {
        let d = UserDefaults.standard
        [("shortcut_baseModifiers", baseModifiers.rawValue), ("shortcut_baseKey", UInt64(baseKey)),
         ("shortcut_forwardModifiers", forwardModifiers.rawValue), ("shortcut_forwardKey", UInt64(forwardKey)),
         ("shortcut_backwardModifiers", backwardModifiers.rawValue), ("shortcut_backwardKey", UInt64(backwardKey))]
            .forEach { d.set($0.1, forKey: $0.0) }
        d.removeObject(forKey: "shortcut_backwardRequiresShift")
    }
    
    static func load() -> ShortcutConfig {
        let d = UserDefaults.standard
        guard let baseRaw = d.object(forKey: "shortcut_baseModifiers") as? UInt64,
              let fwdKey = d.object(forKey: "shortcut_forwardKey") as? Int64,
              let bwdKey = d.object(forKey: "shortcut_backwardKey") as? Int64 else { return .default }
        
        let backMods: CGEventFlags = (d.object(forKey: "shortcut_backwardModifiers") as? UInt64).map { CGEventFlags(rawValue: $0) }
            ?? (d.object(forKey: "shortcut_backwardRequiresShift") as? Bool == true ? .maskShift : [])
        
        return ShortcutConfig(
            baseModifiers: baseRaw == 0 ? Self.default.baseModifiers : CGEventFlags(rawValue: baseRaw),
            baseKey: d.object(forKey: "shortcut_baseKey") as? Int64 ?? 0,
            forwardModifiers: CGEventFlags(rawValue: d.object(forKey: "shortcut_forwardModifiers") as? UInt64 ?? 0),
            forwardKey: fwdKey == 0 ? Self.default.forwardKey : fwdKey,
            backwardModifiers: backMods,
            backwardKey: bwdKey == 0 ? Self.default.backwardKey : bwdKey
        )
    }
    
    private func shortcutString(_ extra: CGEventFlags, _ key: Int64) -> String {
        (modifierNames(from: baseModifiers.union(extra)) + [keyCodeToString(key)]).joined(separator: "+")
    }
}

private let relevantModifierMask: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
private let modifierInfo: [(CGEventFlags, NSEvent.ModifierFlags, String)] = [
    (.maskCommand, .command, "Cmd"), (.maskControl, .control, "Ctrl"),
    (.maskAlternate, .option, "Opt"), (.maskShift, .shift, "Shift")
]

func modifierNames(from flags: CGEventFlags) -> [String] {
    modifierInfo.compactMap { flags.contains($0.0) ? $0.2 : nil }
}

func cgFlags(from modifierFlags: NSEvent.ModifierFlags) -> CGEventFlags {
    CGEventFlags(rawValue: modifierInfo.reduce(0) { modifierFlags.contains($1.1) ? $0 | $1.0.rawValue : $0 })
}

func modifierBitCount(_ flags: CGEventFlags) -> Int {
    modifierInfo.reduce(0) { flags.contains($1.0) ? $0 + 1 : $0 }
}

final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withValue<R>(_ update: (inout Value) -> R) -> R {
        lock.lock(); defer { lock.unlock() }
        return update(&value)
    }
    func get() -> Value {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

final class WeakBox<Object: AnyObject>: @unchecked Sendable {
    weak var value: Object?
    init(_ value: Object?) { self.value = value }
}

extension CGEventFlags {
    func union(_ other: CGEventFlags) -> CGEventFlags { CGEventFlags(rawValue: rawValue | other.rawValue) }
    func contains(_ required: CGEventFlags) -> Bool { required.rawValue == 0 || (rawValue & required.rawValue) == required.rawValue }
}

func keyCodeToString(_ keyCode: Int64) -> String {
    let keyNames: [Int64: String] = [
        48:"Tab", 49:"Space", 51:"Delete", 123:"←", 124:"→", 125:"↓", 126:"↑",
        0:"A", 1:"S", 2:"D", 3:"F", 4:"H", 5:"G", 6:"Z", 7:"X", 8:"C", 9:"V", 11:"B", 12:"Q", 13:"W", 14:"E", 15:"R", 16:"Y", 17:"T",
        18:"1", 19:"2", 20:"3", 21:"4", 22:"6", 23:"5", 24:"=", 25:"9", 26:"7", 27:"-", 28:"8", 29:"0", 30:"]", 31:"O", 32:"U", 33:"[", 34:"I", 35:"P",
        37:"L", 38:"J", 39:"'", 40:"K", 41:";", 42:"\\", 43:",", 44:"/", 45:"N", 46:"M", 47:".", 50:"`",
        96:"F5", 97:"F6", 98:"F7", 99:"F3", 100:"F8", 101:"F9", 103:"F11", 105:"F13", 107:"F14", 109:"F10", 111:"F12", 113:"F15", 118:"F4", 120:"F2", 122:"F1"
    ]
    return keyNames[keyCode] ?? "Key\(keyCode)"
}

actor ThumbnailService {
    static let shared = ThumbnailService()

    private struct Key: Hashable {
        let windowID: CGWindowID
        let width: Int
    }

    private var inFlight: [Key: Task<NSImage?, Never>] = [:]

    private var shareableContentCache: (content: SCShareableContent, fetchedAt: TimeInterval)?
    private let shareableContentTTL: TimeInterval = 0.5

    private init() {}

    func clear() {
        inFlight.values.forEach { $0.cancel() }
        inFlight.removeAll()
        shareableContentCache = nil
    }

    func prune(validWindowIDs: Set<CGWindowID>) {
        if inFlight.isEmpty { return }
        let staleInFlight = inFlight.keys.filter { !validWindowIDs.contains($0.windowID) }
        for key in staleInFlight {
            inFlight[key]?.cancel()
            inFlight[key] = nil
        }
    }

    func thumbnail(windowID: CGWindowID, thumbnailWidth: CGFloat?) async -> NSImage? {
        guard windowID != 0 else { return nil }
        let width = thumbnailWidth.map { max(1, Int($0.rounded())) } ?? 0
        let key = Key(windowID: windowID, width: width)

        // Skip cache - always fetch fresh thumbnails for real-time updates
        // Join existing in-flight request for the same window/size to avoid duplicate captures
        if let task = inFlight[key] { return await task.value }

        let task = Task<NSImage?, Never> {
            defer { Task { self.removeInFlight(key) } }
            guard !Task.isCancelled else { return nil }

            let content = await self.shareableContent()
            guard let scWindow = content?.windows.first(where: { $0.windowID == windowID }) else { return nil }

            let filter = SCContentFilter(desktopIndependentWindow: scWindow)
            let config = SCStreamConfiguration()

            if width > 0 {
                let aspectRatio = scWindow.frame.height / max(1, scWindow.frame.width)
                config.width = width
                config.height = max(1, Int(CGFloat(width) * aspectRatio))
            } else {
                config.width = Int(scWindow.frame.width)
                config.height = Int(scWindow.frame.height)
            }

            config.scalesToFit = true
            config.showsCursor = false
            config.ignoreShadowsDisplay = true
            config.ignoreShadowsSingleWindow = true
            config.capturesAudio = false
            config.captureResolution = .automatic

            do {
                let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                guard !Task.isCancelled else { return nil }
                let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                // Don't cache - we want fresh captures every refresh
                return image
            } catch {
                return nil
            }
        }

        inFlight[key] = task
        return await task.value
    }

    private func removeInFlight(_ key: Key) {
        inFlight[key] = nil
    }

    private func shareableContent() async -> SCShareableContent? {
        let now = CFAbsoluteTimeGetCurrent()
        if let cached = shareableContentCache, (now - cached.fetchedAt) < shareableContentTTL {
            return cached.content
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            shareableContentCache = (content, now)
            return content
        } catch {
            return shareableContentCache?.content
        }
    }
}

extension NSView {
    @discardableResult func add(_ subviews: NSView...) -> Self {
        subviews.forEach(addSubview)
        return self
    }
    func pin(to view: NSView, padding: CGFloat = 0) {
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: padding),
            trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -padding),
            topAnchor.constraint(equalTo: view.topAnchor, constant: padding),
            bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -padding)
        ])
    }
    func center(in view: NSView) {
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([centerXAnchor.constraint(equalTo: view.centerXAnchor), centerYAnchor.constraint(equalTo: view.centerYAnchor)])
    }
    func size(_ w: CGFloat? = nil, _ h: CGFloat? = nil) {
        translatesAutoresizingMaskIntoConstraints = false
        if let w = w { widthAnchor.constraint(equalToConstant: w).isActive = true }
        if let h = h { heightAnchor.constraint(equalToConstant: h).isActive = true }
    }
}
@MainActor
func makeLabel(_ text: String = "", size: CGFloat = 13, weight: NSFont.Weight = .regular, color: NSColor = .labelColor, align: NSTextAlignment = .natural) -> NSTextField {
    let l = NSTextField(labelWithString: text)
    l.font = .systemFont(ofSize: size, weight: weight)
    l.textColor = color
    l.alignment = align
    l.translatesAutoresizingMaskIntoConstraints = false
    return l
}

/// Global shortcut configuration, loaded from UserDefaults on launch
var currentShortcutConfig = ShortcutConfig.load()

private enum AXHelper {
    static func get<T>(_ e: AXUIElement, _ attr: String) -> T? {
        var ref: CFTypeRef?
        let success = AXUIElementCopyAttributeValue(e, attr as CFString, &ref) == .success
        return success ? ref as? T : nil
    }
    static func getValue<T>(_ e: AXUIElement, _ attr: String) -> T? { get(e, attr) }
    static func getBool(_ e: AXUIElement, _ attr: String) -> Bool { get(e, attr) ?? false }
    static func getString(_ e: AXUIElement, _ attr: String) -> String? { get(e, attr) }
    static func getInt(_ e: AXUIElement, _ attr: String) -> Int? { (get(e, attr) as NSNumber?)?.intValue }
    static func setValue(_ e: AXUIElement, _ attr: String, _ val: CFTypeRef) { AXUIElementSetAttributeValue(e, attr as CFString, val) }
    static func performAction(_ e: AXUIElement, _ action: String) { AXUIElementPerformAction(e, action as CFString) }
    
    static func getPoint(_ e: AXUIElement, _ attr: String) -> CGPoint? {
        guard let v: AXValue = get(e, attr), AXValueGetType(v) == .cgPoint else { return nil }
        var p = CGPoint.zero
        _ = withUnsafeMutablePointer(to: &p) { AXValueGetValue(v, .cgPoint, $0) }
        return p
    }
    static func getSize(_ e: AXUIElement, _ attr: String) -> CGSize? {
        guard let v: AXValue = get(e, attr), AXValueGetType(v) == .cgSize else { return nil }
        var s = CGSize.zero
        _ = withUnsafeMutablePointer(to: &s) { AXValueGetValue(v, .cgSize, $0) }
        return s
    }
}

/// Shared cache for app icons, keyed by bundle identifier to avoid duplicates
final class AppIconCache: @unchecked Sendable {
    static let shared = AppIconCache()
    private let cache = NSCache<NSString, NSImage>()
    private let lock = NSLock()
    
    private init() {
        cache.countLimit = 50
    }
    
    func icon(for app: NSRunningApplication?) -> NSImage? {
        guard let app = app else { return nil }
        let key = (app.bundleIdentifier ?? "\(app.processIdentifier)") as NSString
        
        lock.lock()
        if let cached = cache.object(forKey: key) {
            lock.unlock()
            return cached
        }
        lock.unlock()
        
        guard let icon = app.icon else { return nil }
        
        lock.lock()
        cache.setObject(icon, forKey: key)
        lock.unlock()
        return icon
    }
}

class WindowInfo {
    let ownerPID: pid_t
    let ownerName: String
    let windowName: String
    let axWindow: AXUIElement
    var windowID: CGWindowID = 0
    
    private var _app: NSRunningApplication?
    private var _isMinimized: Bool?
    private var _isFullScreen: Bool?
    private var _cachedApp = false
    
    init(ownerPID: pid_t, ownerName: String, windowName: String, axWindow: AXUIElement) {
        self.ownerPID = ownerPID
        self.ownerName = ownerName
        self.windowName = windowName
        self.axWindow = axWindow
    }
    
    var app: NSRunningApplication? {
        if !_cachedApp {
            _app = NSRunningApplication(processIdentifier: ownerPID)
            _cachedApp = true
        }
        return _app
    }
    
    /// Uses shared AppIconCache to avoid duplicate icon storage across windows of the same app
    var appIcon: NSImage? {
        AppIconCache.shared.icon(for: app)
    }
    
    func loadThumbnail(thumbnailWidth: CGFloat? = nil) async -> NSImage? {
        await ThumbnailService.shared.thumbnail(windowID: windowID, thumbnailWidth: thumbnailWidth)
    }
    
    var displayTitle: String { windowName.isEmpty ? ownerName : windowName }
    
    var isMinimized: Bool {
        if _isMinimized == nil {
            _isMinimized = AXHelper.getBool(axWindow, kAXMinimizedAttribute)
        }
        return _isMinimized!
    }
    
    var isFullScreen: Bool {
        if _isFullScreen == nil {
            _isFullScreen = AXHelper.getBool(axWindow, "AXFullScreen")
        }
        return _isFullScreen!
    }
    
    func raise() {
        if AXHelper.getBool(axWindow, kAXMinimizedAttribute) {
            AXHelper.setValue(axWindow, kAXMinimizedAttribute, false as CFTypeRef)
        }
        app?.activate(options: [])
        AXHelper.performAction(axWindow, kAXRaiseAction)
    }
}

extension WindowInfo: @unchecked Sendable {}

@MainActor
protocol SelectableItemView: AnyObject {
    var isSelected: Bool { get set }
}

class FloatingTitleView: NSView {
    private let view = NSView()
    let connectingView = NSView()
    private let titleLabel = makeLabel(size: 13, color: .white, align: .left)
    private let hPad: CGFloat = 8
    private let vPad: CGFloat = 4
    
    override init(frame: NSRect) {
        super.init(frame: frame)
        setupViews()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    
    private func setupViews() {
        wantsLayer = true
        view.wantsLayer = true
        connectingView.wantsLayer = true
        connectingView.layer?.masksToBounds = true
        connectingView.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        connectingView.isHidden = true
        view.layer?.cornerRadius = Config.windowItemCornerRadius
        
        add(view, connectingView, titleLabel)
        view.pin(to: self)
        
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: hPad),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -hPad),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: vPad),
            titleLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -vPad)
        ])
        titleLabel.backgroundColor = .clear
        titleLabel.drawsBackground = false
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.usesSingleLineMode = true
    }

    override func layout() {
        super.layout()
        // Update shadow path based on new bounds
        view.layer?.shadowPath = CGPath(roundedRect: view.bounds, cornerWidth: Config.windowItemCornerRadius, cornerHeight: Config.windowItemCornerRadius, transform: nil)
    }
    
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        view.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        view.layer?.shadowColor = NSColor.black.cgColor
        view.layer?.shadowOpacity = 0.4
        view.layer?.shadowRadius = 2
        view.layer?.shadowOffset = CGSize(width: 0, height: -2)
        view.layer?.masksToBounds = false
        view.layer?.shadowPath = CGPath(roundedRect: view.bounds, cornerWidth: Config.windowItemCornerRadius, cornerHeight: Config.windowItemCornerRadius, transform: nil)
        view.layer?.borderWidth = 1
        view.layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.25).cgColor
    }

    func configure(with title: String) { titleLabel.stringValue = title }
    func idealSize(maxWidth: CGFloat) -> NSSize {
        let s = titleLabel.sizeThatFits(NSSize(width: maxWidth - hPad * 2, height: CGFloat.greatestFiniteMagnitude))
        return NSSize(width: min(s.width + hPad * 2, maxWidth), height: s.height + vPad * 2)
    }
    func positionConnectingView(frame: NSRect) {
        connectingView.frame = frame
        connectingView.isHidden = false
    }
}

/// Base class providing common selection/hover tracking functionality
@MainActor
class BaseItemView: NSView, SelectableItemView {
    var isSelected: Bool = false { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?
    var onHover: (() -> Void)?
    private var trackingArea: NSTrackingArea?
    
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func mouseEntered(with event: NSEvent) { onHover?() }
    
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self
        )
        addTrackingArea(trackingArea!)
    }
}

class WindowItemView: BaseItemView {
    private let iconImageView = NSImageView()
    private let titleLabel = makeLabel(size: 13, color: .labelColor, align: .left)
    private let floatingAppIconView = NSImageView()
    private let titleContainerView = NSView()
    private let minimizedLabel = makeLabel("Minimized", size: 14, weight: .bold, color: .secondaryLabelColor, align: .center)
    private let minimizedBadge: NSView
    private let fullscreenBadge: NSView
    
    private var windowInfo: WindowInfo?
    private var currentWindowID: CGWindowID = 0
    private var visibleCount: Int = 5
    private var iconSizeConstraints: [NSLayoutConstraint] = []
    private var iconCenterYConstraint: NSLayoutConstraint?
    private var floatingIconConstraints: [NSLayoutConstraint] = []

    private var thumbnailTask: Task<Void, Never>?
    
    static let itemSize = Config.gridItemSize
    static let iconSize = Config.gridIconSize
    
    var titleText: String { titleLabel.stringValue }
    var titleLabelFrame: NSRect { titleContainerView.frame }
    var isTitleTruncated: Bool {
        let maxW = bounds.width - 16
        return maxW > 0 && titleLabel.sizeThatFits(NSSize(width: CGFloat.greatestFiniteMagnitude, height: titleLabel.bounds.height)).width > maxW + 1
    }
    func setTitleHidden(_ hidden: Bool) { titleLabel.isHidden = hidden }
    
    static func thumbnailIconSize(forVisibleCount count: Int) -> CGFloat {
        count <= 3 ? round(Config.thumbGridIconSize * 1.79) : (count == 4 ? round(Config.thumbGridIconSize * 1.35) : Config.thumbGridIconSize)
    }
    static func thumbnailItemSize(forVisibleCount count: Int) -> NSSize {
        let s = thumbnailIconSize(forVisibleCount: count)
        return NSSize(width: s + 20, height: round(s * 0.8) + 40)
    }
    
    override init(frame: NSRect) {
        minimizedBadge = Self.createBadge(color: .systemOrange, symbol: "—", fontSize: 14, yOffset: -1)
        fullscreenBadge = Self.createBadge(color: .systemGreen, symbol: "⛶", fontSize: 12, yOffset: 0)
        super.init(frame: frame)
        setupViews()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    
    private static func createBadge(color: NSColor, symbol: String, fontSize: CGFloat, yOffset: CGFloat) -> NSView {
        let b = NSView()
        b.wantsLayer = true
        b.layer?.backgroundColor = color.cgColor
        b.layer?.cornerRadius = 10
        b.translatesAutoresizingMaskIntoConstraints = false
        b.isHidden = true
        let l = makeLabel(symbol, size: fontSize, weight: .bold, color: .labelColor, align: .center)
        b.addSubview(l)
        b.size(20, 20)
        l.center(in: b)
        l.centerYAnchor.constraint(equalTo: b.centerYAnchor, constant: yOffset).isActive = true
        return b
    }
    
    private func setupViews() {
        wantsLayer = true
        layer?.cornerRadius = Config.windowItemCornerRadius

        add(iconImageView, titleContainerView, minimizedLabel, floatingAppIconView, minimizedBadge, fullscreenBadge)
        titleContainerView.add(titleLabel)
        
        iconImageView.imageScaling = .scaleProportionallyUpOrDown
        iconImageView.imageAlignment = .alignCenter
        iconImageView.translatesAutoresizingMaskIntoConstraints = false
        
        titleContainerView.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 2
        
        minimizedLabel.isHidden = true
        
        floatingAppIconView.imageScaling = .scaleProportionallyUpOrDown
        floatingAppIconView.translatesAutoresizingMaskIntoConstraints = false
        floatingAppIconView.isHidden = true
        floatingAppIconView.wantsLayer = true
        
        setupConstraints()
    }
    
    private func setupConstraints() {
        let iconW = iconImageView.widthAnchor.constraint(equalToConstant: Self.iconSize)
        let iconH = iconImageView.heightAnchor.constraint(equalToConstant: Self.iconSize)
        iconSizeConstraints = [iconW, iconH]
        iconCenterYConstraint = iconImageView.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -10)
        iconCenterYConstraint?.isActive = true
        
        NSLayoutConstraint.activate([
            iconImageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconImageView.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 8),
            iconImageView.bottomAnchor.constraint(lessThanOrEqualTo: titleContainerView.topAnchor, constant: -4),
            iconW, iconH,
            
            titleContainerView.centerXAnchor.constraint(equalTo: centerXAnchor),
            titleContainerView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            titleContainerView.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 8),
            titleContainerView.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            
            titleLabel.leadingAnchor.constraint(equalTo: titleContainerView.leadingAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: titleContainerView.trailingAnchor),
            titleLabel.topAnchor.constraint(equalTo: titleContainerView.topAnchor),
            titleLabel.bottomAnchor.constraint(equalTo: titleContainerView.bottomAnchor),
            
            minimizedLabel.centerXAnchor.constraint(equalTo: iconImageView.centerXAnchor),
            minimizedLabel.centerYAnchor.constraint(equalTo: iconImageView.centerYAnchor),
            
            minimizedBadge.trailingAnchor.constraint(equalTo: iconImageView.trailingAnchor, constant: 4),
            minimizedBadge.topAnchor.constraint(equalTo: iconImageView.topAnchor, constant: -4),
            fullscreenBadge.trailingAnchor.constraint(equalTo: iconImageView.trailingAnchor, constant: 4),
            fullscreenBadge.topAnchor.constraint(equalTo: iconImageView.topAnchor, constant: -4),
        ])
        
        floatingIconConstraints = [
            floatingAppIconView.widthAnchor.constraint(equalToConstant: 60),
            floatingAppIconView.heightAnchor.constraint(equalToConstant: 60),
            floatingAppIconView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            floatingAppIconView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -20)
        ]
        NSLayoutConstraint.activate(floatingIconConstraints)
    }
    
    func configure(with windowInfo: WindowInfo, viewMode: ViewMode = currentViewMode, visibleCount: Int = 5) {
        self.windowInfo = windowInfo
        self.currentWindowID = windowInfo.windowID
        self.visibleCount = visibleCount
        if viewMode == .thumbnails {
            configureThumbnailsMode(windowInfo, visibleCount: visibleCount)
            minimizedLabel.isHidden = !windowInfo.isMinimized
            minimizedBadge.isHidden = true
        } else {
            configureGridMode(windowInfo)
            minimizedLabel.isHidden = true
            minimizedBadge.isHidden = !windowInfo.isMinimized
        }
        fullscreenBadge.isHidden = !windowInfo.isFullScreen
        titleLabel.stringValue = windowInfo.displayTitle
        
        // Align truncated titles to the left in icon and thumbnail modes
        if (viewMode == .grid || viewMode == .thumbnails) && isTitleTruncated {
            titleLabel.alignment = .left
        }
    }
    
    private func configureGridMode(_ windowInfo: WindowInfo) {
        cancelThumbnailWork()
        iconImageView.image = windowInfo.appIcon
        floatingAppIconView.isHidden = true
        titleLabel.alignment = .center
        iconSizeConstraints.forEach { $0.constant = Self.iconSize }
        iconCenterYConstraint?.constant = -10
    }
    
    private func configureThumbnailsMode(_ windowInfo: WindowInfo, visibleCount: Int) {
        let windowID = windowInfo.windowID
        let iconSize = Self.thumbnailIconSize(forVisibleCount: visibleCount)
        iconSizeConstraints.forEach { $0.constant = iconSize }
        let floatingIconSize = visibleCount <= 4 ? iconSize * 0.25 : iconSize * 0.35
        floatingIconConstraints[0].constant = floatingIconSize
        floatingIconConstraints[1].constant = floatingIconSize

        // Don't nil the image - keep showing previous thumbnail until new one loads
        // Only clear if this is a different window than before
        if currentWindowID != windowID {
            iconImageView.image = nil
        }
        floatingAppIconView.image = windowInfo.appIcon
        floatingAppIconView.isHidden = false
        
        if SwitcherWindowController.shared.isVisible && windowID != 0 {
            startThumbnailTask(windowInfo: windowInfo, windowID: windowID, visibleCount: visibleCount, force: true)
        }
        titleLabel.alignment = .center
    }
    
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if isSelected {
            layer?.backgroundColor = NSColor.controlAccentColor.cgColor
            layer?.masksToBounds = false
            layer?.shadowColor = NSColor.black.cgColor
            layer?.shadowOpacity = 0.4
            layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: Config.windowItemCornerRadius, cornerHeight: Config.windowItemCornerRadius, transform: nil)
            layer?.borderWidth = 1
            layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.25).cgColor

            if isTitleTruncated {
                layer?.shadowRadius = 0
                layer?.shadowOffset = CGSize(width: 0, height: 0)
            } else {
                layer?.shadowRadius = 2
                layer?.shadowOffset = CGSize(width: 0, height: -2)
            }
            titleLabel.textColor = NSColor.white
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
            layer?.shadowOpacity = 0
            layer?.shadowRadius = 0
            layer?.shadowOffset = .zero
            layer?.shadowColor = nil
            layer?.shadowPath = nil
            layer?.masksToBounds = true
            layer?.borderWidth = 0
            titleLabel.textColor = NSColor.labelColor
        }
    }

    func refreshThumbnail() {
        guard let windowInfo = windowInfo, currentWindowID != 0 else { return }
        startThumbnailTask(windowInfo: windowInfo, windowID: currentWindowID, visibleCount: visibleCount, force: false)
    }

    func cancelThumbnailWork() {
        thumbnailTask?.cancel()
        thumbnailTask = nil
    }
    
    /// Releases the thumbnail image to free memory when leaving thumbnails mode
    func clearThumbnailImage() {
        cancelThumbnailWork()
        iconImageView.image = nil
    }

    private func startThumbnailTask(windowInfo: WindowInfo, windowID: CGWindowID, visibleCount: Int, force: Bool) {
        guard SwitcherWindowController.shared.isVisible, currentViewMode == .thumbnails else { return }
        
        // Cancel any existing task so we can start a fresh one
        thumbnailTask?.cancel()
        thumbnailTask = nil

        let weakView = WeakBox(self)
        let itemSize = WindowItemView.thumbnailItemSize(forVisibleCount: visibleCount)
        thumbnailTask = Task(priority: .utility) { [weakView] in
            defer {
                Task { @MainActor in weakView.value?.thumbnailTask = nil }
            }
            guard let thumbnail = await windowInfo.loadThumbnail(thumbnailWidth: itemSize.width) else { return }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let view = weakView.value, view.currentWindowID == windowID, SwitcherWindowController.shared.isVisible else { return }
                view.iconImageView.image = thumbnail
            }
        }
    }
}

class ListItemView: BaseItemView {
    private let iconImageView = NSImageView()
    private let titleLabel = makeLabel(size: 13, color: .labelColor)
    private let appNameLabel = makeLabel(size: 11, color: .secondaryLabelColor)
    static let itemSize = Config.listItemSize
    
    override init(frame: NSRect) {
        super.init(frame: frame)
        setupViews()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    
    private func setupViews() {
        wantsLayer = true
        layer?.cornerRadius = Config.windowItemCornerRadius
        iconImageView.imageScaling = .scaleProportionallyUpOrDown
        iconImageView.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        appNameLabel.lineBreakMode = .byTruncatingTail
        appNameLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        
        add(iconImageView, titleLabel, appNameLabel)
        
        NSLayoutConstraint.activate([
            iconImageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            iconImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconImageView.widthAnchor.constraint(equalToConstant: 24),
            iconImageView.heightAnchor.constraint(equalToConstant: 24),
            
            titleLabel.leadingAnchor.constraint(equalTo: iconImageView.trailingAnchor, constant: 8),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: appNameLabel.leadingAnchor, constant: -8),
            
            appNameLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            appNameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            appNameLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 100),
        ])
    }
    
    func configure(with windowInfo: WindowInfo) {
        iconImageView.image = windowInfo.appIcon
        titleLabel.stringValue = windowInfo.displayTitle
        appNameLabel.stringValue = windowInfo.ownerName
    }
    
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if isSelected {
            layer?.backgroundColor = NSColor.controlAccentColor.cgColor
            layer?.masksToBounds = false
            layer?.shadowColor = NSColor.black.cgColor
            layer?.shadowOpacity = 0.4
            layer?.shadowRadius = 1
            layer?.shadowOffset = CGSize(width: 0, height: -1)
            layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: Config.windowItemCornerRadius, cornerHeight: Config.windowItemCornerRadius, transform: nil)
            layer?.borderWidth = 1
            layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.25).cgColor
            titleLabel.textColor = NSColor.white
            appNameLabel.textColor = NSColor.white
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
            layer?.shadowColor = nil
            layer?.shadowOpacity = 0
            layer?.shadowRadius = 0
            layer?.shadowOffset = .zero
            layer?.shadowPath = nil
            layer?.masksToBounds = true
            layer?.borderWidth = 0
            titleLabel.textColor = NSColor.labelColor
            appNameLabel.textColor = NSColor.secondaryLabelColor
        }
    }
}

/// Manages the floating switcher window(s) displayed on all screens.
/// Handles layout, selection, and display of window items.
@MainActor
class SwitcherWindowController {
    static let shared = SwitcherWindowController()
    
    private var screenWindows: [NSWindow] = []
    private var screenVisualEffects: [NSVisualEffectView] = []
    private var screenContentViews: [NSView] = []
    private var screenItemViews: [[NSView]] = []
    private var floatingTitleViews: [FloatingTitleView] = []
    
    private var windows: [WindowInfo] = []
    private var selectedIndex = 0
    private var thumbnailRefreshTimer: Timer?
    private var thumbnailCleanupTimer: Timer?
    private var scrollRowOffset = 0
    private var listScrollOffset = 0
    private var lastHoveredIndex: Int?
    private(set) var isVisible = false
    
    private init() {}
    
    func show(windows: [WindowInfo], selectedIndex: Int) {
        guard !windows.isEmpty else { return }
        self.windows = windows
        self.selectedIndex = selectedIndex
        isVisible = true
        scrollRowOffset = 0
        listScrollOffset = 0
        adjustScrollForSelection()
        createWindowsForAllScreens()
        updateDynamicColors()
        updateContent()
        screenWindows.forEach { $0.orderFrontRegardless() }
        detectInitialMousePosition()
        startThumbnailRefreshTimerIfNeeded()
        startThumbnailCleanupTimerIfNeeded()
    }
    
    func hide() {
        isVisible = false
        thumbnailRefreshTimer?.invalidate()
        thumbnailRefreshTimer = nil
        thumbnailCleanupTimer?.invalidate()
        thumbnailCleanupTimer = nil
        cancelThumbnailWorkAndClearCache()
        lastHoveredIndex = nil
        (scrollRowOffset, listScrollOffset) = (0, 0)
        screenWindows.forEach { $0.orderOut(nil) }
    }
    
    func moveSelection(to index: Int) {
        guard !windows.isEmpty, index >= 0, index < windows.count else { return }
        selectedIndex = index
        updateAfterSelectionChange()
    }
    
    private func updateAfterSelectionChange() {
        let prevGrid = scrollRowOffset, prevList = listScrollOffset
        adjustScrollForSelection()
        let changed = currentViewMode == .list ? prevList != listScrollOffset : prevGrid != scrollRowOffset
        changed ? updateContent() : updateSelection()
    }
    
    func selectAndSwitch(index: Int) {
        guard index >= 0 && index < windows.count else { return }
        selectedIndex = index
        WindowManager.shared.switchToWindow(at: index)
    }
    
    func hoverSelect(index: Int) {
        guard index != lastHoveredIndex else { return }
        lastHoveredIndex = index
        guard index >= 0, index < windows.count, index != selectedIndex else { return }
        selectedIndex = index
        WindowManager.shared.updateSelectedIndex(index)
        updateSelection()
    }
    
    func refreshViewMode() {
        guard !windows.isEmpty else { return }
        if currentViewMode != .thumbnails {
            clearThumbnailImagesFromViews()
            cancelThumbnailWorkAndClearCache()
        }
        updateContent()
        startThumbnailRefreshTimerIfNeeded()
        startThumbnailCleanupTimerIfNeeded()
    }
    
    /// Clears thumbnail images from all item views to free memory immediately
    private func clearThumbnailImagesFromViews() {
        for itemViews in screenItemViews {
            for view in itemViews {
                (view as? WindowItemView)?.clearThumbnailImage()
            }
        }
    }
    
    private func startThumbnailRefreshTimerIfNeeded() {
        thumbnailRefreshTimer?.invalidate()
        thumbnailRefreshTimer = nil
        guard isVisible, currentViewMode == .thumbnails else { return }
        thumbnailRefreshTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshThumbnails() }
        }
    }

    private func startThumbnailCleanupTimerIfNeeded() {
        thumbnailCleanupTimer?.invalidate()
        thumbnailCleanupTimer = nil
        guard isVisible, currentViewMode == .thumbnails else { return }
        thumbnailCleanupTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                let validIDs = self.getVisibleWindowIDs()
                await ThumbnailService.shared.prune(validWindowIDs: validIDs)
            }
        }
    }

    /// Returns the windowIDs of windows currently visible in the switcher UI
    private func getVisibleWindowIDs() -> Set<CGWindowID> {
        guard !windows.isEmpty else { return [] }
        let startIndex: Int
        let endIndex: Int
        
        if currentViewMode == .list {
            startIndex = listScrollOffset
            endIndex = min(startIndex + Config.listMaxItems, windows.count)
        } else {
            startIndex = scrollRowOffset * Config.gridColumns
            let visibleRows = currentViewMode == .thumbnails ? Config.thumbnailMaxRows : Config.gridMaxRows
            let maxVisible = Config.gridColumns * visibleRows
            endIndex = min(startIndex + maxVisible, windows.count)
        }
        
        guard startIndex < windows.count else { return [] }
        return Set(windows[startIndex..<endIndex].map { $0.windowID })
    }

    private func cancelThumbnailWorkAndClearCache() {
        for itemViews in screenItemViews {
            for view in itemViews {
                (view as? WindowItemView)?.cancelThumbnailWork()
            }
        }
        Task { await ThumbnailService.shared.clear() }
    }
    
    private func refreshThumbnails() {
        guard isVisible, currentViewMode == .thumbnails else { return }
        for itemViews in screenItemViews {
            for view in itemViews {
                if let windowItemView = view as? WindowItemView {
                    windowItemView.refreshThumbnail()
                }
            }
        }
    }
    
    private func detectInitialMousePosition() {
        let mouse = NSEvent.mouseLocation
        let startIndex = currentViewMode == .list ? listScrollOffset : scrollRowOffset * Config.gridColumns
        for itemViews in screenItemViews {
            for (i, view) in itemViews.enumerated() {
                guard let w = view.window else { continue }
                if view.bounds.contains(view.convert(w.convertPoint(fromScreen: mouse), from: nil)) {
                    lastHoveredIndex = startIndex + i
                    return
                }
            }
        }
    }
    
    private func adjustScrollForSelection() {
        guard !windows.isEmpty else { return }
        if currentViewMode == .list {
            if selectedIndex < listScrollOffset { listScrollOffset = selectedIndex }
            else if selectedIndex >= listScrollOffset + Config.listMaxItems { listScrollOffset = selectedIndex - Config.listMaxItems + 1 }
        } else {
            let row = selectedIndex / Config.gridColumns
            let visible = currentViewMode == .thumbnails ? Config.thumbnailMaxRows : Config.gridMaxRows
            if row < scrollRowOffset { scrollRowOffset = row }
            else if row >= scrollRowOffset + visible { scrollRowOffset = row - visible + 1 }
        }
    }
    
    private func createWindowsForAllScreens() {
        let screens = screensToShow()
        screenWindows.forEach { $0.orderOut(nil) }
        while screenWindows.count > screens.count {
            screenWindows.removeLast()
            screenVisualEffects.removeLast()
            screenContentViews.removeLast()
            screenItemViews.removeLast()
            floatingTitleViews.removeLast()
        }
        while screenWindows.count < screens.count {
            let (window, visualEffect, contentView) = createWindow()
            screenWindows.append(window)
            screenVisualEffects.append(visualEffect)
            screenContentViews.append(contentView)
            screenItemViews.append([])
            let floatingTitle = FloatingTitleView(frame: .zero)
            floatingTitle.isHidden = true
            contentView.addSubview(floatingTitle, positioned: .above, relativeTo: nil)
            floatingTitleViews.append(floatingTitle)
        }
    }
    
    private func screensToShow() -> [NSScreen] {
        let fallback = { [NSScreen.main ?? NSScreen.screens[0]] }
        switch currentScreenMode {
        case .allScreens: return NSScreen.screens
        case .activeScreen:
            guard let app = NSWorkspace.shared.frontmostApplication,
                  let focused: AXUIElement = AXHelper.getValue(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedWindowAttribute),
                  let pos = AXHelper.getPoint(focused, kAXPositionAttribute),
                  let screen = NSScreen.screens.first(where: { $0.frame.contains(pos) }) else { return fallback() }
            return [screen]
        case .mouseScreen:
            return NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }).map { [$0] } ?? fallback()
        }
    }
    
    private func createWindow() -> (NSWindow, NSVisualEffectView, NSView) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 180),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.ignoresMouseEvents = false
        
        let visualEffect = NSVisualEffectView(frame: window.frame)
        visualEffect.material = .hudWindow
        visualEffect.appearance = nil
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 18
        visualEffect.layer?.masksToBounds = true
        visualEffect.layer?.borderWidth = 1
        
        let contentView = NSView(frame: window.frame)
        contentView.wantsLayer = true
        visualEffect.addSubview(contentView)
        window.contentView = visualEffect
        
        return (window, visualEffect, contentView)
    }
    
    /// Updates dynamic colors that depend on system appearance
    private func updateDynamicColors() {
        for visualEffect in screenVisualEffects {
            visualEffect.layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }
    
    private func updateContent() {
        guard !windows.isEmpty else { return }
        currentViewMode == .list ? updateListContent() : updateGridContent()
    }
    
    private func updateListContent() {
        let startIndex = listScrollOffset
        let endIndex = min(startIndex + Config.listMaxItems, windows.count)
        let visibleCount = endIndex - startIndex
        guard visibleCount > 0 else { return }
        let visibleWindows = Array(windows[startIndex..<endIndex])
        let itemSize = ListItemView.itemSize
        
        let totalSize = NSSize(
            width: itemSize.width + Config.itemPadding * 2,
            height: CGFloat(visibleCount) * itemSize.height + CGFloat(visibleCount - 1) * Config.itemSpacing + Config.itemPadding * 2
        )
        
        updateScreens(totalSize: totalSize) { contentView, _ in
            visibleWindows.enumerated().map { visibleIndex, windowInfo in
                let actualIndex = startIndex + visibleIndex
                let itemY = totalSize.height - Config.itemPadding - itemSize.height - CGFloat(visibleIndex) * (itemSize.height + Config.itemSpacing)
                let itemView = ListItemView(frame: NSRect(x: Config.itemPadding, y: itemY, width: itemSize.width, height: itemSize.height))
                itemView.configure(with: windowInfo)
                itemView.isSelected = (actualIndex == selectedIndex)
                itemView.onClick = { [weak self] in self?.selectAndSwitch(index: actualIndex) }
                itemView.onHover = { [weak self] in self?.hoverSelect(index: actualIndex) }
                contentView.addSubview(itemView)
                return itemView
            }
        }
    }
    
    private func updateGridContent() {
        let startIndex = scrollRowOffset * Config.gridColumns
        let visibleRows = (currentViewMode == .thumbnails) ? Config.thumbnailMaxRows : Config.gridMaxRows
        let maxVisible = Config.gridColumns * visibleRows
        let endIndex = min(startIndex + maxVisible, windows.count)
        guard startIndex < windows.count else { return }
        
        let visibleWindows = Array(windows[startIndex..<endIndex])
        let visibleCount = visibleWindows.count
        let columns = min(visibleCount, Config.gridColumns)
        let rows = (visibleCount + Config.gridColumns - 1) / Config.gridColumns
        
        let itemSize: NSSize
        if currentViewMode == .thumbnails {
            itemSize = WindowItemView.thumbnailItemSize(forVisibleCount: visibleCount)
        } else {
            itemSize = WindowItemView.itemSize
        }
        
        let totalSize = NSSize(
            width: CGFloat(columns) * itemSize.width + CGFloat(columns - 1) * Config.itemSpacing + Config.itemPadding * 2,
            height: CGFloat(rows) * itemSize.height + CGFloat(rows - 1) * Config.itemSpacing + Config.itemPadding * 2
        )
        
        updateScreens(totalSize: totalSize) { contentView, _ in
            visibleWindows.enumerated().map { visibleIndex, windowInfo in
                let actualIndex = startIndex + visibleIndex
                let col = visibleIndex % Config.gridColumns
                let row = visibleIndex / Config.gridColumns
                
                let itemX = Config.itemPadding + CGFloat(col) * (itemSize.width + Config.itemSpacing)
                let itemY = totalSize.height - Config.itemPadding - itemSize.height - CGFloat(row) * (itemSize.height + Config.itemSpacing)
                
                let itemView = WindowItemView(frame: NSRect(x: itemX, y: itemY, width: itemSize.width, height: itemSize.height))
                itemView.configure(with: windowInfo, visibleCount: visibleCount)
                itemView.isSelected = (actualIndex == selectedIndex)
                itemView.onClick = { [weak self] in self?.selectAndSwitch(index: actualIndex) }
                itemView.onHover = { [weak self] in self?.hoverSelect(index: actualIndex) }
                contentView.addSubview(itemView)
                return itemView
            }
        }
    }
    
    /// Common screen update logic - positions window and creates items
    private func updateScreens(totalSize: NSSize, createItems: (NSView, NSScreen) -> [NSView]) {
        let screens = screensToShow()
        let startIndex = currentViewMode == .list ? listScrollOffset : scrollRowOffset * Config.gridColumns
        
        for (index, screen) in screens.enumerated() {
            guard index < screenWindows.count else { continue }
            
            let window = screenWindows[index]
            let contentView = screenContentViews[index]
            
            screenItemViews[index].forEach { $0.removeFromSuperview() }
            
            let frame = screen.frame
            window.setFrame(NSRect(
                x: frame.origin.x + (frame.width - totalSize.width) / 2,
                y: frame.origin.y + (frame.height - totalSize.height) / 2,
                width: totalSize.width,
                height: totalSize.height
            ), display: true)
            contentView.frame = NSRect(origin: .zero, size: totalSize)
            window.contentView?.frame = contentView.frame
            
            screenItemViews[index] = createItems(contentView, screen)
            
            if index < floatingTitleViews.count {
                let floatingTitle = floatingTitleViews[index]
                floatingTitle.removeFromSuperview()
                contentView.addSubview(floatingTitle, positioned: .above, relativeTo: nil)
                
                if currentViewMode != .list {
                    updateFloatingTitle(screenIndex: index, itemViews: screenItemViews[index], startIndex: startIndex)
                } else {
                    floatingTitle.isHidden = true
                }
            }
        }
    }
    
    private func updateSelection() {
        let startIndex = currentViewMode == .list ? listScrollOffset : scrollRowOffset * Config.gridColumns
        for (screenIndex, itemViews) in screenItemViews.enumerated() {
            for (visibleIndex, view) in itemViews.enumerated() {
                let actualIndex = startIndex + visibleIndex
                if let itemView = view as? SelectableItemView {
                    itemView.isSelected = (actualIndex == selectedIndex)
                }
            }
            if currentViewMode != .list, screenIndex < floatingTitleViews.count {
                updateFloatingTitle(screenIndex: screenIndex, itemViews: itemViews, startIndex: startIndex)
            }
        }
    }
    
    /// Updates the floating title view for a given screen
    private func updateFloatingTitle(screenIndex: Int, itemViews: [NSView], startIndex: Int) {
        let floatingTitle = floatingTitleViews[screenIndex]
        let containerView = screenContentViews[screenIndex]
        let containerMargin: CGFloat = 8
        
        for view in itemViews {
            if let windowItem = view as? WindowItemView {
                windowItem.setTitleHidden(false)
            }
        }
        
        if itemViews.count <= 1 {
            floatingTitle.isHidden = true
            floatingTitle.connectingView.isHidden = true
            return
        }
        
        let selectedVisibleIndex = selectedIndex - startIndex
        guard selectedVisibleIndex >= 0, selectedVisibleIndex < itemViews.count,
              let itemView = itemViews[selectedVisibleIndex] as? WindowItemView else {
            floatingTitle.isHidden = true
            floatingTitle.connectingView.isHidden = true
            return
        }
        
        itemView.layoutSubtreeIfNeeded()
        
        guard itemView.isTitleTruncated else {
            floatingTitle.isHidden = true
            floatingTitle.connectingView.isHidden = true
            return
        }
        
        itemView.setTitleHidden(true)
        
        let title = itemView.titleText
        let titleFrame = itemView.titleLabelFrame
        
        floatingTitle.configure(with: title)
        floatingTitle.isHidden = false
        
        let maxWidth = containerView.bounds.width - containerMargin * 2
        let titleSize = floatingTitle.idealSize(maxWidth: maxWidth)
        
        let itemCenterX = itemView.frame.midX
        var titleX = itemCenterX - titleSize.width / 2
        
        let minX = containerMargin
        let maxX = containerView.bounds.width - containerMargin - titleSize.width
        titleX = max(minX, min(titleX, maxX))
        
        let titleBottomY = itemView.frame.origin.y + titleFrame.maxY
        // Offset by vPad (4pt) so the text inside the floating title aligns with the non-floating title
        var titleY = titleBottomY - titleSize.height + 4
        let minY = containerMargin
        let maxY = containerView.bounds.height - containerMargin - titleSize.height
        titleY = max(minY, min(titleY, maxY))
        
        floatingTitle.frame = NSRect(x: titleX, y: titleY, width: titleSize.width, height: titleSize.height)

        // Position connecting view relative to floatingTitle
        let itemFrameRelativeToFloatingTitle = NSRect(
            x: itemView.frame.origin.x - titleX + 1,
            y: itemView.frame.origin.y - titleY + round(titleSize.height * 0.5),
            width: itemView.frame.width - 2,
            height: round(titleSize.height * 0.5) + 2
        )
        floatingTitle.positionConnectingView(frame: itemFrameRelativeToFloatingTitle)
    }
}

/// Manages window enumeration, sorting, and switching.
/// Uses Accessibility API to get window list and CGWindowList for z-order.
final class WindowManager {
    static let shared = WindowManager()
    
    private var windowIndex = 0
    private var cachedWindows: [WindowInfo] = []
    private var isShowingSwitcher = false
    /// Tracks the windowID that was last switched to, to ensure only that specific
    /// window moves to front (not all windows of the same app)
    private var lastSwitchedWindowID: CGWindowID = 0
    
    private init() {}
    
    func showSwitcherAndNext() { showSwitcher(delta: 1) }
    func showSwitcherAndPrevious() { showSwitcher(delta: -1) }
    
    func confirmAndSwitch() {
        isShowingSwitcher = false
        guard windowIndex >= 0 && windowIndex < cachedWindows.count else {
            cachedWindows.removeAll()
            return
        }
        let target = cachedWindows[windowIndex]
        lastSwitchedWindowID = target.windowID
        cachedWindows.removeAll()
        Task { @MainActor in SwitcherWindowController.shared.hide() }
        target.raise()
    }
    
    func switchToWindow(at index: Int) {
        isShowingSwitcher = false
        guard index >= 0 && index < cachedWindows.count else {
            cachedWindows.removeAll()
            return
        }
        windowIndex = index
        let target = cachedWindows[index]
        lastSwitchedWindowID = target.windowID
        cachedWindows.removeAll()
        Task { @MainActor in SwitcherWindowController.shared.hide() }
        target.raise()
    }
    
    func cancelSwitcher() {
        isShowingSwitcher = false
        cachedWindows.removeAll()
        Task { @MainActor in SwitcherWindowController.shared.hide() }
    }
    
    func updateSelectedIndex(_ index: Int) {
        guard index >= 0 && index < cachedWindows.count else { return }
        windowIndex = index
    }
    
    func isSwitcherVisible() -> Bool { isShowingSwitcher }
    
    private func showSwitcher(delta: Int) {
        if !isShowingSwitcher {
            cachedWindows = getAllWindows()
            guard !cachedWindows.isEmpty else { return }
            isShowingSwitcher = true
            windowIndex = delta > 0 ? 1 % cachedWindows.count : (cachedWindows.count - 1) % cachedWindows.count
            let windows = cachedWindows
            let index = windowIndex
            Task { @MainActor in
                SwitcherWindowController.shared.show(windows: windows, selectedIndex: index)
            }
        } else {
            guard !cachedWindows.isEmpty else {
                cancelSwitcher()
                return
            }
            windowIndex = (windowIndex + delta + cachedWindows.count) % cachedWindows.count
            let index = windowIndex
            Task { @MainActor in
                SwitcherWindowController.shared.moveSelection(to: index)
            }
        }
    }
    
    func getAllWindows() -> [WindowInfo] {
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }
        let windows = apps.flatMap { getWindowsForApp($0) }
        let windowOrder = getWindowOrder()
        let orderMap = Dictionary(uniqueKeysWithValues: windowOrder.enumerated().map { ($1.windowID, $0) })
        
        var usedIDs = Set<CGWindowID>()
        var sorted: [(WindowInfo, Int)] = windows.map { window in
            if let num = AXHelper.getInt(window.axWindow, kAXWindowNumberAttribute) {
                let id = CGWindowID(num)
                window.windowID = id
                usedIDs.insert(id)
                return (window, orderMap[id] ?? Int.max)
            }
            if let match = findWindowMatch(window, in: windowOrder, usedIDs: &usedIDs) {
                window.windowID = match.1
                return (window, match.0)
            }
            return (window, Int.max)
        }
        sorted.sort { $0.1 < $1.1 }
        
        var result = sorted.map { $0.0 }
        if lastSwitchedWindowID != 0 {
            moveWindowToFront(&result) { $0.windowID == lastSwitchedWindowID }
        }
        lastSwitchedWindowID = 0
        if let active = getActiveWindowIdentifier() {
            moveWindowToFront(&result) { window in
                if let activeID = active.windowID, window.windowID == activeID { return true }
                return CFEqual(window.axWindow, active.element)
            }
        }
        return result
    }
    
    private func moveWindowToFront(_ windows: inout [WindowInfo], matching predicate: (WindowInfo) -> Bool) {
        guard let idx = windows.firstIndex(where: predicate), idx > 0 else { return }
        windows.insert(windows.remove(at: idx), at: 0)
    }
    
    private func getActiveWindowIdentifier() -> (element: AXUIElement, windowID: CGWindowID?)? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let focused: AXUIElement = AXHelper.getValue(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedWindowAttribute) else { return nil }
        let num = AXHelper.getInt(focused, kAXWindowNumberAttribute)
        return (focused, num.map(CGWindowID.init))
    }
    
    private func getWindowsForApp(_ app: NSRunningApplication) -> [WindowInfo] {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        guard let axWindows: [AXUIElement] = AXHelper.getValue(appElement, kAXWindowsAttribute) else {
            return []
        }
        
        let isFinder = app.bundleIdentifier == "com.apple.finder"
        
        return axWindows.compactMap { axWindow -> WindowInfo? in
            let isMinimized = AXHelper.getBool(axWindow, kAXMinimizedAttribute)
            
            if !isMinimized, let size = AXHelper.getSize(axWindow, kAXSizeAttribute),
               size.width < 50 || size.height < 50 {
                return nil
            }
            
            let title = AXHelper.getString(axWindow, kAXTitleAttribute)
            
            if isFinder && (title == nil || title!.isEmpty) { return nil }
            
            if !isMinimized, let subrole: String = AXHelper.getValue(axWindow, kAXSubroleAttribute),
               subrole != "AXStandardWindow" { return nil }
            
            return WindowInfo(ownerPID: app.processIdentifier, ownerName: app.localizedName ?? "Unknown",
                              windowName: title ?? app.localizedName ?? "Unknown", axWindow: axWindow)
        }
    }
    
    private func getWindowOrder() -> [(pid: pid_t, title: String, bounds: CGRect, windowID: CGWindowID)] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { dict -> (pid_t, String, CGRect, CGWindowID)? in
            guard let pid = dict[kCGWindowOwnerPID as String] as? pid_t,
                  let windowID = dict[kCGWindowNumber as String] as? CGWindowID,
                  let layer = dict[kCGWindowLayer as String] as? Int, layer == 0 else { return nil }
            let title = dict[kCGWindowName as String] as? String ?? ""
            guard let b = dict[kCGWindowBounds as String] as? [String: Any] else { return (pid, title, .zero, windowID) }
            return (pid, title, CGRect(x: b["X"] as? CGFloat ?? 0, y: b["Y"] as? CGFloat ?? 0,
                                       width: b["Width"] as? CGFloat ?? 0, height: b["Height"] as? CGFloat ?? 0), windowID)
        }
    }
    
    private func findWindowMatch(_ window: WindowInfo, in order: [(pid: pid_t, title: String, bounds: CGRect, windowID: CGWindowID)],
                                  usedIDs: inout Set<CGWindowID>) -> (Int, CGWindowID)? {
        let pos = AXHelper.getPoint(window.axWindow, kAXPositionAttribute)
        let size = AXHelper.getSize(window.axWindow, kAXSizeAttribute)
        
        for (i, e) in order.enumerated() where e.pid == window.ownerPID && !usedIDs.contains(e.windowID) {
            if let p = pos, let s = size {
                let tol: CGFloat = 2
                if abs(e.bounds.origin.x - p.x) < tol && abs(e.bounds.origin.y - p.y) < tol &&
                   abs(e.bounds.width - s.width) < tol && abs(e.bounds.height - s.height) < tol {
                    usedIDs.insert(e.windowID)
                    return (i, e.windowID)
                }
            }
        }
        for (i, e) in order.enumerated() where e.pid == window.ownerPID && !usedIDs.contains(e.windowID) {
            if !e.title.isEmpty && e.title == window.windowName {
                usedIDs.insert(e.windowID)
                return (i, e.windowID)
            }
        }
        return nil
    }
}

final class HotkeyManager {
    static let shared = HotkeyManager()
    
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var baseComboPressed = false
    private var activeShortcutConfig = ShortcutConfig.default
    
    private init() {}
    
    @MainActor
    func updateShortcutConfig(_ config: ShortcutConfig) {
        activeShortcutConfig = config
    }
    
    @MainActor
    func start() {
        guard isAccessibilityPermissionGranted() else {
            showAccessibilityAlertIfNeeded(onComplete: { [weak self] in self?.start() })
            return
        }
        
        let eventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { proxy, type, event, refcon in
                HotkeyManager.handleEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: nil
        ) else {
            showAccessibilityAlertIfNeeded(onComplete: { [weak self] in self?.start() })
            return
        }
        
        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }
    
    @MainActor
    func stop() {
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes) }
        (eventTap, runLoopSource) = (nil, nil)
    }
    
    private static func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = { Unmanaged.passRetained(event) }
        
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            shared.eventTap.map { CGEvent.tapEnable(tap: $0, enable: true) }
            return pass()
        }
        guard !ShortcutSettingsWindowController.isOpen else { return pass() }
        
        let config = shared.activeShortcutConfig
        let flags = CGEventFlags(rawValue: event.flags.rawValue & relevantModifierMask.rawValue)
        let baseMods = flags.contains(config.baseModifiers)
        
        if type == .flagsChanged {
            let was = shared.baseComboPressed
            shared.baseComboPressed = baseMods && (config.baseKey == 0 || shared.baseComboPressed)
            if was && !baseMods && WindowManager.shared.isSwitcherVisible() { WindowManager.shared.confirmAndSwitch() }
            return pass()
        }
        guard type == .keyDown else { return pass() }
        
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        let fwdReq = config.baseModifiers.union(config.forwardModifiers)
        let bwdReq = config.baseModifiers.union(config.backwardModifiers)
        
        let fwdMatch = flags.rawValue == fwdReq.rawValue && key == config.forwardKey
        let bwdMatch = flags.rawValue == bwdReq.rawValue && key == config.backwardKey
        
        if bwdMatch {
            if PermissionDialog.requestFocusIfOpen() { return pass() }
            shared.baseComboPressed = true
            WindowManager.shared.showSwitcherAndPrevious()
            return nil
        }
        if fwdMatch {
            if PermissionDialog.requestFocusIfOpen() { return pass() }
            shared.baseComboPressed = true
            WindowManager.shared.showSwitcherAndNext()
            return nil
        }
        
        if key == 53 && shared.baseComboPressed {
            WindowManager.shared.cancelSwitcher()
            return nil
        }
        return pass()
    }
}

/// Permission types supported by the permission dialog
enum PermissionType {
    case loginItems
    case accessibility
    case screenRecording
    
    var title: String {
        switch self {
        case .loginItems: return "Start Navi at Login?"
        case .accessibility: return "Accessibility Permission Required"
        case .screenRecording: return "Screen Recording Permission Required"
        }
    }
    var message: String {
        switch self {
        case .loginItems:
            return "Would you like Navi to start automatically when you log in?\n\nThis is recommended for the best experience."
        case .accessibility:
            return "Navi needs Accessibility permission to capture keyboard shortcuts and switch windows.\n\nPlease grant permission in System Settings > Privacy & Security > Accessibility."
        case .screenRecording:
            return "Navi needs Screen Recording permission to capture window thumbnails.\n\nPlease grant permission in System Settings > Privacy & Security > Screen Recording."
        }
    }
    var settingsURL: URL? {
        switch self {
        case .loginItems: return nil
        case .accessibility: return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        case .screenRecording: return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        }
    }
    var primaryButtonTitle: String { self == .loginItems ? "Yes, Enable" : "Open System Settings" }
    var secondaryButtonTitle: String { self == .loginItems ? "Not Now" : "Cancel" }
    var iconName: NSImage.Name { self == .loginItems ? NSImage.applicationIconName : NSImage.cautionName }
    var quitsOnDismiss: Bool { self == .accessibility }
    var closesOnPrimaryAction: Bool { self == .loginItems }
    @MainActor
    func isGranted() -> Bool {
        switch self {
        case .loginItems: return isLoginItemEnabled()
        case .accessibility: return isAccessibilityPermissionGranted()
        case .screenRecording: return isScreenRecordingPermissionGranted()
        }
    }
}

@MainActor
private func isAccessibilityPermissionGranted() -> Bool {
    if #available(macOS 10.9, *) {
        let options = [axTrustedPromptKey: false] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
    return AXIsProcessTrusted()
}

private func isLoginItemEnabled() -> Bool {
    if #available(macOS 13.0, *) {
        return SMAppService.mainApp.status == .enabled
    }
    return true
}

private func isScreenRecordingPermissionGranted() -> Bool {
    CGPreflightScreenCaptureAccess()
}

class PermissionDialog: NSObject, NSWindowDelegate {
    @MainActor private static var currentDialog: PermissionDialog?
    private static let openState = Locked(false)
    @MainActor private static func updateCurrentDialog(_ dialog: PermissionDialog?) {
        currentDialog = dialog
        openState.withValue { $0 = (dialog != nil) }
    }
    nonisolated static func requestFocusIfOpen() -> Bool {
        guard isOpen else { return false }
        Task { @MainActor in _ = focusIfOpen() }
        return true
    }
    
    private var window: NSWindow?
    private let permissionType: PermissionType
    private var onComplete: (() -> Void)?
    
    private init(_ type: PermissionType, onComplete: (() -> Void)? = nil) {
        self.permissionType = type
        self.onComplete = onComplete
        super.init()
    }
    
    /// Returns true if a permission dialog is currently displayed
    nonisolated static var isOpen: Bool { openState.get() }
    
    /// Focuses the current permission dialog if one is open. Returns true if focused.
    @discardableResult
    @MainActor
    static func focusIfOpen() -> Bool {
        guard let dialog = currentDialog, let window = dialog.window else { return false }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }
    
    /// Shows a permission dialog. If the permission is already granted, calls onComplete immediately.
    @MainActor
    static func show(_ type: PermissionType, onComplete: (() -> Void)? = nil) {
        if type.isGranted() {
            onComplete?()
            return
        }
        guard PermissionDialog.currentDialog == nil else { return }
        let dialog = PermissionDialog(type, onComplete: onComplete)
        PermissionDialog.updateCurrentDialog(dialog)
        dialog.showWindow()
    }
    
    @MainActor
    private func showWindow() {
        if window == nil { createWindow() }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    @MainActor
    private func createWindow() {
        let (w, h, margin, btnW, btnH) = (CGFloat(320), CGFloat(330), CGFloat(20), CGFloat(180), CGFloat(32))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: w, height: h), styleMask: [.titled], backing: .buffered, defer: false)
        window?.title = ""
        window?.center()
        window?.delegate = self
        window?.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        window?.contentView = content
        
        let iconView = NSImageView(frame: NSRect(x: (w - 64) / 2, y: h - margin - 64, width: 64, height: 64))
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.image = NSImage(named: permissionType.iconName)
        
        let titleLabel = NSTextField(labelWithString: permissionType.title)
        titleLabel.font = .systemFont(ofSize: 14, weight: .bold)
        titleLabel.alignment = .center
        titleLabel.frame = NSRect(x: 0, y: h - margin - 64 - 35, width: w, height: 20)

        let secondaryButton = NSButton(title: permissionType.secondaryButtonTitle, target: self, action: #selector(secondaryClicked))
        secondaryButton.frame = NSRect(x: (w - btnW) / 2, y: margin, width: btnW, height: btnH)
        secondaryButton.bezelStyle = .rounded

        let primaryButton = NSButton(title: permissionType.primaryButtonTitle, target: self, action: #selector(primaryClicked))
        primaryButton.frame = NSRect(x: (w - btnW) / 2, y: margin + btnH, width: btnW, height: btnH)
        primaryButton.bezelStyle = .rounded
        primaryButton.keyEquivalent = "\r"

        let infoLabel = NSTextField(wrappingLabelWithString: permissionType.message)
        infoLabel.font = .systemFont(ofSize: 13)
        infoLabel.alignment = .center
        infoLabel.frame = NSRect(x: margin, y: primaryButton.frame.maxY + 15, width: w - margin * 2, height: titleLabel.frame.minY - primaryButton.frame.maxY - 25)

        content.add(iconView, titleLabel, secondaryButton, primaryButton, infoLabel)
    }
    
    @MainActor
    @objc private func primaryClicked() {
        if permissionType == .loginItems {
            if #available(macOS 13.0, *) {
                do {
                    try SMAppService.mainApp.register()
                    if let delegate = NSApp.delegate as? AppDelegate {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak delegate] in
                            delegate?.handleLoginItemEnabled()
                        }
                    }
                } catch {
                    print("Failed to register login item: \(error)")
                }
            }
        } else if let url = permissionType.settingsURL {
            NSWorkspace.shared.open(url)
        }
        if permissionType.closesOnPrimaryAction {
            window?.close()
        }
    }
    
    @MainActor
    @objc private func secondaryClicked() {
        window?.close()
    }
    
    @MainActor
    func windowDidBecomeKey(_ notification: Notification) {
        if permissionType.isGranted() {
            window?.close()
        }
    }
    
    @MainActor
    func windowWillClose(_ notification: Notification) {
        window = nil
        PermissionDialog.updateCurrentDialog(nil)
        let granted = permissionType.isGranted()
        let completion = onComplete
        onComplete = nil
        PermissionDialog.currentDialog = nil
        
        // For login items, always call onComplete (it's optional)
        // For other permissions, only call onComplete if granted, otherwise quit if required
        let shouldComplete = permissionType == .loginItems || granted
        
        if shouldComplete {
            // Delay before showing next dialog
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                completion?()
            }
        } else if permissionType.quitsOnDismiss {
            NSApp.terminate(nil)
        }
    }
}

@MainActor
private func showLoginItemsPromptIfNeeded(onComplete: @escaping () -> Void) {
    PermissionDialog.show(.loginItems, onComplete: onComplete)
}

@MainActor
private func showAccessibilityAlertIfNeeded(onComplete: (() -> Void)? = nil) {
    PermissionDialog.show(.accessibility, onComplete: onComplete)
}

@MainActor
private func showScreenRecordingAlert() {
    PermissionDialog.show(.screenRecording)
}

@MainActor
class ShortcutSettingsWindowController: NSObject, NSWindowDelegate {
    nonisolated(unsafe) static var isOpen = false
    
    private var window: NSWindow?
    private var baseModifiersField: ShortcutCaptureField!
    private var baseMirrorField: NSTextField!
    private var forwardKeyField: ShortcutCaptureField!
    private var backwardKeyField: ShortcutCaptureField!
    private var warningLabel: NSTextField!
    private var onSave: (() -> Void)?
    
    func show(onSave: @escaping () -> Void) {
        self.onSave = onSave
        ShortcutSettingsWindowController.isOpen = true
        
        if window != nil {
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        
        createWindow()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    private func createWindow() {
        let (w, h, fieldW, fieldH, leftX, plusW, spacing) = (CGFloat(460), CGFloat(280), CGFloat(190), CGFloat(26), CGFloat(20), CGFloat(20), CGFloat(12))
        let rightX = leftX + fieldW + plusW + spacing * 2
        let plusX = leftX + fieldW + spacing
        
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: w, height: h), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window?.title = "Shortcut Settings"
        window?.center()
        window?.delegate = self
        window?.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        window?.contentView = content
        
        var y = h - 80
        let title = makeLabel("Configure Keyboard Shortcuts", size: 14, weight: .bold)
        title.frame = NSRect(x: 20, y: h - 40, width: w - 40, height: 20)
        content.addSubview(title)
        
        let baseL = makeLabel("Hold:")
        baseL.frame = NSRect(x: 20, y: y, width: 110, height: 18)
        let fwdL = makeLabel("Tap:")
        fwdL.frame = NSRect(x: rightX, y: y, width: 170, height: 18)
        content.add(baseL, fwdL)
        y -= 32
        
        baseModifiersField = ShortcutCaptureField(frame: NSRect(x: leftX, y: y, width: fieldW, height: fieldH))
        baseModifiersField.setKeyCombination(modifiers: currentShortcutConfig.baseModifiers, keyCode: currentShortcutConfig.baseKey)
        baseModifiersField.onUpdate = { [weak self] in
            self?.syncBaseMirrorField()
            self?.updateWarning()
        }
        baseModifiersField.onValidate = { [weak self] m, k in
            self?.isUniqueCombination(m, k, excluding: self?.baseModifiersField) ?? true
        }
        content.addSubview(baseModifiersField)
        
        content.addSubview(makePlusLabel(frame: NSRect(x: plusX, y: y, width: plusW, height: fieldH)))
        
        forwardKeyField = ShortcutCaptureField(frame: NSRect(x: rightX, y: y, width: fieldW, height: fieldH))
        forwardKeyField.setKeyCombination(modifiers: currentShortcutConfig.forwardModifiers, keyCode: currentShortcutConfig.forwardKey)
        forwardKeyField.onUpdate = { [weak self] in
            self?.updateWarning()
        }
        forwardKeyField.onValidate = { [weak self] m, k in
            self?.isUniqueCombination(m, k, excluding: self?.forwardKeyField) ?? true
        }
        content.addSubview(forwardKeyField)
        
        y -= (fieldH + 38)
        let bwdL = makeLabel("Tap (cycle backwards):")
        bwdL.frame = NSRect(x: rightX, y: y + fieldH + 6, width: 170, height: 18)
        content.addSubview(bwdL)
        
        baseMirrorField = makeDisplayField(frame: NSRect(x: leftX, y: y, width: fieldW, height: fieldH))
        content.addSubview(baseMirrorField)
        syncBaseMirrorField()
        
        content.addSubview(makePlusLabel(frame: NSRect(x: plusX, y: y, width: plusW, height: fieldH)))
        
        backwardKeyField = ShortcutCaptureField(frame: NSRect(x: rightX, y: y, width: fieldW, height: fieldH))
        backwardKeyField.setKeyCombination(modifiers: currentShortcutConfig.backwardModifiers, keyCode: currentShortcutConfig.backwardKey)
        backwardKeyField.onUpdate = { [weak self] in self?.updateWarning() }
        backwardKeyField.onValidate = { [weak self] m, k in self?.isUniqueCombination(m, k, excluding: self?.backwardKeyField) ?? true }
        content.addSubview(backwardKeyField)
        
        warningLabel = NSTextField(wrappingLabelWithString: "")
        warningLabel.frame = NSRect(x: 20, y: y - 60, width: w - 20, height: 36)
        warningLabel.textColor = .systemOrange
        warningLabel.font = .systemFont(ofSize: 11)
        content.addSubview(warningLabel)
        
        let btnY: CGFloat = 20
        let reset = NSButton(title: "Reset to Default", target: self, action: #selector(resetToDefault))
        reset.frame = NSRect(x: 20, y: btnY, width: 140, height: 32)
        reset.bezelStyle = .rounded
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.frame = NSRect(x: w - 190, y: btnY, width: 80, height: 32)
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: "Save", target: self, action: #selector(save))
        save.frame = NSRect(x: w - 100, y: btnY, width: 80, height: 32)
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"
        content.add(reset, cancel, save)
        
        updateWarning()
    }
    
    private func makePlusLabel(frame: NSRect) -> NSTextField {
        let label = NSTextField(labelWithString: "+")
        label.alignment = .center
        label.font = NSFont.systemFont(ofSize: 16)
        label.frame = frame
        return label
    }
    
    private func makeDisplayField(frame: NSRect) -> NSTextField {
        let field = NSTextField(frame: frame)
        field.isEditable = false
        field.isSelectable = false
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.backgroundColor = .textBackgroundColor
        field.alphaValue = 0.6
        field.alignment = .center
        field.isEnabled = false
        return field
    }
    
    private func syncBaseMirrorField() {
        baseMirrorField?.stringValue = baseModifiersField.displayValue
    }
    
    /// Check if a combination is unique across all fields (excluding the field being edited)
    private func isUniqueCombination(_ modifiers: CGEventFlags, _ keyCode: Int64, excluding: ShortcutCaptureField?) -> Bool {
        let fields: [ShortcutCaptureField] = [baseModifiersField, forwardKeyField, backwardKeyField]
        for field in fields {
            guard field !== excluding else { continue }
            if field.capturedModifiers.rawValue == modifiers.rawValue && field.capturedKeyCode == keyCode {
                return false
            }
        }
        return true
    }
    
    private func updateWarning() {
        let config = buildConfig()
        if config.conflictsWithSystemShortcuts {
            warningLabel.stringValue = "⚠️ Current hotkeys may occasionally conflict with macOS default shortcuts."
        } else {
            warningLabel.stringValue = ""
        }
    }
    
    private func buildConfig() -> ShortcutConfig {
        return ShortcutConfig(
            baseModifiers: baseModifiersField.capturedModifiers,
            baseKey: baseModifiersField.capturedKeyCode,
            forwardModifiers: forwardKeyField.capturedModifiers,
            forwardKey: forwardKeyField.capturedKeyCode,
            backwardModifiers: backwardKeyField.capturedModifiers,
            backwardKey: backwardKeyField.capturedKeyCode
        )
    }
    
    @objc private func resetToDefault() {
        baseModifiersField.setKeyCombination(modifiers: ShortcutConfig.default.baseModifiers, keyCode: ShortcutConfig.default.baseKey)
        syncBaseMirrorField()
        forwardKeyField.setKeyCombination(modifiers: ShortcutConfig.default.forwardModifiers, keyCode: ShortcutConfig.default.forwardKey)
        backwardKeyField.setKeyCombination(modifiers: ShortcutConfig.default.backwardModifiers, keyCode: ShortcutConfig.default.backwardKey)
        updateWarning()
    }
    
    @objc private func cancel() {
        window?.close()
    }
    
    @objc private func save() {
        guard baseModifiersField.capturedModifiers.rawValue != 0 || baseModifiersField.capturedKeyCode != 0 else {
            NSSound.beep()
            return
        }
        guard forwardKeyField.capturedKeyCode != 0 else {
            NSSound.beep()
            return
        }
        guard backwardKeyField.capturedKeyCode != 0 else {
            NSSound.beep()
            return
        }
        let config = buildConfig()
        currentShortcutConfig = config
        config.save()
        HotkeyManager.shared.updateShortcutConfig(config)
        onSave?()
        window?.close()
    }
    
    func windowWillClose(_ notification: Notification) {
        ShortcutSettingsWindowController.isOpen = false
        window = nil
    }
}

/// Custom text field that captures keyboard shortcuts
class ShortcutCaptureField: NSTextField {
    var capturedModifiers: CGEventFlags = []
    var capturedKeyCode: Int64 = 0
    var onUpdate: (() -> Void)?
    /// Validation callback: returns true if the new combination is allowed, false to revert
    var onValidate: ((CGEventFlags, Int64) -> Bool)?
    var displayValue: String { currentDisplayText }
    
    private static weak var activeField: ShortcutCaptureField?
    private var isCapturing = false
    private var localMonitor: Any?
    private var pendingModifiers: CGEventFlags?
    private var pendingMaxModifiers: CGEventFlags?
    private var originalModifiers: CGEventFlags = []
    private var originalKeyCode: Int64 = 0
    private var currentDisplayText: String = "Click to set"
    
    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }
    
    private func setup() {
        isEditable = false
        isSelectable = false
        isBezeled = true
        bezelStyle = .roundedBezel
        alignment = .center
        font = NSFont.systemFont(ofSize: 12)
        stringValue = currentDisplayText
    }
    
    func setKeyCombination(modifiers: CGEventFlags, keyCode: Int64) {
        capturedModifiers = modifiers
        capturedKeyCode = keyCode
        updateDisplay()
    }
    
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        window?.makeFirstResponder(self)
        beginCapturing()
    }
    
    private func beginCapturing() {
        if let active = ShortcutCaptureField.activeField, active !== self {
            active.cancelCaptureAndRestore()
        }
        ShortcutCaptureField.activeField = self
        originalModifiers = capturedModifiers
        originalKeyCode = capturedKeyCode
        pendingModifiers = nil
        pendingMaxModifiers = nil
        isCapturing = true
        stringValue = "Press keys..."
        backgroundColor = NSColor.selectedTextBackgroundColor
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            self?.handleCaptureEvent(event)
            return nil
        }
    }
    
    private func cancelCaptureAndRestore() {
        stopCapturing(commit: false)
    }
    
    private func stopCapturing(commit: Bool) {
        guard isCapturing else { return }
        isCapturing = false
        backgroundColor = NSColor.textBackgroundColor
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
        pendingModifiers = nil
        pendingMaxModifiers = nil
        if !commit {
            capturedModifiers = originalModifiers
            capturedKeyCode = originalKeyCode
        } else if let validate = onValidate, !validate(capturedModifiers, capturedKeyCode) {
            capturedModifiers = originalModifiers
            capturedKeyCode = originalKeyCode
            NSSound.beep()
        }
        ShortcutCaptureField.activeField = nil
        updateDisplay()
    }
    
    private func updateDisplay(showing modifiers: CGEventFlags? = nil, key: Int64? = nil, includeKey: Bool? = nil) {
        let modifiersToShow = modifiers ?? capturedModifiers
        var parts = modifierNames(from: modifiersToShow)
        let shouldShowKey: Bool
        if let includeKey = includeKey {
            shouldShowKey = includeKey
        } else {
            shouldShowKey = true
        }
        if shouldShowKey {
            let keyCode = key ?? capturedKeyCode
            if keyCode != 0 {
                parts.append(keyCodeToString(keyCode))
            }
        }
        currentDisplayText = parts.isEmpty ? "Click to set" : parts.joined(separator: "+")
        stringValue = currentDisplayText
    }
    
    private func handleCaptureEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            let keyCode = event.keyCode
            if keyCode == 53 || keyCode == 36 || keyCode == 76 {
                NSSound.beep()
                return
            }
        }
        
        if event.type == .flagsChanged {
            let mods = cgFlags(from: event.modifierFlags)
            pendingModifiers = mods
            if !mods.isEmpty {
                if pendingMaxModifiers == nil || modifierBitCount(mods) >= modifierBitCount(pendingMaxModifiers!) {
                    pendingMaxModifiers = mods
                }
                updateDisplay(showing: mods, includeKey: false)
            } else if let pending = pendingMaxModifiers {
                capturedModifiers = pending
                capturedKeyCode = 0
                pendingModifiers = nil
                pendingMaxModifiers = nil
                stopCapturing(commit: true)
                onUpdate?()
            } else {
                updateDisplay()
            }
            return
        }
        if event.type == .keyDown {
            capturedModifiers = cgFlags(from: event.modifierFlags)
            capturedKeyCode = Int64(event.keyCode)
            pendingModifiers = nil
            pendingMaxModifiers = nil
            stopCapturing(commit: true)
            onUpdate?()
        }
    }
    
    override func resignFirstResponder() -> Bool {
        if isCapturing {
            stopCapturing(commit: false)
        }
        return super.resignFirstResponder()
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var shortcutSettingsController: ShortcutSettingsWindowController?
    private var shortcutMenuItem: NSMenuItem?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        if currentViewMode == .thumbnails && !isScreenRecordingPermissionGranted() {
            currentViewMode = .grid
            UserDefaults.standard.set(ViewMode.grid.rawValue, forKey: "viewMode")
        }
        
        HotkeyManager.shared.updateShortcutConfig(currentShortcutConfig)

        setupStatusBar()
        
        // Show login items prompt first (if not already enabled), then start hotkey manager
        // The hotkey manager will show accessibility prompt if needed
        showLoginItemsPromptIfNeeded {
            HotkeyManager.shared.start()
        }
    }
    
    func applicationWillTerminate(_ notification: Notification) { HotkeyManager.shared.stop() }
    
    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            if let url = Bundle.main.url(forResource: "icon", withExtension: "png"), let img = NSImage(contentsOf: url) {
                img.isTemplate = false
                img.size = NSSize(width: 18, height: 18)
                button.image = img
            } else { button.title = "⇌" }
        }
        
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Navi", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        shortcutMenuItem = NSMenuItem(title: currentShortcutConfig.menuTitle, action: #selector(openShortcutSettings), keyEquivalent: "")
        menu.addItem(shortcutMenuItem!)
        menu.addItem(.separator())
        
        [("Icons", ViewMode.grid), ("Thumbnails", .thumbnails), ("List", .list)].forEach { title, mode in
            let item = NSMenuItem(title: title, action: #selector(changeViewMode(_:)), keyEquivalent: "")
            item.representedObject = mode
            item.state = currentViewMode == mode ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        [("All Screens", ScreenMode.allScreens), ("Active Screen", .activeScreen), ("Mouse Position", .mouseScreen)].forEach { title, mode in
            let item = NSMenuItem(title: title, action: #selector(changeScreenMode(_:)), keyEquivalent: "")
            item.representedObject = mode
            item.state = currentScreenMode == mode ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        if #available(macOS 13.0, *) {
            if !isLoginItemEnabled() {
                menu.addItem(NSMenuItem(title: "⚠️ Enable Start at Login", action: #selector(enableLoginItem), keyEquivalent: ""))
                menu.addItem(.separator())
            }
        }
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        menu.delegate = self
        statusItem?.menu = menu
    }
    
    func menuWillOpen(_ menu: NSMenu) {
        if PermissionDialog.requestFocusIfOpen() {
            menu.cancelTracking()
            return
        }
        guard !isAccessibilityPermissionGranted() else { return }
        menu.cancelTracking()
        showAccessibilityAlertIfNeeded(onComplete: { HotkeyManager.shared.start() })
    }
    
    @objc private func changeViewMode(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? ViewMode else { return }
        if mode == .thumbnails && !isScreenRecordingPermissionGranted() {
            showScreenRecordingAlert()
            return
        }
        currentViewMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "viewMode")
        statusItem?.menu?.items.forEach { if let m = $0.representedObject as? ViewMode { $0.state = m == mode ? .on : .off } }
        SwitcherWindowController.shared.refreshViewMode()
    }
    
    @objc private func changeScreenMode(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? ScreenMode else { return }
        currentScreenMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "screenMode")
        statusItem?.menu?.items.forEach { if let m = $0.representedObject as? ScreenMode { $0.state = m == mode ? .on : .off } }
    }
    
    @objc private func openShortcutSettings() {
        if shortcutSettingsController == nil { shortcutSettingsController = ShortcutSettingsWindowController() }
        shortcutSettingsController?.show { [weak self] in self?.shortcutMenuItem?.title = currentShortcutConfig.menuTitle }
    }
    
    @available(macOS 13.0, *)
    @objc private func enableLoginItem() {
        do {
            try SMAppService.mainApp.register()
            handleLoginItemEnabled()
        } catch {
            print("Failed to register login item: \(error)")
        }
    }

    func handleLoginItemEnabled() {
        guard let menu = statusItem?.menu,
              let item = menu.items.first(where: { $0.title == "⚠️ Enable Start at Login" }),
              let index = menu.items.firstIndex(of: item) else { return }
        menu.removeItem(item)
        if index < menu.items.count && menu.items[index].isSeparatorItem {
            menu.removeItem(at: index)
        }
    }
    
    @objc private func quit() {
        HotkeyManager.shared.stop()
        NSApp.terminate(nil)
    }
}

if NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == Bundle.main.bundleIdentifier && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) { exit(0) }

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()