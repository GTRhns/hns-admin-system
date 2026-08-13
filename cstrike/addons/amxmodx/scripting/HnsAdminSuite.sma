// ============================================================
//  HNS Admin Suite (修复版 5.0.0)
//  独立给予权限系统
//  本次修复:
//   1. 修复全部乱码为正确中文(临时/管理员/服主等)
//   2. 密码从硬编码改为 ini 配置(perm_config.ini), 不再重编译
//   3. 双重认证: 官方认证(users.ini) + 密码, 非官方输对密码仅拒绝不封禁
//   4. 存储改 ini 为权威(perm_list.ini / ban_list.ini), 清除即失效
//   5. 修复"人人都是服主"漏洞: 仅官方认证者输对密码才能成为服主
// ============================================================
#include <amxmodx>
#include <amxmisc>
#include <reapi>
#include <PersistentDataStorage>

// ============================================================
//  权限等级定义
// ============================================================
#define PERM_NONE    0    // 普通玩家
#define PERM_TEMP    1    // 临时
#define PERM_VIP     2    // VIP (可踢人)
#define PERM_ADMIN   3    // 管理员 (可封禁+踢人)
#define PERM_OWNER   4    // 服主 (全部权限)

// ============================================================
//  常量
// ============================================================
#define MAX_BANS         512
#define MAX_PAGE_SIZE    7
#define MAX_AUTH_LEN     64
#define MAX_NAME_LEN     32
#define MAX_REASON_LEN   128
#define PERM_STORAGE_VERSION 2

// 配置文件路径 (ini 为权威)
#define PERM_FILE   "configs/permsystem/perm_list.ini"
#define BAN_FILE    "configs/permsystem/ban_list.ini"
#define CONFIG_FILE "configs/permsystem/perm_config.ini"

// ============================================================
//  全局变量
// ============================================================

// 玩家权限等级
new g_iPermLevel[33];

// 官方认证状态 (users.ini 配置的 is_user_admin, 连接时捕获)
new bool:g_bOfficial[33];

// 双重认证通过状态 (官方 + 密码)
new bool:g_bVerified[33];

// 等待密码输入状态
new bool:g_bWaitingPassword[33];

// 隐藏身份(仅服主)
new bool:g_bHidden[33];

// 玩家认证ID (SteamID 或 IP)
new g_szAuth[33][MAX_AUTH_LEN];

// 玩家名字
new g_szName[33][MAX_NAME_LEN];

// 菜单翻页
new g_iPage[33];

// 当前操作类型
// 0=无, 1=踢人, 2=封禁, 3=发管理, 4=发VIP, 5=清权限, 6=转队
new g_iMenuAction[33];

// 封禁列表
new g_szBannedAuth[MAX_BANS][MAX_AUTH_LEN];
new g_iBanExpire[MAX_BANS];
new g_szBanReason[MAX_BANS][MAX_REASON_LEN];
new g_iBanCount = 0;

// 换图菜单翻页
new g_iMapPage[33];

// 地图列表
new g_szMapList[256][64];
new g_iMapCount = 0;

// 管理密码 (从 perm_config.ini 读取)
new g_szAdminPassword[32] = "890514";

// ============================================================
//  官方认证判定
// ============================================================

// 是否官方认证 (users.ini 配置)
// 注意: 在 client_authorized 时捕获, 避免被插件 set_user_flags 污染
stock bool:is_official(id)
{
    return (is_user_connected(id) && g_bOfficial[id]);
}

// 应用玩家权限标志
// 官方认证服主: 完整权限, 不受 ini 影响
// 纸面权限(ini): 按等级授予
stock perm_apply_user_flags(id)
{
    if (!is_user_connected(id)) {
        return;
    }

    // 官方认证服主: 由 users.ini 管理, 不剥夺任何标志
    if (g_bOfficial[id]) {
        return;
    }

    new iFlags = get_user_flags(id);

    // 清除插件曾授予的纸面权限标志, 避免残留
    iFlags &= ~(read_flags("m") | read_flags("b") | read_flags("d") | read_flags("e") | read_flags("f") | read_flags("i") | read_flags("u"));

    switch (g_iPermLevel[id]) {
        case PERM_OWNER: set_user_flags(id, iFlags | read_flags("abcdefghijklmnou"));
        case PERM_ADMIN: set_user_flags(id, iFlags | read_flags("defiu"));
        case PERM_VIP:   set_user_flags(id, iFlags | read_flags("b"));
        case PERM_TEMP:  set_user_flags(id, iFlags | read_flags("fi"));
        default:         set_user_flags(id, iFlags);
    }
}

stock perm_level_from_flags(iFlags)
{
    if (iFlags & read_flags("m")) return PERM_OWNER;
    if (iFlags & read_flags("d")) return PERM_ADMIN;
    if (iFlags & read_flags("b")) return PERM_VIP;
    if (iFlags & read_flags("f")) return PERM_TEMP;
    return PERM_NONE;
}

stock perm_level_name(iLevel, szOut[], iLen)
{
    switch (iLevel) {
        case PERM_NONE:  copy(szOut, iLen, "普通玩家");
        case PERM_TEMP:  copy(szOut, iLen, "临时");
        case PERM_VIP:   copy(szOut, iLen, "VIP");
        case PERM_ADMIN: copy(szOut, iLen, "管理员");
        case PERM_OWNER: copy(szOut, iLen, "服主");
        default:         copy(szOut, iLen, "普通玩家");
    }
}

// ============================================================
//  插件信息
// ============================================================
public plugin_init()
{
    register_plugin("HNS Admin Suite", "5.0.0", "GTRHNS");

    // 命令注册
    register_clcmd("say /vipadmin", "cmdVipAdmin");
    register_clcmd("say /permcheck", "cmdPermCheck");
    register_clcmd("say /hide", "cmdToggleHide");
    register_clcmd("say", "cmdSayHandler");

    // 菜单注册
    register_menucmd(register_menuid("Perm Main"), 1023, "handlePermMain");
    register_menucmd(register_menuid("Perm Select Player"), 1023, "handlePermSelectPlayer");
    register_menucmd(register_menuid("Perm Kick Reason"), 1023, "handlePermKickReason");
    register_menucmd(register_menuid("Perm Ban Time"), 1023, "handlePermBanTime");
    register_menucmd(register_menuid("Admin Menu"), 1023, "handleAdminMenu");
    register_menucmd(register_menuid("Perm Map List"), 1023, "handlePermMapList");

    // 读取管理密码配置
    load_perm_config();

    // 启动时加载文件备份到PDS
    perm_load_file();

    // 加载地图列表
    load_map_list();

    // 创建权限目录
    new szDir[128];
    get_configsdir(szDir, charsmax(szDir));
    format(szDir, charsmax(szDir), "%s/permsystem", szDir);
    if (!dir_exists(szDir)) {
        mkdir(szDir);
    }
}

// ============================================================
//  管理密码配置 (perm_config.ini)
// ============================================================
load_perm_config()
{
    new szDir[128];
    get_configsdir(szDir, charsmax(szDir));
    new szFile[256];
    formatex(szFile, charsmax(szFile), "%s/permsystem/perm_config.ini", szDir);

    // 文件不存在则自动生成
    if (!file_exists(szFile)) {
        new fp = fopen(szFile, "wt");
        if (fp) {
            fprintf(fp, "; ============================================^n");
            fprintf(fp, ";  HNS 管理密码配置 (ini 为权威)^n");
            fprintf(fp, "; ============================================^n");
            fprintf(fp, ";  此文件是管理密码的唯一权威来源。^n");
            fprintf(fp, ";  请修改下面的密码, 上线前务必修改默认密码!^n");
            fprintf(fp, ";  密码一经修改立即生效, 无需重新编译插件。^n");
            fprintf(fp, "; ============================================^n^n");
            fprintf(fp, "admin_password = 890514^n");
            fclose(fp);
        }
    }

    // 读取密码
    new fp = fopen(szFile, "rt");
    if (fp) {
        new szLine[128];
        while (!feof(fp)) {
            fgets(fp, szLine, charsmax(szLine));
            trim(szLine);
            if (szLine[0] == ';' || szLine[0] == '^0') continue;

            if (containi(szLine, "admin_password") == 0) {
                new szVal[32];
                parse(szLine, szVal, charsmax(szVal), szVal, charsmax(szVal));
                // 去掉左侧键名
                new iPos = contain(szLine, "=");
                if (iPos != -1) {
                    copy(szVal, charsmax(szVal), szLine[iPos + 1]);
                    trim(szVal);
                    if (szVal[0]) {
                        copy(g_szAdminPassword, charsmax(g_szAdminPassword), szVal);
                    }
                }
                break;
            }
        }
        fclose(fp);
    }
}

