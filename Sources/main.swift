import Cocoa
import Carbon

private let kAXWindowNumberAttribute = "AXWindowNumber"

// MARK: - Configuration Constants
/// Centralized configuration for easy tuning
private enum Config {
    static let gridColumns = 5
    // Number of grid rows for icons-mode (larger app icon grid)
    static let gridMaxRows = 4
    // Max rows to show when in thumbnails mode (we want at most 3 rows)
    static let thumbnailMaxRows = 3
    static let listMaxItems = 16
    static let itemPadding: CGFloat = 8
    static let itemSpacing: CGFloat = 8
    static let gridItemSize = NSSize(width: 200, height: 160)
    static let gridIconSize: CGFloat = 120
    static let thumbGridIconSize: CGFloat = 210
    static let listItemSize = NSSize(width: 600, height: 32)
    static let autoHideDelay: TimeInterval = 2.0
}

// MARK: - View Mode
/// Display modes for the window switcher UI
/// Persisted to UserDefaults with raw string values
enum ViewMode: String {
    case grid       // Large app icons in a grid layout
    case thumbnails // Live window screenshots with small app icons
    case list       // Compact vertical list with app name
}

/// Global view mode state, loaded from UserDefaults on launch
var currentViewMode: ViewMode = {
    if let saved = UserDefaults.standard.string(forKey: "viewMode"),
       let mode = ViewMode(rawValue: saved) {
        return mode
    }
    return .grid
}()

// MARK: - Screen Mode
/// Which screen(s) to display the switcher UI on
/// Persisted to UserDefaults with raw string values
enum ScreenMode: String {
    case allScreens    // Show on all connected displays (default)
    case activeScreen  // Show only on the screen with the focused window
    case mouseScreen   // Show only on the screen where the mouse cursor is
}

/// Global screen mode state, loaded from UserDefaults on launch
var currentScreenMode: ScreenMode = {
    if let saved = UserDefaults.standard.string(forKey: "screenMode"),
       let mode = ScreenMode(rawValue: saved) {
        return mode
    }
    return .allScreens
}()

// MARK: - Shortcut Configuration
/// Stores custom keyboard shortcut settings
struct ShortcutConfig {
    var baseModifiers: CGEventFlags
    var baseKey: Int64  // 0 means no base key required, only modifiers
    var forwardModifiers: CGEventFlags
    var forwardKey: Int64
    var backwardModifiers: CGEventFlags
    var backwardKey: Int64
    
    static let `default` = ShortcutConfig(
        baseModifiers: [.maskCommand],
        baseKey: 0,  // No base key, just Cmd
        forwardModifiers: [],
        forwardKey: 48, // Tab
        backwardModifiers: [.maskShift],
        backwardKey: 48 // Shift + Tab
    )
    
    /// Human-readable string for base combination
    var baseString: String {
        var parts = modifierNames(from: baseModifiers)
        if baseKey != 0 {
            parts.append(keyCodeToString(baseKey))
        }
        return parts.isEmpty ? "None" : parts.joined(separator: "+")
    }
    
    /// Human-readable string for forward shortcut
    var forwardShortcutString: String {
        combinedShortcutString(extraModifiers: forwardModifiers, key: forwardKey)
    }
    
    /// Human-readable string for backward shortcut
    var backwardShortcutString: String {
        combinedShortcutString(extraModifiers: backwardModifiers, key: backwardKey)
    }
    
    /// Check if shortcuts might conflict with macOS defaults (Cmd+Tab, Cmd+Shift+Tab)
    var conflictsWithSystemShortcuts: Bool {
        let forwardCombo = baseModifiers.union(forwardModifiers)
        let backwardCombo = baseModifiers.union(backwardModifiers)
        let cmdOnly = CGEventFlags.maskCommand
        let cmdShift = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue)
        let usesTab = forwardKey == 48 || backwardKey == 48
        if !usesTab { return false }
        if forwardCombo == cmdOnly && forwardKey == 48 { return true }
        if forwardCombo == cmdShift && forwardKey == 48 { return true }
        if backwardCombo == cmdShift && backwardKey == 48 { return true }
        if backwardCombo == cmdOnly && backwardKey == 48 { return true }
        return false
    }
    
    func save() {
        let defaults = UserDefaults.standard
        defaults.set(baseModifiers.rawValue, forKey: "shortcut_baseModifiers")
        defaults.set(baseKey, forKey: "shortcut_baseKey")
        defaults.set(forwardModifiers.rawValue, forKey: "shortcut_forwardModifiers")
        defaults.set(forwardKey, forKey: "shortcut_forwardKey")
        defaults.set(backwardModifiers.rawValue, forKey: "shortcut_backwardModifiers")
        defaults.set(backwardKey, forKey: "shortcut_backwardKey")
        defaults.removeObject(forKey: "shortcut_backwardRequiresShift")
    }
    
    static func load() -> ShortcutConfig {
        let defaults = UserDefaults.standard
        let baseRaw = defaults.object(forKey: "shortcut_baseModifiers") as? UInt64
        let baseKeyRaw = defaults.object(forKey: "shortcut_baseKey") as? Int64
        let forwardModsRaw = defaults.object(forKey: "shortcut_forwardModifiers") as? UInt64
        let forwardKeyRaw = defaults.object(forKey: "shortcut_forwardKey") as? Int64
        let backwardModsRaw = defaults.object(forKey: "shortcut_backwardModifiers") as? UInt64
        let backwardKeyRaw = defaults.object(forKey: "shortcut_backwardKey") as? Int64
        
        guard let baseRaw = baseRaw,
              let storedForward = forwardKeyRaw,
              let storedBackward = backwardKeyRaw else {
            return .default
        }
        let resolvedForwardKey = storedForward == 0 ? ShortcutConfig.default.forwardKey : storedForward
        let resolvedBackwardKey = storedBackward == 0 ? ShortcutConfig.default.backwardKey : storedBackward
        
        let forwardModifiers = CGEventFlags(rawValue: forwardModsRaw ?? 0)
        let backwardModifiers: CGEventFlags
        if let backwardModsRaw = backwardModsRaw {
            backwardModifiers = CGEventFlags(rawValue: backwardModsRaw)
        } else if let legacyShift = defaults.object(forKey: "shortcut_backwardRequiresShift") as? Bool {
            backwardModifiers = legacyShift ? .maskShift : []
        } else {
            backwardModifiers = []
        }
        
        var baseModifiers = CGEventFlags(rawValue: baseRaw)
        if baseModifiers.rawValue == 0 {
            baseModifiers = ShortcutConfig.default.baseModifiers
        }
        
        return ShortcutConfig(
            baseModifiers: baseModifiers,
            baseKey: baseKeyRaw ?? 0,
            forwardModifiers: forwardModifiers,
            forwardKey: resolvedForwardKey,
            backwardModifiers: backwardModifiers,
            backwardKey: resolvedBackwardKey
        )
    }
    
    private func combinedShortcutString(extraModifiers: CGEventFlags, key: Int64) -> String {
        let modifiers = baseModifiers.union(extraModifiers)
        let modifierText = modifierNames(from: modifiers)
        let keyText = keyCodeToString(key)
        if modifierText.isEmpty { return keyText }
        return (modifierText + [keyText]).joined(separator: "+")
    }
}

private let relevantModifierMask: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]

func modifierNames(from flags: CGEventFlags) -> [String] {
    var names: [String] = []
    if flags.contains(.maskCommand) { names.append("Cmd") }
    if flags.contains(.maskControl) { names.append("Ctrl") }
    if flags.contains(.maskAlternate) { names.append("Opt") }
    if flags.contains(.maskShift) { names.append("Shift") }
    return names
}

func cgFlags(from modifierFlags: NSEvent.ModifierFlags) -> CGEventFlags {
    var flags: CGEventFlags = []
    if modifierFlags.contains(.command) { flags.insert(.maskCommand) }
    if modifierFlags.contains(.control) { flags.insert(.maskControl) }
    if modifierFlags.contains(.option) { flags.insert(.maskAlternate) }
    if modifierFlags.contains(.shift) { flags.insert(.maskShift) }
    return flags
}

func modifierBitCount(_ flags: CGEventFlags) -> Int {
    var count = 0
    if flags.contains(.maskCommand) { count += 1 }
    if flags.contains(.maskControl) { count += 1 }
    if flags.contains(.maskAlternate) { count += 1 }
    if flags.contains(.maskShift) { count += 1 }
    return count
}

extension CGEventFlags {
    func union(_ other: CGEventFlags) -> CGEventFlags {
        CGEventFlags(rawValue: rawValue | other.rawValue)
    }
}

func flagsContain(_ flags: CGEventFlags, _ required: CGEventFlags) -> Bool {
    if required.rawValue == 0 { return true }
    return (flags.rawValue & required.rawValue) == required.rawValue
}

/// Convert key code to human-readable string
func keyCodeToString(_ keyCode: Int64) -> String {
    let keyNames: [Int64: String] = [
        48: "Tab", 49: "Space", 51: "Delete",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7",
        27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
        37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N",
        46: "M", 47: ".", 50: "`",
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11",
        105: "F13", 107: "F14", 109: "F10", 111: "F12", 113: "F15", 118: "F4",
        120: "F2", 122: "F1"
    ]
    return keyNames[keyCode] ?? "Key\(keyCode)"
}

