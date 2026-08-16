#!/bin/sh
# SimpleEQ 専用ドライバのインストール (要 sudo)
# アプリバンドル内から起動されるほか、ソースツリーからは `make driver` の後に直接実行できる:
# sudo Driver/install-driver.sh
set -e

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
BUNDLED_DRIVER="$SCRIPT_DIR/SimpleEQAudio.driver"
BUILT_DRIVER="$SCRIPT_DIR/SimpleEQAudio/build/Build/Products/Release/SimpleEQAudio.driver"
# 共有メモリの置き場所は Shared/SimpleEQRingLayout.h の kSimpleEQRingDirectoryPath を読み取って導出する (値をここへ複製しない)。
LAYOUT_HEADER="$SCRIPT_DIR/Shared/SimpleEQRingLayout.h"
SHM_DIR=$(sed -n 's/^#define[[:space:]]*kSimpleEQRingDirectoryPath[[:space:]]*"\(.*\)".*$/\1/p' "$LAYOUT_HEADER")

if [ -z "$SHM_DIR" ]; then
  echo "error: $LAYOUT_HEADER から kSimpleEQRingDirectoryPath を読み取れませんでした。" >&2
  exit 1
fi

if [ -d "$BUNDLED_DRIVER" ]; then
  DRIVER_BUNDLE="$BUNDLED_DRIVER"
elif [ -d "$BUILT_DRIVER" ]; then
  DRIVER_BUNDLE="$BUILT_DRIVER"
else
  echo "error: ドライバが見つかりません。$BUNDLED_DRIVER と $BUILT_DRIVER のいずれも存在しません。後者は 'make driver' で作られます。" >&2
  exit 1
fi

# 共有メモリファイルの置き場所を事前作成する。
# ドライバ (coreaudiod 配下、他ユーザ権限で動作しうる) とアプリ (ログインユーザ権限) の双方が同じファイルを開閉できる必要があり、
# 個人ローカル利用の前提下ではパーミッション制御をシンプルにするため world-writable にする
# (他ユーザ・他プロセスがリングへ任意の音声データを注入/読み取りできるリスクは許容する)。
mkdir -p "$SHM_DIR"
chmod 777 "$SHM_DIR"

rm -rf "/Library/Audio/Plug-Ins/HAL/SimpleEQAudio.driver"
cp -R "$DRIVER_BUNDLE" "/Library/Audio/Plug-Ins/HAL/"

killall coreaudiod || true

# coreaudiod が再起動すると、AirPlayXPCHelper が公開する HAL プラグインの登録数が倍になり、元の登録が片付かない。
# coreaudiod はシステムオブジェクトへのプロパティ要求 1 回ごとにこの一覧を複製して破棄するため、
# 登録が積み上がるほどあらゆる要求が重くなり、やがて飽和して音声系全体が応答しなくなる。
# 登録はこのヘルパに紐づくため coreaudiod を作り直しても解消しない。
# ここで落として増加の起点を一定に保つ。launchd が管理しているため停止は一時的。
killall AirPlayXPCHelper || true

echo "SimpleEQ 専用ドライバをインストールしました。音声関連のシステムプロセスを再起動しました。"