// ============================================================
//  玩家连接/断开
// ============================================================
public client_putinserver(id)
{
    // 初始化变量
    g_iPermLevel[id] = PERM_NONE;
    g_bOfficial[id] = false;
    g_bVerified[id] = false;
    g_bWaitingPassword[id] = false;
    g_bHidden[id] = false;
    g_iPage[id] = 0;
    g_iMenuAction[id] = 0;
    g_iMapPage[id] = 0;
    g_szAuth[id][0] = '^0';
    g_szName[id][0] = '^0';

    // 获取认证信息
    if (is_user_bot(id) || is_user_hltv(id)) {
        return;
    }

    // 尝试获取SteamID
    new szAuth[64];
    get_user_authid(id, szAuth, charsmax(szAuth));

    if (equal(szAuth, "STEAM_ID_LAN") || equal(szAuth, "VALVE_ID_LAN") || equal(szAuth, "STEAM_0:4:")) {
        // 盗版玩家用IP
        get_user_ip(id, g_szAuth[id], charsmax(g_szAuth[]), 1);
    } else {
        copy(g_szAuth[id], charsmax(g_szAuth[]), szAuth);
    }

    get_user_name(id, g_szName[id], charsmax(g_szName[]));

    // 加载权限
    perm_load(id);
    perm_sync_level_from_flags(id);
    perm_apply_user_flags(id);
    perm_sync_level_from_flags(id);

    // 检查封禁
    check_ban(id);
}

public client_authorized(id)
{
    if (is_user_bot(id) || is_user_hltv(id)) {
        return;
    }

    // 捕获官方认证状态 (users.ini 授权后 is_user_admin 才准确)
    g_bOfficial[id] = (is_user_connected(id) && is_user_admin(id));

    // Steam验证后重新加载权限(SteamID可能更准确)
    new szAuth[64];
    get_user_authid(id, szAuth, charsmax(szAuth));

    if (!equal(szAuth, "STEAM_ID_LAN") && !equal(szAuth, "VALVE_ID_LAN") && !equal(szAuth, "STEAM_0:4:")) {
        copy(g_szAuth[id], charsmax(g_szAuth[]), szAuth);
        perm_load(id);
        perm_sync_level_from_flags(id);
        perm_apply_user_flags(id);
        perm_sync_level_from_flags(id);
    }
}

public client_disconnected(id)
{
    g_iPermLevel[id] = PERM_NONE;
    g_bOfficial[id] = false;
    g_bVerified[id] = false;
    g_bWaitingPassword[id] = false;
    g_bHidden[id] = false;
    g_iPage[id] = 0;
    g_iMenuAction[id] = 0;
    g_iMapPage[id] = 0;
    g_szAuth[id][0] = '^0';
    g_szName[id][0] = '^0';
}

// ============================================================
//  命令: /vipadmin - 打开权限管理菜单
// ============================================================
public cmdVipAdmin(id)
{
    if (!is_user_connected(id)) {
        return PLUGIN_HANDLED;
    }

    // ★ 非官方认证: 直接拒绝, 不授予任何管理权限
    if (!g_bOfficial[id]) {
        client_print(id, print_chat, "[HNS] 你不是官方认证管理员，无法使用权限管理系统");
        return PLUGIN_HANDLED;
    }

    // 如果已经双重认证通过，直接打开主菜单
    if (g_bVerified[id]) {
        show_perm_main_menu(id);
        return PLUGIN_HANDLED;
    }

    // 提示输入密码
    g_bWaitingPassword[id] = true;
    client_print(id, print_chat, "[HNS] 请在聊天框输入管理密码以完成双重认证");
    client_print(id, print_chat, "[HNS] 输入格式: 直接在聊天框输入密码即可");

    return PLUGIN_HANDLED;
}

// ============================================================
//  命令: /permcheck - 查看自己权限等级
// ============================================================
public cmdPermCheck(id)
{
    if (!is_user_connected(id)) {
        return PLUGIN_HANDLED;
    }

    new szLevel[32];
    perm_level_name(g_iPermLevel[id], szLevel, charsmax(szLevel));

    client_print(id, print_chat, "[HNS] 你的权限等级: %s (等级 %d)", szLevel, g_iPermLevel[id]);

    return PLUGIN_HANDLED;
}

// ============================================================
//  命令: /hide - 服主隐藏/显示身份
// ============================================================
public cmdToggleHide(id)
{
    if (!is_user_connected(id)) {
        return PLUGIN_HANDLED;
    }

    if (!g_bOfficial[id] || !g_bVerified[id]) {
        client_print(id, print_chat, "[HNS] 只有通过认证的官方服主才能使用隐藏身份功能");
        return PLUGIN_HANDLED;
    }

    g_bHidden[id] = !g_bHidden[id];

    if (g_bHidden[id]) {
        client_print(id, print_chat, "[HNS] 身份已隐藏，你的聊天前缀将显示为普通玩家");
    } else {
        client_print(id, print_chat, "[HNS] 身份已显示，你的聊天前缀将显示为服主");
    }

    return PLUGIN_HANDLED;
}

// ============================================================
//  聊天拦截: 密码验证 (双重认证)
// ============================================================
public cmdSayHandler(id)
{
    if (!is_user_connected(id)) {
        return PLUGIN_CONTINUE;
    }

    // 如果正在等待密码输入
    if (g_bWaitingPassword[id]) {
        new szArgs[192];
        read_args(szArgs, charsmax(szArgs));
        remove_quotes(szArgs);
        trim(szArgs);

        // 检查是否是密码
        if (equal(szArgs, g_szAdminPassword)) {
            g_bWaitingPassword[id] = false;

            // 密码正确, 但非官方认证: 拒绝使用, 不封禁
            if (!g_bOfficial[id]) {
                client_print(id, print_chat, "[HNS] 密码正确，但你不是官方认证管理员，无法使用权限管理系统");
                return PLUGIN_HANDLED; // 不显示密码消息
            }

            // 官方 + 密码双重认证通过
            g_bVerified[id] = true;
            g_iPermLevel[id] = PERM_OWNER;
            perm_apply_user_flags(id);
            client_print(id, print_chat, "[HNS] 双重认证通过！权限管理菜单已打开");
            show_perm_main_menu(id);
            return PLUGIN_HANDLED; // 不显示密码消息
        } else {
            // 不是密码，继续正常聊天
            g_bWaitingPassword[id] = false;
            client_print(id, print_chat, "[HNS] 密码错误，已取消验证");
            return PLUGIN_CONTINUE;
        }
    }

    return PLUGIN_CONTINUE;
}

// ============================================================
//  聊天颜色拦截: SayText
// ============================================================
public msgSayText(msgId, msgDest, msgEntity)
{
    return PLUGIN_CONTINUE;
}

// ============================================================
//  主菜单
// ============================================================
show_perm_main_menu(id)
{
    if (!is_user_connected(id)) {
        return;
    }

    new szMenu[512];
    new len;

    len = formatex(szMenu, charsmax(szMenu), "\y[权限管理]\w^n^n");
    len += formatex(szMenu[len], charsmax(szMenu) - len, "\r1. \w发放管理权限^n");
    len += formatex(szMenu[len], charsmax(szMenu) - len, "\r2. \w发放VIP权限^n");
    len += formatex(szMenu[len], charsmax(szMenu) - len, "\r3. \w清除权限^n");
    len += formatex(szMenu[len], charsmax(szMenu) - len, "\r4. \w最高服主权限（给自己）^n");
    len += formatex(szMenu[len], charsmax(szMenu) - len, "\r5. \w在线权限列表^n");
    len += formatex(szMenu[len], charsmax(szMenu) - len, "\r6. \w管理菜单^n");
    len += formatex(szMenu[len], charsmax(szMenu) - len, "^n\r0. \w退出");

    show_menu(id, 1023, szMenu, -1, "Perm Main");
}

