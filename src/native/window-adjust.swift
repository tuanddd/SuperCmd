import AppKit
import ApplicationServices
import Foundation

private enum AdjustAction: String {
  case increaseSize10 = "increase-size-10"
  case decreaseSize10 = "decrease-size-10"
  case increaseLeft10 = "increase-left-10"
  case increaseRight10 = "increase-right-10"
  case increaseTop10 = "increase-top-10"
  case increaseBottom10 = "increase-bottom-10"
  case decreaseLeft10 = "decrease-left-10"
  case decreaseRight10 = "decrease-right-10"
  case decreaseTop10 = "decrease-top-10"
  case decreaseBottom10 = "decrease-bottom-10"
  case moveUp10 = "move-up-10"
  case moveDown10 = "move-down-10"
  case moveLeft10 = "move-left-10"
  case moveRight10 = "move-right-10"
}

private struct WindowFrame {
  var x: CGFloat
  var y: CGFloat
  var width: CGFloat
  var height: CGFloat
}

private struct OutputPayload: Encodable {
  let ok: Bool
  let error: String?
}

private let adjustRatio: CGFloat = 0.1
private let minWidth: CGFloat = 120
private let minHeight: CGFloat = 60

private func emit(ok: Bool, error: String? = nil) {
  let encoder = JSONEncoder()
  let payload = OutputPayload(ok: ok, error: error)
  guard let data = try? encoder.encode(payload),
        let text = String(data: data, encoding: .utf8),
        let bytes = (text + "\n").data(using: .utf8) else {
    fputs(ok ? "{\"ok\":true}\n" : "{\"ok\":false,\"error\":\"encode_failed\"}\n", stdout)
    return
  }
  FileHandle.standardOutput.write(bytes)
}

private func clamp(_ value: CGFloat, _ minValue: CGFloat, _ maxValue: CGFloat) -> CGFloat {
  if !value.isFinite { return minValue }
  if maxValue <= minValue { return minValue }
  return max(minValue, min(maxValue, value))
}

private func copyAttribute(_ element: AXUIElement, _ attribute: CFString) -> CFTypeRef? {
  var value: CFTypeRef?
  let status = AXUIElementCopyAttributeValue(element, attribute, &value)
  guard status == .success else { return nil }
  return value
}

private func attributeString(_ element: AXUIElement, _ attribute: CFString) -> String? {
  guard let raw = copyAttribute(element, attribute) else { return nil }
  if let str = raw as? String {
    let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
  return nil
}

private func decodePoint(_ raw: CFTypeRef?) -> CGPoint? {
  guard let raw else { return nil }
  guard CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
  let value = unsafeBitCast(raw, to: AXValue.self)
  guard AXValueGetType(value) == .cgPoint else { return nil }
  var point = CGPoint.zero
  guard AXValueGetValue(value, .cgPoint, &point) else { return nil }
  return point
}

private func decodeSize(_ raw: CFTypeRef?) -> CGSize? {
  guard let raw else { return nil }
  guard CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
  let value = unsafeBitCast(raw, to: AXValue.self)
  guard AXValueGetType(value) == .cgSize else { return nil }
  var size = CGSize.zero
  guard AXValueGetValue(value, .cgSize, &size) else { return nil }
  return size
}

private func focusedWindowElement() -> AXUIElement? {
  let systemWide = AXUIElementCreateSystemWide()
  guard let appRaw = copyAttribute(systemWide, kAXFocusedApplicationAttribute as CFString) else {
    return nil
  }
  guard CFGetTypeID(appRaw) == AXUIElementGetTypeID() else { return nil }
  let appElement = unsafeBitCast(appRaw, to: AXUIElement.self)

  if let focusedRaw = copyAttribute(appElement, kAXFocusedWindowAttribute as CFString),
     CFGetTypeID(focusedRaw) == AXUIElementGetTypeID() {
    let focused = unsafeBitCast(focusedRaw, to: AXUIElement.self)
    if let role = attributeString(focused, kAXRoleAttribute as CFString), role == kAXWindowRole as String {
      return focused
    }
  }

  if let windowsRaw = copyAttribute(appElement, kAXWindowsAttribute as CFString),
     let windows = windowsRaw as? [AXUIElement],
     let firstWindow = windows.first(where: { element in
       attributeString(element, kAXRoleAttribute as CFString) == (kAXWindowRole as String)
     }) {
    return firstWindow
  }

  if let focusedUiRaw = copyAttribute(systemWide, kAXFocusedUIElementAttribute as CFString),
     CFGetTypeID(focusedUiRaw) == AXUIElementGetTypeID() {
    var current = unsafeBitCast(focusedUiRaw, to: AXUIElement.self)
    for _ in 0..<8 {
      if let role = attributeString(current, kAXRoleAttribute as CFString), role == kAXWindowRole as String {
        return current
      }
      guard let parentRaw = copyAttribute(current, kAXParentAttribute as CFString),
            CFGetTypeID(parentRaw) == AXUIElementGetTypeID() else {
        break
      }
      current = unsafeBitCast(parentRaw, to: AXUIElement.self)
    }
  }

  return nil
}

private func readWindowFrame(_ window: AXUIElement) -> WindowFrame? {
  guard let position = decodePoint(copyAttribute(window, kAXPositionAttribute as CFString)),
        let size = decodeSize(copyAttribute(window, kAXSizeAttribute as CFString)) else {
    return nil
  }
  return WindowFrame(
    x: position.x,
    y: position.y,
    width: max(1, size.width),
    height: max(1, size.height)
  )
}

private func setWindowFrame(_ window: AXUIElement, frame: WindowFrame) -> Bool {
  var point = CGPoint(x: frame.x, y: frame.y)
  guard let pointValue = AXValueCreate(.cgPoint, &point) else { return false }
  let pointStatus = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, pointValue)

  var size = CGSize(width: frame.width, height: frame.height)
  guard let sizeValue = AXValueCreate(.cgSize, &size) else { return false }
  let sizeStatus = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)

  return pointStatus == .success && sizeStatus == .success
}