/// Global shortcut configuration, loaded from UserDefaults on launch
var currentShortcutConfig = ShortcutConfig.load()

// MARK: - Accessibility Helpers
/// Consolidated helpers for AXUIElement operations to reduce code duplication
private enum AXHelper {
    static func getValue<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else {
            return nil
        }
        return ref as? T
    }
    
    static func getBool(_ element: AXUIElement, _ attribute: String) -> Bool {
        getValue(element, attribute) ?? false
    }
    
    static func getString(_ element: AXUIElement, _ attribute: String) -> String? {
        getValue(element, attribute)
    }
    
    static func getPoint(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
              let value = ref else { return nil }
        var point = CGPoint.zero
        AXValueGetValue(value as! AXValue, .cgPoint, &point)
        return point
    }
    
    static func getSize(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
              let value = ref else { return nil }
        var size = CGSize.zero
        AXValueGetValue(value as! AXValue, .cgSize, &size)
        return size
    }

    static func getInt(_ element: AXUIElement, _ attribute: String) -> Int? {
        guard let number: NSNumber = getValue(element, attribute) else { return nil }
        return number.intValue
    }
    
    static func setValue(_ element: AXUIElement, _ attribute: String, _ value: CFTypeRef) {
        AXUIElementSetAttributeValue(element, attribute as CFString, value)
    }
    
    static func performAction(_ element: AXUIElement, _ action: String) {
        AXUIElementPerformAction(element, action as CFString)
    }
}

// MARK: - Window Info
/// Represents a single window with lazy-cached properties for performance.
/// Properties are computed once on first access since window enumeration
/// happens frequently but not all properties are always needed.
class WindowInfo {
    let ownerPID: pid_t
    let ownerName: String
    let windowName: String
    let axWindow: AXUIElement
    
    /// CGWindowID used for thumbnail capture via CGWindowListCreateImage.
    /// Set during window enumeration by matching against CGWindowList data.
    var windowID: CGWindowID = 0
    
    // Lazy-cached properties to avoid repeated AX calls
    private var _app: NSRunningApplication?
    private var _appIcon: NSImage?
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
    
    var appIcon: NSImage? {
        if _appIcon == nil { _appIcon = app?.icon }
        return _appIcon
    }
    
    /// Capture a thumbnail of this window using CGWindowListCreateImage.
    /// This is expensive - results should be cached. Returns nil if windowID is invalid.
    /// Note: Requires Screen Recording permission for non-owned windows.
    var thumbnail: NSImage? {
        guard windowID != 0,
              let cgImage = CGWindowListCreateImage(
                  .null, .optionIncludingWindow, windowID,
                  [.boundsIgnoreFraming, .nominalResolution]
              ) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
    
    /// Display title: prefer window title, fallback to app name
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
    
    /// Raise this window to front, un-minimizing if needed
    func raise() {
        // Un-minimize if needed (must check fresh, not cached)
        if AXHelper.getBool(axWindow, kAXMinimizedAttribute) {
            AXHelper.setValue(axWindow, kAXMinimizedAttribute, false as CFTypeRef)
        }
        app?.activate(options: [.activateIgnoringOtherApps])
        AXHelper.performAction(axWindow, kAXRaiseAction)
    }
}

// MARK: - Selectable Item Protocol
/// Protocol for item views that can be selected/hovered in the switcher.
/// Reduces code duplication between WindowItemView and ListItemView.
protocol SelectableItemView: NSView {
    var isSelected: Bool { get set }
    var isActive: Bool { get set }
    var onClick: (() -> Void)? { get set }
    var onHover: (() -> Void)? { get set }
}

// MARK: - Floating Title View
/// A floating overlay that shows the full title of a selected item when truncated
class FloatingTitleView: NSView {
    private let visualEffect: NSVisualEffectView
    private let titleLabel: NSTextField
    private let horizontalPadding: CGFloat = 8
    private let verticalPadding: CGFloat = 4
    
    override init(frame: NSRect) {
        visualEffect = NSVisualEffectView()
        titleLabel = NSTextField(labelWithString: "")
        super.init(frame: frame)
        setupViews()
    }
    
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    
    private func setupViews() {
        wantsLayer = true
        
        // Blurred background using hudWindow material
        visualEffect.material = .hudWindow
        visualEffect.appearance = NSAppearance(named: .darkAqua)
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        // Add darkening and border on top of the blur
        visualEffect.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.15).cgColor
        visualEffect.layer?.borderWidth = 1
        visualEffect.layer?.borderColor = NSColor.white.withAlphaComponent(0.5).cgColor
        visualEffect.layer?.shadowColor = NSColor.black.cgColor
        visualEffect.layer?.shadowOpacity = 0.25
        visualEffect.layer?.shadowRadius = 6
        visualEffect.layer?.shadowOffset = CGSize(width: 0, height: -1)
        visualEffect.layer?.masksToBounds = true
        visualEffect.translatesAutoresizingMaskIntoConstraints = false
        addSubview(visualEffect)
        
        // Title label
        titleLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 2
        titleLabel.alignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)
        titleLabel.backgroundColor = .clear
        titleLabel.drawsBackground = false
        
        NSLayoutConstraint.activate([
            visualEffect.leadingAnchor.constraint(equalTo: leadingAnchor),
            visualEffect.trailingAnchor.constraint(equalTo: trailingAnchor),
            visualEffect.topAnchor.constraint(equalTo: topAnchor),
            visualEffect.bottomAnchor.constraint(equalTo: bottomAnchor),
            
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: horizontalPadding),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -horizontalPadding),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: verticalPadding),
            titleLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -verticalPadding),
        ])
    }

    override func layout() {
        super.layout()
        // Make the corner radius large enough to create a pill shape
        let radius = max(10, bounds.height / 2)
        visualEffect.layer?.cornerRadius = radius
        // Keep border/shadow aligned with the new radius
    }
    
    func configure(with title: String) {
        titleLabel.stringValue = title
    }
    
    /// Calculate ideal size for the given max width
    func idealSize(maxWidth: CGFloat) -> NSSize {
        let maxLabelWidth = maxWidth - horizontalPadding * 2
        let labelSize = titleLabel.sizeThatFits(NSSize(width: maxLabelWidth, height: CGFloat.greatestFiniteMagnitude))
        return NSSize(
            width: min(labelSize.width + horizontalPadding * 2, maxWidth),
            height: labelSize.height + verticalPadding * 2
        )
    }
}

// MARK: - Base Item View
/// Base class providing common selection/hover tracking functionality
class BaseItemView: NSView, SelectableItemView {
    var isSelected: Bool = false { didSet { needsDisplay = true } }
    var isActive: Bool = false { didSet { needsDisplay = true } }
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
    
    /// Override to provide selection styling
    func applySelectionStyle() {
        // Subclasses implement specific styling
    }
}

// MARK: - Window Item View (Icons/Thumbnails Mode)
/// Displays a window as a grid item with icon/thumbnail and title.
/// In thumbnails mode, loads screenshots asynchronously.
class WindowItemView: BaseItemView {
    // MARK: UI Components
    private let iconImageView = NSImageView()
    private let thumbnailContainer = NSView()  // Background behind thumbnail
    private let titleLabel = NSTextField(labelWithString: "")
    private let appNameLabel = NSTextField(labelWithString: "")  // App name above thumbnail
    private let appNameContainerView = NSView()  // Container for icon + app name at top
    private let smallAppIconView = NSImageView()
    private let floatingAppIconView = NSImageView()  // Floating app icon at bottom-right of thumbnail
    private let titleContainerView = NSView()
    private let minimizedLabel = NSTextField(labelWithString: "Minimized")  // Shown when minimized in thumbnails mode
    private let minimizedBadge: NSView
    private let fullscreenBadge: NSView
    
    private var windowInfo: WindowInfo?
    private var currentWindowID: CGWindowID = 0
    
    // Dynamic constraints for icon size and position
    private var iconSizeConstraints: [NSLayoutConstraint] = []
    private var iconCenterYConstraint: NSLayoutConstraint?  // Used for both grid and thumbnails mode
    private var floatingIconConstraints: [NSLayoutConstraint] = []
    
    static let itemSize = Config.gridItemSize
    static let iconSize = Config.gridIconSize
    
    // MARK: Public properties for floating title
    
    /// The current title text
    var titleText: String { titleLabel.stringValue }
    
    /// Frame of the title label in item's coordinate system
    var titleLabelFrame: NSRect { titleContainerView.frame }
    
    /// Whether the title is truncated
    var isTitleTruncated: Bool {
        // Calculate the max available width for the title (item width minus padding)
        let maxLabelWidth = bounds.width - 16  // 8px padding on each side
        guard maxLabelWidth > 0 else { return false }
        let labelSize = titleLabel.sizeThatFits(NSSize(width: CGFloat.greatestFiniteMagnitude, height: titleLabel.bounds.height))
        return labelSize.width > maxLabelWidth + 1  // +1 for rounding tolerance
    }
    