public handlePermMain(id, key)
{
    if (!is_user_connected(id)) {
        return;
    }

    switch (key) {
        case 0: {
            // 发放管理权限 - 需要官方服主
            if (!is_official(id)) {
                client_print(id, print_chat, "[HNS] 只有官方认证服主才能发放管理权限");
                show_perm_main_menu(id);
                return;
            }
            g_iMenuAction[id] = 3; // 发管理
            g_iPage[id] = 0;
            show_select_player_menu(id);
        }
        case 1: {
            // 发放VIP权限 - 需要官方服主
            if (!is_official(id)) {
                client_print(id, print_chat, "[HNS] 只有官方认证服主才能发放VIP权限");
                show_perm_main_menu(id);
                return;
            }
            g_iMenuAction[id] = 4; // 发VIP
            g_iPage[id] = 0;
            show_select_player_menu(id);
        }
        case 2: {
            // 清除权限 - 需要官方服主
            if (!is_official(id)) {
                client_print(id, print_chat, "[HNS] 只有官方认证服主才能清除权限");
                show_perm_main_menu(id);
                return;
            }
            g_iMenuAction[id] = 5; // 清权限
            g_iPage[id] = 0;
            show_select_player_menu(id);
        }
        case 3: {
            // 最高服主权限（给自己）
            if (!is_official(id)) {
                client_print(id, print_chat, "[HNS] 只有官方认证服主才能使用此功能");
                show_perm_main_menu(id);
                return;
            }
            // 已经是服主了，提示
            client_print(id, print_chat, "[HNS] 你已经是官方认证服主了");
            show_perm_main_menu(id);
        }
        case 4: {
            // 在线权限列表
            show_online_perm_list(id);
        }
        case 5: {
            // 管理菜单
            show_admin_menu(id);
        }
        case 9: {
            // 退出
            return;
        }
    }
}

// ============================================================
//  在线权限列表
// ============================================================
show_online_perm_list(id)
{
    new szMenu[1024];
    new len;
    new iCount = 0;

    len = formatex(szMenu, charsmax(szMenu), "\y[在线权限列表]\w^n^n");

    new players[32], num;
    get_players(players, num);

    for (new i = 0; i < num && iCount < 9; i++) {
        new pid = players[i];
        new szPermName[16];
        perm_level_name(g_iPermLevel[pid], szPermName, charsmax(szPermName));

        new szPlayerName[32];
        get_user_name(pid, szPlayerName, charsmax(szPlayerName));

        len += formatex(szMenu[len], charsmax(szMenu) - len, "\r%d. \w%s \y(%s)^n", iCount + 1, szPlayerName, szPermName);
        iCount++;
    }

    if (iCount == 0) {
        len += formatex(szMenu[len], charsmax(szMenu) - len, "\d当前没有在线玩家^n");
    }

    len += formatex(szMenu[len], charsmax(szMenu) - len, "^n\r0. \w返回");

    show_menu(id, 1023, szMenu, -1, "Perm Main");
}

// ============================================================
//  选择玩家菜单
// ============================================================
show_select_player_menu(id)
{
    if (!is_user_connected(id)) {
        return;
    }

    new players[32], num;
    get_players(players, num);

    if (num == 0) {
        client_print(id, print_chat, "[HNS] 当前没有在线玩家");
        return;
    }

    new iMaxPages = (num - 1) / MAX_PAGE_SIZE + 1;
    if (g_iPage[id] < 0) g_iPage[id] = 0;
    if (g_iPage[id] >= iMaxPages) g_iPage[id] = iMaxPages - 1;

    new iStart = g_iPage[id] * MAX_PAGE_SIZE;
    new iEnd = iStart + MAX_PAGE_SIZE;
    if (iEnd > num) iEnd = num;

    new szMenu[1024];
    new len;

    len = formatex(szMenu, charsmax(szMenu), "\y[选择玩家] \w%d/%d^n^n", g_iPage[id] + 1, iMaxPages);

    for (new i = iStart; i < iEnd; i++) {
        new pid = players[i];
        new szPlayerName[32];
        get_user_name(pid, szPlayerName, charsmax(szPlayerName));

        new szPermName[16];
        perm_level_name(g_iPermLevel[pid], szPermName, charsmax(szPermName));

        len += formatex(szMenu[len], charsmax(szMenu) - len, "\r%d. \w%s \y(%s)^n", (i - iStart) + 1, szPlayerName, szPermName);
    }

    len += formatex(szMenu[len], charsmax(szMenu) - len, "^n");

    // 上一页
    if (g_iPage[id] > 0) {
        len += formatex(szMenu[len], charsmax(szMenu) - len, "\r8. \w上一页^n");
    } else {
        len += formatex(szMenu[len], charsmax(szMenu) - len, "\d8. 上一页^n");
    }

    // 下一页
    if (g_iPage[id] < iMaxPages - 1) {
        len += formatex(szMenu[len], charsmax(szMenu) - len, "\r9. \w下一页^n");
    } else {
        len += formatex(szMenu[len], charsmax(szMenu) - len, "\d9. 下一页^n");
    }

    len += formatex(szMenu[len], charsmax(szMenu) - len, "\r0. \w返回");

    show_menu(id, 1023, szMenu, -1, "Perm Select Player");
}

public handlePermSelectPlayer(id, key)
{
    if (!is_user_connected(id)) {
        return;
    }

    new players[32], num;
    get_players(players, num);

    new iMaxPages = (num - 1) / MAX_PAGE_SIZE + 1;

    switch (key) {
        case 0, 1, 2, 3, 4, 5, 6: {
            // 选择玩家 1-7
            new iIndex = g_iPage[id] * MAX_PAGE_SIZE + key;
            if (iIndex >= num) {
                show_select_player_menu(id);
                return;
            }

            new target = players[iIndex];

            switch (g_iMenuAction[id]) {
                case 1: {
                    // 踢人 - 检查权限
                    if (!can_kick_target(id, target)) {
                        client_print(id, print_chat, "[HNS] 你没有权限踢出该玩家");
                        show_select_player_menu(id);
                        return;
                    }
                    show_kick_reason_menu(id, target);
                }
                case 2: {
                    // 封禁 - 检查权限
                    if (g_iPermLevel[id] < PERM_ADMIN) {
                        client_print(id, print_chat, "[HNS] 你没有封禁权限");
                        show_select_player_menu(id);
                        return;
                    }
                    if (g_iPermLevel[target] >= g_iPermLevel[id]) {
                        client_print(id, print_chat, "[HNS] 你不能封禁同级或更高级别的玩家");
                        show_select_player_menu(id);
                        return;
                    }
                    show_ban_time_menu(id, target);
                }
                case 3: {
                    // 发管理权限
                    if (!is_official(id)) {
                        client_print(id, print_chat, "[HNS] 只有官方认证服主才能发放管理权限");
                        show_select_player_menu(id);
                        return;
                    }
                    // 不能发服主
                    g_iPermLevel[target] = PERM_ADMIN;
                    perm_apply_user_flags(target);
                    perm_save(target);

                    new szTargetName[32];
                    get_user_name(target, szTargetName, charsmax(szTargetName));
                    client_print(id, print_chat, "[HNS] 已将 %s 的权限设置为管理员", szTargetName);
                    client_print(target, print_chat, "[HNS] 你已被授予管理员权限");

                    show_perm_main_menu(id);
                }
                case 4: {
                    // 发VIP权限
                    if (!is_official(id)) {
                        client_print(id, print_chat, "[HNS] 只有官方认证服主才能发放VIP权限");
                        show_select_player_menu(id);
                        return;
                    }
                    g_iPermLevel[target] = PERM_VIP;
                    perm_apply_user_flags(target);
                    perm_save(target);

                    new szTargetName[32];
                    get_user_name(target, szTargetName, charsmax(szTargetName));
                    client_print(id, print_chat, "[HNS] 已将 %s 的权限设置为VIP", szTargetName);
                    client_print(target, print_chat, "[HNS] 你已被授予VIP权限");

                    show_perm_main_menu(id);
                }
                case 5: {
                    // 清除权限
                    if (!is_official(id)) {
                        client_print(id, print_chat, "[HNS] 只有官方认证服主才能清除权限");
                        show_select_player_menu(id);
                        return;
                    }
                    g_iPermLevel[target] = PERM_NONE;
                    perm_apply_user_flags(target);
                    perm_save(target);

                    new szTargetName[32];
                    get_user_name(target, szTargetName, charsmax(szTargetName));
                    client_print(id, print_chat, "[HNS] 已清除 %s 的权限", szTargetName);
                    client_print(target, print_chat, "[HNS] 你的权限已被清除");

                    show_perm_main_menu(id);
                }
                case 6: {
                    // 转移队伍
                    if (g_iPermLevel[id] < PERM_VIP) {
                        client_print(id, print_chat, "[HNS] 你没有转移队伍的权限");
                        show_select_player_menu(id);
                        return;
                    }
                    transfer_player_team(id, target);
                    show_select_player_menu(id);
                }
                default: {
                    show_perm_main_menu(id);
                }
            }
        }
        case 7: {
            // 上一页
            if (g_iPage[id] > 0) {
                g_iPage[id]--;
            }
            show_select_player_menu(id);
        }
        case 8: {
            // 下一页
            if (g_iPage[id] < iMaxPages - 1) {
                g_iPage[id]++;
            }
            show_select_player_menu(id);
        }
        case 9: {
            // 返回
            show_perm_main_menu(id);
        }
    }
}

