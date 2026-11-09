#!/bin/bash
#
# disable-macos-updates.sh
# 一键屏蔽 macOS 系统更新（网络 + 系统偏好 + 描述文件 三层）
#
# 实测环境：macOS 15.8.1 (24H32) / Apple Silicon
# 适用版本：macOS 13 Ventura ~ 15 Sequoia
#
# 用法：
#   sudo ./disable-macos-updates.sh            # 基础屏蔽（hosts + 系统偏好 + 去红点）
#   sudo ./disable-macos-updates.sh --proxy-bypass   # 额外：把更新域名加入系统代理绕过列表
#   sudo ./disable-macos-updates.sh --clear-cache    # 额外：清理已缓存的更新 offer（需 python3）
#   sudo ./disable-macos-updates.sh --profile        # 额外：生成描述文件（需手动双击安装）
#   sudo ./disable-macos-updates.sh --all            # 以上全部
#
# 恢复：sudo ./restore-macos-updates.sh
#
set -euo pipefail

DOMAINS=(
  swscan.apple.com
  swquery.apple.com
  swdownload.apple.com
  swdist.apple.com
  swcdn.apple.com
  swpost.apple.com
  mesu.apple.com
  gdmf.apple.com
  gdmf-ados.apple.com
  gsra.apple.com
  wkms-public.apple.com
  oscdn.apple.com
  osrecovery.apple.com
  appldnld.apple.com
  updates.cdn-apple.com
  updates-http.cdn-apple.com
  xp.apple.com
)

HOSTS_BEGIN="# === BEGIN macOS update block ==="
HOSTS_END="# === END macOS update block ==="

info()  { printf '[+] %s\n' "$*"; }
warn()  { printf '[!] %s\n' "$*"; }
ok()    { printf '[✓] %s\n' "$*"; }

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "请使用 sudo 运行：sudo $0 $*" >&2
    exit 1
  fi
}

require_macos() {
  if [ "$(uname -s)" != "Darwin" ]; then
    echo "此脚本仅适用于 macOS" >&2
    exit 1
  fi
}

console_user() {
  stat -f %Su /dev/console
}

# ---------- 1. hosts 屏蔽 ----------
block_hosts() {
  if grep -qF "$HOSTS_BEGIN" /etc/hosts; then
    ok "hosts 已存在屏蔽段，跳过"
    return
  fi
  local backup="/etc/hosts.bak.$(date +%Y%m%d%H%M%S)"
  cp /etc/hosts "$backup"
  info "已备份 hosts -> $backup"

  {
    echo ""
    echo "$HOSTS_BEGIN"
    local d
    for d in "${DOMAINS[@]}"; do
      echo "127.0.0.1 $d"
    done
    echo "$HOSTS_END"
  } >> /etc/hosts

  dscacheutil -flushcache 2>/dev/null || true
  killall -HUP mDNSResponder 2>/dev/null || true
  ok "hosts 已写入 ${#DOMAINS[@]} 条更新域名屏蔽"
}

# ---------- 2. 系统偏好 ----------
disable_prefs() {
  local plist="/Library/Preferences/com.apple.SoftwareUpdate"
  defaults write "$plist" AutomaticDownload -bool false
  defaults write "$plist" AutomaticInstallation -bool false
  defaults write "$plist" AutomaticallyInstallMacOSUpdates -bool false
  defaults write "$plist" ConfigDataInstall -bool false
  defaults write "$plist" CriticalUpdateInstall -bool false
  # App Store 自动更新（可选但推荐）
  defaults write /Library/Preferences/com.apple.commerce AutoUpdate -bool false 2>/dev/null || true
  defaults write /Library/Preferences/com.apple.commerce AutoUpdateRestartRequired -bool false 2>/dev/null || true

  # 清掉缓存的更新 offer（红点的数据来源）
  defaults delete "$plist" FirstOfferDateDictionary 2>/dev/null || true
  defaults delete "$plist" RecommendedUpdates 2>/dev/null || true
  defaults delete "$plist" LastRecommendedMajorOSBundleIdentifier 2>/dev/null || true

  # 通知日期推到 2035，阻止重新弹通知（用户域）
  local u
  u="$(console_user)"
  if [ -n "$u" ] && [ "$u" != "root" ]; then
    sudo -u "$u" defaults write com.apple.SoftwareUpdate UserNotificationDate -date "2035-01-01 12:00:00 +0000" 2>/dev/null || true
    sudo -u "$u" defaults write com.apple.SoftwareUpdate MajorOSUserNotificationDate -date "2035-01-01 12:00:00 +0000" 2>/dev/null || true
    sudo -u "$u" defaults write com.apple.SoftwareUpdate AutomaticCheckEnabled -bool false 2>/dev/null || true
  fi

  ok "自动更新开关已全部关闭，通知日期锁定 2035"
}

# ---------- 3. 清除红点 ----------
clear_badge() {
  local u
  u="$(console_user)"
  if [ -n "$u" ] && [ "$u" != "root" ]; then
    sudo -u "$u" defaults write com.apple.systempreferences AttentionPrefBundleIDs 0 2>/dev/null || true
    sudo -u "$u" defaults delete com.apple.systempreferences DidShowPrefBundleIDs 2>/dev/null || true
    # 停止更新通知进程（launchd 会按需重启）
    pkill -f SoftwareUpdateNotificationManager 2>/dev/null || true
  fi
  killall Dock 2>/dev/null || true
  ok "Dock 徽标已重置"
}