    /// Set the visibility of the title label (used when floating title is shown)
    func setTitleHidden(_ hidden: Bool) {
        titleLabel.isHidden = hidden
    }
    
    /// Thumbnail icon size based on visible window count
    static func thumbnailIconSize(forVisibleCount count: Int) -> CGFloat {
        if count <= 3 {
            return round(Config.thumbGridIconSize * 1.79)
        } else if count == 4 {
            return round(Config.thumbGridIconSize * 1.35)
        } else {
            return Config.thumbGridIconSize  // 190
        }
    }
    
    /// Item size based on visible window count (for thumbnails mode)
    static func thumbnailItemSize(forVisibleCount count: Int) -> NSSize {
        let iconSize = thumbnailIconSize(forVisibleCount: count)
        // Add padding for thumbnail + title area
        return NSSize(width: iconSize + 20, height: round(iconSize * 0.8) + 40)
    }
    
    override init(frame: NSRect) {
        minimizedBadge = Self.createBadge(color: .systemOrange, symbol: "—", fontSize: 14, yOffset: -1)
        fullscreenBadge = Self.createBadge(color: .systemGreen, symbol: "⛶", fontSize: 12, yOffset: 0)
        super.init(frame: frame)
        setupViews()
    }
    
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    
    /// Creates a circular badge with centered symbol (for minimized/fullscreen indicators)
    private static func createBadge(color: NSColor, symbol: String, fontSize: CGFloat, yOffset: CGFloat) -> NSView {
        let badge = NSView()
        badge.wantsLayer = true
        badge.layer?.backgroundColor = color.cgColor
        badge.layer?.cornerRadius = 10
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.isHidden = true
        
        let label = NSTextField(labelWithString: symbol)
        label.font = NSFont.systemFont(ofSize: fontSize, weight: .bold)
        label.textColor = .white
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(label)
        
        NSLayoutConstraint.activate([
            badge.widthAnchor.constraint(equalToConstant: 20),
            badge.heightAnchor.constraint(equalToConstant: 20),
            label.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: badge.centerYAnchor, constant: yOffset)
        ])
        return badge
    }
    
    private func setupViews() {
        wantsLayer = true
        layer?.cornerRadius = 12
        
        // App name container (holds icon + app name at top in thumbnails mode)
        appNameContainerView.translatesAutoresizingMaskIntoConstraints = false
        appNameContainerView.isHidden = true
        addSubview(appNameContainerView)
        
        // Small app icon shown in thumbnails mode (in top container next to app name)
        smallAppIconView.imageScaling = .scaleProportionallyUpOrDown
        smallAppIconView.translatesAutoresizingMaskIntoConstraints = false
        appNameContainerView.addSubview(smallAppIconView)
        
        // App name label (shown above thumbnail in thumbnails mode) - gray color
        appNameLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        appNameLabel.textColor = .secondaryLabelColor
        appNameLabel.lineBreakMode = .byTruncatingTail
        appNameLabel.translatesAutoresizingMaskIntoConstraints = false
        appNameContainerView.addSubview(appNameLabel)
        
        // Thumbnail container provides a subtle background behind the thumbnail image
        thumbnailContainer.wantsLayer = true
        thumbnailContainer.layer?.cornerRadius = 4
        thumbnailContainer.translatesAutoresizingMaskIntoConstraints = false
        thumbnailContainer.isHidden = true
        addSubview(thumbnailContainer)
        
        // Main icon/thumbnail image
        iconImageView.imageScaling = .scaleProportionallyUpOrDown
        iconImageView.imageAlignment = .alignCenter
        iconImageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconImageView)
        
        // Title container holds title label at bottom
        titleContainerView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleContainerView)
        
        // Title label with truncation
        titleLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 2
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleContainerView.addSubview(titleLabel)
        
        // Minimized label (shown in center when window is minimized in thumbnails mode)
        let italicBoldFont = NSFontManager.shared.font(
            withFamily: NSFont.systemFont(ofSize: 14).familyName ?? "Helvetica",
            traits: [.boldFontMask, .italicFontMask],
            weight: 0,
            size: 14
        ) ?? NSFont.boldSystemFont(ofSize: 14)
        minimizedLabel.font = italicBoldFont
        minimizedLabel.textColor = .secondaryLabelColor
        minimizedLabel.alignment = .center
        minimizedLabel.translatesAutoresizingMaskIntoConstraints = false
        minimizedLabel.isHidden = true
        addSubview(minimizedLabel)
        
        // Floating app icon for thumbnails mode (at bottom-right of thumbnail)
        floatingAppIconView.imageScaling = .scaleProportionallyUpOrDown
        floatingAppIconView.translatesAutoresizingMaskIntoConstraints = false
        floatingAppIconView.isHidden = true
        floatingAppIconView.wantsLayer = true
        floatingAppIconView.layer?.shadowColor = NSColor.black.cgColor
        floatingAppIconView.layer?.shadowOpacity = 0.5
        floatingAppIconView.layer?.shadowOffset = CGSize(width: 0, height: -2)
        floatingAppIconView.layer?.shadowRadius = 4
        addSubview(floatingAppIconView)
        
        // Add badges
        addSubview(minimizedBadge)
        addSubview(fullscreenBadge)
        
        setupConstraints()
    }
    
    private func setupConstraints() {
        // Store icon size constraints for dynamic updates
        let iconWidth = iconImageView.widthAnchor.constraint(equalToConstant: Self.iconSize)
        let iconHeight = iconImageView.heightAnchor.constraint(equalToConstant: Self.iconSize)
        iconSizeConstraints = [iconWidth, iconHeight]
        
        // Create dynamic vertical position constraint for icon
        // Centered vertically with offset to account for title at bottom
        iconCenterYConstraint = iconImageView.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -10)
        iconCenterYConstraint?.isActive = true
        
        NSLayoutConstraint.activate([
            // App name container at top (for thumbnails mode)
            appNameContainerView.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            appNameContainerView.centerXAnchor.constraint(equalTo: centerXAnchor),
            appNameContainerView.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 8),
            appNameContainerView.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            
            // Small app icon in top container
            smallAppIconView.leadingAnchor.constraint(equalTo: appNameContainerView.leadingAnchor),
            smallAppIconView.centerYAnchor.constraint(equalTo: appNameContainerView.centerYAnchor),
            smallAppIconView.widthAnchor.constraint(equalToConstant: 16),
            smallAppIconView.heightAnchor.constraint(equalToConstant: 16),
            
            // App name label next to icon
            appNameLabel.leadingAnchor.constraint(equalTo: smallAppIconView.trailingAnchor, constant: 4),
            appNameLabel.trailingAnchor.constraint(equalTo: appNameContainerView.trailingAnchor),
            appNameLabel.topAnchor.constraint(equalTo: appNameContainerView.topAnchor),
            appNameLabel.bottomAnchor.constraint(equalTo: appNameContainerView.bottomAnchor),
            
            // Main icon centered horizontally (vertical constraint is dynamic)
            iconImageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconImageView.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 8),
            iconImageView.bottomAnchor.constraint(lessThanOrEqualTo: titleContainerView.topAnchor, constant: -4),
            iconWidth,
            iconHeight,
            
            // Title at bottom with consistent 4px margin
            titleContainerView.centerXAnchor.constraint(equalTo: centerXAnchor),
            titleContainerView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            titleContainerView.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 8),
            titleContainerView.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            
            // Title label (no icon in bottom title anymore)
            titleLabel.leadingAnchor.constraint(equalTo: titleContainerView.leadingAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: titleContainerView.trailingAnchor),
            titleLabel.topAnchor.constraint(equalTo: titleContainerView.topAnchor),
            titleLabel.bottomAnchor.constraint(equalTo: titleContainerView.bottomAnchor),
            
            // Minimized label centered in icon area
            minimizedLabel.centerXAnchor.constraint(equalTo: iconImageView.centerXAnchor),
            minimizedLabel.centerYAnchor.constraint(equalTo: iconImageView.centerYAnchor),
            
            // Badges at top-right of icon (mutually exclusive - window can't be both)
            minimizedBadge.trailingAnchor.constraint(equalTo: iconImageView.trailingAnchor, constant: 4),
            minimizedBadge.topAnchor.constraint(equalTo: iconImageView.topAnchor, constant: -4),
            fullscreenBadge.trailingAnchor.constraint(equalTo: iconImageView.trailingAnchor, constant: 4),
            fullscreenBadge.topAnchor.constraint(equalTo: iconImageView.topAnchor, constant: -4),
        ])
        
        // Floating app icon constraints (positioned at bottom-right of item)
        // Size will be updated dynamically in configureThumbnailsMode
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
        
        if viewMode == .thumbnails {
            configureThumbnailsMode(windowInfo, visibleCount: visibleCount)
            // In thumbnails mode: show minimized label instead of badge, hide minimized badge
            minimizedLabel.isHidden = !windowInfo.isMinimized
            minimizedBadge.isHidden = true
        } else {
            configureGridMode(windowInfo)
            minimizedLabel.isHidden = true
            minimizedBadge.isHidden = !windowInfo.isMinimized
        }

        fullscreenBadge.isHidden = !windowInfo.isFullScreen
        titleLabel.stringValue = windowInfo.displayTitle
    }
    
    private func configureGridMode(_ windowInfo: WindowInfo) {
        iconImageView.image = windowInfo.appIcon
        thumbnailContainer.isHidden = true
        appNameContainerView.isHidden = true
        floatingAppIconView.isHidden = true
        titleLabel.alignment = .center
        
        // Reset icon size to default
        iconSizeConstraints.forEach { $0.constant = Self.iconSize }
        
        // Adjust vertical offset for grid mode
        iconCenterYConstraint?.constant = -10
    }
    
    private var currentVisibleCount: Int = 5
    
    private func configureThumbnailsMode(_ windowInfo: WindowInfo, visibleCount: Int) {
        let windowID = windowInfo.windowID
        currentVisibleCount = visibleCount
        
        // Update icon size based on visible count
        let iconSize = Self.thumbnailIconSize(forVisibleCount: visibleCount)
        iconSizeConstraints.forEach { $0.constant = iconSize }
        
        // Update floating icon size based on visible count
        let floatingIconSize =  visibleCount <= 4 ? iconSize * 0.25 : iconSize * 0.35
        floatingIconConstraints[0].constant = floatingIconSize  // width
        floatingIconConstraints[1].constant = floatingIconSize  // height
        
        // Start with empty state while thumbnail loads
        iconImageView.image = nil
        thumbnailContainer.isHidden = true
        
        // Hide app name container (not used in thumbnails mode)
        appNameContainerView.isHidden = true
        
        // Show floating app icon at bottom-right of thumbnail
        floatingAppIconView.image = windowInfo.appIcon
        floatingAppIconView.isHidden = false
        
        // Load thumbnail asynchronously to avoid blocking UI
        // Check isVisible to avoid capturing after switcher is dismissed (prevents screen capture indicator flash)
        if SwitcherWindowController.shared.isVisible && windowID != 0 {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let thumbnail = windowInfo.thumbnail else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self = self,
                          self.currentWindowID == windowID,
                          SwitcherWindowController.shared.isVisible else { return }
                    self.showThumbnail(thumbnail, iconSize: iconSize)
                }
            }
        }
        
        titleLabel.alignment = .center
    }
    
    /// Display thumbnail image
    private func showThumbnail(_ thumbnail: NSImage, iconSize: CGFloat? = nil) {
        iconImageView.image = thumbnail
    }
    
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if isSelected {
            layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.2).cgColor
            layer?.borderColor = NSColor.systemBlue.withAlphaComponent(0.7).cgColor
            layer?.borderWidth = 2
        } else if isActive {
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.1).cgColor
            layer?.borderColor = NSColor.white.withAlphaComponent(0.5).cgColor
            layer?.borderWidth = 0
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
            layer?.borderColor = NSColor.clear.cgColor
            layer?.borderWidth = 0
        }
    }
}

