import SwiftUI
#if os(macOS)
import AppKit
typealias PlatformView = NSView
typealias PlatformColor = NSColor
typealias PlatformBezierPath = NSBezierPath
#else
import UIKit
typealias PlatformView = UIView
typealias PlatformColor = UIColor
typealias PlatformBezierPath = UIBezierPath
#endif

public class SchematicCanvas: PlatformView {
    public var document: SchematicDocument? {
        didSet { redraw() }
    }
    
    private var zoom: CGFloat = 1.0
    private var pan: CGPoint = .zero
    private var isDragging = false
    private var dragStart: CGPoint = .zero
    private var panStart: CGPoint = .zero
    
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
    
    // --- DRAWING ---
    
    #if os(macOS)
    public override func draw(_ dirtyRect: NSRect) { drawContent(context: NSGraphicsContext.current!.cgContext, rect: dirtyRect) }
    #else
    public override func draw(_ rect: CGRect) { drawContent(context: UIGraphicsGetCurrentContext()!, rect: rect) }
    #endif
    
    private func drawContent(context: CGContext, rect: CGRect) {
        context.saveGState()
        context.translateBy(x: pan.x, y: pan.y)
        context.scaleBy(x: zoom, y: zoom)
        
        // 1. Draw Grid
        context.setFillColor(PlatformColor.lightGray.withAlphaComponent(0.3).cgColor)
        let gridSize = GridPoint.gridSize
        let startX = Int(rect.minX / zoom - pan.x / zoom) / Int(gridSize) - 1
        let endX = Int(rect.maxX / zoom - pan.x / zoom) / Int(gridSize) + 1
        let startY = Int(rect.minY / zoom - pan.y / zoom) / Int(gridSize) - 1
        let endY = Int(rect.maxY / zoom - pan.y / zoom) / Int(gridSize) + 1
        
        for x in startX...endX {
            for y in startY...endY {
                let p = GridPoint(x, y).toCGPoint()
                context.fillEllipse(in: CGRect(x: p.x - 1, y: p.y - 1, width: 2, height: 2))
            }
        }
        
        // 2. Draw Wires
        context.setStrokeColor(PlatformColor.black.cgColor)
        context.setLineWidth(2.0 / zoom)
        if let doc = document {
            for wire in doc.wires {
                if wire.points.count > 1 {
                    let path = PlatformBezierPath()
                    let p0 = wire.points[0].toCGPoint()
                    path.move(to: p0)
                    for i in 1..<wire.points.count {
                        path.addLine(to: wire.points[i].toCGPoint())
                    }
                    #if os(macOS)
                    path.stroke()
                    #else
                    context.addPath(path.cgPath)
                    context.strokePath()
                    #endif
                }
            }
            
            // 3. Draw Symbols
            for sym in doc.symbols {
                let p = sym.position.toCGPoint()
                let box = CGRect(x: p.x - 30, y: p.y - 15, width: 60, height: 30)
                context.setStrokeColor(PlatformColor.blue.cgColor)
                context.setLineWidth(1.0 / zoom)
                #if os(macOS)
                let path = PlatformBezierPath(rect: box)
                path.stroke()
                let text = NSAttributedString(string: sym.refDes, attributes: [.foregroundColor: PlatformColor.black])
                text.draw(at: CGPoint(x: p.x - 10, y: p.y - 5))
                #else
                context.stroke(rect) // simplified for iOS
                let text = NSAttributedString(string: sym.refDes, attributes: [.foregroundColor: UIColor.black])
                text.draw(at: CGPoint(x: p.x - 10, y: p.y - 5))
                #endif
            }
        }
        
        context.restoreGState()
    }
    
    // --- INTERACTION ---
    
    private func screenToGrid(_ screenPoint: CGPoint) -> GridPoint {
        let worldPoint = CGPoint(x: (screenPoint.x - pan.x) / zoom, y: (screenPoint.y - pan.y) / zoom)
        return GridPoint(worldPoint)
    }
    
    #if os(macOS)
    public override func mouseDown(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        isDragging = true
        dragStart = loc
        panStart = pan
    }
    
    public override func mouseDragged(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        pan = CGPoint(x: panStart.x + loc.x - dragStart.x, y: panStart.y + loc.y - dragStart.y)
        redraw()
    }
    
    public override func mouseUp(with event: NSEvent) {
        isDragging = false
    }
    
    public override func magnify(with event: NSEvent) {
        let factor = event.magnification + 1.0
        zoom *= factor
        redraw()
    }
    
    public override func scrollWheel(with event: NSEvent) {
        pan.x += event.deltaX
        pan.y -= event.deltaY
        redraw()
    }
    #else
    @objc func handlePan(_ sender: UIPanGestureRecognizer) {
        let translation = sender.translation(in: self)
        pan = CGPoint(x: panStart.x + translation.x, y: panStart.y + translation.y)
        if sender.state == .began { panStart = pan }
        redraw()
    }
    
    @objc func handlePinch(_ sender: UIPinchGestureRecognizer) {
        zoom *= sender.scale
        sender.scale = 1.0
        redraw()
    }
    
    @objc func handleTap(_ sender: UITapGestureRecognizer) {
        let loc = sender.location(in: self)
        let gridPoint = screenToGrid(loc)
        
        // Demo: Add a resistor or ground on tap
        if let doc = document {
            let count = doc.symbols.count
            let isGround = count % 3 == 2
            let sym = SymbolInstance(
                descriptorId: isGround ? "ground" : "resistor",
                refDes: isGround ? "GND" : "R\(count + 1)",
                position: gridPoint
            )
            doc.addSymbol(sym)
        }
    }
    
    // iOS touch pan start
    public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        panStart = pan
    }
    #endif
}
