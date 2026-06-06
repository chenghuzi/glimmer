import SwiftUI

public struct GlimmerRootView: View {
    public init() {}

    public var body: some View {
        AppRootView()
            .task {
                await ParityTestRunner.runIfConfigured()
                await PreprocessParityRunner.runIfConfigured()
            }
    }
}
