import SwiftUI

/// ビジュアライザ領域を覆う面。上端のタブで中身を選ぶ。
struct MixerSurfaceView: View {
    @ObservedObject var model: MixerModel
    @ObservedObject var viewModel: EQViewModel
    let clock: MixerRenderClock?

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            content
                .padding(.top, EQLayout.SurfaceTab.contentGap)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    UnevenRoundedRectangle(bottomLeadingRadius: EQLayout.windowCornerRadius)
                        .fill(EQLayout.textPanelBackground)
                )
        }
        .foregroundColor(EQLayout.Palette.text)
        .colorScheme(.dark)
    }

    @ViewBuilder
    private var content: some View {
        switch model.tab {
        case .appMixer:
            MixerView(model: model, viewModel: viewModel, clock: clock)
        case .soundLab(let feature):
            SoundLabView(viewModel: viewModel, feature: feature)
        }
    }

    // MARK: - タブ列

    /// 重ね順がそのまま見え方になる。地 → 下端の線 → タブ の順に置き、
    /// 選んでいるタブの塗りがその線を覆うことで、中身と地続きに見える。
    /// 線はタブの隙間にだけ出るため、色はタブの枠と同じものを使う。
    private var tabBar: some View {
        ZStack(alignment: .bottom) {
            EQLayout.SurfaceTab.stripBackground
            Rectangle()
                .fill(EQLayout.SurfaceTab.lineColor)
                .frame(height: EQLayout.Mixer.separatorThickness)
            // 幅は全タブで揃える。名前の長さが選びやすさを左右しないようにする。
            HStack(alignment: .bottom, spacing: EQLayout.SurfaceTab.spacing) {
                ForEach(MixerSurfaceTab.allCases, id: \.self) { tab in
                    tabButton(tab)
                }
            }
            .padding(.horizontal, EQLayout.SurfaceTab.horizontalInset)
        }
        .frame(height: EQLayout.SurfaceTab.height)
    }

    private func tabButton(_ tab: MixerSurfaceTab) -> some View {
        let isActive = model.tab == tab
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: EQLayout.SurfaceTab.cornerRadius,
            topTrailingRadius: EQLayout.SurfaceTab.cornerRadius
        )
        return Button {
            model.select(tab: tab)
        } label: {
            Text(tab.title)
                .font(.system(size: 12, weight: isActive ? .bold : .medium))
                .foregroundColor(isActive ? EQLayout.Palette.cyanSoft : EQLayout.Palette.dim)
                .lineLimit(1)
                .padding(.horizontal, EQLayout.SurfaceTab.buttonHorizontalPadding)
                .frame(maxWidth: .infinity)
                .frame(height: EQLayout.SurfaceTab.tabHeight)
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .background(
            shape.fill(
                isActive ? EQLayout.textPanelBackground : EQLayout.SurfaceTab.idleTabBackground
            )
        )
        .overlay(shape.strokeBorder(EQLayout.SurfaceTab.lineColor, lineWidth: 1))
        // 選んでいるタブだけ下辺を中身と同色で塗り潰し、枠を切って中身と地続きにする。
        // 他のタブは枠の下辺がそのまま列の線を継ぐ。
        .overlay(alignment: .bottom) {
            if isActive {
                Rectangle()
                    .fill(EQLayout.textPanelBackground)
                    .frame(height: EQLayout.Mixer.separatorThickness)
            }
        }
    }
}
