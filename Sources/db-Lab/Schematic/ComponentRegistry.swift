import CoreGraphics

public struct PinDescriptor: Sendable {
    public let id: String
    public let name: String
    public let position: CGPoint // Relative to symbol origin
}

public struct ComponentDescriptor: Sendable {
    public let id: String
    public let prefix: String
    public let displayName: String
    public let pins: [PinDescriptor]
}

public final class ComponentRegistry: Sendable {
    public static let shared = ComponentRegistry()
    private let registry: [String: ComponentDescriptor]
    
    private init() {
        registry = [
            "resistor": ComponentDescriptor(
                id: "resistor", prefix: "R", displayName: "Resistor",
                pins: [
                    PinDescriptor(id: "1", name: "1", position: CGPoint(x: -40, y: 0)),
                    PinDescriptor(id: "2", name: "2", position: CGPoint(x: 40, y: 0))
                ]
            ),
            "ground": ComponentDescriptor(
                id: "ground", prefix: "GND", displayName: "Ground",
                pins: [PinDescriptor(id: "1", name: "1", position: CGPoint(x: 0, y: -20))]
            )
        ]
    }
    
    public func descriptor(for id: String) -> ComponentDescriptor? { registry[id] }
}
