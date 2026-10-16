import SwiftUI

#if os(macOS)
public struct SchematicCanvasView: NSViewRepresentable {
    public let document: SchematicDocument
    public var activeComponentDescriptorID: String?
    public var wireToolEnabled: Bool
    
    public init(
        document: SchematicDocument,
        activeComponentDescriptorID: String? = nil,
        wireToolEnabled: Bool = false
    ) {
        self.document = document
        self.activeComponentDescriptorID = activeComponentDescriptorID
        self.wireToolEnabled = wireToolEnabled
    }
    
    public func makeNSView(context: Context) -> SchematicCanvas {
        let view = SchematicCanvas()
        view.document = document
        view.activeComponentDescriptorID = activeComponentDescriptorID
        view.wireToolEnabled = wireToolEnabled
        return view
    }
    
    public func updateNSView(_ nsView: SchematicCanvas, context: Context) {
        nsView.document = document
        nsView.activeComponentDescriptorID = activeComponentDescriptorID
        nsView.wireToolEnabled = wireToolEnabled
    }
}
#else
public struct SchematicCanvasView: UIViewRepresentable {
    public let document: SchematicDocument
    public var activeComponentDescriptorID: String?
    public var wireToolEnabled: Bool
    
    public init(
        document: SchematicDocument,
        activeComponentDescriptorID: String? = nil,
        wireToolEnabled: Bool = false
    ) {
        self.document = document
        self.activeComponentDescriptorID = activeComponentDescriptorID
        self.wireToolEnabled = wireToolEnabled
    }
    
    public func makeUIView(context: Context) -> SchematicCanvas {
        let view = SchematicCanvas()
        view.document = document
        view.activeComponentDescriptorID = activeComponentDescriptorID
        view.wireToolEnabled = wireToolEnabled
        return view
    }
    
    public func updateUIView(_ uiView: SchematicCanvas, context: Context) {
        uiView.document = document
        uiView.activeComponentDescriptorID = activeComponentDescriptorID
        uiView.wireToolEnabled = wireToolEnabled
    }
}
#endif