// MARK: - List Item View
/// Compact horizontal list item showing icon, title, and app name
class ListItemView: BaseItemView {
    private let iconImageView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let appNameLabel = NSTextField(labelWithString: "")
    
    static let itemSize = Config.listItemSize
    
    override init(frame: NSRect) {
        super.init(frame: frame)
        setupViews()
    }
    
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    
    private func setupViews() {
        wantsLayer = true
        layer?.cornerRadius = 6
        
        iconImageView.imageScaling = .scaleProportionallyUpOrDown
        iconImageView.translatesAutoresizingMaskIntoConstraints = false
        
        titleLabel.font = NSFont.systemFont(ofSize: 13)
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        
        appNameLabel.font = NSFont.systemFont(ofSize: 11)
        appNameLabel.textColor = .secondaryLabelColor
        appNameLabel.lineBreakMode = .byTruncatingTail
        appNameLabel.translatesAutoresizingMaskIntoConstraints = false
        appNameLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        
        addSubview(iconImageView)
        addSubview(titleLabel)
        addSubview(appNameLabel)
        
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
            layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.3).cgColor
        } else if isActive {
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.1).cgColor
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
        }
    }
}

// MARK: - Switcher Window Controller
/// Manages the floating switcher window(s) displayed on all screens.
/// Handles layout, selection, and display of window items.
class SwitcherWindowController {
    static let shared = SwitcherWindowController()
    
    // Per-screen window management for multi-display support
    private var screenWindows: [NSWindow] = []
    private var screenContentViews: [NSView] = []
    private var screenItemViews: [[NSView]] = []
    private var floatingTitleViews: [FloatingTitleView] = []  // Floating title overlays per screen
    
    private var windows: [WindowInfo] = []
    private var selectedIndex = 0
    private var hideTimer: Timer?
    private var scrollRowOffset = 0
    private var listScrollOffset = 0  // Scroll offset for list mode
    private var lastHoveredIndex: Int?  // Tracks hover to detect real mouse movement vs UI rebuild
    private(set) var isVisible = false
    
    private init() {}
    
    // MARK: Public API
    
    func show(windows: [WindowInfo], selectedIndex: Int, keepOpen: Bool = false) {
        guard !windows.isEmpty else { return }
        
        self.windows = windows
        self.selectedIndex = selectedIndex
        self.isVisible = true
        
        scrollRowOffset = 0
        listScrollOffset = 0
        adjustScrollForSelection()
        hideTimer?.invalidate()
        
        createWindowsForAllScreens()
        updateContent()
        screenWindows.forEach { $0.orderFrontRegardless() }
        
        // Check if mouse is already inside an item to prevent accidental hover selection
        detectInitialMousePosition()
        
        if !keepOpen { scheduleHide() }
    }
    
    func hide() {
        isVisible = false
        hideTimer?.invalidate()
        hideTimer = nil
        lastHoveredIndex = nil
        scrollRowOffset = 0
        listScrollOffset = 0
        screenWindows.forEach { $0.orderOut(nil) }
    }
    
    func moveSelection(by delta: Int) {
        guard !windows.isEmpty else { return }
        let previousGridOffset = scrollRowOffset
        let previousListOffset = listScrollOffset
        selectedIndex = (selectedIndex + delta + windows.count) % windows.count
        adjustScrollForSelection()
        let offsetChanged = currentViewMode == .list ? (previousListOffset != listScrollOffset) : (previousGridOffset != scrollRowOffset)
        offsetChanged ? updateContent() : updateSelection()
    }
    
    func moveSelection(to index: Int) {
        guard !windows.isEmpty, index >= 0, index < windows.count else { return }
        let previousGridOffset = scrollRowOffset
        let previousListOffset = listScrollOffset
        selectedIndex = index
        adjustScrollForSelection()
        let offsetChanged = currentViewMode == .list ? (previousListOffset != listScrollOffset) : (previousGridOffset != scrollRowOffset)
        offsetChanged ? updateContent() : updateSelection()
    }
    
    func selectAndSwitch(index: Int) {
        guard index >= 0 && index < windows.count else { return }
        selectedIndex = index
        WindowManager.shared.switchToWindow(at: index)
    }
    
    func hoverSelect(index: Int) {
        // Only trigger on actual mouse movement (not UI rebuild causing mouseEntered)
        guard index != lastHoveredIndex else { return }
        lastHoveredIndex = index
        guard index >= 0, index < windows.count, index != selectedIndex else { return }
        
        selectedIndex = index
        WindowManager.shared.updateSelectedIndex(index)
        updateSelection()
    }
    
    func refreshViewMode() {
        guard !windows.isEmpty else { return }
        updateContent()
    }
    
    // MARK: Private Implementation
    
