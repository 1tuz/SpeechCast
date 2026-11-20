import AppKit
// `@preconcurrency` downgrades AX diagnostics: the attribute keys are constant C globals.
@preconcurrency import ApplicationServices

/// Always against a named process: the system-wide focus answers with ours.
enum AccessibilityText {
    /// Generous for a responsive app, short enough that a wedged one can't stall the main actor.
    private static let timeout: Float = 1

    /// The two have different fixes; collapsing them tells a reader to select what they selected.
    enum Selection: Equatable {
        case text(String)
        case noFocusedElement
        case empty
    }

    static func focusedElement(in app: NSRunningApplication) -> AXUIElement? {
        let application = AXUIElementCreateApplication(app.processIdentifier)
        // Per element and never inherited, so the focused element needs its own against a hang.
        AXUIElementSetMessagingTimeout(application, timeout)
        activateManualAccessibility(of: application)
        var focusedValue: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                application,
                kAXFocusedUIElementAttribute as CFString,
                &focusedValue) == .success,
            let focusedValue,
            CFGetTypeID(focusedValue) == AXUIElementGetTypeID()
        else { return nil }

        let element = focusedValue as! AXUIElement
        AXUIElementSetMessagingTimeout(element, timeout)
        return element
    }

    static func read(in app: NSRunningApplication) -> Selection {
        guard let element = focusedElement(in: app) else { return .noFocusedElement }
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            &value)
        if status == .success, let text = value as? String, !text.isEmpty { return .text(text) }
        guard let web = webSelection(in: element), !web.isEmpty else { return .empty }
        return .text(web)
    }

    /// A narrower question, for callers that can act on the text but not on why there is none.
    static func selection(in app: NSRunningApplication) -> String? {
        guard case .text(let text) = read(in: app) else { return nil }
        return text
    }

    /// Chromium builds its tree only once asked, so Chrome and Electron answer nothing until this.
    private static func activateManualAccessibility(of application: AXUIElement) {
        AXUIElementSetAttributeValue(
            application, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    /// Browsers have no `AXSelectedText`: web selection exists only as an opaque marker range.
    private static func webSelection(in element: AXUIElement) -> String? {
        var range: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                element,
                kAXSelectedTextMarkerRangeAttribute as CFString,
                &range) == .success,
            let range,
            CFGetTypeID(range) == AXTextMarkerRangeGetTypeID()
        else { return nil }

        var value: CFTypeRef?
        guard
            AXUIElementCopyParameterizedAttributeValue(
                element,
                kAXStringForTextMarkerRangeParameterizedAttribute as CFString,
                range,
                &value) == .success
        else { return nil }
        return value as? String
    }

    // MARK: - Bounded reads

    /// Auto Learn's whole vocabulary: identity, a caret, a length, and a short window at a range.
    /// Nothing here walks the field, so a million-character document costs the same as an empty one.
    static func role(of element: AXUIElement) -> String? {
        stringAttribute(kAXRoleAttribute, of: element)
    }

    static func isSecure(_ element: AXUIElement) -> Bool {
        stringAttribute(kAXSubroleAttribute, of: element) == "AXSecureTextField"
            || stringAttribute(kAXRoleAttribute, of: element) == "AXSecureTextField"
    }

    static func numberOfCharacters(of element: AXUIElement) -> Int? {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                element, kAXNumberOfCharactersAttribute as CFString, &value) == .success,
            let value,
            CFGetTypeID(value) == CFNumberGetTypeID()
        else { return nil }
        return (value as? NSNumber)?.intValue
    }

    static func selectedRange(of element: AXUIElement) -> NSRange? {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
            let value,
            CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    static func string(of element: AXUIElement, range: NSRange) -> String? {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let axRange = AXValueCreate(.cfRange, &cfRange) else { return nil }
        var value: CFTypeRef?
        guard
            AXUIElementCopyParameterizedAttributeValue(
                element, kAXStringForRangeParameterizedAttribute as CFString, axRange, &value)
                == .success
        else { return nil }
        return value as? String
    }

    static func focusedElement(processIdentifier: pid_t) -> AXUIElement? {
        let application = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(application, timeout)
        var focused: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                application, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
            let focused,
            CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return nil }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, timeout)
        return element
    }

    private static func stringAttribute(_ attribute: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
            let value,
            CFGetTypeID(value) == CFStringGetTypeID()
        else { return nil }
        return value as? String
    }
}
