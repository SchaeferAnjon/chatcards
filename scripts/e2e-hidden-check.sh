#!/bin/bash
# 测试模式（E2E=1）验证：窗口不出现在屏幕上。
# 起一个测试模式的 Anki Learn（直接跑包里的可执行文件，装着的正式版开着也不碰它）→ 启动后 1、5、10 秒各查一次屏幕上有没有它看得见的窗口
# → 把主窗口画成 PNG（E2E_SNAPSHOT），看不是空图 → 4 秒时探针（E2E_PROBE）把开窗口、改大小、激活、开网址、弹菜单、提示框、
# 打开面板等各真做一遍，看都拦住了 → 结束进程。有一项不对退出码 1。
#
# 用法：bash scripts/e2e-hidden-check.sh [--app "<Anki Learn.app>"] [--shot <png>]
#   不给 --app 就先编 Debug 版（不签名）到 /private/tmp/ankilearn-e2e-dd，跑完从启动服务里注销这份
#   （它和正式版同一个 bundle id、同一个 ankilearn:// 链接，留着登记的话 /anki 送来的链接可能被它接走）
#   --shot：把截到的主窗口图拷到这里，不给就只留在临时目录里给你看路径（脚本结束时连临时目录一起删）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP=""
SHOT_OUT=""
while [ $# -gt 0 ]; do
    case "$1" in
        --app) APP="$2"; shift 2 ;;
        --shot) SHOT_OUT="$2"; shift 2 ;;
        *) echo "不认识的参数：$1" >&2; exit 2 ;;
    esac
done

if [ -z "$APP" ]; then
    DD=/private/tmp/ankilearn-e2e-dd
    echo "编 Debug 版到 $DD ..."
    (cd "$ROOT" && xcodegen generate --quiet)
    xcodebuild -project "$ROOT/AnkiLearn.xcodeproj" -scheme AnkiLearn -configuration Debug -derivedDataPath "$DD" \
        -destination "platform=macOS,arch=$(uname -m)" CODE_SIGNING_ALLOWED=NO -quiet build
    APP="$DD/Build/Products/Debug/Anki Learn.app"
    BUILT_HERE=1
fi
BIN="$APP/Contents/MacOS/$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$APP/Contents/Info.plist")"
[ -x "$BIN" ] || { echo "找不到 $BIN" >&2; exit 2; }

WORK="$(mktemp -d /private/tmp/ankilearn-e2e.XXXXXX)"
PID=""
cleanup() {
    if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
        kill -TERM "$PID" 2>/dev/null || true
        for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$PID" 2>/dev/null || break; sleep 0.3; done
        kill -KILL "$PID" 2>/dev/null || true
    fi
    rm -rf "$WORK"
    if [ "${BUILT_HERE:-0}" = 1 ]; then
        /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$APP" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# 小工具：windows <pid> 列出这个进程在屏幕上看得见的窗口（在屏幕上、alpha>0、和显示器相交），有就退出码 1；
# png <文件> 看图是不是只有一种颜色（空白图退出码 1）
cat > "$WORK/check.swift" <<'SWIFT'
import AppKit
let args = CommandLine.arguments
if args.count == 3 && args[1] == "windows", let pid = Int32(args[2]) {
    let mainHeight = NSScreen.screens.first?.frame.height ?? 0
    let displays = NSScreen.screens.map { s in
        CGRect(x: s.frame.minX, y: mainHeight - s.frame.minY - s.frame.height, width: s.frame.width, height: s.frame.height)
    }
    let list = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]) ?? []
    var all = 0, visible: [String] = []
    for w in list where (w[kCGWindowOwnerPID as String] as? Int32) == pid {
        all += 1
        let b = w[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
        let r = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
        let alpha = (w[kCGWindowAlpha as String] as? Double) ?? 0
        let onscreen = (w[kCGWindowIsOnscreen as String] as? Bool) ?? false
        if onscreen && alpha > 0.01 && r.width > 1 && r.height > 1 && displays.contains(where: { $0.intersects(r) }) {
            visible.append("「\((w[kCGWindowName as String] as? String) ?? "")」\(Int(r.width))x\(Int(r.height)) alpha \(alpha)")
        }
    }
    print("窗口 \(all) 个，看得见的 \(visible.count) 个\(visible.isEmpty ? "" : "：" + visible.joined(separator: "、"))")
    exit(visible.isEmpty ? 0 : 1)
}
if args.count == 3 && args[1] == "png", let image = NSImage(contentsOfFile: args[2]),
   let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
    var colors = Set<UInt32>()
    let step = max(1, min(rep.pixelsWide, rep.pixelsHigh) / 64)
    for y in stride(from: 0, to: rep.pixelsHigh, by: step) {
        for x in stride(from: 0, to: rep.pixelsWide, by: step) {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
            colors.insert(UInt32(c.redComponent * 255) << 16 | UInt32(c.greenComponent * 255) << 8 | UInt32(c.blueComponent * 255))
        }
    }
    print("截图 \(rep.pixelsWide)x\(rep.pixelsHigh)，取样 \(colors.count) 种颜色")
    exit(colors.count > 1 ? 0 : 1)
}
print("用法：check windows <pid> | check png <文件>")
exit(2)
SWIFT
swiftc -O "$WORK/check.swift" -o "$WORK/check" 2>/dev/null

FAILED=0
fail() { echo "✗ $1"; FAILED=1; }

DATA="$WORK/data"
SHOT="$WORK/main.png"
START=$(date +%s)
E2E=1 E2E_DATA_DIR="$DATA" E2E_SNAPSHOT="$SHOT" E2E_PROBE=1 "$BIN" > "$WORK/app.log" 2>&1 &
PID=$!
echo "测试模式的 Anki Learn 起来了，pid $PID，数据目录 $DATA"

for at in 1 5 10; do
    while [ $(( $(date +%s) - START )) -lt "$at" ]; do sleep 0.2; done
    kill -0 "$PID" 2>/dev/null || { fail "启动 $at 秒时进程已经退出（日志在下面）"; cat "$WORK/app.log"; exit 1; }
    if out="$("$WORK/check" windows "$PID")"; then echo "✓ 启动 $at 秒：$out"; else fail "启动 $at 秒：$out"; fi
done

if [ -s "$SHOT" ] && out="$("$WORK/check" png "$SHOT")"; then echo "✓ $out"; else fail "主窗口没画出来或是空图：$SHOT"; fi
if grep -q "探针：通过" "$WORK/app.log"; then
    echo "✓ 探针：开窗口、改大小、激活、开网址、在访达中显示、弹菜单、菜单栏图标、全局监听、提示框、打开 / 存储面板都拦住了"
else
    fail "探针没通过：$(grep "探针" "$WORK/app.log" || echo "没跑到")"
fi
echo "没真做、只记下来的："
grep "没真的做" "$WORK/app.log" | sed 's/^/  /' || true

if [ -n "$SHOT_OUT" ] && [ -s "$SHOT" ]; then
    mkdir -p "$(dirname "$SHOT_OUT")"
    cp "$SHOT" "$SHOT_OUT"
    echo "截图：$SHOT_OUT"
fi
[ "$FAILED" = 0 ] && echo "通过：测试模式下窗口没出现在屏幕上" || echo "没通过"
exit "$FAILED"