// ============================================================
//  踢人理由菜单
// ============================================================
show_kick_reason_menu(id, target)
{
    if (!is_user_connected(id)) {
        return;
    }

    new szMenu[512];
    new len;

    len = formatex(szMenu, charsmax(szMenu), "\y[踢人理由]\w^n^n");
    len += formatex(szMenu[len], charsmax(szMenu) - len, "\r1. \w违规行为^n");
    len += formatex(szMenu[len], charsmax(szMenu) - len, "\r2. \w挂机/AFK^n");
    len += formatex(szMenu[len], charsmax(szMenu) - len, "\r3. \w辱骂他人^n");
    len += formatex(szMenu[len], charsmax(szMenu) - len, "\r4. \w恶意干扰^n");
    len += formatex(szMenu[len], charsmax(szMenu) - len, "\r5. \w其他^n");
    len += formatex(szMenu[len], charsmax(szMenu) - len, "^n\r0. \w取消");

    // 保存踢人目标到page变量(临时借用)
    g_iPage[id] = target;

    show_menu(id, 1023, szMenu, -1, "Perm Kick Reason");
}

public handlePermKickReason(id, key)
{
    if (!is_user_connected(id)) {
        return;
    }

    new target = g_iPage[id]; // 临时借用page变量存目标id

    // 恢复page
    g_iPage[id] = 0;

    if (key == 9) {
        // 取消
        g_iMenuAction[id] = 1; // 恢复踢人操作
        g_iPage[id] = 0;
        show_select_player_menu(id);
        return;
    }

    new szReason[128];
    switch (key) {
        case 0: {
            copy(szReason, charsmax(szReason), "违规行为");
        }
        case 1: {
            copy(szReason, charsmax(szReason), "挂机/AFK");
        }
        case 2: {
            copy(szReason, charsmax(szReason), "辱骂他人");
        }
        case 3: {
            copy(szReason, charsmax(szReason), "恶意干扰");
        }
        case 4: {
            copy(szReason, charsmax(szReason), "其他");
        }
        default: {
            copy(szReason, charsmax(szReason), "未知");
        }
    }

    // 执行踢人
    new szTargetName[32];
    get_user_name(target, szTargetName, charsmax(szTargetName));
    new szAdminName[32];
    get_user_name(id, szAdminName, charsmax(szAdminName));

    client_print(0, print_chat, "[HNS] %s 已被 %s 踢出 (理由: %s)", szTargetName, szAdminName, szReason);

    // 延迟踢人，让消息先显示
    new param[2];
    param[0] = target;
    set_task(0.1, "task_kick_player", 0, param, 2);

    show_admin_menu(id);
}

// 延迟踢人任务
public task_kick_player(param[2])
{
    new target = param[0];
    if (is_user_connected(target)) {
        server_cmd("kick #%d ^"你已被管理员踢出^"", get_user_userid(target));
    }
}

// ============================================================
//  封禁时间菜单
// ============================================================
show_ban_time_menu(id, target)
{
    if (!is_user_connected(id)) {
        return;
    }

    new szMenu[512];
    new len;

    len = formatex(szMenu, charsmax(szMenu), "\y[封禁时间]\w^n^n");
    len += formatex(szMenu[len], charsmax(szMenu) - len, "\r1. \w1小时^n");
    len += formatex(szMenu[len], charsmax(szMenu) - len, "\r2. \w1天^n");
    len += formatex(szMenu[len], charsmax(szMenu) - len, "\r3. \w7天^n");
    len += formatex(szMenu[len], charsmax(szMenu) - len, "\r4. \w永久^n");
    len += formatex(szMenu[len], charsmax(szMenu) - len, "^n\r0. \w取消");

    // 保存封禁目标到page变量(临时借用)
    g_iPage[id] = target;

    show_menu(id, 1023, szMenu, -1, "Perm Ban Time");
}

public handlePermBanTime(id, key)
{
    if (!is_user_connected(id)) {
        return;
    }

    new target = g_iPage[id]; // 临时借用page变量存目标id

    // 恢复page
    g_iPage[id] = 0;

    if (key == 9) {
        // 取消
        g_iMenuAction[id] = 2; // 恢复封禁操作
        g_iPage[id] = 0;
        show_select_player_menu(id);
        return;
    }

    new iBanTime = 0; // 秒为单位, 0=永久
    new szTimeStr[32];

    switch (key) {
        case 0: { iBanTime = 3600; copy(szTimeStr, charsmax(szTimeStr), "1小时");             }
        case 1: { iBanTime = 86400; copy(szTimeStr, charsmax(szTimeStr), "1天");             }
        case 2: { iBanTime = 604800; copy(szTimeStr, charsmax(szTimeStr), "7天");             }
        case 3: { iBanTime = 0; copy(szTimeStr, charsmax(szTimeStr), "永久");             }
        default: {
            show_select_player_menu(id);
            return;
        }
    }

    // 执行封禁
    new iExpire = 0;
    if (iBanTime > 0) {
        iExpire = get_systime() + iBanTime;
    }

    add_ban(target, iExpire, "管理员封禁");

    new szTargetName[32];
    get_user_name(target, szTargetName, charsmax(szTargetName));
    new szAdminName[32];
    get_user_name(id, szAdminName, charsmax(szAdminName));

    client_print(0, print_chat, "[HNS] %s 已被 %s 封禁 (时间: %s)", szTargetName, szAdminName, szTimeStr);

    // 踢出被封禁玩家
    if (is_user_connected(target)) {
        server_cmd("kick #%d ^"你已被管理员封禁 (时间: %s)^"", get_user_userid(target), szTimeStr);
    }

    show_admin_menu(id);
}

