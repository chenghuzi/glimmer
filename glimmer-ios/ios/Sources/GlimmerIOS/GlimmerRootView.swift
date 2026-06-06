import SwiftUI

public struct GlimmerRootView: View {
    public init() {}

    public var body: some View {
        ContentView()
            .task {
                await ParityTestRunner.runIfConfigured()
                await PreprocessParityRunner.runIfConfigured()
            }
    }
}
