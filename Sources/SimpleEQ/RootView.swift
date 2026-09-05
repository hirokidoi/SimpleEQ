import SwiftUI

/// 全体レイアウト (上部バー + 本体 {EQ プロット, L/R レベルメーター, プリセットレール})。
struct RootView: View {
    @ObservedObject var viewModel: EQViewModel
    @ObservedObject var mixer: MixerModel
    let mixerClock: MixerRenderClock?
    /// 独立ウィンドウを開く導線。option を押しながらの操作では Diagnostics を開く。
    var onOpenWindow: (WindowDestination) -> Void

    var body: some View {
        VStack(spacing: 0) {
            TopBarView(viewModel: viewModel, mixer: mixer, onOpenWindow: onOpenWindow)
            HStack(spacing: 0) {
                // L/R レベルメーター表示が OFF の間は、その列のビューを HStack から除去することで EQ 本体が広がる。
                ZStack(alignment: .topLeading) {
                    VisualizerLayerView(viewModel: viewModel)
                    HStack(spacing: 0) {
                        EQPlotView()
                        if viewModel.showLevelMeter {
                            LevelMeterColumnView()
                        }
                    }
                    VisualizerInteractionView(viewModel: viewModel)
                    if mixer.shown {
                        MixerView(model: mixer, viewModel: viewModel, clock: mixerClock)
                    }
                }
                PresetRailView(viewModel: viewModel, mixer: mixer, onOpenWindow: onOpenWindow)
            }
        }
        .background(RoundedRectangle(cornerRadius: EQLayout.windowCornerRadius).fill(EQLayout.Palette.bg))
        .foregroundColor(EQLayout.Palette.text)
    }
}