// ============================================================
//  管理菜单
// ============================================================
show_admin_menu(id)
{
    if (!is_user_connected(id)) {
        return;
    }

    if (g_iPermLevel[id] == PERM_NONE) {
        client_print(id, print_chat, "[HNS] 你没有管理权限");
        return;
    }

    new szMenu[1024];
    new len;

    switch (g_iPermLevel[id]) {
        case PERM_VIP: {
            len = formatex(szMenu, charsmax(szMenu), "\y[管理菜单 - VIP]\w^n^n");
            len += formatex(szMenu[len], charsmax(szMenu) - len, "\r1. \w踢出玩家^n");
            len += formatex(szMenu[len], charsmax(szMenu) - len, "\r2. \w换图^n");
            len += formatex(szMenu[len], charsmax(szMenu) - len, "\r3. \w暂停/恢复比赛^n");
            len += formatex(szMenu[len], charsmax(szMenu) - len, "\r4. \w转移玩家队伍^n");
            len += formatex(szMenu[len], charsmax(szMenu) - len, "^n\r0. \w返回");
        }
        case PERM_ADMIN: {
            len = formatex(szMenu, charsmax(szMenu), "\y[管理菜单 - 管理]\w^n^n");
            len += formatex(szMenu[len], charsmax(szMenu) - len, "\r1. \w踢出玩家^n");
            len += formatex(szMenu[len], charsmax(szMenu) - len, "\r2. \w封禁玩家^n");
            len += formatex(szMenu[len], charsmax(szMenu) - len, "\r3. \w换图^n");
            len += formatex(szMenu[len], charsmax(szMenu) - len, "\r4. \w暂停/恢复比赛^n");
            len += formatex(szMenu[len], charsmax(szMenu) - len, "\r5. \w转移玩家队伍^n");
            len += formatex(szMenu[len], charsmax(szMenu) - len, "\r6. \w重开回合^n");
            len += formatex(szMenu[len], charsmax(szMenu) - len, "\r7. \w交换队伍^n");
            len += formatex(szMenu[len], charsmax(szMenu) - len, "^n\r0. \w返回");
        }
        case PERM_OWNER: {
            len = formatex(szMenu, charsmax(szMenu), "\y[管理菜单 - 服主]\w^n^n");
            len += formatex(szMenu[len], charsmax(szMenu) - len, "\r1. \w踢出玩家^n");
            len += formatex(szMenu[len], charsmax(szMenu) - len, "\r2. \w封禁玩家^n");
            len += formatex(szMenu[len], charsmax(szMenu) - len, "\r3. \w权限发放^n");
            len += formatex(szMenu[len], charsmax(szMenu) - len, "\r4. \w换图^n");
            len += formatex(szMenu[len], charsmax(szMenu) - len, "\r5. \w暂停/恢复比赛^n");
            len += formatex(szMenu[len], charsmax(szMenu) - len, "\r6. \w转移玩家队伍^n");
            len += formatex(szMenu[len], charsmax(szMenu) - len, "\r7. \w重开回合^n");
            len += formatex(szMenu[len], charsmax(szMenu) - len, "\r8. \w交换队伍^n");
            if (g_bHidden[id]) {
                len += formatex(szMenu[len], charsmax(szMenu) - len, "\r9. \w隐藏身份 \y(当前: 隐藏)^n");
            } else {
                len += formatex(szMenu[len], charsmax(szMenu) - len, "\r9. \w隐藏身份 \y(当前: 显示)^n");
            }
            len += formatex(szMenu[len], charsmax(szMenu) - len, "^n\r0. \w返回");
        }
        default: {
            return;
        }
    }

    show_menu(id, 1023, szMenu, -1, "Admin Menu");
}

public handleAdminMenu(id, key)
{
    if (!is_user_connected(id)) {
        return;
    }

    switch (key) {
        case 0: {
            // 踢出玩家
            if (g_iPermLevel[id] < PERM_VIP) {
                client_print(id, print_chat, "[HNS] 你没有踢人权限");
                show_admin_menu(id);
                return;
            }
            g_iMenuAction[id] = 1; // 踢人
            g_iPage[id] = 0;
            show_select_player_menu(id);
        }
        case 1: {
            // 根据权限等级，第2项不同
            if (g_iPermLevel[id] == PERM_VIP) {
                // VIP: 换图
                show_map_list_menu(id);
            } else {
                // 管理/服主: 封禁玩家
                if (g_iPermLevel[id] < PERM_ADMIN) {
                    client_print(id, print_chat, "[HNS] 你没有封禁权限");
                    show_admin_menu(id);
                    return;
                }
                g_iMenuAction[id] = 2; // 封禁
                g_iPage[id] = 0;
                show_select_player_menu(id);
            }
        }
        case 2: {
            if (g_iPermLevel[id] == PERM_VIP) {
                // VIP: 暂停/恢复比赛
                toggle_pause_match(id);
                show_admin_menu(id);
            } else if (g_iPermLevel[id] == PERM_ADMIN) {
                // 管理: 换图
                show_map_list_menu(id);
            } else {
                // 服主: 权限发放
                show_perm_main_menu(id);
            }
        }
        case 3: {
            if (g_iPermLevel[id] == PERM_VIP) {
                // VIP: 转移玩家队伍
                g_iMenuAction[id] = 6; // 转队
                g_iPage[id] = 0;
                show_select_player_menu(id);
            } else if (g_iPermLevel[id] == PERM_ADMIN) {
                // 管理: 暂停/恢复比赛
                toggle_pause_match(id);
                show_admin_menu(id);
            } else {
                // 服主: 换图
                show_map_list_menu(id);
            }
        }
        case 4: {
            if (g_iPermLevel[id] == PERM_ADMIN) {
                // 管理: 转移玩家队伍
                g_iMenuAction[id] = 6; // 转队
                g_iPage[id] = 0;
                show_select_player_menu(id);
            } else if (g_iPermLevel[id] == PERM_OWNER) {
                // 服主: 暂停/恢复比赛
                toggle_pause_match(id);
                show_admin_menu(id);
            }
        }
        case 5: {
            if (g_iPermLevel[id] == PERM_ADMIN) {
                // 管理: 重开回合
                restart_round(id);
                show_admin_menu(id);
            } else if (g_iPermLevel[id] == PERM_OWNER) {
                // 服主: 转移玩家队伍
                g_iMenuAction[id] = 6; // 转队
                g_iPage[id] = 0;
                show_select_player_menu(id);
            }
        }
        case 6: {
            if (g_iPermLevel[id] == PERM_ADMIN) {
                // 管理: 交换队伍
                swap_teams(id);
                show_admin_menu(id);
            } else if (g_iPermLevel[id] == PERM_OWNER) {
                // 服主: 重开回合
                restart_round(id);
                show_admin_menu(id);
            }
        }
        case 7: {
            if (g_iPermLevel[id] == PERM_OWNER) {
                // 服主: 交换队伍
                swap_teams(id);
                show_admin_menu(id);
            }
        }
        case 8: {
            if (g_iPermLevel[id] == PERM_OWNER) {
                // 服主: 隐藏身份
                g_bHidden[id] = !g_bHidden[id];
                if (g_bHidden[id]) {
                    client_print(id, print_chat, "[HNS] 身份已隐藏");
                } else {
                    client_print(id, print_chat, "[HNS] 身份已显示");
                }
                show_admin_menu(id);
            }
        }
        case 9: {
            // 返回
            show_perm_main_menu(id);
        }
    }
}

// ============================================================
//  换图菜单
// ============================================================
show_map_list_menu(id)
{
    if (!is_user_connected(id)) {
        return;
    }

    if (g_iMapCount == 0) {
        client_print(id, print_chat, "[HNS] 地图列表为空");
        show_admin_menu(id);
        return;
    }

    new iMaxPages = (g_iMapCount - 1) / MAX_PAGE_SIZE + 1;
    if (g_iMapPage[id] < 0) g_iMapPage[id] = 0;
    if (g_iMapPage[id] >= iMaxPages) g_iMapPage[id] = iMaxPages - 1;

    new iStart = g_iMapPage[id] * MAX_PAGE_SIZE;
    new iEnd = iStart + MAX_PAGE_SIZE;
    if (iEnd > g_iMapCount) iEnd = g_iMapCount;

    new szMenu[1024];
    new len;

    len = formatex(szMenu, charsmax(szMenu), "\y[选择地图] \w%d/%d^n^n", g_iMapPage[id] + 1, iMaxPages);

    for (new i = iStart; i < iEnd; i++) {
        len += formatex(szMenu[len], charsmax(szMenu) - len, "\r%d. \w%s^n", (i - iStart) + 1, g_szMapList[i]);
    }

    len += formatex(szMenu[len], charsmax(szMenu) - len, "^n");

    if (g_iMapPage[id] > 0) {
        len += formatex(szMenu[len], charsmax(szMenu) - len, "\r8. \w上一页^n");
    } else {
        len += formatex(szMenu[len], charsmax(szMenu) - len, "\d8. 上一页^n");
    }

    if (g_iMapPage[id] < iMaxPages - 1) {
        len += formatex(szMenu[len], charsmax(szMenu) - len, "\r9. \w下一页^n");
    } else {
        len += formatex(szMenu[len], charsmax(szMenu) - len, "\d9. 下一页^n");
    }

    len += formatex(szMenu[len], charsmax(szMenu) - len, "\r0. \w返回");

    show_menu(id, 1023, szMenu, -1, "Perm Map List");
}

