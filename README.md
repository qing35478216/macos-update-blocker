# macOS 系统更新屏蔽 + 去红点

一键关闭 macOS 自动更新、屏蔽更新服务器、消除「系统设置」里的更新红点。

> 实测环境：macOS 15.8.1 (24H32) / Apple Silicon
> 适用：macOS 13 Ventura ~ 15 Sequoia（部分逻辑对更早版本也有效）

## 它解决什么问题

1. **自动更新关不干净**——系统设置里关了「自动更新」，后台仍会检查、下载、提示
2. **代理软件绕过 hosts**——Clash / SakuraCat 等开启系统代理后，域名由代理端解析，`/etc/hosts` 的屏蔽完全失效
3. **红点清不掉**——更新 offer 缓存在 `softwareupdated` 守护进程内存里，删 plist 也没用（该进程受 SIP 保护，杀不掉）
4. **检测工具误报**——`softwareupdate --schedule` 在 macOS 15 是只读遗留接口，恒报 `on`

## 三层屏蔽原理

| 层级 | 手段 | 作用 |
|------|------|------|
| 网络层 | `/etc/hosts` + 系统代理绕过列表 | 17 个 Apple 更新域名全部指向 `127.0.0.1`，代理也不再转发 |
| 系统层 | 关闭 5 个自动更新开关 + 通知日期锁到 2035 | 不检查、不下载、不安装、不弹通知 |
| 托管层 | 配置描述文件（`com.apple.SoftwareUpdate`） | MDM 级别强制关闭，系统设置显示「由配置文件管理」 |

## 红点清除的关键技巧

macOS 15 的红点来自 `softwareupdated` 内存中的 `RecommendedUpdates` 缓存（通常是 Safari 更新）。
脚本会：

1. 删除 plist 里的 `RecommendedUpdates` / `FirstOfferDateDictionary`
2. **临时把更新目录指向本地空目录**，跑一次扫描，让守护进程认为「0 updates available」
3. 重置 `AttentionPrefBundleIDs` 并重启 Dock

## 快速开始

```bash
git clone https://github.com/qing35478216/macos-update-blocker.git
cd macos-update-blocker
chmod +x *.sh

# 基础屏蔽（hosts + 系统偏好 + 去红点）
sudo ./disable-macos-updates.sh

# 推荐：全部功能
sudo ./disable-macos-updates.sh --all
```

### 参数说明

| 参数 | 作用 |
|------|------|
| 无 | hosts 屏蔽 + 系统偏好 + 去红点 |
| `--proxy-bypass` | 把 17 个更新域名加入所有网络服务的代理绕过列表（防 Clash/SakuraCat 绕过） |
| `--clear-cache` | 用本地空目录清理已缓存的更新 offer（需 python3） |
| `--profile` | 生成 `disable-autoupdate.mobileconfig` |
| `--all` | 以上全部 |

### 描述文件安装

`--profile` 生成的 `disable-autoupdate.mobileconfig`：

1. 双击文件
2. 系统设置 → 通用 → 设备管理 → 允许安装
3. 安装后「软件更新」会显示「自动更新：关闭（由配置文件管理）」

> macOS 15 已禁止 `profiles install` 命令行安装，只能走图形界面。

## 恢复更新

```bash
sudo ./restore-macos-updates.sh
```

然后手动移除描述文件：系统设置 → 通用 → 设备管理 → 移除「关闭 macOS 自动更新」。

## 已验证的状态

```text
$ softwareupdate --list
不能连接到Apple软件更新服务器。

$ defaults read /Library/Managed Preferences/com.apple.SoftwareUpdate
AutomaticCheckEnabled = 0
AutomaticDownload = 0
...
```

`softwareupdate --schedule` 仍会显示 `Automatic checking for updates is turned on`——这是 macOS 15 的遗留只读接口，即使装了 MDM 描述文件也不变，**不代表更新是开着的**。

## 风险提示

- 屏蔽后系统与 Safari 都不会收到安全更新，请自行评估安全风险
- 修改前会自动备份 `/etc/hosts` 为 `/etc/hosts.bak.<时间戳>`
- 脚本不修改 SIP、不替换系统二进制，所有改动均可逆
- 升级到新版本 macOS 后，`/etc/hosts` 屏蔽段与描述文件通常会保留，若红点回归可重跑脚本

## License

MIT
