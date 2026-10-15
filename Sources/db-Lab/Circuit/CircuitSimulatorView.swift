import SwiftUI

public struct CircuitSimulatorView: View {
    @StateObject private var document = SchematicDocument()
    
    public init() {}
    
    public var body: some View {
        VStack {
            HStack {
                Text("Nets found: \(document.nets.count)")
                Spacer()
            }
            .padding()
            
            SchematicCanvasView(document: document)
                .background(Color.white)
                .border(Color.gray)
        }
    }
}
