import SwiftUI
#if os(macOS)
import AppKit
public typealias PlatformView = NSView
typealias PlatformColor = NSColor
#else
import UIKit
public typealias PlatformView = UIView
typealias PlatformColor = UIColor
#endif

public class SchematicCanvas: PlatformView {
    public var document: SchematicDocument? {
        didSet { redraw() }
    }
    public var activeComponentDescriptorID: String? {
        didSet { redraw() }
    }
    public var wireToolEnabled = false {
        didSet {
            if !wireToolEnabled { wireStart = nil }
            redraw()
        }
    }
    public var busToolEnabled = false {
        didSet {
            if !busToolEnabled { wireStart = nil }
            redraw()
        }
    }
    public var labelToolEnabled = false {
        didSet { redraw() }
    }
    public var pendingLabelName = "NET" {
        didSet { redraw() }
    }
    /// When set, the next tap places an instance of this sheet.
    public var pendingSubcircuitSheetId: UUID? {
        didSet { redraw() }
    }

    private var zoom: CGFloat = 1
    private var pan: CGPoint = .zero
    private var dragStart: CGPoint = .zero
    private var panStart: CGPoint = .zero
    private var didDrag = false
    private var wireStart: GridPoint?

    private var movingSymbolID: UUID?
    private var moveOffset: (x: Int, y: Int) = (0, 0)
    private var moveCheckpointed = false

