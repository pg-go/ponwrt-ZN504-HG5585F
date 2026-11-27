#!/usr/bin/env bash
set -euo pipefail

# PonWrt-ZN504 Custom Package & Architecture Integration Script
# Integrates:
# - QWRT Recommended: Airoha PPE / EIP-93, CPUFreq, RAMFree, Diskman, TTYD, FileTransfer
# - QWRT Optional: Samba4, GecoosAC, WOL Ultra
# - Kahen Essence: Temperature RPC (/sbin/tempinfo), Footstrap Theme, Clean Feeds
# - LeoooChen Essence: Line-rate PPPoE / XG-PON offload & High Throughput Buffers
# - Honk eBPF removed for Moto-7 (Nikki single-core); Tailscale not used

echo "=== [PonWrt-ZN504] Preparing build dependencies and custom packages ==="

# 1. 确保 luci-app-airoha-npu (NPU/PPE SoC 状态监控) 处于可用状态
if [ ! -d "./package/luci-app-airoha-npu" ]; then
    echo "--> Cloning luci-app-airoha-npu..."
    git clone --depth 1 https://github.com/rchen14b/luci-app-airoha-npu.git ./package/luci-app-airoha-npu
else
    echo "[OK] luci-app-airoha-npu is present"
fi

# 2. 清理历史遗留 Momo 组件
rm -rf ./package/luci-app-momo 2>/dev/null || true
echo "[OK] Momo package removed"

# 3. 集成 Kahen 精华：自动连接 autocore 温度检测至 LuCI 状态界面
if [ -f "./scripts/integrate-temperature.py" ]; then
    echo "--> Running temperature integration..."
    python3 ./scripts/integrate-temperature.py . || true
fi

# 4. 集成 NNdroid 关键优化：EN7572 激光冷启动防抖 & LOID 补零方向与原始报文字节展示
TOP_DIR="$(pwd)"
if [ -d "./feeds/pon_drivers" ] && [ -f "$TOP_DIR/patches/01-pon-drivers-epon-laser-recovery.patch" ]; then
    echo "--> Applying EN7572 burst laser latch recovery patch to pon_drivers..."
    (cd feeds/pon_drivers && git apply --check "$TOP_DIR/patches/01-pon-drivers-epon-laser-recovery.patch" 2>/dev/null && git apply "$TOP_DIR/patches/01-pon-drivers-epon-laser-recovery.patch") || true
    ./scripts/feeds install -p pon_drivers -f || true
fi

if [ -d "./feeds/pon_userspace" ] && [ -f "$TOP_DIR/patches/02-pon-userspace-loid-padding-wire-view.patch" ]; then
    echo "--> Applying LOID padding & wire byte preview patch to pon_userspace..."
    (cd feeds/pon_userspace && git apply --check "$TOP_DIR/patches/02-pon-userspace-loid-padding-wire-view.patch" 2>/dev/null && git apply "$TOP_DIR/patches/02-pon-userspace-loid-padding-wire-view.patch") || true
    ./scripts/feeds install -p pon_userspace -f || true
fi

if [ -d "./feeds/pon_userspace" ] && [ -f "$TOP_DIR/patches/03-pon-userspace-iptv-bridge-mac-fix.patch" ]; then
    echo "--> Applying IPTV bridge MAC flipping root-fix patch to pon_userspace..."
    (cd feeds/pon_userspace && git apply --check "$TOP_DIR/patches/03-pon-userspace-iptv-bridge-mac-fix.patch" 2>/dev/null && git apply "$TOP_DIR/patches/03-pon-userspace-iptv-bridge-mac-fix.patch") || true
    ./scripts/feeds install -p pon_userspace -f || true
fi

# 5. 规避 Airoha 架构下非必要 feed 循环依赖 (如无用的 squeezelite 音频)
if [ -L "./package/feeds/packages/squeezelite" ]; then
    rm -f "./package/feeds/packages/squeezelite"
fi