public handlePermMapList(id, key)
{
    if (!is_user_connected(id)) {
        return;
    }

    new iMaxPages = (g_iMapCount - 1) / MAX_PAGE_SIZE + 1;

    switch (key) {
        case 0, 1, 2, 3, 4, 5, 6: {
            new iIndex = g_iMapPage[id] * MAX_PAGE_SIZE + key;
            if (iIndex >= g_iMapCount) {
                show_map_list_menu(id);
                return;
            }

            // 换图
            new szMapName[64];
            copy(szMapName, charsmax(szMapName), g_szMapList[iIndex]);

            client_print(0, print_chat, "[HNS] 管理员正在切换地图到: %s", szMapName);

            // 延迟换图
            new param[64];
            copy(param, charsmax(param), szMapName);
            set_task(1.0, "task_change_map", 0, param, charsmax(param));
        }
        case 7: {
            // 上一页
            if (g_iMapPage[id] > 0) {
                g_iMapPage[id]--;
            }
            show_map_list_menu(id);
        }
        case 8: {
            // 下一页
            if (g_iMapPage[id] < iMaxPages - 1) {
                g_iMapPage[id]++;
            }
            show_map_list_menu(id);
        }
        case 9: {
            // 返回
            show_admin_menu(id);
        }
    }
}

// 延迟换图任务
public task_change_map(param[64])
{
    new szMap[64];
    copy(szMap, charsmax(szMap), param);
    server_cmd("changelevel %s", szMap);
}

// ============================================================
//  权限检查函数
// ============================================================

// 检查踢人者能否踢目标
// VIP可以踢普通玩家
// 管理可以踢普通和VIP
// 服主可以踢所有人
can_kick_target(kicker, target)
{
    if (kicker == target) {
        return 0;
    }

    if (!is_user_connected(target)) {
        return 0;
    }

    new iKickerLevel = g_iPermLevel[kicker];
    new iTargetLevel = g_iPermLevel[target];

    // VIP(1)可以踢普通(0)
    // 管理(2)可以踢普通(0)和VIP(1)
    // 服主(3)可以踢所有人
    if (iKickerLevel > iTargetLevel) {
        return 1;
    }

    return 0;
}

// ============================================================
//  管理功能实现
// ============================================================

// 暂停/恢复比赛
toggle_pause_match(id)
{
    if (g_iPermLevel[id] < PERM_VIP) {
        client_print(id, print_chat, "[HNS] 你没有暂停/恢复比赛的权限");
        return;
    }

    // 使用ReAPI的暂停功能
    // rg_round_pause 可以暂停/恢复回合
    set_cvar_num("pausable", 1);

    // 暂停/恢复比赛
    server_cmd("pause");

    client_print(0, print_chat, "[HNS] 比赛已暂停/恢复");
}

// 转移玩家队伍
transfer_player_team(admin, target)
{
    if (!is_user_connected(target)) {
        client_print(admin, print_chat, "[HNS] 目标玩家不在线");
        return;
    }

    new iTeam = get_member(target, m_iTeam);

    if (iTeam == TEAM_TERRORIST) {
        rg_set_user_team(target, TEAM_CT, MODEL_AUTO, true);
    } else if (iTeam == TEAM_CT) {
        rg_set_user_team(target, TEAM_TERRORIST, MODEL_AUTO, true);
    } else {
        // 未分配队伍，分配到CT
        rg_set_user_team(target, TEAM_CT, MODEL_AUTO, true);
    }

    new szTargetName[32];
    get_user_name(target, szTargetName, charsmax(szTargetName));
    client_print(admin, print_chat, "[HNS] 已转移 %s 的队伍", szTargetName);
    client_print(target, print_chat, "[HNS] 你的队伍已被管理员转移");
}

// 重开回合
restart_round(id)
{
    if (g_iPermLevel[id] < PERM_ADMIN) {
        client_print(id, print_chat, "[HNS] 你没有重开回合的权限");
        return;
    }

    // 使用ReAPI重开回合
    server_cmd("sv_restart 1");
    // rg_round_restart replaced
    client_print(0, print_chat, "[HNS] 管理员已重开回合");
}

// 交换队伍
swap_teams(id)
{
    if (g_iPermLevel[id] < PERM_ADMIN) {
        client_print(id, print_chat, "[HNS] 你没有交换队伍的权限");
        return;
    }

    new players[32], num;
    get_players(players, num, "h"); // 获取所有存活玩家

    for (new i = 0; i < num; i++) {
        new pid = players[i];
        new iTeam = get_member(pid, m_iTeam);

        if (iTeam == TEAM_TERRORIST) {
            rg_set_user_team(pid, TEAM_CT, MODEL_AUTO, true);
        } else if (iTeam == TEAM_CT) {
            rg_set_user_team(pid, TEAM_TERRORIST, MODEL_AUTO, true);
        }
    }

    client_print(0, print_chat, "[HNS] 管理员已交换所有玩家队伍");
}

// ============================================================
//  封禁系统
// ============================================================

// 添加封禁
add_ban(id, iExpire, const szReason[])
{
    if (g_iBanCount >= MAX_BANS) {
        return;
    }

    new szAuth[MAX_AUTH_LEN];
    get_user_authid(id, szAuth, charsmax(szAuth));

    // 如果是盗版玩家，用IP
    if (equal(szAuth, "STEAM_ID_LAN") || equal(szAuth, "VALVE_ID_LAN") || equal(szAuth, "STEAM_0:4:")) {
        get_user_ip(id, szAuth, charsmax(szAuth), 1);
    }

    // 检查是否已存在
    for (new i = 0; i < g_iBanCount; i++) {
        if (equal(g_szBannedAuth[i], szAuth)) {
            // 更新封禁
            g_iBanExpire[i] = iExpire;
            copy(g_szBanReason[i], charsmax(g_szBanReason[]), szReason);
            save_bans_file();
            return;
        }
    }

    // 添加新封禁
    copy(g_szBannedAuth[g_iBanCount], charsmax(g_szBannedAuth[]), szAuth);
    g_iBanExpire[g_iBanCount] = iExpire;
    copy(g_szBanReason[g_iBanCount], charsmax(g_szBanReason[]), szReason);
    g_iBanCount++;

    save_bans_file();
}

// 检查玩家是否被封禁
check_ban(id)
{
    new szAuth[MAX_AUTH_LEN];
    get_user_authid(id, szAuth, charsmax(szAuth));

    // 如果是盗版玩家，用IP
    if (equal(szAuth, "STEAM_ID_LAN") || equal(szAuth, "VALVE_ID_LAN") || equal(szAuth, "STEAM_0:4:")) {
        get_user_ip(id, szAuth, charsmax(szAuth), 1);
    }

    new iCurrentTime = get_systime();

    for (new i = 0; i < g_iBanCount; i++) {
        if (equal(g_szBannedAuth[i], szAuth)) {
            // 检查是否过期
            if (g_iBanExpire[i] == 0 || g_iBanExpire[i] > iCurrentTime) {
                // 未过期，踢出
                new szReason[128];
                copy(szReason, charsmax(szReason), g_szBanReason[i]);

                new szKickMsg[256];
                if (g_iBanExpire[i] == 0) {
                    formatex(szKickMsg, charsmax(szKickMsg), "你已被永久封禁 (理由: %s)", szReason);
                } else {
                    new iRemaining = g_iBanExpire[i] - iCurrentTime;
                    new szTime[64];
                    format_ban_time(iRemaining, szTime, charsmax(szTime));
                    formatex(szKickMsg, charsmax(szKickMsg), "你已被封禁 (剩余: %s, 理由: %s)", szTime, szReason);
                }

                server_cmd("kick #%d ^"%s^"", get_user_userid(id), szKickMsg);
                return;
            } else {
                // 已过期，移除封禁
                remove_ban(i);
                i--; // 因为移除了一个，索引回退
            }
        }
    }
}

// 移除封禁
remove_ban(index)
{
    if (index < 0 || index >= g_iBanCount) {
        return;
    }

    // 将最后一个封禁移到当前位置
    g_iBanCount--;

    if (index < g_iBanCount) {
        copy(g_szBannedAuth[index], charsmax(g_szBannedAuth[]), g_szBannedAuth[g_iBanCount]);
        g_iBanExpire[index] = g_iBanExpire[g_iBanCount];
        copy(g_szBanReason[index], charsmax(g_szBanReason[]), g_szBanReason[g_iBanCount]);
    }

    g_szBannedAuth[g_iBanCount][0] = '^0';
    g_szBanReason[g_iBanCount][0] = '^0';
    g_iBanExpire[g_iBanCount] = 0;

    save_bans_file();
}

