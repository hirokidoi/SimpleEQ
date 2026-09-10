#!/bin/sh
# SimpleEQ 専用ドライバのインストール (要 sudo)
# アプリバンドル内から起動されるほか、ソースツリーからは `make driver` の後に直接実行できる:
# sudo Driver/install-driver.sh
set -e

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
BUNDLED_DRIVER="$SCRIPT_DIR/SimpleEQAudio.driver"
BUILT_DRIVER="$SCRIPT_DIR/SimpleEQAudio/build/Build/Products/Release/SimpleEQAudio.driver"
INSTALLED_DRIVER="/Library/Audio/Plug-Ins/HAL/SimpleEQAudio.driver"
# 共有メモリの置き場所は Shared/SimpleEQRingLayout.h を読み取って導出する (値をここへ複製しない)。
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

# 導入済みより古い版の配置を拒否する。降格を止めれば、旧ビルドのアプリが自分の同梱ドライバを再導入して version が往復する事故も止まる。
if [ -d "$INSTALLED_DRIVER" ]; then
  INSTALLED_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$INSTALLED_DRIVER/Contents/Info.plist" 2>/dev/null || true)
  NEW_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$DRIVER_BUNDLE/Contents/Info.plist" 2>/dev/null || true)
  if [ -n "$INSTALLED_VERSION" ] && [ -n "$NEW_VERSION" ]; then
    IS_DOWNGRADE=$(awk -v a="$NEW_VERSION" -v b="$INSTALLED_VERSION" 'BEGIN {
      na = split(a, A, "."); nb = split(b, B, ".");
      n = (na > nb) ? na : nb;
      for(i = 1; i <= n; i++) {
        ai = (i <= na) ? A[i] + 0 : 0;
        bi = (i <= nb) ? B[i] + 0 : 0;
        if(ai < bi) { print "1"; exit }
        if(ai > bi) { print "0"; exit }
      }
      print "0";
    }')
    if [ "$IS_DOWNGRADE" = "1" ]; then
      echo "error: 導入済みのドライバ (バージョン $INSTALLED_VERSION) より古いバージョン ($NEW_VERSION) は配置できません。" >&2
      exit 1
    fi
  fi
fi

# 共有メモリファイルの置き場所を事前作成する。
# 書き込みが要るのは作成する coreaudiod だけで、アプリは読み取り専用でしか開かない。
# ディレクトリの所有者を coreaudiod の account に揃えることで、他のローカルユーザによる削除・差し替えを防ぐ
# (読み取りは誰でもできる。ローカルユーザ間の保護であり、悪意ある相手からの保護ではない)。
mkdir -p "$SHM_DIR"

SHM_OWNER="_coreaudiod"
if ! id -u "$SHM_OWNER" >/dev/null 2>&1; then
  echo "error: アカウント $SHM_OWNER が見つかりません。$SHM_DIR の所有者を設定できません。" >&2
  exit 1
fi

if ! chown "$SHM_OWNER" "$SHM_DIR"; then
  echo "error: $SHM_DIR の所有者を $SHM_OWNER に設定できませんでした。" >&2
  exit 1
fi

if ! chmod 0755 "$SHM_DIR"; then
  echo "error: $SHM_DIR のパーミッションを設定できませんでした。" >&2
  exit 1
fi

# 残っているリングファイルは削除する。所有者が $SHM_OWNER と異なると、ドライバの再作成 (open(O_CREAT|O_RDWR)) が失敗し無音の原因になる。
SHM_FILE_NAME=$(sed -n 's/^#define[[:space:]]*kSimpleEQRingFileName[[:space:]]*"\(.*\)".*$/\1/p' "$LAYOUT_HEADER")
if [ -z "$SHM_FILE_NAME" ]; then
  echo "error: $LAYOUT_HEADER から kSimpleEQRingFileName を読み取れませんでした。" >&2
  exit 1
fi
rm -f "$SHM_DIR/$SHM_FILE_NAME"

rm -rf "$INSTALLED_DRIVER"
cp -R "$DRIVER_BUNDLE" "$(dirname "$INSTALLED_DRIVER")/"

killall coreaudiod || true

# coreaudiod が再起動すると、AirPlayXPCHelper が公開する HAL プラグインの登録数が倍になり、元の登録が片付かない。
# coreaudiod はシステムオブジェクトへのプロパティ要求 1 回ごとにこの一覧を複製して破棄するため、
# 登録が積み上がるほどあらゆる要求が重くなり、やがて飽和して音声系全体が応答しなくなる。
# 登録はこのヘルパに紐づくため coreaudiod を作り直しても解消しない。
# ここで落として増加の起点を一定に保つ。launchd が管理しているため停止は一時的。
killall AirPlayXPCHelper || true

echo "SimpleEQ 専用ドライバをインストールしました。音声関連のシステムプロセスを再起動しました。"