    private func scheduleHide() {
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: Config.autoHideDelay, repeats: false) { [weak self] _ in
            self?.hide()
        }
    }
    
    /// Detects if the mouse cursor is already inside an item view when the UI opens
    /// If so, sets lastHoveredIndex to prevent hover selection on that item
    private func detectInitialMousePosition() {
        let mouseLocation = NSEvent.mouseLocation
        
        for itemViews in screenItemViews {
            for (visibleIndex, view) in itemViews.enumerated() {
                let startIndex = currentViewMode == .list ? listScrollOffset : scrollRowOffset * Config.gridColumns
                let actualIndex = startIndex + visibleIndex
                
                // Convert mouse location to view's coordinate system
                if let window = view.window {
                    let pointInWindow = window.convertPoint(fromScreen: mouseLocation)
                    let pointInView = view.convert(pointInWindow, from: nil)
                    
                    // Check if mouse is inside this item's bounds
                    if view.bounds.contains(pointInView) {
                        lastHoveredIndex = actualIndex
                        return
                    }
                }
            }
        }
    }
    
    /// Ensures selection is visible, adjusting scroll offset if needed
    private func adjustScrollForSelection() {
        guard !windows.isEmpty else { return }
        
        if currentViewMode == .list {
            // List mode scrolling - adjust offset to keep selection visible
            if selectedIndex < listScrollOffset {
                listScrollOffset = selectedIndex
            } else if selectedIndex >= listScrollOffset + Config.listMaxItems {
                listScrollOffset = selectedIndex - Config.listMaxItems + 1
            }
            return
        }
        
        let selectedRow = selectedIndex / Config.gridColumns
        // Rows visible depends on whether we're in thumbnails mode or the regular icon grid mode
        let visibleRows = (currentViewMode == .thumbnails) ? Config.thumbnailMaxRows : Config.gridMaxRows
        if selectedRow < scrollRowOffset {
            scrollRowOffset = selectedRow
        } else if selectedRow >= scrollRowOffset + visibleRows {
            scrollRowOffset = selectedRow - visibleRows + 1
        }
    }
    
    private func createWindowsForAllScreens() {
        let screens = screensToShow()
        
        // Hide all existing windows first, then adjust count
        screenWindows.forEach { $0.orderOut(nil) }
        
        // Adjust window count to match screen count
        while screenWindows.count > screens.count {
            screenWindows.removeLast()
            screenContentViews.removeLast()
            screenItemViews.removeLast()
            floatingTitleViews.removeLast()
        }
        while screenWindows.count < screens.count {
            let (window, contentView) = createWindow()
            screenWindows.append(window)
            screenContentViews.append(contentView)
            screenItemViews.append([])
            
            // Create floating title view for this screen
            let floatingTitle = FloatingTitleView(frame: .zero)
            floatingTitle.isHidden = true
            contentView.addSubview(floatingTitle, positioned: .above, relativeTo: nil)
            floatingTitleViews.append(floatingTitle)
        }
    }
    
    /// Returns the screens to display the switcher on based on current screen mode
    private func screensToShow() -> [NSScreen] {
        switch currentScreenMode {
        case .allScreens:
            return NSScreen.screens
        case .activeScreen:
            // Get the screen containing the frontmost window
            if let frontApp = NSWorkspace.shared.frontmostApplication,
               let axApp = AXUIElementCreateApplication(frontApp.processIdentifier) as AXUIElement?,
               let focusedWindow: AXUIElement = AXHelper.getValue(axApp, kAXFocusedWindowAttribute),
               let position = AXHelper.getPoint(focusedWindow, kAXPositionAttribute) {
                for screen in NSScreen.screens {
                    if screen.frame.contains(position) {
                        return [screen]
                    }
                }
            }
            // Fallback to main screen
            return [NSScreen.main ?? NSScreen.screens[0]]
        case .mouseScreen:
            let mouseLocation = NSEvent.mouseLocation
            for screen in NSScreen.screens {
                if screen.frame.contains(mouseLocation) {
                    return [screen]
                }
            }
            // Fallback to main screen
            return [NSScreen.main ?? NSScreen.screens[0]]
        }
    }
    
    private func createWindow() -> (NSWindow, NSView) {
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
        visualEffect.appearance = NSAppearance(named: .darkAqua)
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 18
        visualEffect.layer?.masksToBounds = true
        
        let contentView = NSView(frame: window.frame)
        contentView.wantsLayer = true
        visualEffect.addSubview(contentView)
        window.contentView = visualEffect
        
        return (window, contentView)
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
                itemView.isActive = (actualIndex == 0)
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
        
        // Use dynamic item size for thumbnails mode based on visible count
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
                itemView.isActive = (actualIndex == 0)
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
            
            // Clear existing items
            screenItemViews[index].forEach { $0.removeFromSuperview() }
            
            // Center on screen
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
            
            // Ensure floating title is above all items and update it
            if index < floatingTitleViews.count {
                let floatingTitle = floatingTitleViews[index]
                floatingTitle.removeFromSuperview()
                contentView.addSubview(floatingTitle, positioned: .above, relativeTo: nil)
                
                // Update floating title for grid/thumbnails mode
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
                    itemView.isActive = (actualIndex == 0)
                }
            }
            // Update floating title for grid/thumbnails mode
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
        
        // Reset all item titles to visible first
        for view in itemViews {
            if let windowItem = view as? WindowItemView {
                windowItem.setTitleHidden(false)
            }
        }
        
        // If there's 1 or fewer items visible, do not show a floating title at all
        // Keep the original truncated title visible
        if itemViews.count <= 1 {
            floatingTitle.isHidden = true
            return
        }
        
        // Find the selected item view
        let selectedVisibleIndex = selectedIndex - startIndex
        guard selectedVisibleIndex >= 0, selectedVisibleIndex < itemViews.count,
              let itemView = itemViews[selectedVisibleIndex] as? WindowItemView else {
            floatingTitle.isHidden = true
            return
        }
        
        // Force layout to get accurate frame sizes
        itemView.layoutSubtreeIfNeeded()
        
        // Check if the title is truncated
        guard itemView.isTitleTruncated else {
            floatingTitle.isHidden = true
            return
        }
        
        // Hide the original title since we'll show the floating one
        itemView.setTitleHidden(true)
        
        // Get title info from the item
        let title = itemView.titleText
        let titleFrame = itemView.titleLabelFrame
        
        // Configure floating title
        floatingTitle.configure(with: title)
        floatingTitle.isHidden = false
        
        // Calculate max width (container width minus margins)
        let maxWidth = containerView.bounds.width - containerMargin * 2
        let titleSize = floatingTitle.idealSize(maxWidth: maxWidth)
        
        // Calculate ideal X position (centered on item)
        let itemCenterX = itemView.frame.midX
        var titleX = itemCenterX - titleSize.width / 2
        
        // Constrain to container bounds
        let minX = containerMargin
        let maxX = containerView.bounds.width - containerMargin - titleSize.width
        titleX = max(minX, min(titleX, maxX))
        
        // Y position: align with the title label in item coordinates
        // Center the floating title vertically on the original title position
        let titleCenterY = itemView.frame.origin.y + titleFrame.midY
        let titleY = titleCenterY - titleSize.height / 2
        
        floatingTitle.frame = NSRect(x: titleX, y: titleY, width: titleSize.width, height: titleSize.height)
    }
}

// MARK: - Window Manager
/// Manages window enumeration, sorting, and switching.
/// Uses Accessibility API to get window list and CGWindowList for z-order.
class WindowManager {
    static let shared = WindowManager()
    
    private var windowIndex = 0
    private var cachedWindows: [WindowInfo] = []
    private var isShowingSwitcher = false
    /// Tracks the windowID that was last switched to, to ensure only that specific
    /// window moves to front (not all windows of the same app)
    private var lastSwitchedWindowID: CGWindowID = 0
    
    private init() {}
    
    // MARK: Public API
    
    func showSwitcherAndNext() { showSwitcher(delta: 1) }
    func showSwitcherAndPrevious() { showSwitcher(delta: -1) }
    
    func confirmAndSwitch() {
        isShowingSwitcher = false
        guard windowIndex >= 0 && windowIndex < cachedWindows.count else { return }
        let target = cachedWindows[windowIndex]
        lastSwitchedWindowID = target.windowID
        DispatchQueue.main.async { SwitcherWindowController.shared.hide() }
        target.raise()
    }
    
    func switchToWindow(at index: Int) {
        isShowingSwitcher = false
        guard index >= 0 && index < cachedWindows.count else { return }
        windowIndex = index
        lastSwitchedWindowID = cachedWindows[index].windowID
        DispatchQueue.main.async { SwitcherWindowController.shared.hide() }
        cachedWindows[index].raise()
    }
    
    func cancelSwitcher() {
        isShowingSwitcher = false
        // Don't reset lastSwitchedWindowID on cancel - keep the previous window at front
        DispatchQueue.main.async { SwitcherWindowController.shared.hide() }
    }
    
    func updateSelectedIndex(_ index: Int) {
        guard index >= 0 && index < cachedWindows.count else { return }
        windowIndex = index
    }
    
    func isSwitcherVisible() -> Bool { isShowingSwitcher }
    
    // MARK: Private Implementation
    
    private func showSwitcher(delta: Int) {
        if !isShowingSwitcher {
            cachedWindows = getAllWindows()
            // No windows to show - do nothing
            guard !cachedWindows.isEmpty else { return }
            windowIndex = 0
            isShowingSwitcher = true
            windowIndex = (windowIndex + delta + cachedWindows.count) % cachedWindows.count
            DispatchQueue.main.async {
                SwitcherWindowController.shared.show(windows: self.cachedWindows, selectedIndex: self.windowIndex, keepOpen: true)
            }
        } else {
            // Switcher is visible but windows might have changed
            guard !cachedWindows.isEmpty else {
                cancelSwitcher()
                return
            }
            windowIndex = (windowIndex + delta + cachedWindows.count) % cachedWindows.count
            DispatchQueue.main.async {
                SwitcherWindowController.shared.moveSelection(to: self.windowIndex)
            }
        }
    }
    
    /// Enumerate all windows using Accessibility API, sorted by z-order (front-to-back)
    func getAllWindows() -> [WindowInfo] {
        var windows: [WindowInfo] = []
        
        // Get windows from all regular apps (excluding self)
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }
        
        for app in apps {
            windows.append(contentsOf: getWindowsForApp(app))
        }
        