# =========================================================
# 6. Moto-7 定制软件（来自 pg-go/OpenWrt-AN758X HG5585F-Moto）
#    Nikki 单核做代理（honk/sing-box 已去掉）。
#    只拉取 configs/release.config 第 8 节里 =y 的那几个；
#    feeds / 内核树已有的（natmap、upnp、iptv、usb-net、jq 等）不用拉。
# =========================================================
PKG_DIR="package/custom"
mkdir -p "$PKG_DIR"

clone() {  # clone <url> <dir> [branch]
  local url="$1" dir="$2" br="$3"
  [ -d "$dir" ] && { echo "已存在，跳过: $dir"; return 0; }
  echo "--- git clone $url -> $dir ---"
  if [ -n "$br" ]; then
    git clone --depth 1 -b "$br" "$url" "$dir" 2>&1 | tail -3
  else
    git clone --depth 1 "$url" "$dir" 2>&1 | tail -3
  fi
  if [ -d "$dir" ]; then
    echo "✅ 克隆成功: $dir"
    return 0
  fi
  echo "::error::克隆失败: $url"
  return 1
}

# --- EasyTier：easytier-noweb（预编译二进制）+ luci-app-easytier ---
# 源：EasyTier/luci-app-easytier（monorepo，拷出子目录；整仓丢进 package/custom
# 会让包名对不上）。本体不用 Rust 源码编译，Makefile 下载预编译二进制。
ET_TMP="$(mktemp -d)/easytier"
if ! clone https://github.com/EasyTier/luci-app-easytier "$ET_TMP" main; then
  echo "::error::EasyTier/luci-app-easytier 拉取失败，easytier-noweb / luci-app-easytier 会被 defconfig 剔除"
  exit 1
fi
for p in easytier-noweb luci-app-easytier; do
  if [ ! -f "$ET_TMP/$p/Makefile" ]; then
    echo "::error::$ET_TMP/$p/Makefile 不存在（上游改结构了？）"
    exit 1
  fi
  rm -rf "$PKG_DIR/$p"
  cp -a "$ET_TMP/$p" "$PKG_DIR/"
  echo "✅ 已拷贝: $p"
done
rm -rf "$ET_TMP"

# --- Nikki：mihomo 透明代理 + nikki 服务 + luci-app-nikki 界面 ---
# 源：nikkinikki-org/OpenWrt-nikki。包在三个子目录，拷出子目录。
# mihomo-meta（1.19.34，PROVIDES mihomo，Go 编译 with_gvisor，TUN 同 Homi）
# + nikki 服务 + luci-app-nikki 界面。mihomo-meta 是 Go 编译，
# 会给固件构建增加约 10 分钟。
NIKKI_TMP="$(mktemp -d)/nikki"
if ! clone https://github.com/nikkinikki-org/OpenWrt-nikki "$NIKKI_TMP" main; then
  echo "::error::nikkinikki-org/OpenWrt-nikki 拉取失败，mihomo-meta / nikki / luci-app-nikki 会被 defconfig 剔除"
  exit 1
fi
for p in mihomo-meta nikki luci-app-nikki; do
  if [ ! -f "$NIKKI_TMP/$p/Makefile" ]; then
    echo "::error::$NIKKI_TMP/$p/Makefile 不存在（上游改结构了？）"
    exit 1
  fi
  rm -rf "$PKG_DIR/$p"
  cp -a "$NIKKI_TMP/$p" "$PKG_DIR/"
  echo "✅ 已拷贝: $p"
done
rm -rf "$NIKKI_TMP"

# --- Aurora 主题 + 设置页 ---
# --- Aurora 主题 + 设置页 ---
# 源：eamonxg/luci-theme-aurora 与 eamonxg/luci-app-aurora-config（设置页，
# 要求主题 ≥1.2.0）。两个仓库根目录就是包体（Makefile 在根目录），整仓拷
# （去掉 .git）。注意：两仓默认分支是 master，不是 main。
for repo in luci-theme-aurora luci-app-aurora-config; do
  AU_TMP="$(mktemp -d)/aurora"
  if ! clone "https://github.com/eamonxg/$repo" "$AU_TMP" master; then
    echo "::error::eamonxg/$repo 拉取失败，$repo 会被 defconfig 剔除"
    exit 1
  fi
  if [ ! -f "$AU_TMP/Makefile" ]; then
    echo "::error::$AU_TMP/Makefile 不存在（上游改结构了？）"
    exit 1
  fi
  rm -rf "$PKG_DIR/$repo"
  cp -a "$AU_TMP" "$PKG_DIR/$repo"
  rm -rf "$PKG_DIR/$repo/.git"
  echo "✅ 已拷贝: $repo"
  rm -rf "$AU_TMP"