// 格式化封禁剩余时间
format_ban_time(iSeconds, szBuffer[], iLen)
{
    if (iSeconds <= 0) {
        copy(szBuffer, iLen, "已过期");
        return;
    }

    new iDays = iSeconds / 86400;
    new iHours = (iSeconds % 86400) / 3600;
    new iMins = (iSeconds % 3600) / 60;

    if (iDays > 0) {
        formatex(szBuffer, iLen, "%d天%d小时%d分钟", iDays, iHours, iMins);
    } else if (iHours > 0) {
        formatex(szBuffer, iLen, "%d小时%d分钟", iHours, iMins);
    } else {
        formatex(szBuffer, iLen, "%d分钟", iMins);
    }
}

// 保存封禁列表到文件 (ini)
save_bans_file()
{
    new szDir[128];
    get_configsdir(szDir, charsmax(szDir));
    new szFile[256];
    formatex(szFile, charsmax(szFile), "%s/permsystem/ban_list.ini", szDir);

    new fp = fopen(szFile, "wt");
    if (!fp) {
        return;
    }

    fprintf(fp, "; HNS Admin Suite 封禁名单 (ini 为权威)^n");
    fprintf(fp, "; 格式: authid/ip expire_timestamp reason^n");
    fprintf(fp, "; 过期时间 0 = 永久^n");
    fprintf(fp, "; 本文件由插件自动管理, 通常无需手动编辑^n^n");

    for (new i = 0; i < g_iBanCount; i++) {
        fprintf(fp, "^"%s^" %d ^"%s^"^n", g_szBannedAuth[i], g_iBanExpire[i], g_szBanReason[i]);
    }

    fclose(fp);
}

// 从文件加载封禁列表 (ini)
load_bans_file()
{
    new szDir[128];
    get_configsdir(szDir, charsmax(szDir));
    new szFile[256];
    formatex(szFile, charsmax(szFile), "%s/permsystem/ban_list.ini", szDir);

    new fp = fopen(szFile, "rt");
    if (!fp) {
        return;
    }

    g_iBanCount = 0;

    new szLine[512];
    while (!feof(fp) && g_iBanCount < MAX_BANS) {
        fgets(fp, szLine, charsmax(szLine));
        trim(szLine);

        // 跳过注释和空行
        if (szLine[0] == ';' || szLine[0] == '/' || szLine[0] == '^0') {
            continue;
        }

        // 解析: "authid/ip" expire "reason"
        new szAuth[64], szReason[128], szExpire[32];
        new iLen = strlen(szLine);

        // 提取authid (引号内)
        new iStart = -1, iEnd = -1;
        for (new i = 0; i < iLen; i++) {
            if (szLine[i] == '"') {
                if (iStart == -1) {
                    iStart = i + 1;
                } else {
                    iEnd = i;
                    break;
                }
            }
        }

        if (iStart == -1 || iEnd == -1) {
            continue;
        }

        new iAuthLen = iEnd - iStart;
        if (iAuthLen >= charsmax(szAuth)) {
            iAuthLen = charsmax(szAuth) - 1;
        }
        copy(szAuth, iAuthLen, szLine[iStart]);

        // 跳过引号和空格，找expire
        new iPos = iEnd + 1;
        while (iPos < iLen && (szLine[iPos] == ' ' || szLine[iPos] == '"')) {
            iPos++;
        }

        // 提取expire
        new iExpireStart = iPos;
        while (iPos < iLen && szLine[iPos] != ' ' && szLine[iPos] != '"') {
            iPos++;
        }
        new iExpireLen = iPos - iExpireStart;
        if (iExpireLen >= charsmax(szExpire)) {
            iExpireLen = charsmax(szExpire) - 1;
        }
        copy(szExpire, iExpireLen, szLine[iExpireStart]);

        // 提取reason (引号内)
        iStart = -1;
        iEnd = -1;
        for (new i = iPos; i < iLen; i++) {
            if (szLine[i] == '"') {
                if (iStart == -1) {
                    iStart = i + 1;
                } else {
                    iEnd = i;
                    break;
                }
            }
        }

        if (iStart != -1 && iEnd != -1) {
            new iReasonLen = iEnd - iStart;
            if (iReasonLen >= charsmax(szReason)) {
                iReasonLen = charsmax(szReason) - 1;
            }
            copy(szReason, iReasonLen, szLine[iStart]);
        } else {
            copy(szReason, charsmax(szReason), "未知");
        }

        // 检查是否过期
        new iExpire = str_to_num(szExpire);
        if (iExpire != 0 && iExpire < get_systime()) {
            continue; // 跳过已过期的封禁
        }

        copy(g_szBannedAuth[g_iBanCount], charsmax(g_szBannedAuth[]), szAuth);
        g_iBanExpire[g_iBanCount] = iExpire;
        copy(g_szBanReason[g_iBanCount], charsmax(g_szBanReason[]), szReason);
        g_iBanCount++;
    }

    fclose(fp);
}

// ============================================================
//  地图列表加载
// ============================================================
load_map_list()
{
    // 从mapcyclefile加载地图列表
    new szMapCycleFile[64];
    get_cvar_string("mapcyclefile", szMapCycleFile, charsmax(szMapCycleFile));

    new fp = fopen(szMapCycleFile, "rt");
    if (!fp) {
        // 尝试默认路径
        fp = fopen("mapcycle.txt", "rt");
        if (!fp) {
            return;
        }
    }

    g_iMapCount = 0;
    new szLine[64];

    while (!feof(fp) && g_iMapCount < 256) {
        fgets(fp, szLine, charsmax(szLine));
        trim(szLine);

        // 跳过注释和空行
        if (szLine[0] == ';' || szLine[0] == '/' || szLine[0] == '^0' || strlen(szLine) < 2) {
            continue;
        }

        // 检查是否是当前地图
        new szCurrentMap[64];
        get_mapname(szCurrentMap, charsmax(szCurrentMap));

        if (!equal(szLine, szCurrentMap)) {
            copy(g_szMapList[g_iMapCount], charsmax(g_szMapList[]), szLine);
            g_iMapCount++;
        }
    }

    fclose(fp);
}

// ============================================================
//  权限保存/加载 (PDS + ini 文件双备份)
// ============================================================

// 同步玩家权限等级(从flags较高者)
stock perm_sync_level_from_flags(id)
{
    if (!is_user_connected(id)) {
        return;
    }

    new iDetectedLevel = perm_level_from_flags(get_user_flags(id));
    if (iDetectedLevel > g_iPermLevel[id]) {
        g_iPermLevel[id] = iDetectedLevel;
    }
}

// 保存玩家权限到PDS和文件
stock perm_save(id)
{
    // 若 auth 尚未加载, 尝试重新获取, 避免发放权限后不保存
    if (g_szAuth[id][0] == '^0') {
        new szAuthTmp[64];
        get_user_authid(id, szAuthTmp, charsmax(szAuthTmp));
        if (szAuthTmp[0] && !equal(szAuthTmp, "STEAM_ID_LAN") && !equal(szAuthTmp, "VALVE_ID_LAN") && !equal(szAuthTmp, "STEAM_0:4:")) {
            copy(g_szAuth[id], charsmax(g_szAuth[]), szAuthTmp);
        } else {
            get_user_ip(id, g_szAuth[id], charsmax(g_szAuth[]), 1);
        }
        // 仍为空则放弃(无法识别身份无法保存)
        if (g_szAuth[id][0] == '^0')
            return;
    }

    new szKey[128];
    new szValue[8];
    num_to_str(g_iPermLevel[id], szValue, charsmax(szValue));

    // 判断是Steam玩家还是盗版玩家
    if (contain(g_szAuth[id], "STEAM_") != -1) {
        formatex(szKey, charsmax(szKey), "hns_perm_%s", g_szAuth[id]);
    } else {
        formatex(szKey, charsmax(szKey), "hns_permip_%s", g_szAuth[id]);
    }

    // 保存到PDS
    PDS_SetString(szKey, szValue);

    // 保存到文件
    perm_save_file();
}