# ---------- 4. 代理绕过（可选） ----------
proxy_bypass() {
  local svc list existing d changed=0
  while IFS= read -r svc; do
    [ -z "$svc" ] && continue
    case "$svc" in \**) continue ;; esac

    existing="$(networksetup -getproxybypassdomains "$svc" 2>/dev/null | grep -v "There aren't any" || true)"
    list=()
    while IFS= read -r line; do
      [ -n "$line" ] && list+=("$line")
    done <<< "$existing"

    for d in "${DOMAINS[@]}"; do
      if [ "${#list[@]}" -eq 0 ] || ! printf '%s\n' "${list[@]}" | grep -qxF "$d"; then
        list+=("$d")
      fi
    done

    if networksetup -setproxybypassdomains "$svc" "${list[@]}" >/dev/null 2>&1; then
      changed=$((changed + 1))
    else
      warn "无法设置网络服务「$svc」的代理绕过（可能未启用）"
    fi
  done < <(networksetup -listallnetworkservices 2>/dev/null | tail -n +2)

  if [ "$changed" -gt 0 ]; then
    ok "已为 $changed 个网络服务添加 ${#DOMAINS[@]} 个代理绕过域名"
  else
    warn "未修改任何网络服务"
  fi
}

# ---------- 5. 清理缓存 offer（可选） ----------
clear_cached_offers() {
  if ! command -v python3 >/dev/null 2>&1; then
    warn "未找到 python3，跳过缓存清理"
    return
  fi

  local tmpdir port server_pid
  tmpdir="$(mktemp -d)"
  port=$(( (RANDOM % 1000) + 18000 ))

  cat > "$tmpdir/index.sucatalog" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>Products</key><dict/></dict></plist>
PLIST

  ( cd "$tmpdir" && python3 -m http.server "$port" --bind 127.0.0.1 >/dev/null 2>&1 ) &
  server_pid=$!
  sleep 2

  info "用本地空目录触发一次「0 更新」扫描（端口 $port）"
  defaults write /Library/Preferences/com.apple.SoftwareUpdate CatalogURL "http://127.0.0.1:$port/index.sucatalog"
  softwareupdate --list >/dev/null 2>&1 || true
  defaults delete /Library/Preferences/com.apple.SoftwareUpdate CatalogURL 2>/dev/null || true

  kill "$server_pid" 2>/dev/null || true
  rm -rf "$tmpdir"

  ok "缓存清理完成（若仍显示红点，重跑一次或重启后重试）"
}

# ---------- 6. 生成描述文件（可选） ----------
gen_profile() {
  local out
  out="$(pwd)/disable-autoupdate.mobileconfig"
  cat > "$out" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>PayloadContent</key>
  <array>
    <dict>
      <key>AutomaticCheckEnabled</key><false/>
      <key>AutomaticDownload</key><false/>
      <key>AutomaticallyInstallMacOSUpdates</key><false/>
      <key>CriticalUpdateInstall</key><false/>
      <key>ConfigDataInstall</key><false/>
      <key>PayloadIdentifier</key><string>local.disable.autoupdate.settings</string>
      <key>PayloadType</key><string>com.apple.SoftwareUpdate</string>
      <key>PayloadUUID</key><string>$(uuidgen)</string>
      <key>PayloadVersion</key><integer>1</integer>
      <key>PayloadDisplayName</key><string>自动更新设置</string>
    </dict>
  </array>
  <key>PayloadDisplayName</key><string>关闭 macOS 自动更新</string>
  <key>PayloadDescription</key><string>禁止自动检查、下载和安装 macOS 更新</string>
  <key>PayloadIdentifier</key><string>local.disable.autoupdate</string>
  <key>PayloadOrganization</key><string>Local</string>
  <key>PayloadRemovalDisallowed</key><false/>
  <key>PayloadType</key><string>Configuration</string>
  <key>PayloadUUID</key><string>$(uuidgen)</string>
  <key>PayloadVersion</key><integer>1</integer>
</dict>
</plist>
EOF
  ok "描述文件已生成：$out"
  warn "macOS 15 已禁用命令行安装，请双击该文件，在系统设置中允许安装"
}

# ---------- 主流程 ----------
main() {
  local do_bypass=0 do_cache=0 do_profile=0
  for arg in "$@"; do
    case "$arg" in
      --proxy-bypass) do_bypass=1 ;;
      --clear-cache)  do_cache=1 ;;
      --profile)      do_profile=1 ;;
      --all)          do_bypass=1; do_cache=1; do_profile=1 ;;
      -h|--help)      sed -n '2,20p' "$0"; exit 0 ;;
      *) echo "未知参数：$arg" >&2; exit 1 ;;
    esac
  done

  require_root "$@"
  require_macos

  echo "=== 屏蔽 macOS 系统更新 ==="
  block_hosts
  disable_prefs
  clear_badge
  [ "$do_bypass" -eq 1 ] && proxy_bypass
  [ "$do_cache" -eq 1 ] && clear_cached_offers
  [ "$do_profile" -eq 1 ] && gen_profile

  echo
  ok "完成。当前状态："
  echo "    - 更新检查：$(softwareupdate --list 2>&1 | head -1)"
  echo "    - hosts 屏蔽：$(grep -cE '^127\.0\.0\.1 .*apple\.com' /etc/hosts) 条"
  echo "    - 代理绕过：$(networksetup -getproxybypassdomains "$(networksetup -listallnetworkservices | sed -n '2p')" 2>/dev/null | grep -c 'apple.com' || true) 条（首个网络服务）"
  echo
  echo "提示：softwareupdate --schedule 在 macOS 15 是只读遗留接口，恒报 on，属正常现象。"
  echo "恢复更新请运行：sudo ./restore-macos-updates.sh"
}

main "$@"