private func screenVisibleArea(for frame: WindowFrame) -> CGRect? {
  let center = CGPoint(x: frame.x + frame.width * 0.5, y: frame.y + frame.height * 0.5)
  for screen in NSScreen.screens {
    if screen.visibleFrame.contains(center) || screen.frame.contains(center) {
      return screen.visibleFrame
    }
  }
  if let main = NSScreen.main?.visibleFrame {
    return main
  }
  return NSScreen.screens.first?.visibleFrame
}

private func adjustedFrame(_ base: WindowFrame, action: AdjustAction) -> WindowFrame {
  let stepX = max(1, round(base.width * adjustRatio))
  let stepY = max(1, round(base.height * adjustRatio))
  var next = base

  switch action {
  case .increaseSize10:
    next = WindowFrame(
      x: base.x - round(stepX / 2),
      y: base.y - round(stepY / 2),
      width: base.width + stepX,
      height: base.height + stepY
    )
  case .decreaseSize10:
    next = WindowFrame(
      x: base.x + round(stepX / 2),
      y: base.y + round(stepY / 2),
      width: max(minWidth, base.width - stepX),
      height: max(minHeight, base.height - stepY)
    )
  case .increaseLeft10:
    let rightEdge = base.x + base.width
    let leftEdge = base.x - stepX
    next = WindowFrame(
      x: leftEdge,
      y: base.y,
      width: rightEdge - leftEdge,
      height: base.height
    )
  case .increaseRight10:
    next = WindowFrame(
      x: base.x,
      y: base.y,
      width: base.width + stepX,
      height: base.height
    )
  case .increaseTop10:
    let bottomEdge = base.y + base.height
    let topEdge = base.y - stepY
    next = WindowFrame(
      x: base.x,
      y: topEdge,
      width: base.width,
      height: bottomEdge - topEdge
    )
  case .increaseBottom10:
    next = WindowFrame(
      x: base.x,
      y: base.y,
      width: base.width,
      height: base.height + stepY
    )
  case .decreaseLeft10:
    let rightEdge = base.x + base.width
    let width = max(minWidth, base.width - stepX)
    next = WindowFrame(
      x: rightEdge - width,
      y: base.y,
      width: width,
      height: base.height
    )
  case .decreaseRight10:
    next = WindowFrame(
      x: base.x,
      y: base.y,
      width: max(minWidth, base.width - stepX),
      height: base.height
    )
  case .decreaseTop10:
    let bottomEdge = base.y + base.height
    let height = max(minHeight, base.height - stepY)
    next = WindowFrame(
      x: base.x,
      y: bottomEdge - height,
      width: base.width,
      height: height
    )
  case .decreaseBottom10:
    next = WindowFrame(
      x: base.x,
      y: base.y,
      width: base.width,
      height: max(minHeight, base.height - stepY)
    )
  case .moveUp10:
    next = WindowFrame(x: base.x, y: base.y - stepY, width: base.width, height: base.height)
  case .moveDown10:
    next = WindowFrame(x: base.x, y: base.y + stepY, width: base.width, height: base.height)
  case .moveLeft10:
    next = WindowFrame(x: base.x - stepX, y: base.y, width: base.width, height: base.height)
  case .moveRight10:
    next = WindowFrame(x: base.x + stepX, y: base.y, width: base.width, height: base.height)
  }

  if let area = screenVisibleArea(for: base) {
    next.width = clamp(round(next.width), minWidth, max(minWidth, area.width))
    next.height = clamp(round(next.height), minHeight, max(minHeight, area.height))
    next.x = clamp(round(next.x), area.origin.x, area.origin.x + area.width - next.width)
    next.y = clamp(round(next.y), area.origin.y, area.origin.y + area.height - next.height)
  } else {
    next.width = max(minWidth, round(next.width))
    next.height = max(minHeight, round(next.height))
    next.x = round(next.x)
    next.y = round(next.y)
  }

  return next
}

private func run() {
  guard let rawAction = CommandLine.arguments.dropFirst().first,
        let action = AdjustAction(rawValue: rawAction) else {
    emit(ok: false, error: "invalid_action")
    return
  }

  guard AXIsProcessTrusted() else {
    emit(ok: false, error: "accessibility_not_trusted")
    return
  }

  guard let window = focusedWindowElement() else {
    emit(ok: false, error: "no_focused_window")
    return
  }

  guard let base = readWindowFrame(window) else {
    emit(ok: false, error: "window_frame_unavailable")
    return
  }

  let next = adjustedFrame(base, action: action)
  guard setWindowFrame(window, frame: next) else {
    emit(ok: false, error: "set_window_frame_failed")
    return
  }

  emit(ok: true)
}

run()