done

# --- luci-app-netpath（NetPath 仪表盘）---
# 源：pg-go/luci-app-netpath（用户自有项目）。包在子目录 luci-app-netpath/，
# 拷出子目录；默认分支 main。
NP_TMP="$(mktemp -d)/netpath"
if ! clone https://github.com/pg-go/luci-app-netpath "$NP_TMP" main; then
  echo "::error::pg-go/luci-app-netpath 拉取失败，luci-app-netpath 会被 defconfig 剔除"
  exit 1
fi
if [ ! -f "$NP_TMP/luci-app-netpath/Makefile" ]; then
  echo "::error::$NP_TMP/luci-app-netpath/Makefile 不存在（上游改结构了？）"
  exit 1
fi
rm -rf "$PKG_DIR/luci-app-netpath"
cp -a "$NP_TMP/luci-app-netpath" "$PKG_DIR/"
echo "✅ 已拷贝: luci-app-netpath"
rm -rf "$NP_TMP"

# --- luci-app-harbor-file-pro（HarborFile Pro 文件管理）---
# 源：whzhni1/luci-app-harbor-file-pro。包在子目录 luci-app-harbor-file-pro/，
# 拷出子目录；纯 ucode 应用无编译，依赖 rpcd/ucode 系列标准包。
# 钉在 v1.1.5（2026-11-26 教训）：上游 main 的 2.0.0（commit 8f83d18）
# 把 Makefile 尾部的 $(eval $(call BuildPackage,...)) 删了，只留
# include luci.mk，结果 make prepare-tmpinfo 扫不到它，构建直接报错退出。
# 1.1.5 是 2026-11-23 成功构建过的版本；2.0.0 上游修好前别放开。
HB_TMP="$(mktemp -d)/harbor"
if ! clone https://github.com/whzhni1/luci-app-harbor-file-pro "$HB_TMP" v1.1.5; then
  echo "::error::whzhni1/luci-app-harbor-file-pro 拉取失败，luci-app-harbor-file-pro 会被 defconfig 剔除"
  exit 1
fi
if [ ! -f "$HB_TMP/luci-app-harbor-file-pro/Makefile" ]; then
  echo "::error::$HB_TMP/luci-app-harbor-file-pro/Makefile 不存在（上游改结构了？）"
  exit 1
fi
rm -rf "$PKG_DIR/luci-app-harbor-file-pro"
cp -a "$HB_TMP/luci-app-harbor-file-pro" "$PKG_DIR/"
echo "✅ 已拷贝: luci-app-harbor-file-pro"
rm -rf "$HB_TMP"

# --- luci-app-dufs（DUFS 文件服务器 LuCI 界面）---
# 源：pg-go/luci-app-dufs（用户自有项目，内嵌 aarch64 dufs 二进制）。
# 仓库根目录就是包体（Makefile 在根目录），整仓拷（去掉 .git）。
DF_TMP="$(mktemp -d)/dufs"
if ! clone https://github.com/pg-go/luci-app-dufs "$DF_TMP" main; then
  echo "::error::pg-go/luci-app-dufs 拉取失败，luci-app-dufs 会被 defconfig 剔除"
  exit 1
fi
if [ ! -f "$DF_TMP/Makefile" ]; then
  echo "::error::$DF_TMP/Makefile 不存在（上游改结构了？）"
  exit 1
