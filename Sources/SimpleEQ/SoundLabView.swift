import SwiftUI

/// Sound Lab の 1 機能。面のタブの 1 つとして出る。
struct SoundLabView: View {
    @ObservedObject var viewModel: EQViewModel
    let feature: SoundLabFeature

    private var isOn: Bool { viewModel.soundLab[keyPath: feature.enabledKeyPath] }
    /// 行が操作を受ける状態か。行ごとの条件はこの内側で効く。
    private var rowsAreLive: Bool { isOn && viewModel.processingInEffect }

    /// 空間のボタンは幅を揃える。名前を変えれば追随する。
    private static let roomButtonWidth = EQLayout.choiceButtonWidth(
        fitting: LiveSimulationRoom.allCases.map(\.title),
        fontSize: EQLayout.SoundLab.choiceButtonFontSize
    )

    /// 面の幅は、いちばん広い操作である空間のボタン列が収まるぶんだけ取る。
    private static let panelWidth: CGFloat = {
        let count = CGFloat(LiveSimulationRoom.allCases.count)
        let rooms = roomButtonWidth * count + EQLayout.SoundLab.choiceButtonSpacing * (count - 1)
        return EQLayout.SoundLab.labelWidth + EQLayout.panelRowSpacing * 2 + rooms
            + EQLayout.SoundLab.panelWidthSlack
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: EQLayout.SoundLab.detailHeaderGap) {
            detailHeader
                .opacity(viewModel.processingInEffect ? 1 : EQLayout.disabledOpacity)
            rows(for: feature)
                .disabled(!isOn)
                .opacity(rowsAreLive ? 1 : EQLayout.disabledOpacity)
            Spacer(minLength: 0)
        }
        // 設定が音へ届かない間は、他の操作系と同じく沈めて拒否する。
        .allowsHitTesting(viewModel.processingInEffect)
        .frame(maxWidth: Self.panelWidth, alignment: .topLeading)
        .padding(.horizontal, EQLayout.SoundLab.horizontalInset)
        .padding(.bottom, EQLayout.SoundLab.bottomInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - 見出しの帯

    private var detailHeader: some View {
        let shape = RoundedRectangle(cornerRadius: EQLayout.SoundLab.headerBandCornerRadius)
        return HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(feature.title).font(.system(size: 14, weight: .bold))
                Text(feature.summary)
                    .font(.system(size: 11.5))
                    .foregroundColor(EQLayout.Palette.faint)
            }
            Spacer(minLength: 0)
            SettingsToggle(isOn: binding(feature.enabledKeyPath))
        }
        .padding(.horizontal, EQLayout.SoundLab.headerBandHorizontalPadding)
        .padding(.vertical, EQLayout.SoundLab.headerBandVerticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            shape.fill(
                isOn
                    ? AnyShapeStyle(EQLayout.Palette.activeButtonGradient)
                    : AnyShapeStyle(Color.white.opacity(0.05))
            )
        )
        .overlay(
            shape.stroke(
                isOn ? EQLayout.Palette.cyan.opacity(0.6) : EQLayout.Palette.buttonLine, lineWidth: 1
            )
        )
        // 帯のどこを押しても入り切りする。スイッチはその中で自分の押下を受ける。
        .contentShape(shape)
        .pointerStyle(.link)
        .onTapGesture { viewModel.soundLab[keyPath: feature.enabledKeyPath].toggle() }
    }

    @ViewBuilder
    private func rows(for feature: SoundLabFeature) -> some View {
        switch feature {
        case .liveSimulation: liveSimulationRows
        case .stereoExpander: stereoExpanderRows
        case .bassHarmonics: bassHarmonicsRows
        case .trebleExciter: trebleExciterRows
        case .loudness: loudnessRows
        }
    }

    @ViewBuilder
    private var liveSimulationRows: some View {
        PanelRow(
            title: "空間", subtitle: "広い空間ほど響きが長く残る",
            labelWidth: EQLayout.SoundLab.labelWidth
        ) {
            HStack(spacing: EQLayout.SoundLab.choiceButtonSpacing) {
                ForEach(LiveSimulationRoom.allCases, id: \.self) { room in
                    ChoiceButton(
                        room.title, width: Self.roomButtonWidth,
                        fontSize: EQLayout.SoundLab.choiceButtonFontSize,
                        isActive: viewModel.soundLab.liveSimulation.room == room
                    ) {
                        viewModel.soundLab.liveSimulation.room = room
                    }
                }
            }
        }
        sliderRow(
            "響きの量", subtitle: "原音と響きの割合。上げ切ると原音が消える",
            value: binding(\.liveSimulation.mix), spec: LiveSimulationSettings.mixRange
        ) { "\(Int($0))%" }
    }

    @ViewBuilder
    private var stereoExpanderRows: some View {
        sliderRow(
            "広がり", subtitle: "左右の差を強調する量。0 でほぼモノラル、1.0 が原音",
            value: binding(\.stereoExpander.width), spec: StereoExpanderSettings.widthRange
        ) { String(format: "%.1f", $0) }
        logSliderRow(
            "広げ始める周波数", subtitle: "この周波数より上を広げる。下限で全帯域が対象",
            value: binding(\.stereoExpander.crossover), spec: StereoExpanderSettings.crossoverRange
        )
        PanelRow(
            title: "位相の拡散", subtitle: "位相をずらして左右の相関を下げる",
            labelWidth: EQLayout.SoundLab.labelWidth
        ) {
            SettingsToggle(isOn: binding(\.stereoExpander.diffusionEnabled))
        }
        sliderRow(
            "拡散量", subtitle: "上げるほど位相のずれが大きくなる",
            value: binding(\.stereoExpander.diffusionAmount), spec: StereoExpanderSettings.diffusionRange,
            enabled: viewModel.soundLab.stereoExpander.diffusionEnabled
        ) { String(format: "%.2f", $0) }
    }

    @ViewBuilder
    private var bassHarmonicsRows: some View {
        sliderRow(
            "低域の境目", subtitle: "この周波数より下を取り出して倍音を作る",
            value: binding(\.bassHarmonics.cutoff), spec: BassHarmonicsSettings.cutoffRange
        ) { "\(Int($0)) Hz" }
        sliderRow(
            "倍音の量", subtitle: "上げるほど強く歪ませ、高い倍音まで作る",
            value: binding(\.bassHarmonics.drive), spec: BassHarmonicsSettings.driveRange
        ) { String(format: "%.1f", $0) }
        sliderRow(
            "混ぜる量", subtitle: "作った倍音を原音へ足す量。基音は足さない",
            value: binding(\.bassHarmonics.mix), spec: BassHarmonicsSettings.mixRange
        ) { "\(Int($0))%" }
    }

    @ViewBuilder
    private var trebleExciterRows: some View {
        sliderRow(
            "高域の境目", subtitle: "この周波数より上を取り出して倍音を作る",
            value: binding(\.trebleExciter.cutoff), spec: TrebleExciterSettings.cutoffRange
        ) { "\(Int($0)) Hz" }
        sliderRow(
            "倍音の量", subtitle: "上げるほど強く歪ませ、輪郭が立つ",
            value: binding(\.trebleExciter.drive), spec: TrebleExciterSettings.driveRange
        ) { String(format: "%.1f", $0) }
        sliderRow(
            "混ぜる量", subtitle: "作った倍音を原音へ足す量",
            value: binding(\.trebleExciter.mix), spec: TrebleExciterSettings.mixRange
        ) { "\(Int($0))%" }
    }

    @ViewBuilder
    private var loudnessRows: some View {
        sliderRow(
            "補正の上限", subtitle: "音量が最小のときの持ち上げ量。音量を上げるほど浅い",
            value: binding(\.loudness.amountDb), spec: LoudnessSettings.amountRange
        ) { EQLayout.formatSignedDb($0) }
        sliderRow(
            "低域の境目", subtitle: "この周波数より下を持ち上げる",
            value: binding(\.loudness.bassFrequency),
            spec: LoudnessSettings.bassFrequencyRange
        ) { "\(Int($0)) Hz" }
        sliderRow(
            "高域の境目", subtitle: "この周波数より上を持ち上げる",
            value: binding(\.loudness.trebleFrequency),
            spec: LoudnessSettings.trebleFrequencyRange
        ) { "\(Int($0)) Hz" }
        sliderRow(
            "戻る速さ", subtitle: "音が詰まって補正を下げたあと、戻すまでの時間",
            value: binding(\.loudness.headroomReleaseSeconds),
            spec: LoudnessSettings.headroomReleaseRange
        ) { String(format: "%.1f 秒", $0) }
    }

    // MARK: - 行

    private func binding<Value>(_ keyPath: WritableKeyPath<SoundLabSettings, Value>) -> Binding<Value> {
        Binding(
            get: { viewModel.soundLab[keyPath: keyPath] },
            set: { viewModel.soundLab[keyPath: keyPath] = $0 }
        )
    }

    private func sliderRow(
        _ title: String, subtitle: String? = nil,
        value: Binding<Double>, spec: SoundLabSpec.Range, enabled: Bool = true,
        format: @escaping (Double) -> String
    ) -> some View {
        panelSliderRow(
            title: title, subtitle: subtitle, labelWidth: EQLayout.SoundLab.labelWidth, value: value,
            range: spec.bounds, step: spec.step, defaultValue: spec.defaultValue, format: format
        )
        .disabled(!enabled)
        // 行を囲む側が既に沈んでいるならそれ以上は沈めない。二重に掛けると他より薄くなる。
        .opacity(enabled || !rowsAreLive ? 1 : EQLayout.disabledOpacity)
    }

    /// 周波数は低い側の分解能が要るため、つまみの位置を対数で割り当てる。
    private func logSliderRow(
        _ title: String, subtitle: String? = nil,
        value: Binding<Double>, spec: SoundLabSpec.Range, enabled: Bool = true
    ) -> some View {
        let bounds = log10(spec.bounds.lowerBound)...log10(spec.bounds.upperBound)
        let position = Binding<Double>(
            get: { log10(min(spec.bounds.upperBound, max(spec.bounds.lowerBound, value.wrappedValue))) },
            set: { value.wrappedValue = (pow(10, $0) / spec.step).rounded() * spec.step }
        )
        return panelSliderRow(
            title: title, subtitle: subtitle, labelWidth: EQLayout.SoundLab.labelWidth,
            value: position, range: bounds,
            format: { "\(Int(pow(10, $0).rounded())) Hz" }
        ) {
            EmptyView()
        } trailing: {
            ResetDotButton { value.wrappedValue = spec.defaultValue }
        }
        .disabled(!enabled)
        // 行を囲む側が既に沈んでいるならそれ以上は沈めない。二重に掛けると他より薄くなる。
        .opacity(enabled || !rowsAreLive ? 1 : EQLayout.disabledOpacity)
    }
}
