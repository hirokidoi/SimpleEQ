import AppKit
import SwiftUI

/// コンパクトビューの画面。
struct CompactRootView: View {
    @ObservedObject var viewModel: EQViewModel
    @ObservedObject var mixer: MixerModel

    @Environment(\.displayScale) private var displayScale

    private let labelFontSize: CGFloat = 10

    private static let labeledBands = Set(stride(from: 1, to: EQSpec.bandCount, by: 2))

    var body: some View {
        content.overlay(alignment: .topLeading) {
            CompactHideButton(viewModel: viewModel, mixer: mixer)
        }
    }

    @ViewBuilder
    private var content: some View {
        if mixer.shown {
            CompactMixerView(model: mixer, viewModel: viewModel)
        } else {
            visualizer
        }
    }

    private var visualizer: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                VisualizerLayerView(viewModel: viewModel, compact: true)
                HStack(spacing: 0) {
                    freqRow
                    if viewModel.showLevelMeter {
                        channelRow(contentWidth: proxy.size.width)
                    }
                }
            }
        }
        .padding(EdgeInsets(
            top: EQLayout.compactMargin, leading: EQLayout.compactMargin,
            bottom: EQLayout.compactMarginBottom, trailing: EQLayout.compactMargin
        ))
        .background(RoundedRectangle(cornerRadius: EQLayout.windowCornerRadius).fill(EQLayout.Palette.bg))
        .overlay {
            WindowDragArea(viewModel: viewModel, mixer: mixer) { viewModel.viewMode = .normal }
        }
    }

    private var freqRow: some View {
        VStack(spacing: 0) {
            Color.clear
            HStack(spacing: 0) {
                ForEach(Array(EQSpec.FREQS.indices), id: \.self) { band in
                    freqLabel(band: band)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: EQLayout.compactLabelRowHeight)
        }
    }

    @ViewBuilder
    private func freqLabel(band: Int) -> some View {
        if Self.labeledBands.contains(band) {
            label(EQPlotView.formatFrequency(EQSpec.FREQS[band]))
        } else {
            Color.clear
        }
    }

    private func channelRow(contentWidth: CGFloat) -> some View {
        let eqWidth = EQLayout.eqContentWidth(totalWidth: contentWidth, showLevelMeter: true, compact: true)
        let edgeInset = EQLayout.compactBarEdgeInset(
            eqWidth: eqWidth, pixelGrid: EQLayout.PixelGrid(scale: displayScale)
        )
        return VStack(spacing: 0) {
            Color.clear
            HStack(spacing: LevelMeterRenderer.channelGap(compact: true)) {
                label("L").frame(width: LevelMeterRenderer.barWidth(compact: true))
                label("R").frame(width: LevelMeterRenderer.barWidth(compact: true))
            }
            .padding(.trailing, edgeInset)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .frame(height: EQLayout.compactLabelRowHeight)
        }
        .frame(width: EQLayout.meterColumnWidth(compact: true))
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: labelFontSize))
            .foregroundColor(EQLayout.Palette.faint)
            .lineLimit(1)
    }
}
