import SwiftUI

#if os(macOS)
public struct SchematicCanvasView: NSViewRepresentable {
    public let document: SchematicDocument
    
    public init(document: SchematicDocument) {
        self.document = document
    }
    
    public func makeNSView(context: Context) -> SchematicCanvas {
        let view = SchematicCanvas()
        view.document = document
        return view
    }
    
    public func updateNSView(_ nsView: SchematicCanvas, context: Context) {
        nsView.document = document
    }
}
#else
public struct SchematicCanvasView: UIViewRepresentable {
    public let document: SchematicDocument
    
    public init(document: SchematicDocument) {
        self.document = document
    }
    
    public func makeUIView(context: Context) -> SchematicCanvas {
        let view = SchematicCanvas()
        view.document = document
        return view
    }
    
    public func updateUIView(_ uiView: SchematicCanvas, context: Context) {
        uiView.document = document
    }
}
#endif
