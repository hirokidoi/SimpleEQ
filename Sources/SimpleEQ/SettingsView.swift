import AppKit
import SwiftUI

/// Settings 画面。EQ ウィンドウの Settings ボタンから、EQ ウィンドウとは独立した
/// (自由に移動でき、幅は固定で高さのみ可変な) ウィンドウとして開く。各セクションは
/// @Published プロパティへ直結するため、操作は即座に反映される。
struct SettingsView: View {
    @ObservedObject var viewModel: EQViewModel
    var onDone: () -> Void
    /// スクロールが要らなくなる高さをウィンドウ側が上限に置けるよう、内容の超過量を知らせる。
    var onScrollOverflowChange: (CGFloat) -> Void

    @State private var loginItemEnabled = LoginItem.isEnabled
    @State private var showingResetPresetsConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            header
            MeasuredScrollView(onOverflowChange: onScrollOverflowChange) {
                VStack(alignment: .leading, spacing: 0) {
                    generalSection
                    gainSection
                    deviceSection
                    presetsSection
                    visualizerSection
                }
                .padding(.horizontal, 24)
            }
            footer
        }
        // 高さの ideal は与えない (スクロールビューの測りに影響するため)。
        .frame(
            minWidth: EQLayout.settingsWindowWidth, idealWidth: EQLayout.settingsWindowWidth, maxWidth: EQLayout.settingsWindowWidth,
            minHeight: EQLayout.settingsWindowMinHeight
        )
        .background(EQLayout.textPanelBackground)
        .foregroundColor(EQLayout.Palette.text)
        // Picker/Slider 等のネイティブ (AppKit 由来) コントロールは .foregroundColor を無視するため、
        // 明示的に dark を指定してネイティブコントロールの見た目も合わせる。
        .colorScheme(.dark)
    }

    // MARK: - ヘッダー / フッター

    private var header: some View {
        HStack {
            Text("Settings").font(.system(size: 15, weight: .bold))
            Spacer()
            Button(action: onDone) {
                Text("Done")
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundColor(Color(red: 0.03, green: 0.07, blue: 0.1))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .background(
                        Capsule().fill(LinearGradient(
                            colors: [EQLayout.Palette.cyan, EQLayout.Palette.cyanSoft],
                            startPoint: .leading, endPoint: .trailing
                        ))
                    )
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .background(EQLayout.Palette.panel)
        .overlay(alignment: .bottom) {
            Rectangle().fill(EQLayout.Palette.line).frame(height: 1)
        }
    }

    private var footer: some View {
        HStack {
            Text(versionText)
                .font(.system(size: 12.5))
                .foregroundColor(EQLayout.Palette.faint)
            Spacer()
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .overlay(alignment: .top) {
            Rectangle().fill(EQLayout.Palette.line).frame(height: 1)
        }
    }

    private var versionText: String { "SimpleEQ \(AppVersion.text)" }

    // MARK: - General

    private var generalSection: some View {
        PanelSection("General") {
            settingsRow(title: AlwaysOnTopMenu.title) {
                SettingsToggle(isOn: $viewModel.alwaysOnTop)
            }
            settingsRow(title: "起動時に EQ ウィンドウを表示") {
                SettingsToggle(isOn: $viewModel.showWindowOnLaunch)
            }
            settingsRow(title: "ビューモード") {
                HStack(spacing: 5) {
                    ForEach(ViewMode.allCases, id: \.self) { mode in
                        choiceButton(mode.title, isActive: viewModel.viewMode == mode) {
                            viewModel.viewMode = mode
                        }
                    }
                }
            }
            settingsRow(title: "ログイン時に自動起動") {
                SettingsToggle(isOn: Binding(
                    get: { loginItemEnabled },
                    set: { newValue in
                        if LoginItem.setEnabled(newValue) { loginItemEnabled = newValue }
                    }
                ))
            }
        }
    }

    // MARK: - Gain (即時反映)

    private var gainSection: some View {
        PanelSection("Gain") {
            sliderRow(
                title: "プリアンプ", subtitle: "プリセットを適用したときは、その設定内容に連動する",
                value: $viewModel.preampDb, range: EQSpec.DB_MIN...EQSpec.DB_MAX, step: 1,
                defaultValue: 0
            ) { EQLayout.formatSignedDb($0) }
            .disabled(!viewModel.processingInEffect)
            .opacity(viewModel.processingInEffect ? 1 : EQLayout.disabledOpacity)
        }
    }

    // MARK: - Device

    private var deviceSection: some View {
        PanelSection("Device") {
            settingsRow(
                title: "起動時の出力デバイス", subtitle: "「自動選択」の場合は起動時の出力デバイスが自動的に選択される"
            ) {
                // このPickerは次回起動時に使う既定値の永続化のみを行い、現在の出力先には影響しない。
                sharedOutputDevicePicker(
                    selection: $viewModel.persistedDefaultOutputDeviceUID,
                    options: viewModel.availableOutputDeviceOptions,
                    autoLabel: "自動選択",
                    fallbackLabel: "選択中のデバイス (現在検出できません)"
                )
                ResetDotButton { viewModel.persistedDefaultOutputDeviceUID = nil }
            }
            settingsRow(
                title: "出力デバイスの自動追従",
                subtitle: "OS 側で出力先デバイスを切り替えたときにも自動的に追従する"
            ) {
                SettingsToggle(isOn: $viewModel.adoptsSystemOutputSelection)
            }
            settingsRow(title: "取り込み専用ドライバ", subtitle: "検出されない時は専用ドライバをインストール（管理者権限が必要）してアプリの再起動が必要") {
                DriverStatusRow(viewModel: viewModel)
            }
        }
    }

    // MARK: - Presets

    private var presetsSection: some View {
        PanelSection("Presets") {
            settingsRow(title: "プリセットの初期化", subtitle: "現在登録されている内容をすべて削除して初期値に戻す") {
                Button {
                    showingResetPresetsConfirmation = true
                } label: {
                    Text("初期化実行")
                        .font(.system(size: 13))
                        .foregroundColor(EQLayout.Palette.faint)
                        .frame(maxWidth: 100)
                        .padding(.vertical, 10)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(EQLayout.Palette.buttonLine, lineWidth: 1))
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .destructiveConfirmationAlert(
                    "プリセットを初期化しますか？", isPresented: $showingResetPresetsConfirmation,
                    confirmTitle: "初期化", onConfirm: viewModel.resetAllPresets
                )
            }

            levelRow(
                title: "フェード速度", subtitle: "ハンドルの表示/非表示の速さ", level: $viewModel.handleFadeLevel,
                scale: EQLayout.Tuning.handleFade
            )
            levelRow(
                title: "プレビュー追従速度", subtitle: "プリセット hover 時のカーブ追従", level: $viewModel.handlePreviewLevel,
                scale: EQLayout.Tuning.handlePreview
            )
        }
    }

    // MARK: - Visualizer (即時反映)

    private var visualizerFpsChoiceBinding: Binding<Double> {
        Binding(
            get: { Double(Self.visualizerFpsChoiceIndex(of: viewModel.visualizerFps)) },
            set: { viewModel.visualizerFps = EQLayout.Tuning.visualizerFpsChoices[Int($0)] }
        )
    }

    private static func visualizerFpsChoiceIndex(of fps: Double) -> Int {
        EQLayout.Tuning.visualizerFpsChoices.firstIndex(of: fps)
            ?? EQLayout.Tuning.visualizerFpsChoices.firstIndex(of: EQLayout.Tuning.visualizerFpsDefault)!
    }

    private var visualizerSection: some View {
        PanelSection("Visualizer") {
            settingsRow(title: "マスターレベルメーター表示", subtitle: "L/R 各チャンネルのレベルメーターを表示") {
                SettingsToggle(isOn: $viewModel.showLevelMeter)
            }

            sliderRow(
                title: "最大フレームレート", subtitle: "描画フレームレートの最大値",
                value: visualizerFpsChoiceBinding,
                range: 0...Double(EQLayout.Tuning.visualizerFpsChoices.count - 1), step: 1,
                defaultValue: Double(Self.visualizerFpsChoiceIndex(of: EQLayout.Tuning.visualizerFpsDefault))
            ) { "\(Int(EQLayout.Tuning.visualizerFpsChoices[Int($0)])) fps" }

            sliderRow(
                title: "レベルレンジ下限", subtitle: "静かな音への感度",
                value: $viewModel.floorDb, range: EQLayout.Tuning.floorDbRange, step: EQLayout.Tuning.floorDbStep,
                defaultValue: EQLayout.Tuning.floorDbDefault
            ) { "\(Int($0)) dBFS" }

            levelRow(
                title: "立ち上がり速度", subtitle: "アタックの機敏さ", level: $viewModel.attackLevel,
                scale: EQLayout.Tuning.attack
            )
            levelRow(
                title: "下がり速度", subtitle: "減衰時の機敏さ", level: $viewModel.releaseLevel,
                scale: EQLayout.Tuning.release
            )

            settingsRow(title: "ピークホールド表示", subtitle: "各バンドのピークインジケーターを表示") {
                SettingsToggle(isOn: $viewModel.peakHoldEnabled)
            }
            Group {
                sliderRow(
                    title: "ピーク保持時間", subtitle: "ピーク到達後、下がり始めるまでの時間",
                    value: $viewModel.peakHoldSeconds, range: EQLayout.Tuning.peakHoldSecondsRange, step: EQLayout.Tuning.peakHoldSecondsStep,
                    defaultValue: EQLayout.Tuning.peakHoldSecondsDefault
                ) { "\(Int(($0 * 1000).rounded())) ms" }
                sliderRow(
                    title: "ピーク減衰速度", subtitle: "保持時間経過後にピークが下がる速さ",
                    value: $viewModel.peakDecayDbPerSec, range: EQLayout.Tuning.peakDecayDbPerSecRange, step: EQLayout.Tuning.peakDecayDbPerSecStep,
                    defaultValue: EQLayout.Tuning.peakDecayDbPerSecDefault
                ) { $0 == 0 ? "減衰なし" : "\(Int($0)) dB/s" }
                sliderRow(
                    title: "ピークインジケーターの明るさ", subtitle: "バー本体の色から白へ寄せる度合い",
                    value: $viewModel.peakCapBrightenAmount, range: EQLayout.Tuning.peakCapBrightenAmountRange, step: EQLayout.Tuning.peakCapBrightenAmountStep,
                    defaultValue: EQLayout.Tuning.peakCapBrightenAmountDefault
                ) { "\(Int(($0 * 100).rounded()))%" }
            }
            .disabled(!viewModel.peakHoldEnabled)
            .opacity(viewModel.peakHoldEnabled ? 1 : EQLayout.disabledOpacity)
        }
    }

    // MARK: - 行ビルダー

    @ViewBuilder
    private func settingsRow<Control: View>(
        title: String, subtitle: String? = nil, @ViewBuilder control: @escaping () -> Control
    ) -> some View {
        PanelRow(title: title, subtitle: subtitle, control: control)
    }

    private func sliderRow(
        title: String, subtitle: String? = nil,
        value: Binding<Double>, range: ClosedRange<Double>, step: Double, defaultValue: Double,
        format: @escaping (Double) -> String
    ) -> some View {
        let steppedValue = steppedBinding(value, range: range, step: step)
        return settingsRow(title: title, subtitle: subtitle) {
            HStack(spacing: 10) {
                Slider(value: steppedValue, in: range).tint(EQLayout.Palette.cyan)
                Text(format(value.wrappedValue))
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(EQLayout.Palette.cyanSoft)
                    .frame(width: 72, alignment: .trailing)
                ResetDotButton { value.wrappedValue = defaultValue }
            }
        }
    }

    /// 既定へ戻す点は行ごとの既定を見る (項目によって既定の段が違うため、共通の段へ戻すと
    /// 起動直後の状態と食い違う)。
    private func levelRow(
        title: String, subtitle: String? = nil, level: Binding<Int>, scale: EQLayout.Tuning.LevelScale
    ) -> some View {
        settingsRow(title: title, subtitle: subtitle) {
            HStack(spacing: 5) {
                ForEach(1...scale.values.count, id: \.self) { lv in
                    levelButton(lv, isActive: level.wrappedValue == lv) { level.wrappedValue = lv }
                }
                ResetDotButton { level.wrappedValue = scale.defaultLevel }
            }
        }
    }

    private func levelButton(_ lv: Int, isActive: Bool, action: @escaping () -> Void) -> some View {
        choiceButton("\(lv)", width: 34, isActive: isActive, action: action)
    }

    /// 幅を渡さない場合は文字の幅に合わせる。
    private func choiceButton(
        _ title: String, width: CGFloat? = nil, isActive: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundColor(isActive ? EQLayout.Palette.cyanSoft : EQLayout.Palette.text)
                .padding(.horizontal, width == nil ? 12 : 0)
                .frame(width: width, height: 30)
                .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isActive ? AnyShapeStyle(EQLayout.Palette.activeButtonGradient) : AnyShapeStyle(Color.white.opacity(0.05)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isActive ? EQLayout.Palette.cyan.opacity(0.6) : EQLayout.Palette.buttonLine, lineWidth: 1)
        )
    }

}
