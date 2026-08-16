#!/bin/sh
# SimpleEQ 専用ドライバのアンインストール (要 sudo)
set -e

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
LAYOUT_HEADER="$SCRIPT_DIR/Shared/SimpleEQRingLayout.h"
SHM_DIR=$(sed -n 's/^#define[[:space:]]*kSimpleEQRingDirectoryPath[[:space:]]*"\(.*\)".*$/\1/p' "$LAYOUT_HEADER")
SHM_FILE_NAME=$(sed -n 's/^#define[[:space:]]*kSimpleEQRingFileName[[:space:]]*"\(.*\)".*$/\1/p' "$LAYOUT_HEADER")

if [ -z "$SHM_DIR" ] || [ -z "$SHM_FILE_NAME" ]; then
  echo "error: $LAYOUT_HEADER から kSimpleEQRingDirectoryPath/kSimpleEQRingFileName を読み取れませんでした。" >&2
  exit 1
fi

rm -rf "/Library/Audio/Plug-Ins/HAL/SimpleEQAudio.driver"

# 共有メモリファイルも削除する。
# ドライバがロードされていない間はアプリ側の起動時検出 (SharedRingReader.open) がこのファイルのヘッダだけを見て判定するため、
# 削除しないまま残すとアンインストール後もヘッダが有効なまま (実際には誰も書き込んでいない) 検出済みと誤判定されてしまう。
# 既にこのファイルを mmap 済みの実行中プロセスがあっても、unlink 後もその参照は有効なままアクセスでき (POSIX のセマンティクス)、
# 次回インストール時にはドライバが改めて作成し直すため、削除して実害はない。
rm -f "$SHM_DIR/$SHM_FILE_NAME"

killall coreaudiod || true

# coreaudiod が再起動すると、AirPlayXPCHelper が公開する HAL プラグインの登録数が倍になり、元の登録が片付かない。
# coreaudiod はシステムオブジェクトへのプロパティ要求 1 回ごとにこの一覧を複製して破棄するため、
# 登録が積み上がるほどあらゆる要求が重くなり、やがて飽和して音声系全体が応答しなくなる。
# 登録はこのヘルパに紐づくため coreaudiod を作り直しても解消しない。
# ここで落として増加の起点を一定に保つ。launchd が管理しているため停止は一時的。
killall AirPlayXPCHelper || true

echo "SimpleEQ 専用ドライバをアンインストールしました。音声関連のシステムプロセスを再起動しました。"
