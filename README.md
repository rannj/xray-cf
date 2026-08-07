# xray-cf-lite

最小化 VLESS + XHTTP + Cloudflare 节点部署脚本。不需要面板，一个 Bash 脚本搞定。

## 适用场景

- NAT 小鸡（端口映射环境）
- Alpine / LXC 容器
- 低配机器（256MB 内存即可）
- 不想装 3x-ui 等面板

## 前置条件

### 服务器

- Linux（Debian/Ubuntu/Alpine/CentOS 均可）
- root 权限
- Bash 4+
  - Debian/Ubuntu 默认自带
  - Alpine 需要安装：`apk add bash`
  - CentOS 默认自带
- 脚本会自动安装 `curl`、`jq`、`unzip`（通过 apk/apt/yum）
- xray-core 由脚本自动下载安装（不依赖官方安装脚本，兼容非 systemd 环境）

### init 系统

- **systemd**（Debian/Ubuntu/CentOS 等）：自动使用 systemd 管理 xray 服务
- **OpenRC**（Alpine 等）：自动创建 `/etc/init.d/xray` 服务脚本

### Cloudflare

- 域名已托管在 Cloudflare
- 账号邮箱 + **Global API Key**（在 [Cloudflare Dashboard](https://dash.cloudflare.com/profile/api-tokens) -> API Keys -> Global API Key 查看）
- 脚本会自动处理 CF 安全规则（Bot Fight Mode、Security Level、Browser Check），无需手动操作

### NAT 环境

如果服务器是 NAT（内网 IP，通过端口映射暴露服务），需要提前知道：

- SSH 端口映射（用于登录）
- 一组可用的端口映射（用于 VLESS XHTTP 节点）
- 安装时按提示输入内部端口和外部端口

## 安装

不需要落盘，直接联网运行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/byJoey/xray-cf-lite/main/xray_cf_lite.sh)
```

首次运行后自动注册快捷命令 `x`，之后直接输入：

```bash
x
```

等效于每次联网拉取最新脚本执行，不在本地留文件。

## 功能

```
1. 安装节点        部署 xray + 配置 CF（DNS/SSL/Origin Rules）+ 生成订阅链接
2. 卸载            停止 xray + 回滚 CF 配置(DNS/SSL/Origin Rules) + 清理本地状态/凭据/订阅快照
3. 查看订阅        显示上次生成的订阅链接
4. 修改配置        修改 UUID / 端口 / XHTTP 路径（可单改或全改）
5. 查看当前配置    显示域名、UUID、端口映射、xray 服务状态、订阅链接
6. 更新外部端口    NAT 换端口专用：只更新 CF Origin Rules，不重启 xray
```

## 安装流程中的可选项

| 选项 | 说明 | 默认值 |
|------|------|--------|
| 域名 | 绑定到 CF 的子域名 | 必填 |
| CF 凭据 | 邮箱 + Global API Key | 首次必填，之后自动复用 |
| 协议与传输 | VLESS + XHTTP | 固定 |
| UUID | 节点身份标识 | 自动生成 |
| 端口 | xray 监听端口 | 随机（直连）/ 手动输入映射（NAT） |
| XHTTP 路径 | XHTTP 请求路径 | `/{UUID前8位}` |

## NAT 端口映射

脚本自动检测 NAT 环境。安装时按提示输入端口映射：

```
内部监听端口(xray监听): 80
外部映射端口(对外暴露): 15331
```

- 内部端口 = xray 在容器内监听的端口
- 外部端口 = 宿主机暴露的映射端口，写入 CF Origin Rules

**外部端口变了怎么办？**

选菜单 6，输入新的外部端口即可。只更新 CF Origin Rules，不重启 xray，几秒完成。

## 崩溃自动重启

xray 进程崩溃后 1 秒自动拉起，无限重启：

- **systemd**：通过 drop-in 配置 `Restart=on-failure`、`RestartSec=1`
- **OpenRC**：通过 `supervise-daemon` 的 `respawn` 机制，`respawn_delay=1`、`respawn_max=0`（无限）

## 文件说明

| 文件 | 路径 | 说明 |
|------|------|------|
| xray 二进制 | `/usr/local/bin/xray` | 自动下载 |
| xray 配置 | `/usr/local/etc/xray/config.json` | 自动生成 |
| 状态记录 | `/etc/xray-cf-lite/state.json` | 卸载回滚依据 |
| CF 凭据 | `/etc/xray-cf-lite/cf_account.json` | 权限 600 |
| 订阅快照 | `./cf_lite_last_links.txt` | 运行目录下 |
| OpenRC 服务 | `/etc/init.d/xray` | 仅 OpenRC 环境 |

## 工作原理

```
客户端 -> Cloudflare CDN (443/TLS) -> Origin Rules (改端口) -> 服务器外部端口 -> NAT -> xray 内部端口
```

- Cloudflare 代理域名，客户端通过 CDN 连接
- Origin Rules 将 XHTTP 路径及其动态子路径转发到节点端口
- SSL 模式设为 `flexible`（CF 到源站用 HTTP）
- xray 使用 VLESS + XHTTP，服务端采用 XHTTP 默认模式
- 生成的客户端节点使用 `stream-up`，利用 Cloudflare 已开启的 gRPC 支持实现流式上行
- 客户端通过 Cloudflare 443/TLS 连接，Cloudflare 到源站由 Origin Rules 回源

## 注意事项

- 安装时自动关闭 Bot Fight Mode / Security Level / Browser Check，卸载时自动恢复原值
- 卸载会完整恢复 CF 配置（DNS 记录、SSL 模式、Origin Rules）到安装前状态，并清理本地 state.json / cf_account.json / 订阅快照
- CF 凭据保存在服务器本地，不会上传到任何地方；输入时会实时校验，错误可当场重输（不会直接退出）
- 一台服务器同时只支持一组部署（再次安装需先卸载）

## XHTTP 说明

- 服务端仅设置随机路径，其余 XHTTP 参数采用 Xray Core 默认值。
- Cloudflare 需要预先开启 gRPC；脚本生成的客户端节点固定使用 `stream-up`。
- XHTTP 会在基础路径后追加会话标识，因此 Origin Rule 使用路径前缀匹配。
- 节点链接要求客户端支持 XHTTP；旧版仅支持 WebSocket 的客户端无法使用。
- 已通过旧版脚本部署的 WS 节点需要先卸载，再使用新版脚本重新安装。
- 设计与参数说明参见 [Xray Core XHTTP 官方文档](https://xtls.github.io/config/transports/xhttp.html)。
