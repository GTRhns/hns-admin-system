#!/usr/bin/env bash
# HNS Admin System 编译脚本 (Linux)
# 用法: ./compile.sh
# 依赖: amxxpc (AMX Mod X 编译器), reapi.inc, PersistentDataStorage.inc

set -e

# 脚本所在目录
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTING="$DIR/cstrike/addons/amxmodx/scripting"
SRC="$SCRIPTING/HnsAdminSuite.sma"
OUT="$SCRIPTING/HnsAdminSuite.amxx"

# 需要 include 目录(标准 + reapi + PDS)
INCLUDE_DIRS="$SCRIPTING/include"

echo "==> 编译 HnsAdminSuite.sma"
# 若 amxxpc 在 PATH 中则直接使用，否则尝试本地
if command -v amxxpc >/dev/null 2>&1; then
    amxxpc "$SRC" -o"$OUT" -i"$INCLUDE_DIRS"
else
    # 尝试使用仓库内或系统里已有的 amxxpc
    if [ -f "$SCRIPTING/amxxpc" ]; then
        "$SCRIPTING/amxxpc" "$SRC" -o"$OUT" -i"$INCLUDE_DIRS"
    else
        echo "未找到 amxxpc，请将 AMXX 编译器放入 PATH 或 $SCRIPTING/ 目录"
        exit 1
    fi
fi

echo "==> 编译完成: $OUT"