import SwiftUI

#if os(macOS)
public struct SchematicCanvasView: NSViewRepresentable {
    public let document: SchematicDocument
    public var activeComponentDescriptorID: String?
    public var wireToolEnabled: Bool
    public var labelToolEnabled: Bool
    public var pendingLabelName: String

    public init(
        document: SchematicDocument,
        activeComponentDescriptorID: String? = nil,
        wireToolEnabled: Bool = false,
        labelToolEnabled: Bool = false,
        pendingLabelName: String = "NET"
    ) {
        self.document = document
        self.activeComponentDescriptorID = activeComponentDescriptorID
        self.wireToolEnabled = wireToolEnabled
        self.labelToolEnabled = labelToolEnabled
        self.pendingLabelName = pendingLabelName
    }

    public func makeNSView(context: Context) -> SchematicCanvas {
        let view = SchematicCanvas()
        apply(to: view)
        return view
    }

    public func updateNSView(_ nsView: SchematicCanvas, context: Context) {
        apply(to: nsView)
    }

    private func apply(to view: SchematicCanvas) {
        view.document = document
        view.activeComponentDescriptorID = activeComponentDescriptorID
        view.wireToolEnabled = wireToolEnabled
        view.labelToolEnabled = labelToolEnabled
        view.pendingLabelName = pendingLabelName
    }
}
#else
public struct SchematicCanvasView: UIViewRepresentable {
    public let document: SchematicDocument
    public var activeComponentDescriptorID: String?
    public var wireToolEnabled: Bool
    public var labelToolEnabled: Bool
    public var pendingLabelName: String

    public init(
        document: SchematicDocument,
        activeComponentDescriptorID: String? = nil,
        wireToolEnabled: Bool = false,
        labelToolEnabled: Bool = false,
        pendingLabelName: String = "NET"
    ) {
        self.document = document
        self.activeComponentDescriptorID = activeComponentDescriptorID
        self.wireToolEnabled = wireToolEnabled
        self.labelToolEnabled = labelToolEnabled
        self.pendingLabelName = pendingLabelName
    }

    public func makeUIView(context: Context) -> SchematicCanvas {
        let view = SchematicCanvas()
        apply(to: view)
        return view
    }

    public func updateUIView(_ uiView: SchematicCanvas, context: Context) {
        apply(to: uiView)
    }

    private func apply(to view: SchematicCanvas) {
        view.document = document
        view.activeComponentDescriptorID = activeComponentDescriptorID
        view.wireToolEnabled = wireToolEnabled
        view.labelToolEnabled = labelToolEnabled
        view.pendingLabelName = pendingLabelName
    }
}
#endif
