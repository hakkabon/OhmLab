import CoreGraphics

public struct PinDescriptor {
    public let id: String
    public let name: String
    public let position: CGPoint // Relative to symbol origin
}

public struct ComponentDescriptor {
    public let id: String
    public let prefix: String
    public let displayName: String
    public let pins: [PinDescriptor]
}

public class ComponentRegistry {
    public static let shared = ComponentRegistry()
    private var registry: [String: ComponentDescriptor] = [:]
    
    private init() { registerDefaults() }
    
    public func descriptor(for id: String) -> ComponentDescriptor? { registry[id] }
    
    private func registerDefaults() {
        registry["resistor"] = ComponentDescriptor(
            id: "resistor", prefix: "R", displayName: "Resistor",
            pins: [
                PinDescriptor(id: "1", name: "1", position: CGPoint(x: -40, y: 0)),
                PinDescriptor(id: "2", name: "2", position: CGPoint(x: 40, y: 0))
            ]
        )
        registry["ground"] = ComponentDescriptor(
            id: "ground", prefix: "GND", displayName: "Ground",
            pins: [PinDescriptor(id: "1", name: "1", position: CGPoint(x: 0, y: -20))]
        )
    }
}
