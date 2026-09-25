# Thin CLI wrapper over the Xcode project (source of truth: project.yml).
# `make install` builds and copies the app into /Applications.
.PHONY: project build install uninstall uninstall-all test clean-test-prefs icon clean driver install-driver uninstall-driver

APP_NAME := SimpleEQ
BUNDLE_ID := com.hirokidoi.simpleeq
APP := build/Build/Products/Release/$(APP_NAME).app
DEST := /Applications/$(APP_NAME).app
SAVED_STATE := $(HOME)/Library/Saved Application State/$(BUNDLE_ID).savedState
LOGS_DIR := $(HOME)/Library/Logs/$(APP_NAME)
INSTALLED_DRIVER := $(shell sed -n 's/^INSTALLED_DRIVER="\(.*\)"$$/\1/p' Driver/uninstall-driver.sh)

DRIVER_NOTICE = @if [ -z "$(INSTALLED_DRIVER)" ]; then \
	    echo "Driver/uninstall-driver.sh からドライバの配置先を読み取れませんでした。"; exit 1; \
	elif [ -e "$(INSTALLED_DRIVER)" ]; then \
	    echo "専用ドライバ ($(INSTALLED_DRIVER)) は残っています。"; \
	    $(MAKE) --no-print-directory uninstall-driver; \
	fi

# driver / install-driver / uninstall-driver は、アプリを経由せずドライバを入れ替えるための経路。
# identifiers はソース (SimpleEQAudio.c) / project.pbxproj に直書きしてあるので、ここではビルド引数を渡さない。
DRIVER_BUILD_DIR := Driver/SimpleEQAudio/build
DRIVER_BUNDLE := $(DRIVER_BUILD_DIR)/Build/Products/Release/SimpleEQAudio.driver

APP_ICONSET := Resources/Assets.xcassets/AppIcon.appiconset
DRIVER_ICON := Driver/SimpleEQAudio/SimpleEQAudio/SimpleEQAudio.icns

# ドライバのアイコンが出るのは一覧の小さな枠だけなので、そこへ収まる寸法までを載せる。
DRIVER_ICON_PNGS := icon_16x16.png icon_16x16@2x.png icon_32x32.png icon_32x32@2x.png \
                    icon_128x128.png icon_128x128@2x.png icon_256x256.png

project:
	xcodegen generate

build: project
	xcodebuild -project SimpleEQ.xcodeproj -scheme SimpleEQ -configuration Release -derivedDataPath build build

install: build
	rm -rf "$(DEST)"
	mkdir -p "$(dir $(DEST))"
	cp -R "$(APP)" "$(DEST)"
	@echo "$(DEST) にインストールしました。"

uninstall:
	@if [ -e "$(DEST)" ]; then \
	    rm -rf "$(DEST)" && echo "$(DEST) を削除しました。"; \
	else \
	    echo "$(DEST) はインストールされていません。"; \
	fi
	$(DRIVER_NOTICE)

# 設定は cfprefsd が持っているため、plist を直接消さず defaults で消す。
uninstall-all:
	@if pgrep -x "$(APP_NAME)" >/dev/null; then \
	    echo "$(APP_NAME) が動いています。終了してからやり直してください。"; exit 1; \
	fi; \
	targets=""; \
	for path in "$(DEST)" "$(SAVED_STATE)" "$(LOGS_DIR)"; do \
	    if [ -e "$$path" ]; then targets="$$targets  $$path\n"; fi; \
	done; \
	has_defaults=0; \
	if defaults read "$(BUNDLE_ID)" >/dev/null 2>&1; then \
	    has_defaults=1; targets="$$targets  設定 (defaults のドメイン $(BUNDLE_ID))\n"; \
	fi; \
	if [ -z "$$targets" ]; then echo "削除するものはありません。"; exit 0; fi; \
	echo "次のものを削除します:"; printf "%b" "$$targets"; \
	printf "よろしいですか？ [y/N] "; read -r answer; \
	if [ "$$answer" != y ]; then echo "中止しました。"; exit 0; fi; \
	rm -rf "$(DEST)" "$(SAVED_STATE)" "$(LOGS_DIR)"; \
	if [ $$has_defaults -eq 1 ]; then defaults delete "$(BUNDLE_ID)"; fi; \
	echo "削除しました。"
	$(DRIVER_NOTICE)

