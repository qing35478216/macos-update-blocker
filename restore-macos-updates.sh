#!/bin/bash
#
# restore-macos-updates.sh
# 恢复 macOS 系统更新（撤销 disable-macos-updates.sh 的所有改动）
#
# 用法：sudo ./restore-macos-updates.sh
#
set -euo pipefail

HOSTS_BEGIN="# === BEGIN macOS update block ==="
HOSTS_END="# === END macOS update block ==="
PLIST="/Library/Preferences/com.apple.SoftwareUpdate"

info() { printf '[+] %s\n' "$*"; }
ok()   { printf '[✓] %s\n' "$*"; }

if [ "$(id -u)" -ne 0 ]; then
  echo "请使用 sudo 运行：sudo $0" >&2
  exit 1
fi

# ---------- 1. 移除 hosts 屏蔽 ----------
if grep -qF "$HOSTS_BEGIN" /etc/hosts; then
  tmp="$(mktemp)"
  awk -v b="$HOSTS_BEGIN" -v e="$HOSTS_END" '
    $0 == b { skip = 1; next }
    $0 == e { skip = 0; next }
    !skip
  ' /etc/hosts > "$tmp"
  cat "$tmp" > /etc/hosts
  rm -f "$tmp"
  dscacheutil -flushcache 2>/dev/null || true
  killall -HUP mDNSResponder 2>/dev/null || true
  ok "hosts 屏蔽段已移除"
else
  info "hosts 中没有屏蔽段，跳过"
fi

# ---------- 2. 恢复系统偏好 ----------
defaults write "$PLIST" AutomaticDownload -bool true
defaults write "$PLIST" AutomaticInstallation -bool true
defaults write "$PLIST" AutomaticallyInstallMacOSUpdates -bool true
defaults write "$PLIST" ConfigDataInstall -bool true
defaults write "$PLIST" CriticalUpdateInstall -bool true
defaults delete "$PLIST" CatalogURL 2>/dev/null || true

u="$(stat -f %Su /dev/console)"
if [ -n "$u" ] && [ "$u" != "root" ]; then
  sudo -u "$u" defaults delete com.apple.SoftwareUpdate UserNotificationDate 2>/dev/null || true
  sudo -u "$u" defaults delete com.apple.SoftwareUpdate MajorOSUserNotificationDate 2>/dev/null || true
fi

# ---------- 3. 重置徽标 ----------
if [ -n "$u" ] && [ "$u" != "root" ]; then
  sudo -u "$u" defaults delete com.apple.systempreferences AttentionPrefBundleIDs 2>/dev/null || true
  sudo -u "$u" defaults delete com.apple.systempreferences DidShowPrefBundleIDs 2>/dev/null || true
fi
killall Dock 2>/dev/null || true

ok "系统偏好已恢复"
echo
echo "注意：配置描述文件需要手动移除："
echo "  系统设置 → 通用 → 设备管理 → 选中「关闭 macOS 自动更新」→ 移除"
echo
echo "完成后可运行 softwareupdate --list 验证是否恢复联网检查。"
