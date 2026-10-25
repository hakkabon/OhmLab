import Testing
import OhmLabSimulationProtocol

@Suite("OhmLab 2.2 native Rust portability")
struct NativeRustPortabilityTests {
    @Test func frozenContractPublishesTheDirectRustScope() {
        #expect(NativeRustPortabilityContract.currentVersion == 1)
        #expect(NativeRustPortabilityContract.backendIdentifier == "rust-numeric-core")
        #expect(NativeRustPortabilityContract.implementationVersion ==
                "rust-numeric-core-0.34.0-native")
        #expect(NativeRustPortabilityContract.rustNumericCoreVersion == "0.34.0")
        #expect(NativeRustPortabilityContract.supportedAnalyses ==
                ["dc-operating-point", "ac-small-signal"])
    }
}