        // Sort by z-order using CGWindowList data
        let windowOrder = getWindowOrder()
        var orderIndexByWindowID: [CGWindowID: Int] = [:]
        for (idx, entry) in windowOrder.enumerated() {
            orderIndexByWindowID[entry.windowID] = idx
        }
        var usedWindowIDs = Set<CGWindowID>()
        var sortInfos: [(window: WindowInfo, order: Int)] = []
        for window in windows {
            if let windowNumber = AXHelper.getInt(window.axWindow, kAXWindowNumberAttribute) {
                let windowID = CGWindowID(windowNumber)
                window.windowID = windowID
                usedWindowIDs.insert(windowID)
                let order = orderIndexByWindowID[windowID] ?? Int.max
                sortInfos.append((window, order))
                continue
            }
            let pos = AXHelper.getPoint(window.axWindow, kAXPositionAttribute)
            let size = AXHelper.getSize(window.axWindow, kAXSizeAttribute)
            if let match = findWindowMatch(window, pos: pos, size: size, in: windowOrder, usedWindowIDs: &usedWindowIDs) {
                window.windowID = match.windowID
                sortInfos.append((window, match.index))
            } else {
                sortInfos.append((window, Int.max))
            }
        }
        sortInfos.sort { $0.order < $1.order }
        
        // If we have a lastSwitchedWindowID, ensure only that specific window is at the front
        // This prevents all windows of the same app from jumping to the top
        if lastSwitchedWindowID != 0 {
            let targetWindowID = lastSwitchedWindowID
            lastSwitchedWindowID = 0  // Clear after use
            var result = sortInfos.map { $0.window }
            if let switchedIndex = result.firstIndex(where: { $0.windowID == targetWindowID }), switchedIndex > 0 {
                let switchedWindow = result.remove(at: switchedIndex)
                result.insert(switchedWindow, at: 0)
            }
            return result
        }
        
        return sortInfos.map { $0.window }
    }
    
    private func getWindowsForApp(_ app: NSRunningApplication) -> [WindowInfo] {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        guard let axWindows: [AXUIElement] = AXHelper.getValue(appElement, kAXWindowsAttribute) else {
            return []
        }
        
        let isFinder = app.bundleIdentifier == "com.apple.finder"
        
        return axWindows.compactMap { axWindow -> WindowInfo? in
            let isMinimized = AXHelper.getBool(axWindow, kAXMinimizedAttribute)
            
            // Filter out tiny windows (unless minimized - they have no size)
            if !isMinimized, let size = AXHelper.getSize(axWindow, kAXSizeAttribute),
               size.width < 50 || size.height < 50 {
                return nil
            }
            
            let title = AXHelper.getString(axWindow, kAXTitleAttribute)
            
            // Finder: skip untitled windows (desktop window)
            if isFinder && (title == nil || title!.isEmpty) { return nil }
            
            // Skip non-standard windows (unless minimized)
            if !isMinimized, let subrole: String = AXHelper.getValue(axWindow, kAXSubroleAttribute),
               subrole != "AXStandardWindow" {
                return nil
            }
            
            return WindowInfo(
                ownerPID: app.processIdentifier,
                ownerName: app.localizedName ?? "Unknown",
                windowName: title ?? app.localizedName ?? "Unknown",
                axWindow: axWindow
            )
        }
    }
    
    /// Get window z-order from CGWindowList (front-to-back)
    private func getWindowOrder() -> [(pid: pid_t, title: String, bounds: CGRect, windowID: CGWindowID)] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        
        return list.compactMap { dict -> (pid_t, String, CGRect, CGWindowID)? in
            guard let pid = dict[kCGWindowOwnerPID as String] as? pid_t,
                  let windowID = dict[kCGWindowNumber as String] as? CGWindowID,
                  let layer = dict[kCGWindowLayer as String] as? Int,
                  layer == 0 else { return nil }
            
            let title = dict[kCGWindowName as String] as? String ?? ""
            var bounds = CGRect.zero
            if let b = dict[kCGWindowBounds as String] as? [String: Any] {
                bounds = CGRect(x: b["X"] as? CGFloat ?? 0, y: b["Y"] as? CGFloat ?? 0,
                               width: b["Width"] as? CGFloat ?? 0, height: b["Height"] as? CGFloat ?? 0)
            }
            return (pid, title, bounds, windowID)
        }
    }
    
    /// Match AX window to CGWindowList entry by title or position
    /// The usedWindowIDs set tracks which windowIDs have already been assigned to prevent duplicates
    private func findWindowMatch(_ window: WindowInfo, pos: CGPoint?, size: CGSize?,
                                  in order: [(pid: pid_t, title: String, bounds: CGRect, windowID: CGWindowID)],
                                  usedWindowIDs: inout Set<CGWindowID>) -> (index: Int, windowID: CGWindowID)? {
        // First try position/size match (most reliable for distinguishing windows)
        if let pos = pos, let size = size {
            for (idx, entry) in order.enumerated() where entry.pid == window.ownerPID {
                guard !usedWindowIDs.contains(entry.windowID) else { continue }
                let tolerance: CGFloat = 2
                if abs(entry.bounds.origin.x - pos.x) < tolerance &&
                   abs(entry.bounds.origin.y - pos.y) < tolerance &&
                   abs(entry.bounds.size.width - size.width) < tolerance &&
                   abs(entry.bounds.size.height - size.height) < tolerance {
                    usedWindowIDs.insert(entry.windowID)
                    return (idx, entry.windowID)
                }
            }
        }
        // Fallback to title match (only if position match failed)
        for (idx, entry) in order.enumerated() where entry.pid == window.ownerPID {
            guard !usedWindowIDs.contains(entry.windowID) else { continue }
            if !entry.title.isEmpty && entry.title == window.windowName {
                usedWindowIDs.insert(entry.windowID)
                return (idx, entry.windowID)
            }
        }
        return nil
    }
}

// MARK: - Hotkey Manager
/// Captures global keyboard events using CGEvent tap.
/// Requires Accessibility permission.
class HotkeyManager {
    static let shared = HotkeyManager()
    
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var baseComboPressed = false
    
    private init() {}
    
    func start() {
        guard AXIsProcessTrusted() else {
            showAccessibilityAlert()
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
            showAccessibilityAlert()
            return
        }
        
        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }
    
    func stop() {
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes) }
        eventTap = nil
        runLoopSource = nil
    }
    
    private static func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Re-enable tap if disabled
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = shared.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passRetained(event)
        }
        
        // Don't process shortcuts while settings dialog is open
        if ShortcutSettingsWindowController.isOpen {
            return Unmanaged.passRetained(event)
        }
        
        let config = currentShortcutConfig
        let sanitizedFlags = CGEventFlags(rawValue: event.flags.rawValue & relevantModifierMask.rawValue)
        let baseModsPressed = flagsContain(sanitizedFlags, config.baseModifiers)
        
        // Track base modifier state for release detection
        // If baseKey is set, we track when that key is held; otherwise just modifiers
        if type == .flagsChanged {
            let wasPressed = shared.baseComboPressed
            // Only consider base pressed if modifiers match (baseKey handled on keyDown)
            shared.baseComboPressed = baseModsPressed && (config.baseKey == 0 || shared.baseComboPressed)
            
            // Confirm selection when modifiers released
            if wasPressed && !baseModsPressed && WindowManager.shared.isSwitcherVisible() {
                WindowManager.shared.confirmAndSwitch()
            }
            return Unmanaged.passRetained(event)
        }
        
        guard type == .keyDown else { return Unmanaged.passRetained(event) }
        
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        
        // Build full requirements for forward/backward shortcuts
        let forwardRequirement = config.baseModifiers.union(config.forwardModifiers)
        let backwardRequirement = config.baseModifiers.union(config.backwardModifiers)
        
        // When forward and backward use the same key, we need to check the more specific
        // shortcut (with more modifiers) first to avoid the less specific one always matching.
        // Check backward first if it has more modifiers than forward, otherwise check forward first.
        let forwardModCount = modifierBitCount(forwardRequirement)
        let backwardModCount = modifierBitCount(backwardRequirement)
        let checkBackwardFirst = (config.forwardKey == config.backwardKey && backwardModCount > forwardModCount)
        
        func tryForward() -> Bool {
            if flagsContain(sanitizedFlags, forwardRequirement) && keyCode == config.forwardKey {
                shared.baseComboPressed = true
                WindowManager.shared.showSwitcherAndNext()
                return true
            }
            return false
        }
        
        func tryBackward() -> Bool {
            if flagsContain(sanitizedFlags, backwardRequirement) && keyCode == config.backwardKey {
                shared.baseComboPressed = true
                WindowManager.shared.showSwitcherAndPrevious()
                return true
            }
            return false
        }
        
        if checkBackwardFirst {
            if tryBackward() { return nil }
            if tryForward() { return nil }
        } else {
            if tryForward() { return nil }
            if tryBackward() { return nil }
        }
        
        // Escape: cancel switcher
        if keyCode == 53 && shared.baseComboPressed {  // Escape = 53
            WindowManager.shared.cancelSwitcher()
            return nil
        }
        
        return Unmanaged.passRetained(event)
    }
}

// MARK: - Permission Dialog
/// Permission types supported by the permission dialog
enum PermissionType {
    case accessibility
    case screenRecording
    
    var title: String {
        switch self {
        case .accessibility: return "Accessibility Permission Required"
        case .screenRecording: return "Screen Recording Permission Required"
        }
    }
    
