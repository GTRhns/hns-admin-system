# HNS Admin System — 捉迷藏服务器 封禁 & 权限管理插件

一个自包含、可独立运行的 **Counter-Strike 1.6 / AMX Mod X** 管理插件。它将完整的 **封禁系统** 与 **权限发放系统** 整合进同一个菜单，不依赖任何第三方比赛系统，开箱即用。

> 本项目由 GTR 捉迷藏服务器 ([GTRHNS]) 实战中使用并开源，代码逻辑已在线上稳定运行。

---

## 功能特性

### 封禁系统
- 支持 SteamID / 盗版 IP 双重识别，盗版玩家自动按 IP 封禁
- 封禁时长可选：`1 小时 / 1 天 / 7 天 / 永久`
- 封禁原因记录，玩家被踢时显示剩余时间与原因
- 自动过期清理，过期封禁自动移除
- 双备份持久化：**文件**（`configs/permsystem/ban_list.txt`）+ **PDS**
- 封禁名单容量 `MAX_BANS`（默认 512）

### 权限发放系统
- 五级权限：`普通(0) / Helper(1) / VIP(2) / 管理员(3) / 服主(4)`
- 服主可在线发放/撤销 `管理员`、`VIP` 权限
- 一键给自己授予最高服主权限
- 双备份持久化：**文件**（`configs/permsystem/perm_list.txt`）+ **PDS**，离线玩家权限不丢失
- 兼容旧存储版本（`StorageVersion` 自动迁移）
- 权限标志自动映射到 AMXX flags + 聊天前缀

### 管理菜单（分级）
| 功能 | VIP | 管理员 | 服主 |
| --- |:-:|:-:|:-:|
| 踢出玩家 | ✔ | ✔ | ✔ |
| 封禁玩家 | - | ✔ | ✔ |
| 权限发放 | - | - | ✔ |
| 换图 | ✔ | ✔ | ✔ |
| 暂停/恢复比赛 | ✔ | ✔ | ✔ |
| 转移玩家队伍 | ✔ | ✔ | ✔ |
| 重开回合 | - | ✔ | ✔ |
| 交换队伍 | - | ✔ | ✔ |
| 隐藏身份 | - | - | ✔ |

---

## 环境要求

- [AMX Mod X](https://www.amxmodx.org/) 1.9+（需 `amxmodx`、`amxmisc`）
- [ReAPI](https://github.com/s1lentq/ReGameDLL_CS) 模块（`reapi`）
- [PersistentDataStorage](https://github.com/SiriusTR/PersistentDataStorage) 模块（`PersistentDataStorage`）
- 原版 AMXX 需在 `addons/amxmodx/configs/modules.ini` 中启用 `reapi` 与 `PersistentDataStorage`

```ini
; modules.ini
reapi
PersistentDataStorage
```

---

## 安装步骤

1. 将 `HnsMatchPermSystem.amxx` 放入 `cstrike/addons/amxmodx/plugins/`
2. 在 `cstrike/addons/amxmodx/configs/plugins.ini` 末尾添加一行：

   ```ini
   HnsMatchPermSystem.amxx
   ```

   > 建议放在文件靠后位置，确保后加载、覆盖其它插件对菜单/命令的拦截。

3. 将 `configs/openhns-prefixes.ini` 放入 `cstrike/addons/amxmodx/configs/`（用于聊天前缀 `[服主]` / `[管理员]` / `[VIP]`）
4. 首次启动会自动创建 `configs/permsystem/` 目录并生成空名单文件
5. 重启服务器或 `amx_plugins` 加载插件

---

## 快速上手

- 服主进入游戏后输入 **`/vipadmin`** 打开权限管理菜单
- 拥有 AMXX 最高权限标志 `m` 的账号免密直接进入
- 普通账号会提示输入管理密码（见下方配置修改 `ADMIN_PASSWORD`）
- `/permcheck` — 查看自己的权限等级
- `/hide` — 服主隐藏/显示身份（聊天前缀切换）

---

## 配置说明

### 管理密码

源码顶部常量，发布前请务必修改：

```pawn
#define ADMIN_PASSWORD   "890514"
```

### 权限等级

| 等级 | 常量 | 名称 | AMXX flags |
| --- | --- | --- | --- |
| 0 | `PERM_NONE` | 普通玩家 | - |
| 1 | `PERM_TEMP` | Helper | `fi` |
| 2 | `PERM_VIP` | VIP | `b` |
| 3 | `PERM_ADMIN` | 管理员 | `defiu` |
| 4 | `PERM_OWNER` | 服主 | `abcdefghijklmnou` |

### 权限名单文件 `configs/permsystem/perm_list.txt`

```
; HNS PermSystem Permission List
; StorageVersion: 2
; Format: steamid_or_ip name permission_level
; Levels: 0=normal 1=helper 2=vip 3=admin 4=owner

STEAM_0:0:916902420 pro 3
```

玩家名含空格时会自动替换为 `_`。文件采用 UTF-8 编码。

### 封禁名单文件 `configs/permsystem/ban_list.txt`

```
; HNS PermSystem Ban List
; Format: "authid/ip" expire_timestamp "reason"
; expire 0 = permanent

"STEAM_0:1:12345678" 1840000000 "违规行为"
"192.168.1.100" 0 "恶意干扰"
```

### 聊天前缀 `configs/openhns-prefixes.ini`

```
"flag" "m" "[!t服主!d] "
"flag" "d" "[!g管理员!d] "
"flag" "b" "[!tVIP!d] "
```

---

## 编译方法

### Linux
```bash
./compile.sh
# 或直接使用 amxxpc
./amxxpc HnsMatchPermSystem.sma -oHnsMatchPermSystem.amxx
```

### Windows
将源码放入 `scripting/`，用 `compile.exe` 或 amxx 自带编译脚本编译。

> 中文请在源码内直接使用 UTF-8 编码，并按你的服务器 AMXX 环境选择是否转 GBK 以保证游戏内正常显示。

---

## 目录结构

```
hns-admin-system/
├── README.md
├── LICENSE
├── compile.sh
├── cstrike/
│   └── addons/
│       └── amxmodx/
│           ├── scripting/
│           │   └── HnsMatchPermSystem.sma   # 插件源码
│           └── configs/
│               ├── openhns-prefixes.ini     # 聊天前缀
│               └── permsystem/              # 运行时名单目录 (*.example 为模板)
```

> 仓库内 `permsystem/` 下的 `perm_list.txt.example`、`ban_list.txt.example` 为模板，
> 部署时复制为去除 `.example` 后缀的实际文件即可（运行时数据不入库）。

---

## 声明

- 本项目仅供学习与服务器管理使用，请遵守你所在地区的相关法律法规
- 请勿将本项目用于任何非法用途
- 使用本项目造成的任何后果由使用者自行承担

## License

[MIT](LICENSE)