    public override init(frame frameRect: CGRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        #if os(macOS)
        wantsLayer = true
        layer?.backgroundColor = PlatformColor.white.cgColor
        #else
        backgroundColor = .white
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:))))
        addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:))))
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap(_:))))
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
        #endif
    }

    private func redraw() {
        #if os(macOS)
        needsDisplay = true
        #else
        setNeedsDisplay()
        #endif
    }

    #if os(macOS)
    public override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        drawContent(context: context, rect: dirtyRect)
    }
    #else
    public override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        drawContent(context: context, rect: rect)
    }
    #endif

    // MARK: - Drawing

    private func drawContent(context: CGContext, rect: CGRect) {
        context.saveGState()
        context.translateBy(x: pan.x, y: pan.y)
        context.scaleBy(x: zoom, y: zoom)

        drawGrid(context: context, rect: rect)

        guard let document else {
            context.restoreGState()
            return
        }

        let wireColor = PlatformColor.black.cgColor
        for wire in document.wires {
            guard let first = wire.points.first, wire.points.count > 1 else { continue }
            let path = CGMutablePath()
            path.move(to: first.toCGPoint())
            for point in wire.points.dropFirst() {
                path.addLine(to: point.toCGPoint())
            }
            context.setStrokeColor(wire.isBus ? PlatformColor.systemBlue.cgColor : wireColor)
            context.setLineWidth((wire.isBus ? 5 : 2) / zoom)
            context.addPath(path)
            context.strokePath()
            if wire.id == document.selectedWireID {
                context.setStrokeColor(PlatformColor.systemGreen.cgColor)
                context.setLineWidth((wire.isBus ? 7 : 4) / zoom)
                context.addPath(path)
                context.strokePath()
            }
        }
        context.setStrokeColor(wireColor)
        context.setLineWidth(2 / zoom)

        for point in junctionPoints(in: document) {
            let center = point.toCGPoint()
            context.setFillColor(PlatformColor.black.cgColor)
            context.fillEllipse(in: CGRect(x: center.x - 3.5, y: center.y - 3.5, width: 7, height: 7))
        }

        let catalog = document.subcircuitCatalog
        for symbol in document.symbols {
            guard let descriptor = catalog.descriptor(for: symbol) else { continue }
            drawSymbol(symbol, descriptor: descriptor, in: context, selected: symbol.id == document.selectedSymbolID)
        }

        for label in document.netLabels {
            drawNetLabel(label, selected: label.id == document.selectedLabelID)
        }

        context.restoreGState()
    }

    private func drawGrid(context: CGContext, rect: CGRect) {
        context.setFillColor(PlatformColor.lightGray.withAlphaComponent(0.3).cgColor)
        let gridSize = GridPoint.gridSize
        let startX = Int(rect.minX / zoom - pan.x / zoom) / Int(gridSize) - 1
        let endX = Int(rect.maxX / zoom - pan.x / zoom) / Int(gridSize) + 1
        let startY = Int(rect.minY / zoom - pan.y / zoom) / Int(gridSize) - 1
        let endY = Int(rect.maxY / zoom - pan.y / zoom) / Int(gridSize) + 1
        for x in startX...endX {
            for y in startY...endY {
                let point = GridPoint(x, y).toCGPoint()
                context.fillEllipse(in: CGRect(x: point.x - 1, y: point.y - 1, width: 2, height: 2))
            }
        }
    }

    private func drawSymbol(
        _ symbol: SymbolInstance,
        descriptor: ComponentDescriptor,
        in context: CGContext,
        selected: Bool
    ) {
        let origin = symbol.position.toCGPoint()
        context.saveGState()
        context.translateBy(x: origin.x, y: origin.y)
        context.rotate(by: CGFloat(symbol.rotation) * .pi / 180)
        context.setStrokeColor(PlatformColor.systemBlue.cgColor)
        context.setLineWidth(2 / zoom)
        if selected {
            context.stroke(subcircuitSelectionRect(for: descriptor))
        }

        let path = CGMutablePath()
        switch descriptor.symbol {
        case .subcircuit:
            let halfWidth = SubcircuitInstance.halfWidth
            let rows = max(descriptor.pins.count, 1)
            let height = CGFloat(rows + 1) * SubcircuitInstance.pinSpacing
            path.addRect(CGRect(x: -halfWidth, y: -height / 2, width: halfWidth * 2, height: height))
        case .resistor:
            path.move(to: CGPoint(x: -40, y: 0))
            path.addLine(to: CGPoint(x: -20, y: 0))
            for index in 0..<6 {
                let x = CGFloat(-20 + (index + 1) * 40 / 7)
                path.addLine(to: CGPoint(x: x, y: index.isMultiple(of: 2) ? -8 : 8))
            }
            path.addLine(to: CGPoint(x: 20, y: 0))
            path.addLine(to: CGPoint(x: 40, y: 0))
        case .capacitor:
            path.move(to: CGPoint(x: -40, y: 0))
            path.addLine(to: CGPoint(x: -5, y: 0))
            path.move(to: CGPoint(x: -5, y: -12))
            path.addLine(to: CGPoint(x: -5, y: 12))
            path.move(to: CGPoint(x: 5, y: -12))
            path.addLine(to: CGPoint(x: 5, y: 12))
            path.move(to: CGPoint(x: 5, y: 0))
            path.addLine(to: CGPoint(x: 40, y: 0))
        case .inductor, .inductorSeries:
            path.move(to: CGPoint(x: -40, y: 0))
            path.addLine(to: CGPoint(x: -20, y: 0))
            for index in 0..<4 {
                let centerX = CGFloat(-15 + index * 10)
                path.addArc(
                    center: CGPoint(x: centerX, y: 0),
                    radius: 5,
                    startAngle: .pi,
                    endAngle: 0,
                    clockwise: false
                )
            }
            path.move(to: CGPoint(x: 20, y: 0))
            path.addLine(to: CGPoint(x: 40, y: 0))
        case .voltageSource, .currentSource:
            path.move(to: CGPoint(x: -40, y: 0))
            path.addLine(to: CGPoint(x: -12, y: 0))
            path.addEllipse(in: CGRect(x: -12, y: -12, width: 24, height: 24))
            path.move(to: CGPoint(x: 12, y: 0))
            path.addLine(to: CGPoint(x: 40, y: 0))
            if descriptor.symbol == .voltageSource {
                path.move(to: CGPoint(x: -4, y: -5))
                path.addLine(to: CGPoint(x: 4, y: -5))
                path.move(to: CGPoint(x: 0, y: -9))
                path.addLine(to: CGPoint(x: 0, y: -1))
                path.move(to: CGPoint(x: -4, y: 5))
                path.addLine(to: CGPoint(x: 4, y: 5))
            } else {
                path.move(to: CGPoint(x: 0, y: 6))
                path.addLine(to: CGPoint(x: 0, y: -6))
                path.move(to: CGPoint(x: -4, y: -2))
                path.addLine(to: CGPoint(x: 0, y: -6))
                path.addLine(to: CGPoint(x: 4, y: -2))
            }
        case .diode:
            path.move(to: CGPoint(x: -40, y: 0))
            path.addLine(to: CGPoint(x: -8, y: 0))
            path.move(to: CGPoint(x: -8, y: -10))
            path.addLine(to: CGPoint(x: -8, y: 10))
            path.addLine(to: CGPoint(x: 8, y: 0))
            path.addLine(to: CGPoint(x: -8, y: -10))
            path.move(to: CGPoint(x: 8, y: -10))
            path.addLine(to: CGPoint(x: 8, y: 10))
            path.move(to: CGPoint(x: 8, y: 0))
            path.addLine(to: CGPoint(x: 40, y: 0))
        case .npnTransistor, .pnpTransistor:
            // Base lead and bar.
            path.move(to: CGPoint(x: -40, y: 0))
            path.addLine(to: CGPoint(x: -10, y: 0))
            path.move(to: CGPoint(x: -10, y: -16))
            path.addLine(to: CGPoint(x: -10, y: 16))
            // Collector lead up to its pin.
            path.move(to: CGPoint(x: -10, y: -7))
            path.addLine(to: CGPoint(x: 22, y: -26))
            path.addLine(to: CGPoint(x: 40, y: -40))
            // Emitter lead down to its pin.
            path.move(to: CGPoint(x: -10, y: 7))
            path.addLine(to: CGPoint(x: 22, y: 26))
            path.addLine(to: CGPoint(x: 40, y: 40))
            // Emitter arrow: outward for NPN, inward for PNP.
            let outer = CGPoint(x: 22, y: 26)
            let inner = CGPoint(x: 8, y: 15)
            let tail = descriptor.symbol == .npnTransistor ? inner : outer
            let head = descriptor.symbol == .npnTransistor ? outer : inner
            let angle = atan2(head.y - tail.y, head.x - tail.x)
            path.move(to: tail)
            path.addLine(to: head)
            path.move(to: head)
            path.addLine(to: CGPoint(x: head.x - 8 * cos(angle - 0.5), y: head.y - 8 * sin(angle - 0.5)))
            path.move(to: head)
            path.addLine(to: CGPoint(x: head.x - 8 * cos(angle + 0.5), y: head.y - 8 * sin(angle + 0.5)))
        case .nmosTransistor, .pmosTransistor:
            // Gate lead and plate.
            path.move(to: CGPoint(x: -40, y: 0))
            path.addLine(to: CGPoint(x: -18, y: 0))
            path.move(to: CGPoint(x: -18, y: -15))
            path.addLine(to: CGPoint(x: -18, y: 15))
            // Channel, drawn in three segments to suggest enhancement mode.
            path.move(to: CGPoint(x: -8, y: -15))
            path.addLine(to: CGPoint(x: -8, y: -6))
            path.move(to: CGPoint(x: -8, y: -3))
            path.addLine(to: CGPoint(x: -8, y: 3))
            path.move(to: CGPoint(x: -8, y: 6))
            path.addLine(to: CGPoint(x: -8, y: 15))
            // Drain (top) lead to its pin.
            path.move(to: CGPoint(x: -8, y: -12))
            path.addLine(to: CGPoint(x: 16, y: -12))
            path.addLine(to: CGPoint(x: 40, y: -40))
            // Source (bottom) lead to its pin.
            path.move(to: CGPoint(x: -8, y: 12))
            path.addLine(to: CGPoint(x: 16, y: 12))
            path.addLine(to: CGPoint(x: 40, y: 40))
            // Bulk (middle) lead to its pin.
            path.move(to: CGPoint(x: -8, y: 0))
            path.addLine(to: CGPoint(x: 16, y: 0))
            path.addLine(to: CGPoint(x: 40, y: 0))
            // Bulk arrow: toward the channel for N-MOS, away for P-MOS.
            let arrowStart = descriptor.symbol == .nmosTransistor ? CGPoint(x: 4, y: 0) : CGPoint(x: -8, y: 0)
            let arrowEnd = descriptor.symbol == .nmosTransistor ? CGPoint(x: -8, y: 0) : CGPoint(x: 4, y: 0)
            let arrowAngle = atan2(arrowEnd.y - arrowStart.y, arrowEnd.x - arrowStart.x)
            path.move(to: arrowStart)
            path.addLine(to: arrowEnd)
            path.move(to: arrowEnd)
            path.addLine(to: CGPoint(x: arrowEnd.x - 7 * cos(arrowAngle - 0.5), y: arrowEnd.y - 7 * sin(arrowAngle - 0.5)))
            path.move(to: arrowEnd)
            path.addLine(to: CGPoint(x: arrowEnd.x - 7 * cos(arrowAngle + 0.5), y: arrowEnd.y - 7 * sin(arrowAngle + 0.5)))
        case .njfTransistor, .pjfTransistor:
            // Gate lead and plate.
            path.move(to: CGPoint(x: -40, y: 0))
            path.addLine(to: CGPoint(x: -18, y: 0))
            path.move(to: CGPoint(x: -18, y: -15))
            path.addLine(to: CGPoint(x: -18, y: 15))
            // Channel: a single continuous bar for a depletion device.
            path.move(to: CGPoint(x: -8, y: -15))
            path.addLine(to: CGPoint(x: -8, y: 15))
            // Drain (top) and source (bottom) leads to their pins.
            path.move(to: CGPoint(x: -8, y: -12))
            path.addLine(to: CGPoint(x: 16, y: -12))
            path.addLine(to: CGPoint(x: 40, y: -40))
            path.move(to: CGPoint(x: -8, y: 12))
            path.addLine(to: CGPoint(x: 16, y: 12))
            path.addLine(to: CGPoint(x: 40, y: 40))
            // Gate arrow: toward the channel for N-JFET, away for P-JFET.
            let gateTail = descriptor.symbol == .njfTransistor ? CGPoint(x: -22, y: 0) : CGPoint(x: -14, y: 0)
            let gateHead = descriptor.symbol == .njfTransistor ? CGPoint(x: -14, y: 0) : CGPoint(x: -22, y: 0)
            let gateAngle = atan2(gateHead.y - gateTail.y, gateHead.x - gateTail.x)
            path.move(to: gateTail)
            path.addLine(to: gateHead)
            path.move(to: gateHead)
            path.addLine(to: CGPoint(x: gateHead.x - 6 * cos(gateAngle - 0.5), y: gateHead.y - 6 * sin(gateAngle - 0.5)))
            path.move(to: gateHead)
            path.addLine(to: CGPoint(x: gateHead.x - 6 * cos(gateAngle + 0.5), y: gateHead.y - 6 * sin(gateAngle + 0.5)))
        case .ground:
            path.move(to: CGPoint(x: 0, y: -20))
            path.addLine(to: CGPoint(x: 0, y: -8))
            path.move(to: CGPoint(x: -12, y: -8))
            path.addLine(to: CGPoint(x: 12, y: -8))
            path.move(to: CGPoint(x: -8, y: -3))
            path.addLine(to: CGPoint(x: 8, y: -3))
            path.move(to: CGPoint(x: -4, y: 2))
            path.addLine(to: CGPoint(x: 4, y: 2))
        }
        context.addPath(path)
        context.strokePath()

        // Pin endpoints, so connection opportunities are visible.
        context.setFillColor(PlatformColor.systemRed.cgColor)
        for pin in descriptor.pins {
            let scaled = CGPoint(x: pin.position.x, y: pin.position.y)
            context.fillEllipse(in: CGRect(x: scaled.x - 2.5, y: scaled.y - 2.5, width: 5, height: 5))
        }

        if descriptor.symbol == .subcircuit {
            let height = CGFloat(max(descriptor.pins.count, 1) + 1) * SubcircuitInstance.pinSpacing
            drawLabel(symbol.refDes, at: CGPoint(x: -18, y: -height / 2 - 18))
            drawLabel(descriptor.displayName, at: CGPoint(x: -SubcircuitInstance.halfWidth + 6, y: -8))
        } else {
            drawLabel(symbol.refDes, at: CGPoint(x: -18, y: -27))
            if let label = valueLabel(for: symbol, descriptor: descriptor) {
                drawLabel(label, at: CGPoint(x: -24, y: 16))
            }
        }
        context.restoreGState()
    }

    private func subcircuitSelectionRect(for descriptor: ComponentDescriptor) -> CGRect {
        guard descriptor.symbol == .subcircuit else {
            return CGRect(x: -34, y: -19, width: 68, height: 38)
        }
        let rows = max(descriptor.pins.count, 1)
        let height = CGFloat(rows + 1) * SubcircuitInstance.pinSpacing
        return CGRect(x: -SubcircuitInstance.halfWidth, y: -height / 2, width: SubcircuitInstance.halfWidth * 2, height: height)
    }

    private func drawNetLabel(_ label: NetLabel, selected: Bool) {
        let point = label.position.toCGPoint()
        let string = attributed(label.name, bold: true, color: PlatformColor.systemPurple)
        let size = string.size()
        let origin = CGPoint(x: point.x + 4, y: point.y + 4)
        let box = CGRect(x: origin.x - 3, y: origin.y - 2, width: size.width + 6, height: size.height + 4)
        let context = currentContext()
        context?.setFillColor(PlatformColor.systemPurple.withAlphaComponent(selected ? 0.35 : 0.15).cgColor)
        context?.fill(box)
        context?.setStrokeColor(PlatformColor.systemPurple.cgColor)
        context?.setLineWidth(1 / zoom)
        context?.stroke(box)
        string.draw(at: origin)
    }

    private func currentContext() -> CGContext? {
        #if os(macOS)
        return NSGraphicsContext.current?.cgContext
        #else
        return UIGraphicsGetCurrentContext()
        #endif
    }

    private func drawLabel(_ string: String, at point: CGPoint) {
        attributed(string, bold: false, color: PlatformColor.black).draw(at: point)
    }

    private func attributed(_ string: String, bold: Bool, color: PlatformColor) -> NSAttributedString {
        #if os(macOS)
        let font = bold ? NSFont.boldSystemFont(ofSize: 11) : NSFont.systemFont(ofSize: 10)
        #else
        let font = bold ? UIFont.boldSystemFont(ofSize: 11) : UIFont.systemFont(ofSize: 10)
        #endif
        return NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
    }

    private func valueLabel(for symbol: SymbolInstance, descriptor: ComponentDescriptor) -> String? {
        guard let parameter = descriptor.parameters.first,
              let value = symbol.parameters[parameter.id] else {
            return nil
        }
        switch descriptor.symbol {
        case .resistor:
            return value >= 1_000
                ? String(format: "%.3g kΩ", value / 1_000)
                : String(format: "%.3g Ω", value)
        case .capacitor:
            if value >= 1e-3 { return String(format: "%.3g mF", value * 1e3) }
            if value >= 1e-6 { return String(format: "%.3g µF", value * 1e6) }
            if value >= 1e-9 { return String(format: "%.3g nF", value * 1e9) }
            return String(format: "%.3g pF", value * 1e12)
        case .inductor, .inductorSeries:
            return value >= 1
                ? String(format: "%.3g H", value)
                : String(format: "%.3g mH", value * 1e3)
        case .voltageSource:
            return sourceValueLabel(
                dc: symbol.parameters["dcVoltage"] ?? 0,
                ac: symbol.parameters["acMagnitude"] ?? 0,
                unit: "V"
            )
        case .currentSource:
            return sourceValueLabel(
                dc: symbol.parameters["dcCurrent"] ?? 0,
                ac: symbol.parameters["acMagnitude"] ?? 0,
                unit: "A"
            )
        case .diode:
            return String(format: "IS=%.0e A", value)
        case .npnTransistor, .pnpTransistor:
            let beta = symbol.parameters["forwardBeta"] ?? 0
            return String(format: "β=%.3g", beta)
        case .nmosTransistor, .pmosTransistor:
            let threshold = symbol.parameters["thresholdVoltage"] ?? 0
            return String(format: "Vt=%.3g V", threshold)
        case .njfTransistor, .pjfTransistor:
            let threshold = symbol.parameters["thresholdVoltage"] ?? 0
            return String(format: "Vgs(off)=%.3g V", threshold)
        case .ground, .subcircuit:
            return nil
        }
    }

    private func sourceValueLabel(dc: Double, ac: Double, unit: String) -> String {
        var parts: [String] = []
        if dc != 0 { parts.append("\(String(format: "%.3g", dc)) \(unit) DC") }
        if ac != 0 { parts.append("\(String(format: "%.3g", ac)) \(unit) AC") }
        return parts.isEmpty ? "0 \(unit)" : parts.joined(separator: " / ")
    }

    // MARK: - Junctions

    private func junctionPoints(in document: SchematicDocument) -> [GridPoint] {
        let conductionWires = document.wires.filter { !$0.isBus }
        let segments = conductionWires.flatMap(\.segments)
        var rayCount: [GridPoint: Int] = [:]
        var isTerminal: Set<GridPoint> = []

        for (start, end) in segments {
            isTerminal.insert(start)
            isTerminal.insert(end)
        }
        for wire in conductionWires {
            for vertex in wire.points {
                for (start, end) in segments {
                    if vertex == start || vertex == end {
                        rayCount[vertex, default: 0] += 1
                    } else if ConnectivityBuilder.liesOnSegment(vertex, start, end) {
                        rayCount[vertex, default: 0] += 2
                    }
                }
            }
        }
        let catalog = document.subcircuitCatalog
        for symbol in document.symbols {
            guard let descriptor = catalog.descriptor(for: symbol) else { continue }
            for entry in PinGeometry.pinLocations(for: symbol, descriptor: descriptor) {
                rayCount[entry.location, default: 0] += 1
                isTerminal.insert(entry.location)
            }
        }

        return rayCount.filter { $0.value >= 3 && isTerminal.contains($0.key) }
            .keys
            .sorted { ($0.x, $0.y) < ($1.x, $1.y) }
    }

    // MARK: - Hit testing

    private func screenToGrid(_ screenPoint: CGPoint) -> GridPoint {
        let worldPoint = CGPoint(x: (screenPoint.x - pan.x) / zoom, y: (screenPoint.y - pan.y) / zoom)
        return GridPoint(worldPoint)
    }

    private func symbolHit(at screenPoint: CGPoint) -> SymbolInstance? {
        guard let document else { return nil }
        let world = CGPoint(x: (screenPoint.x - pan.x) / zoom, y: (screenPoint.y - pan.y) / zoom)
        let catalog = document.subcircuitCatalog
        return document.symbols.reversed().first { symbol in
            let origin = symbol.position.toCGPoint()
            if symbol.isSubcircuitInstance, let descriptor = catalog.descriptor(for: symbol) {
                let height = CGFloat(max(descriptor.pins.count, 1) + 1) * SubcircuitInstance.pinSpacing
                let rect = CGRect(
                    x: origin.x - SubcircuitInstance.halfWidth - 8,
                    y: origin.y - height / 2 - 8,
                    width: SubcircuitInstance.halfWidth * 2 + 16,
                    height: height + 16
                )
                return rect.contains(world)
            }
            return hypot(origin.x - world.x, origin.y - world.y) <= 40
        }
    }

    private func wireHit(at screenPoint: CGPoint) -> WireSegment? {
        guard let document else { return nil }
        let world = CGPoint(x: (screenPoint.x - pan.x) / zoom, y: (screenPoint.y - pan.y) / zoom)
        for wire in document.wires.reversed() {
            for (start, end) in wire.segments {
                if distance(from: world, toSegment: start.toCGPoint(), end.toCGPoint()) <= 8 {
                    return wire
                }
            }
        }
        return nil
    }

    private func labelHit(at screenPoint: CGPoint) -> NetLabel? {
        guard let document else { return nil }
        let world = CGPoint(x: (screenPoint.x - pan.x) / zoom, y: (screenPoint.y - pan.y) / zoom)
        return document.netLabels.reversed().first { label in
            let origin = label.position.toCGPoint()
            return abs(origin.x - world.x) <= 24 && abs(origin.y - world.y) <= 12
        }
    }

    private func distance(from point: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(point.x - a.x, point.y - a.y) }
        let t = max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared))
        let projected = CGPoint(x: a.x + t * dx, y: a.y + t * dy)
        return hypot(point.x - projected.x, point.y - projected.y)
    }

    // MARK: - Interaction

    private func beginInteraction(at screenPoint: CGPoint) {
        dragStart = screenPoint
        panStart = pan
        didDrag = false
        movingSymbolID = nil
        moveCheckpointed = false

        guard activeComponentDescriptorID == nil, pendingSubcircuitSheetId == nil,
              !wireToolEnabled, !busToolEnabled, !labelToolEnabled,
              let symbol = symbolHit(at: screenPoint) else {
            return
        }
        let grid = screenToGrid(screenPoint)
        movingSymbolID = symbol.id
        moveOffset = (symbol.position.x - grid.x, symbol.position.y - grid.y)
    }

    private func continueInteraction(to screenPoint: CGPoint) {
        if let movingSymbolID {
            let location = hypot(screenPoint.x - dragStart.x, screenPoint.y - dragStart.y)
            if location > 3 { didDrag = true }
            guard didDrag else { return }
            if !moveCheckpointed {
                document?.checkpoint()
                moveCheckpointed = true
            }
            let grid = screenToGrid(screenPoint)
            document?.moveSymbol(
                id: movingSymbolID,
                to: GridPoint(grid.x + moveOffset.x, grid.y + moveOffset.y),
                recordUndo: false
            )
            redraw()
            return
        }

        let location = hypot(screenPoint.x - dragStart.x, screenPoint.y - dragStart.y)
        if location > 3 { didDrag = true }
        pan = CGPoint(x: panStart.x + screenPoint.x - dragStart.x, y: panStart.y + screenPoint.y - dragStart.y)
        redraw()
    }

    private func endInteraction(at screenPoint: CGPoint) {
        if movingSymbolID == nil, !didDrag {
            handleCanvasTap(at: screenPoint)
        }
        movingSymbolID = nil
        redraw()
    }

    private func handleCanvasTap(at point: CGPoint) {
        guard let document else { return }
        let gridPoint = screenToGrid(point)
        if let sheetId = pendingSubcircuitSheetId {
            document.addSubcircuitInstance(sheetId: sheetId, at: gridPoint)
        } else if let descriptorID = activeComponentDescriptorID {
            document.addComponent(descriptorId: descriptorID, at: gridPoint)
        } else if wireToolEnabled || busToolEnabled {
            if let start = wireStart {
                if start != gridPoint {
                    let points: [GridPoint]
                    if start.x == gridPoint.x || start.y == gridPoint.y {
                        points = [start, gridPoint]
                    } else {
                        points = [start, GridPoint(gridPoint.x, start.y), gridPoint]
                    }
                    document.addWire(WireSegment(points: points, isBus: busToolEnabled))
                }
                wireStart = nil
            } else {
                wireStart = gridPoint
            }
        } else if labelToolEnabled {
            document.addNetLabel(name: pendingLabelName, at: gridPoint)
        } else {
            if let symbol = symbolHit(at: point) {
                document.selectedSymbolID = symbol.id
                document.selectedWireID = nil
                document.selectedLabelID = nil
            } else if let wire = wireHit(at: point) {
                document.selectedWireID = wire.id
                document.selectedSymbolID = nil
                document.selectedLabelID = nil
            } else if let label = labelHit(at: point) {
                document.selectedLabelID = label.id
                document.selectedSymbolID = nil
                document.selectedWireID = nil
            } else {
                document.selectedSymbolID = nil
                document.selectedWireID = nil
                document.selectedLabelID = nil
            }
        }
        redraw()
    }

    #if os(macOS)
    public override var acceptsFirstResponder: Bool { true }

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        if event.clickCount == 2, let symbol = symbolHit(at: point), let reference = symbol.sheetRef {
            document?.enterSheet(id: reference)
            redraw()
            return
        }
        beginInteraction(at: point)
    }

    public override func mouseDragged(with event: NSEvent) {
        continueInteraction(to: convert(event.locationInWindow, from: nil))
    }

    public override func mouseUp(with event: NSEvent) {
        endInteraction(at: convert(event.locationInWindow, from: nil))
    }

    public override func magnify(with event: NSEvent) {
        zoom = min(max(zoom * (event.magnification + 1), 0.1), 8)
        redraw()
    }

    public override func scrollWheel(with event: NSEvent) {
        pan.x += event.deltaX
        pan.y -= event.deltaY
        redraw()
    }

    public override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case "\u{7f}", "\u{8}":
            document?.deleteSelection()
        case "r", "R":
            if let id = document?.selectedSymbolID { document?.rotateSymbol(id: id, by: 90) }
        default:
            super.keyDown(with: event)
        }
        redraw()
    }
    #else
    private var panMode = false

    @objc private func handlePan(_ sender: UIPanGestureRecognizer) {
        let location = sender.location(in: self)
        switch sender.state {
        case .began:
            if let symbol = symbolHit(at: location),
               activeComponentDescriptorID == nil, !wireToolEnabled, !labelToolEnabled {
                let grid = screenToGrid(location)
                movingSymbolID = symbol.id
                moveOffset = (symbol.position.x - grid.x, symbol.position.y - grid.y)
                moveCheckpointed = false
                panMode = false
            } else {
                panStart = pan
                dragStart = location
                panMode = true
            }
        case .changed:
            if panMode {
                let translation = sender.translation(in: self)
                pan = CGPoint(x: panStart.x + translation.x, y: panStart.y + translation.y)
                redraw()
            } else if let movingSymbolID {
                if !moveCheckpointed {
                    document?.checkpoint()
                    moveCheckpointed = true
                }
                let grid = screenToGrid(location)
                document?.moveSymbol(
                    id: movingSymbolID,
                    to: GridPoint(grid.x + moveOffset.x, grid.y + moveOffset.y),
                    recordUndo: false
                )
                redraw()
            }
        case .ended, .cancelled:
            movingSymbolID = nil
            panMode = false
        default:
            break
        }
    }

    @objc private func handlePinch(_ sender: UIPinchGestureRecognizer) {
        zoom = min(max(zoom * sender.scale, 0.1), 8)
        sender.scale = 1
        redraw()
    }

    @objc private func handleTap(_ sender: UITapGestureRecognizer) {
        handleCanvasTap(at: sender.location(in: self))
    }

    @objc private func handleDoubleTap(_ sender: UITapGestureRecognizer) {
        let location = sender.location(in: self)
        if let symbol = symbolHit(at: location), let reference = symbol.sheetRef {
            document?.enterSheet(id: reference)
            redraw()
        }
    }
    #endif
}