# 検証は使い捨ての保存領域を作る。macOS はその名前ごとに設定のファイルを作り、中身を消してもファイル自体は残る。
# しかも設定を司る常駐が、検証の処理を終えた後に書き戻すため、消す前に書き戻しが済むのを待つ。
#
# 検証が失敗した場合は make がここで止まり、その回のぶんは残る。
# ただし、失敗が続く状況は一時的であるケースが多く、残るのも中身の無いファイルであるため許容する。
# 取りこぼしたぶんは clean-test-prefs を単体で叩けば回収できる。
test:
	swift test
	sleep 10 && $(MAKE) clean-test-prefs

# 検証が残した設定のファイルを消す。test と clean の両方から呼ぶため、対象の並びはここだけに置く。
# 対象は接頭辞で書き下す。変数にすると、空になったときに利用者の設定すべてへ広がる。
# 接頭辞は検証側が名前を組み立てる口 (TestDefaults) が付けるものと揃える。
# 検証が増えても名前がその口を通る限り、ここは 1 つのままでよい。
#
# 消す側は find に渡す。
# シェルの展開でファイル名を並べる形だと、取りこぼしが積み重なって対象が増えたときに引数の上限へ当たり、
# 検証が全件通っていても掃除の失敗で test が失敗扱いになる。
clean-test-prefs:
	find "$(HOME)/Library/Preferences" -maxdepth 1 -type f \
	     -name 'SimpleEQTests.*.plist' -delete

# Regenerate the app icon PNGs from Scripts/makeicon.swift into the asset catalog.
# Writes the throwaway compiled binary into build/, not tmp/: tmp/ is the project's shared scratch
# (holds retained references and other workflows' artifacts),
# and clean must be able to remove build output without touching it.
#
# ドライバ用の icns も同じターゲットで作る。分けると、絵を変えたときに片方だけが更新された状態になる。
icon:
	mkdir -p build
	swiftc Scripts/makeicon.swift -o build/makeicon
	build/makeicon $(APP_ICONSET)
	rm -rf build/SimpleEQAudio.iconset
	mkdir -p build/SimpleEQAudio.iconset
	cp $(addprefix $(APP_ICONSET)/,$(DRIVER_ICON_PNGS)) build/SimpleEQAudio.iconset/
	iconutil -c icns build/SimpleEQAudio.iconset -o $(DRIVER_ICON)
	rm -rf build/SimpleEQAudio.iconset

# ビルドの成果物に加え、検証が残した設定のファイルも消す。
# 後者は利用者のホーム配下にあるため、消す範囲がプロジェクト内に閉じない点に注意。
clean: clean-test-prefs
	rm -rf build SimpleEQ.xcodeproj $(DRIVER_BUILD_DIR)

# ドライバ本体のビルドのみ (sudo 不要)。成果物は $(DRIVER_BUNDLE)。
driver:
	xcodebuild -project Driver/SimpleEQAudio/SimpleEQAudio.xcodeproj -scheme SimpleEQAudio -configuration Release -derivedDataPath $(DRIVER_BUILD_DIR) build

# 配置手順をコマンドとして画面に提示するのみ (sudo を要するため実行はしない)。
install-driver: driver
	@echo "以下を手動で実行してください (sudo が必要です):"
	@echo "  sudo Driver/install-driver.sh"

uninstall-driver:
	@echo "以下を手動で実行してください (sudo が必要です):"
	@echo "  sudo Driver/uninstall-driver.sh"