    var message: String {
        switch self {
        case .accessibility:
            return "Twoggler needs Accessibility permission to capture keyboard shortcuts and switch windows.\n\nPlease grant permission in System Settings > Privacy & Security > Accessibility."
        case .screenRecording:
            return "Twoggler needs Screen Recording permission to capture window thumbnails.\n\nPlease grant permission in System Settings > Privacy & Security > Screen Recording."
        }
    }
    
    var settingsURL: URL {
        switch self {
        case .accessibility:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        case .screenRecording:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        }
    }
    
    /// Whether closing the dialog without permission should quit the app
    var quitsOnDismissWithoutPermission: Bool {
        switch self {
        case .accessibility: return true
        case .screenRecording: return false
        }
    }
    
    /// Check if the permission is currently granted
    func isGranted() -> Bool {
        switch self {
        case .accessibility:
            return AXIsProcessTrusted()
        case .screenRecording:
            return CGPreflightScreenCaptureAccess()
        }
    }
}

/// Custom dialog for permission requests.
/// Unlike NSAlert, this dialog does not close when clicking buttons.
/// Checks for permission when the window regains focus.
/// For Accessibility: if dismissed without permission, the application terminates.
/// For Screen Recording: dismissing just closes the dialog.
class PermissionDialog: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let permissionType: PermissionType
    private var onPermissionGranted: (() -> Void)?
    
    init(permissionType: PermissionType, onPermissionGranted: (() -> Void)? = nil) {
        self.permissionType = permissionType
        self.onPermissionGranted = onPermissionGranted
        super.init()
    }
    
    func show() {
        guard window == nil else {
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        
        createWindow()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    private func createWindow() {
        let windowWidth: CGFloat = 320
        let windowHeight: CGFloat = 320
        let iconSize: CGFloat = 64
        let topMargin: CGFloat = 20
        let sideMargin: CGFloat = 20
        let buttonWidth: CGFloat = 180
        let buttonHeight: CGFloat = 32
        let buttonSpacing: CGFloat = 10
        
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window?.title = ""
        window?.center()
        window?.delegate = self
        window?.isReleasedWhenClosed = false
        
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight))
        window?.contentView = contentView
        
        // Warning icon (using system alert icon)
        let iconView = NSImageView(frame: NSRect(
            x: (windowWidth - iconSize) / 2,
            y: windowHeight - topMargin - iconSize,
            width: iconSize,
            height: iconSize
        ))
        iconView.image = NSImage(named: NSImage.cautionName)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        contentView.addSubview(iconView)
        
        // Title label
        let titleLabel = NSTextField(labelWithString: permissionType.title)
        titleLabel.font = NSFont.boldSystemFont(ofSize: 13)
        titleLabel.alignment = .center
        titleLabel.frame = NSRect(
            x: sideMargin,
            y: windowHeight - topMargin - iconSize - 15 - 20,
            width: windowWidth - sideMargin * 2,
            height: 20
        )
        contentView.addSubview(titleLabel)
        
        // Buttons first to calculate available space
        // Cancel button - bottom button
        let cancelButton = NSButton(frame: NSRect(
            x: (windowWidth - buttonWidth) / 2,
            y: sideMargin,
            width: buttonWidth,
            height: buttonHeight
        ))
        cancelButton.title = "Cancel"
        cancelButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)
        contentView.addSubview(cancelButton)
        
        // "Open System Settings" button (primary) - top button
        let openSettingsButton = NSButton(frame: NSRect(
            x: (windowWidth - buttonWidth) / 2,
            y: sideMargin + buttonHeight + buttonSpacing,
            width: buttonWidth,
            height: buttonHeight
        ))
        openSettingsButton.title = "Open System Settings"
        openSettingsButton.bezelStyle = .rounded
        openSettingsButton.keyEquivalent = "\r"
        openSettingsButton.target = self
        openSettingsButton.action = #selector(openSystemSettings)
        contentView.addSubview(openSettingsButton)
        
        // Informative text
        // Calculate available height
        let buttonsTop = openSettingsButton.frame.maxY
        let titleBottom = titleLabel.frame.minY
        let infoHeight = titleBottom - buttonsTop - 20 // 10 padding top and bottom
        
        let infoLabel = NSTextField(wrappingLabelWithString: permissionType.message)
        infoLabel.font = NSFont.systemFont(ofSize: 11)
        infoLabel.alignment = .center
        infoLabel.frame = NSRect(
            x: sideMargin,
            y: buttonsTop + 10,
            width: windowWidth - sideMargin * 2,
            height: infoHeight
        )
        contentView.addSubview(infoLabel)
    }
    
    private func checkPermissionAndClose() {
        if permissionType.isGranted() {
            window?.close()
            window = nil
            onPermissionGranted?()
        }
    }
    
    @objc private func openSystemSettings() {
        NSWorkspace.shared.open(permissionType.settingsURL)
    }
    
    @objc private func cancelClicked() {
        window?.close()
    }
    
    // MARK: - NSWindowDelegate
    
    func windowDidBecomeKey(_ notification: Notification) {
        // Check permission when window regains focus
        checkPermissionAndClose()
    }
    
    func windowWillClose(_ notification: Notification) {
        // Check if permission was granted before closing
        let permissionGranted = permissionType.isGranted()
        if permissionGranted {
            onPermissionGranted?()
        } else if permissionType.quitsOnDismissWithoutPermission {
            NSApplication.shared.terminate(nil)
        }
        window = nil
    }
}

/// Singleton instance for the accessibility permission dialog
private var accessibilityPermissionDialog: PermissionDialog?

private func showAccessibilityAlert() {
    DispatchQueue.main.async {
        if accessibilityPermissionDialog == nil {
            accessibilityPermissionDialog = PermissionDialog(
                permissionType: .accessibility,
                onPermissionGranted: {
                    // Restart hotkey manager now that permission is granted
                    HotkeyManager.shared.start()
                }
            )
        }
        accessibilityPermissionDialog?.show()
    }
}

/// Singleton instance for the screen recording permission dialog
private var screenRecordingPermissionDialog: PermissionDialog?

private func showScreenRecordingAlert() {
    DispatchQueue.main.async {
        if screenRecordingPermissionDialog == nil {
            screenRecordingPermissionDialog = PermissionDialog(permissionType: .screenRecording)
        }
        screenRecordingPermissionDialog?.show()
    }
}