fi
rm -rf "$PKG_DIR/luci-app-dufs"
cp -a "$DF_TMP" "$PKG_DIR/luci-app-dufs"
rm -rf "$PKG_DIR/luci-app-dufs/.git"
echo "✅ 已拷贝: luci-app-dufs"
rm -rf "$DF_TMP"

# feed 里已有同名 luci-app-dufs（ImmortalWrt luci feed），且 feeds install 在
# customize.sh 之前跑，所以构建时 custom 版与 feed 版同名并存，构建实际会用
# feed 版（界面无 https、无 ipv6 列表，已实证）。必须删掉 feed 版，只留 custom 版。
# 注意：package/feeds/luci/luci-app-dufs 是 feeds install 建的软链，
# rm -rf 不带尾斜杠只删链本身，不动 feed 源码。
rm -rf "package/feeds/luci/luci-app-dufs"
echo "✅ 已删除 feed 版 luci-app-dufs（只留 custom 版）"

# ---------------------------------------------------------
# 让新包进入索引
#   prepare-tmpinfo 直接扫 package/ 树（scan.mk: find -L package -maxdepth 5），
#   package/custom/<pkg>/Makefile 深度 3，本来就会被扫到，不需要注册 feed。
#   只删 tmp/.packageinfo 是不够的：prepare-tmpinfo 有 scan_unchanged 优化
#   （拿 tmp/info/.scan-*.stamp 比 mtime），stamp 还在且没有更新的 Makefile
#   时它会跳过扫描 —— 结果 .packageinfo 被删了却没人重建，索引反而空了。
#   所以 stamp 也要一起删。
# ---------------------------------------------------------
if [ -n "$(ls -A "$PKG_DIR" 2>/dev/null)" ]; then
  rm -f tmp/.packageinfo tmp/.targetinfo
  rm -f tmp/info/.scan-packageinfo.stamp tmp/info/.scan-targetinfo.stamp
  rm -f tmp/.config-package.in tmp/.config-target.in
  echo ">>> make prepare-tmpinfo（重新扫描 package/ 树）"
  make -s prepare-tmpinfo OPENWRT_BUILD= 2>&1 | tail -5 || true
  echo "=========================================="
  echo "包索引校验（判据：tmp/.packageinfo）"
  echo "=========================================="
  echo "package/custom 内容："
  INDEX_MISS=""
  for d in "$PKG_DIR"/*; do
    [ -d "$d" ] || continue
    n=$(basename "$d")
    if grep -qx "Package: $n" tmp/.packageinfo 2>/dev/null; then
      echo "  ✅ $n"
    else
      echo "  ❌ $n —— tmp/.packageinfo 里查不到"
      INDEX_MISS="$INDEX_MISS $n"
    fi
  done
  echo "------------------------------------------"
  echo "tmp/.packageinfo 包总数: $(grep -c '^Package: ' tmp/.packageinfo 2>/dev/null || echo 0)"
  echo "=========================================="
  # 必装插件（configs/release.config 第 8 节里是 =y 的那几个）必须进索引，
  # 否则 defconfig 会静默剔除。任一项没进索引，直接报错退出。
  REQUIRED="easytier-noweb luci-app-easytier mihomo-meta nikki luci-app-nikki luci-theme-aurora luci-app-aurora-config luci-app-netpath luci-app-harbor-file-pro luci-app-dufs"
  HARD_MISS=""
  for r in $REQUIRED; do
    grep -qx "Package: $r" tmp/.packageinfo 2>/dev/null || HARD_MISS="$HARD_MISS $r"
  done
  if [ -n "$HARD_MISS" ]; then
    echo "::error::以下必装插件未进入 tmp/.packageinfo，defconfig 会把 .config 里的 =y 静默剔除:$HARD_MISS"
    echo "  已索引缺失清单:$INDEX_MISS"
    exit 1
  fi
  [ -n "$INDEX_MISS" ] && echo "::warning::部分可选包未进入索引（不影响必装插件）:$INDEX_MISS"
else
  echo "未启用任何第三方插件"
fi

echo "=== [PonWrt-ZN504] Build preparation complete ==="

echo "=== [PonWrt-ZN504] Build preparation complete ==="
