import ApplicationServices
import CoreGraphics

/// Thin wrappers over the Accessibility API, which is a C API with a lot of
/// ceremony around every read.
enum AXKit {

    static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success,
              let result, CFGetTypeID(result) == AXUIElementGetTypeID() else { return nil }
        return (result as! AXUIElement)
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success,
              let value = result as? String else { return nil }
        return value
    }

    static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success,
              let value = result as? Bool else { return nil }
        return value
    }

    static func children(_ element: AXUIElement) -> [AXUIElement] {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &result) == .success,
              let array = result as? [AXUIElement] else { return [] }
        return array
    }

    static func frame(_ element: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionRef, let sizeRef,
              CFGetTypeID(positionRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeRef) == AXValueGetTypeID() else { return nil }

        var origin = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(positionRef as! AXValue, .cgPoint, &origin)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        return CGRect(origin: origin, size: size)
    }

    static func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success
        else { return false }
        return settable.boolValue
    }

    @discardableResult
    static func set(_ element: AXUIElement, _ attribute: String, _ value: CFTypeRef) -> Bool {
        AXUIElementSetAttributeValue(element, attribute as CFString, value) == .success
    }

    /// Apps disagree about where a control's human label lives, so try each of
    /// the places it plausibly is, in decreasing order of specificity.
    static func label(of element: AXUIElement) -> String? {
        let direct = [
            kAXPlaceholderValueAttribute,
            kAXTitleAttribute,
            kAXDescriptionAttribute,
            kAXHelpAttribute
        ]
        for attribute in direct {
            if let value = string(element, attribute), !value.isEmpty { return value }
        }
        // Some apps point at a separate label element instead of naming themselves.
        if let labelElement = self.element(element, kAXTitleUIElementAttribute) {
            for attribute in [kAXValueAttribute, kAXTitleAttribute] {
                if let value = string(labelElement, attribute), !value.isEmpty { return value }
            }
        }
        return nil
    }

    static func isSame(_ lhs: AXUIElement, _ rhs: AXUIElement) -> Bool {
        CFEqual(lhs, rhs)
    }
}