// MARK: - Shortcut Settings Window
/// Dialog for configuring custom keyboard shortcuts
class ShortcutSettingsWindowController: NSObject, NSWindowDelegate {
    static var isOpen = false
    
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
        let windowWidth: CGFloat = 460
        let windowHeight: CGFloat = 280
        let fieldWidth: CGFloat = 190
        let fieldHeight: CGFloat = 26
        let leftFieldX: CGFloat = 20
        let plusWidth: CGFloat = 20
        let interFieldSpacing: CGFloat = 12
        let rightFieldX = leftFieldX + fieldWidth + plusWidth + interFieldSpacing * 2
        let plusX = leftFieldX + fieldWidth + interFieldSpacing
        
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window?.title = "Shortcut Settings"
        window?.center()
        window?.delegate = self
        window?.isReleasedWhenClosed = false
        
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight))
        window?.contentView = contentView
        
        var yOffset: CGFloat = windowHeight - 80
        
        let titleLabel = NSTextField(labelWithString: "Configure Keyboard Shortcuts")
        titleLabel.font = NSFont.boldSystemFont(ofSize: 14)
        titleLabel.frame = NSRect(x: 20, y: windowHeight - 40, width: windowWidth - 40, height: 20)
        contentView.addSubview(titleLabel)
        
        // Row 1 - Base + Forward
        let baseLabel = NSTextField(labelWithString: "Base:")
        baseLabel.frame = NSRect(x: 20, y: yOffset, width: 110, height: 18)
        contentView.addSubview(baseLabel)
        
        let forwardLabel = NSTextField(labelWithString: "Forward Selection:")
        forwardLabel.frame = NSRect(x: rightFieldX, y: yOffset, width: 170, height: 18)
        contentView.addSubview(forwardLabel)
        yOffset -= 32
        
        baseModifiersField = ShortcutCaptureField(frame: NSRect(x: leftFieldX, y: yOffset, width: fieldWidth, height: fieldHeight))
        baseModifiersField.captureMode = .modifiersAndKey
        baseModifiersField.setKeyCombination(modifiers: currentShortcutConfig.baseModifiers, keyCode: currentShortcutConfig.baseKey)
        baseModifiersField.onUpdate = { [weak self] in
            self?.syncBaseMirrorField()
            self?.updateWarning()
        }
        baseModifiersField.onValidate = { [weak self] mods, key in
            self?.isUniqueCombination(mods, key, excluding: self?.baseModifiersField) ?? true
        }
        contentView.addSubview(baseModifiersField)
        
        let forwardPlus = makePlusLabel(frame: NSRect(x: plusX, y: yOffset, width: plusWidth, height: fieldHeight))
        contentView.addSubview(forwardPlus)
        
        forwardKeyField = ShortcutCaptureField(frame: NSRect(x: rightFieldX, y: yOffset, width: fieldWidth, height: fieldHeight))
        forwardKeyField.captureMode = .modifiersAndKey
        forwardKeyField.setKeyCombination(modifiers: currentShortcutConfig.forwardModifiers, keyCode: currentShortcutConfig.forwardKey)
        forwardKeyField.onUpdate = { [weak self] in self?.updateWarning() }
        forwardKeyField.onValidate = { [weak self] mods, key in
            self?.isUniqueCombination(mods, key, excluding: self?.forwardKeyField) ?? true
        }
        contentView.addSubview(forwardKeyField)
        
        // Row 2 - Mirrored Base + Backward
        yOffset -= (fieldHeight + 38)
        let backwardLabel = NSTextField(labelWithString: "Backward Selection:")
        backwardLabel.frame = NSRect(x: rightFieldX, y: yOffset + fieldHeight + 6, width: 170, height: 18)
        contentView.addSubview(backwardLabel)
        
        baseMirrorField = makeDisplayField(frame: NSRect(x: leftFieldX, y: yOffset, width: fieldWidth, height: fieldHeight))
        contentView.addSubview(baseMirrorField)
        syncBaseMirrorField()
        
        let backwardPlus = makePlusLabel(frame: NSRect(x: plusX, y: yOffset, width: plusWidth, height: fieldHeight))
        contentView.addSubview(backwardPlus)
        
        backwardKeyField = ShortcutCaptureField(frame: NSRect(x: rightFieldX, y: yOffset, width: fieldWidth, height: fieldHeight))
        backwardKeyField.captureMode = .modifiersAndKey
        backwardKeyField.setKeyCombination(modifiers: currentShortcutConfig.backwardModifiers, keyCode: currentShortcutConfig.backwardKey)
        backwardKeyField.onUpdate = { [weak self] in self?.updateWarning() }
        backwardKeyField.onValidate = { [weak self] mods, key in
            self?.isUniqueCombination(mods, key, excluding: self?.backwardKeyField) ?? true
        }
        contentView.addSubview(backwardKeyField)
        
        // Warning label
        warningLabel = NSTextField(wrappingLabelWithString: "")
        warningLabel.frame = NSRect(x: 20, y: yOffset - 60, width: windowWidth - 30, height: 36)
        warningLabel.textColor = .systemOrange
        warningLabel.font = NSFont.systemFont(ofSize: 11)
        contentView.addSubview(warningLabel)
        
        // Buttons
        let buttonY: CGFloat = 20
        
        let resetButton = NSButton(title: "Reset to Default", target: self, action: #selector(resetToDefault))
        resetButton.frame = NSRect(x: 20, y: buttonY, width: 140, height: 32)
        resetButton.bezelStyle = .rounded
        contentView.addSubview(resetButton)
        
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancelButton.frame = NSRect(x: windowWidth - 190, y: buttonY, width: 80, height: 32)
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}" // Escape
        contentView.addSubview(cancelButton)
        
        let saveButton = NSButton(title: "Save", target: self, action: #selector(save))
        saveButton.frame = NSRect(x: windowWidth - 100, y: buttonY, width: 80, height: 32)
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r" // Return
        contentView.addSubview(saveButton)
        
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
            warningLabel.stringValue = "⚠️ Warning: Current shortcuts may occasionally conflict with macOS defaults."
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
        // Base must have at least modifiers OR a key
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
    enum CaptureMode {
        case modifiersOnly
        case modifiersAndKey
    }
    
    var captureMode: CaptureMode = .modifiersOnly
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
    
    func setModifiers(_ modifiers: CGEventFlags) {
        capturedModifiers = modifiers
        updateDisplay()
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
            // Validation failed - revert to original values
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
            shouldShowKey = captureMode == .modifiersAndKey
        }
        if shouldShowKey {
            let keyCode = key ?? capturedKeyCode
            // Only show key if it's non-zero (0 means no key set)
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
        
        switch captureMode {
        case .modifiersOnly:
            guard event.type == .flagsChanged else { return }
            let mods = cgFlags(from: event.modifierFlags)
            if !mods.isEmpty {
                pendingModifiers = mods
                if pendingMaxModifiers == nil || modifierBitCount(mods) >= modifierBitCount(pendingMaxModifiers!) {
                    pendingMaxModifiers = mods
                }
                updateDisplay(showing: mods)
            } else if let pending = pendingMaxModifiers {
                capturedModifiers = pending
                capturedKeyCode = 0  // No key for modifiers-only
                pendingModifiers = nil
                pendingMaxModifiers = nil
                stopCapturing(commit: true)
                onUpdate?()
            }
        case .modifiersAndKey:
            if event.type == .flagsChanged {
                let mods = cgFlags(from: event.modifierFlags)
                pendingModifiers = mods
                if !mods.isEmpty {
                    if pendingMaxModifiers == nil || modifierBitCount(mods) >= modifierBitCount(pendingMaxModifiers!) {
                        pendingMaxModifiers = mods
                    }
                    updateDisplay(showing: mods, includeKey: false)
                } else if let pending = pendingMaxModifiers {
                    // User released all modifiers - commit with just modifiers, no key
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
    }
    
    override func resignFirstResponder() -> Bool {
        if isCapturing {
            stopCapturing(commit: false)
        }
        return super.resignFirstResponder()
    }
}

// MARK: - App Delegate
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var shortcutSettingsController: ShortcutSettingsWindowController?
    private var shortcutMenuItem: NSMenuItem?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Reset to grid mode if thumbnails permission was revoked
        if currentViewMode == .thumbnails && !CGPreflightScreenCaptureAccess() {
            currentViewMode = .grid
            UserDefaults.standard.set(ViewMode.grid.rawValue, forKey: "viewMode")
        }
        
        setupStatusBar()
        HotkeyManager.shared.start()
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        HotkeyManager.shared.stop()
    }
    
    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem?.button {
            var image: NSImage?
            
            // Try to load from bundle resources
            if let iconURL = Bundle.main.url(forResource: "icon", withExtension: "png") {
                image = NSImage(contentsOf: iconURL)
            }
            
            if let image = image {
                image.isTemplate = false
                image.size = NSSize(width: 18, height: 18)
                button.image = image
            } else {
                button.title = "⇌"
            }
        }
        
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Twoggler", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        shortcutMenuItem = NSMenuItem(title: shortcutMenuTitle(), action: #selector(openShortcutSettings), keyEquivalent: "")
        menu.addItem(shortcutMenuItem!)
        menu.addItem(.separator())
        
        for (title, mode) in [("Icons", ViewMode.grid), ("Thumbnails", .thumbnails), ("List", .list)] {
            let item = NSMenuItem(title: title, action: #selector(changeViewMode(_:)), keyEquivalent: "")
            item.representedObject = mode
            item.state = currentViewMode == mode ? .on : .off
            menu.addItem(item)
        }
        
        menu.addItem(.separator())
        
        for (title, mode) in [("All Screens", ScreenMode.allScreens), ("Active Screen", .activeScreen), ("Mouse Position", .mouseScreen)] {
            let item = NSMenuItem(title: title, action: #selector(changeScreenMode(_:)), keyEquivalent: "")
            item.representedObject = mode
            item.state = currentScreenMode == mode ? .on : .off
            menu.addItem(item)
        }
        
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        
        statusItem?.menu = menu
    }
    
    @objc private func changeViewMode(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? ViewMode else { return }
        
        // Check permission for thumbnails mode
        if mode == .thumbnails && !CGPreflightScreenCaptureAccess() {
            showScreenRecordingAlert()
            return
        }
        
        currentViewMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "viewMode")
        
        // Update menu checkmarks
        statusItem?.menu?.items.forEach { item in
            if let itemMode = item.representedObject as? ViewMode {
                item.state = itemMode == mode ? .on : .off
            }
        }
        
        SwitcherWindowController.shared.refreshViewMode()
    }
    
    @objc private func changeScreenMode(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? ScreenMode else { return }
        
        currentScreenMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "screenMode")
        
        // Update menu checkmarks
        statusItem?.menu?.items.forEach { item in
            if let itemMode = item.representedObject as? ScreenMode {
                item.state = itemMode == mode ? .on : .off
            }
        }
    }
    
    @objc private func openShortcutSettings() {
        if shortcutSettingsController == nil {
            shortcutSettingsController = ShortcutSettingsWindowController()
        }
        shortcutSettingsController?.show { [weak self] in
            self?.updateShortcutMenuItem()
        }
    }
    
    private func updateShortcutMenuItem() {
        shortcutMenuItem?.title = shortcutMenuTitle()
    }
    
    private func shortcutMenuTitle() -> String {
        "\(currentShortcutConfig.forwardShortcutString) to switch windows"
    }
    
    @objc private func quit() {
        HotkeyManager.shared.stop()
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - Main Entry Point

// Prevent multiple instances
if NSWorkspace.shared.runningApplications.contains(where: {
    $0.bundleIdentifier == Bundle.main.bundleIdentifier && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
}) {
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()  // Strong reference to prevent deallocation
app.delegate = delegate
app.setActivationPolicy(.accessory)  // Menu bar app only (no dock icon)
app.run()