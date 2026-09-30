#!/usr/bin/env bash
# ============================================================================
# strip_bg_modes.sh —— 斩后台「plist 一半」：删掉目标 App 的全部后台模式 + 后台任务
# 白名单 + WiFi 常连。与 NoBgCPU.dylib（运行时一半）配合 = iOS 16 任意 App 彻底无后台。
#
# 用法:  ./strip_bg_modes.sh <bundle-id> [ssh-host]
# 例:    ./strip_bg_modes.sh app.swiftgram.ios
#        ./strip_bg_modes.sh net.colorfulclouds.app.pro root@192.168.3.156
#
# 删的键（静态声明，dylib 运行时钩不到，只能改 plist）:
#   UIBackgroundModes                 —— audio / voip / fetch / location / processing /
#                                        bluetooth* / remote-notification / external-accessory ... 全删
#   BGTaskSchedulerPermittedIdentifiers —— 后台刷新/处理任务白名单
#   UIRequiresPersistentWiFi          —— WiFi 常连
#
# 前置: ssh 可达（默认 root@192.168.3.156）；App 经 TrollFools 注入（bundle 可写）；
#       本机有 python3（没有就 set PYTHON3=托管运行时路径再跑）。
# ⚠️ 改完务必 kill -9 该 App 并确认新 PID 才真重读（killall 杀不掉，见 skill）。
# ============================================================================
set -euo pipefail

BID="${1:?用法: $0 <bundle-id> [ssh-host]}"
HOST="${2:-root@192.168.3.156}"
PY="${PYTHON3:-python3}"

echo "[*] 定位 $BID 的 Info.plist ..."
PL=$(ssh "$HOST" "ls -d /var/containers/Bundle/Application/*/$BID.app/Info.plist 2>/dev/null | head -1")
[ -z "$PL" ] && { echo "找不到 $BID 的 Info.plist（App 没装？）"; exit 1; }
echo "    路径: $PL"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "[*] 备份到设备 $PL.orig_$(date +%Y%m%d) 并拉取到本地 ..."
ssh "$HOST" "if [ ! -f $PL.orig ]; then cp $PL $PL.orig; fi"
scp -q "$HOST:$PL" "$TMP/Info.plist"

"$PY" - "$TMP/Info.plist" <<'PY'
import plistlib, sys
p = sys.argv[1]
d = plistlib.load(open(p, 'rb'))
removed = []
for k in ("UIBackgroundModes", "BGTaskSchedulerPermittedIdentifiers", "UIRequiresPersistentWiFi"):
    if k in d:
        removed.append(k)
        del d[k]
plistlib.dump(d, open(p, 'wb'))
if removed:
    print("    已删除:", ", ".join(removed))
else:
    print("    本来就没有这些键，无需改动")
PY

echo "[*] 回写并刷新系统登记 ..."
scp -q "$TMP/Info.plist" "$HOST:$PL"
ssh "$HOST" "uicache -p $BID"

echo "[+] 完成。请 kill -9 $BID 并确认新 PID 后重开 App 生效。"
echo "   回滚: ssh $HOST cp $PL.orig $PL && uicache -p $BID"
