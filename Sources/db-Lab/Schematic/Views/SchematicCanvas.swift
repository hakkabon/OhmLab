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

    private var zoom: CGFloat = 1
    private var pan: CGPoint = .zero
    private var dragStart: CGPoint = .zero
    private var panStart: CGPoint = .zero
    private var didDrag = false
    private var wireStart: GridPoint?

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

    private func drawContent(context: CGContext, rect: CGRect) {
        context.saveGState()
        context.translateBy(x: pan.x, y: pan.y)
        context.scaleBy(x: zoom, y: zoom)

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

        guard let document else {
            context.restoreGState()
            return
        }

        context.setStrokeColor(PlatformColor.black.cgColor)
        context.setLineWidth(2 / zoom)
        for wire in document.wires {
            guard let first = wire.points.first, wire.points.count > 1 else { continue }
            let path = CGMutablePath()
            path.move(to: first.toCGPoint())
            for point in wire.points.dropFirst() {
                path.addLine(to: point.toCGPoint())
            }
            context.addPath(path)
            context.strokePath()
        }

        for symbol in document.symbols {
            guard let descriptor = ComponentRegistry.shared.descriptor(for: symbol.descriptorId) else {
                continue
            }
            drawSymbol(symbol, descriptor: descriptor, in: context, selected: symbol.id == document.selectedSymbolID)
        }
        context.restoreGState()
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
            context.stroke(CGRect(x: -34, y: -19, width: 68, height: 38))
        }

        let path = CGMutablePath()
        switch descriptor.symbol {
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
        drawLabel(symbol.refDes, at: CGPoint(x: -18, y: -27))
        if let label = valueLabel(for: symbol, descriptor: descriptor) {
            drawLabel(label, at: CGPoint(x: -24, y: 16))
        }
        context.restoreGState()
    }

    private func drawLabel(_ string: String, at point: CGPoint) {
        #if os(macOS)
        NSAttributedString(
            string: string,
            attributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: PlatformColor.black]
        ).draw(at: point)
        #else
        NSAttributedString(
            string: string,
            attributes: [.font: UIFont.systemFont(ofSize: 10), .foregroundColor: PlatformColor.black]
        ).draw(at: point)
        #endif
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
        case .voltageSource, .currentSource:
            return "\(String(format: "%.3g", value)) \(parameter.unit)"
        case .ground:
            return nil
        }
    }

    private func screenToGrid(_ screenPoint: CGPoint) -> GridPoint {
        let worldPoint = CGPoint(x: (screenPoint.x - pan.x) / zoom, y: (screenPoint.y - pan.y) / zoom)
        return GridPoint(worldPoint)
    }

    private func handleCanvasTap(at point: CGPoint) {
        guard let document else { return }
        let gridPoint = screenToGrid(point)
        if let descriptorID = activeComponentDescriptorID {
            document.addComponent(descriptorId: descriptorID, at: gridPoint)
        } else if wireToolEnabled {
            if let start = wireStart {
                if start != gridPoint {
                    let points: [GridPoint]
                    if start.x == gridPoint.x || start.y == gridPoint.y {
                        points = [start, gridPoint]
                    } else {
                        points = [start, GridPoint(gridPoint.x, start.y), gridPoint]
                    }
                    document.addWire(WireSegment(points: points))
                }
                wireStart = nil
            } else {
                wireStart = gridPoint
            }
        } else {
            let worldPoint = gridPoint.toCGPoint()
            document.selectedSymbolID = document.symbols
                .reversed()
                .first(where: { hypot($0.position.toCGPoint().x - worldPoint.x, $0.position.toCGPoint().y - worldPoint.y) <= 40 })?
                .id
        }
        redraw()
    }

    #if os(macOS)
    public override func mouseDown(with event: NSEvent) {
        dragStart = convert(event.locationInWindow, from: nil)
        panStart = pan
        didDrag = false
    }

    public override func mouseDragged(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        if hypot(location.x - dragStart.x, location.y - dragStart.y) > 3 {
            didDrag = true
        }
        pan = CGPoint(x: panStart.x + location.x - dragStart.x, y: panStart.y + location.y - dragStart.y)
        redraw()
    }

    public override func mouseUp(with event: NSEvent) {
        guard !didDrag else { return }
        handleCanvasTap(at: convert(event.locationInWindow, from: nil))
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
    #else
    @objc private func handlePan(_ sender: UIPanGestureRecognizer) {
        let translation = sender.translation(in: self)
        if sender.state == .began {
            panStart = pan
        }
        pan = CGPoint(x: panStart.x + translation.x, y: panStart.y + translation.y)
        redraw()
    }

    @objc private func handlePinch(_ sender: UIPinchGestureRecognizer) {
        zoom = min(max(zoom * sender.scale, 0.1), 8)
        sender.scale = 1
        redraw()
    }

    @objc private func handleTap(_ sender: UITapGestureRecognizer) {
        handleCanvasTap(at: sender.location(in: self))
    }
    #endif
}
