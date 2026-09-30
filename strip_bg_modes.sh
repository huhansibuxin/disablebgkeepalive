#!/usr/bin/env bash
# ============================================================================
# strip_bg_modes.sh —— 斩后台「plist 一半」：删掉目标 App 的全部后台模式 + 后台任务
# 白名单 + WiFi 常连。与 DisableBgKeepalive.dylib（运行时一半）配合 = iOS 16 任意 App 彻底无后台。
#
# 用法:  ./strip_bg_modes.sh [--dry-run] <bundle-id> [ssh-host]
# 例:    ./strip_bg_modes.sh --dry-run app.swiftgram.ios      # 只预览，不改
#        ./strip_bg_modes.sh app.swiftgram.ios
#        ./strip_bg_modes.sh net.colorfulclouds.app.pro root@192.168.3.156
#
# 安全约束（老板要求：不误删、不重复删）：
#   1. 只删这 3 个键，其余字段原样保留：
#        UIBackgroundModes / BGTaskSchedulerPermittedIdentifiers / UIRequiresPersistentWiFi
#   2. 备份只建一次：设备上首次跑才 cp 成 Info.plist.orig；已存在则不覆盖
#      （回滚永远可用：cp Info.plist.orig Info.plist && uicache -p <bid>）
#   3. 幂等：键已被删时 plistlib 删除是 no-op，重跑不报错、不改写、不破坏
#   4. --dry-run：只拉 plist 分析并打印会删哪些键，完全不动设备
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

DRY=0
if [ "${1:-}" = "--dry-run" ]; then DRY=1; shift; fi

BID="${1:?用法: $0 [--dry-run] <bundle-id> [ssh-host]}"
HOST="${2:-root@192.168.3.156}"
PY="${PYTHON3:-python3}"

echo "[*] 定位 $BID 的 Info.plist ..."
PL=$(ssh "$HOST" "ls -d /var/containers/Bundle/Application/*/$BID.app/Info.plist 2>/dev/null | head -1")
[ -z "$PL" ] && { echo "找不到 $BID 的 Info.plist（App 没装？）"; exit 1; }
echo "    路径: $PL"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
scp -q "$HOST:$PL" "$TMP/Info.plist"

if [ "$DRY" = "1" ]; then
  echo "[*] DRY-RUN：仅分析，不修改设备"
  "$PY" - "$TMP/Info.plist" <<'PY'
import plistlib, sys
d = plistlib.load(open(sys.argv[1], 'rb'))
keys = ("UIBackgroundModes", "BGTaskSchedulerPermittedIdentifiers", "UIRequiresPersistentWiFi")
present = [k for k in keys if k in d]
print("    现 plist 总键数:", len(d))
if present:
    for k in present:
        v = d[k]
        print(f"    将删除: {k} = {v if not isinstance(v,list) else '['+', '.join(map(str,v))+']'}")
else:
    print("    无可删的后台键（已是斩后台状态）")
PY
  exit 0
fi

echo "[*] 备份（若存在 Info.plist.orig 则不覆盖）..."
if ssh "$HOST" "[ -f $PL.orig ]"; then
  echo "    已存在 $PL.orig，跳过备份（回滚点保留）"
else
  ssh "$HOST" "cp $PL $PL.orig" && echo "    已备份到 $PL.orig"
fi

"$PY" - "$TMP/Info.plist" <<'PY'
import plistlib, sys
p = sys.argv[1]
d = plistlib.load(open(p, 'rb'))
before = len(d)
removed = []
for k in ("UIBackgroundModes", "BGTaskSchedulerPermittedIdentifiers", "UIRequiresPersistentWiFi"):
    if k in d:
        removed.append(k)
        del d[k]
plistlib.dump(d, open(p, 'wb'))
print(f"    总键数 {before} -> {len(d)}")
if removed:
    print("    已删除:", ", ".join(removed))
else:
    print("    本来就没有这些键，未改动（幂等）")
PY

echo "[*] 回写并刷新系统登记 ..."
scp -q "$TMP/Info.plist" "$HOST:$PL"
ssh "$HOST" "uicache -p $BID"

echo "[+] 完成。请 kill -9 $BID 并确认新 PID 后重开 App 生效。"
echo "   回滚: ssh $HOST cp $PL.orig $PL && uicache -p $BID"