// 从PDS和文件加载玩家权限
stock perm_load(id)
{
    if (g_szAuth[id][0] == '^0') {
        return;
    }

    new szKey[128];
    new szValue[8];

    // 判断是Steam玩家还是盗版玩家
    if (contain(g_szAuth[id], "STEAM_") != -1) {
        formatex(szKey, charsmax(szKey), "hns_perm_%s", g_szAuth[id]);
    } else {
        formatex(szKey, charsmax(szKey), "hns_permip_%s", g_szAuth[id]);
    }

    // 先从PDS加载
    if (PDS_GetString(szKey, szValue, charsmax(szValue))) {
        g_iPermLevel[id] = str_to_num(szValue);
        return;
    }

    // PDS没有，从文件加载
    new szDir[128];
    get_configsdir(szDir, charsmax(szDir));
    new szFile[256];
    formatex(szFile, charsmax(szFile), "%s/permsystem/perm_list.ini", szDir);

    new fp = fopen(szFile, "rt");
    if (!fp) {
        g_iPermLevel[id] = PERM_NONE;
        return;
    }

    new szLine[256];
    new bool:bFound = false;
    new iFileVersion = 1;

    while (!feof(fp) && !bFound) {
        fgets(fp, szLine, charsmax(szLine));
        trim(szLine);

        if (containi(szLine, "StorageVersion:") != -1) {
            new szVersion[16];
            copy(szVersion, charsmax(szVersion), szLine);
            replace(szVersion, charsmax(szVersion), ";", "");
            replace(szVersion, charsmax(szVersion), "StorageVersion:", "");
            trim(szVersion);
            iFileVersion = str_to_num(szVersion);
            continue;
        }

        // 跳过注释和空行
        if (szLine[0] == ';' || szLine[0] == '/' || szLine[0] == '^0') {
            continue;
        }

        // 格式: steamid_or_ip name permission_level
        new szAuth[64], szName[32], szPerm[8];
        parse(szLine, szAuth, charsmax(szAuth), szName, charsmax(szName), szPerm, charsmax(szPerm));

        if (equal(szAuth, g_szAuth[id])) {
            new iPerm = str_to_num(szPerm);
            // 旧版本迁移: 1=VIP 2=管理员 3=服主 → 2=VIP 3=管理员 4=服主
            if (iFileVersion < PERM_STORAGE_VERSION && iPerm >= 1 && iPerm <= 3)
                iPerm += 1;

            if (iPerm >= PERM_NONE && iPerm <= PERM_OWNER) {
                g_iPermLevel[id] = iPerm;

                // 同步到PDS
                num_to_str(iPerm, szValue, charsmax(szValue));
                PDS_SetString(szKey, szValue);
            }
            bFound = true;
        }
    }

    fclose(fp);

    if (!bFound) {
        g_iPermLevel[id] = PERM_NONE;
    }
}

// 写入文件备份 (ini)
stock perm_save_file()
{
    new szDir[128];
    get_configsdir(szDir, charsmax(szDir));
    new szFile[256];
    formatex(szFile, charsmax(szFile), "%s/permsystem/perm_list.ini", szDir);

    // ★ 先读取现有文件中的全部历史记录(含离线玩家)，避免覆盖丢失
    new Trie:tExisting = TrieCreate();
    new fp_r = fopen(szFile, "rt");
    if (fp_r) {
        new szLine[256];
        while (!feof(fp_r)) {
            fgets(fp_r, szLine, charsmax(szLine));
            trim(szLine);
            if (szLine[0] == ';' || szLine[0] == '/' || szLine[0] == '^0') continue;

            new szAuth[64], szName[32], szPerm[8];
            parse(szLine, szAuth, charsmax(szAuth), szName, charsmax(szName), szPerm, charsmax(szPerm));
            if (!szAuth[0]) continue;

            // 记录离线/在线玩家原权限 (仅当当前不在内存中覆盖时保留)
            if (!TrieKeyExists(tExisting, szAuth)) {
                TrieSetCell(tExisting, szAuth, str_to_num(szPerm));
            }
        }
        fclose(fp_r);
    }

    new fp = fopen(szFile, "wt");
    if (!fp) {
        TrieDestroy(tExisting);
        return;
    }

    fprintf(fp, "; HNS Admin Suite 权限名单 (ini 为权威)^n");
    fprintf(fp, "; StorageVersion: %d^n", PERM_STORAGE_VERSION);
    fprintf(fp, "; 格式: steamid_or_ip name permission_level^n");
    fprintf(fp, "; 等级: 0=普通 1=临时 2=VIP 3=管理员 4=服主^n");
    fprintf(fp, "; 重要: 本文件是纸面权限的唯一权威。玩家不在本文件里 = 普通玩家。^n");
    fprintf(fp, "; 官方认证服主由 users.ini 管理, 不受本文件限制。^n");
    fprintf(fp, "; 清除某人的记录 = 立即失效其纸面权限。^n^n");

    new players[32], num;
    get_players(players, num);

    // 写入在线玩家(内存中的最新权限)
    for (new i = 0; i < num; i++) {
        new pid = players[i];
        if (g_iPermLevel[pid] > PERM_NONE && g_szAuth[pid][0] != '^0') {
            new szName[32];
            get_user_name(pid, szName, charsmax(szName));

            // 替换空格为下划线
            for (new j = 0; j < strlen(szName); j++) {
                if (szName[j] == ' ') {
                    szName[j] = '_';
                }
            }

            fprintf(fp, "%s %s %d^n", g_szAuth[pid], szName, g_iPermLevel[pid]);
            // 已在内存中，从历史表移除(避免重复)
            if (TrieKeyExists(tExisting, g_szAuth[pid])) {
                TrieDeleteKey(tExisting, g_szAuth[pid]);
            }
        }
    }

    // 补写离线玩家(保留其历史权限，防止权限自动掉)
    new TrieIter:tIter = TrieIterCreate(tExisting);
    new szIterAuth[64], iIterPerm;
    while (!TrieIterEnded(tIter)) {
        TrieIterGetKey(tIter, szIterAuth, charsmax(szIterAuth));
        TrieIterGetCell(tIter, iIterPerm);
        if (iIterPerm > PERM_NONE) {
            fprintf(fp, "%s unknown %d^n", szIterAuth, iIterPerm);
        }
        TrieIterNext(tIter);
    }
    TrieIterDestroy(tIter);
    TrieDestroy(tExisting);

    fclose(fp);
}

// 启动时从文件加载到PDS (ini)
stock perm_load_file()
{
    new szDir[128];
    get_configsdir(szDir, charsmax(szDir));
    new szFile[256];
    formatex(szFile, charsmax(szFile), "%s/permsystem/perm_list.ini", szDir);

    new fp = fopen(szFile, "rt");
    if (!fp) {
        return;
    }

    new szLine[256];
    new iFileVersion = 1;

    while (!feof(fp)) {
        fgets(fp, szLine, charsmax(szLine));
        trim(szLine);

        if (containi(szLine, "StorageVersion:") != -1) {
            new szVersion[16];
            copy(szVersion, charsmax(szVersion), szLine);
            replace(szVersion, charsmax(szVersion), ";", "");
            replace(szVersion, charsmax(szVersion), "StorageVersion:", "");
            trim(szVersion);
            iFileVersion = str_to_num(szVersion);
            continue;
        }

        // 跳过注释和空行
        if (szLine[0] == ';' || szLine[0] == '/' || szLine[0] == '^0') {
            continue;
        }

        // 格式: steamid_or_ip name permission_level
        new szAuth[64], szName[32], szPerm[8];
        parse(szLine, szAuth, charsmax(szAuth), szName, charsmax(szName), szPerm, charsmax(szPerm));

        new iPerm = str_to_num(szPerm);
        if (iFileVersion < PERM_STORAGE_VERSION && iPerm >= 1 && iPerm <= 3) {
            iPerm += 1;
        }
        if (iPerm < PERM_NONE || iPerm > PERM_OWNER) {
            continue;
        }

        // 构建PDS键名
        new szKey[128];
        if (contain(szAuth, "STEAM_") != -1) {
            formatex(szKey, charsmax(szKey), "hns_perm_%s", szAuth);
        } else {
            formatex(szKey, charsmax(szKey), "hns_permip_%s", szAuth);
        }

        // 加载到PDS
        num_to_str(iPerm, szPerm, charsmax(szPerm));
        PDS_SetString(szKey, szPerm);
    }

    fclose(fp);

    // 同时加载封禁列表
    load_bans_file();
}