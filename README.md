# xray-cf-lite

使用 **VLESS + XHTTP + Cloudflare Tunnel** 部署 Xray 节点的轻量 Bash 脚本。Xray 仅监听本机回环地址，服务器无需公网 IP、NAT 端口映射或开放入站端口。

## 架构

```text
客户端 → Cloudflare (443/TLS) → Cloudflare Tunnel
       → cloudflared → 127.0.0.1:8080 → Xray VLESS/XHTTP
```

`cloudflared` 主动连接 Cloudflare，外部无法绕过 Cloudflare 直接访问 Xray。

## 前置条件

### 服务器

- Linux，root 权限，Bash 4+
- systemd 或 OpenRC
- `cloudflared` **2025.4.0 或更高版本**
- 脚本自动安装 `curl`、`jq`、`unzip` 和 Xray Core
- 脚本**不会下载、安装或升级 cloudflared**

### Cloudflare Tunnel

1. 在 Cloudflare Dashboard 的 **Networking → Tunnels** 创建远程管理 Tunnel。
2. 打开 Tunnel，选择 **Add a replica**，复制命令中的 `eyJ...` Token。
3. 添加 Published application：

   - Hostname：准备作为节点使用的域名
   - Service URL：`http://127.0.0.1:8080`
   - Path：留空

如果安装时选择其他本地端口，Service URL 必须使用相同端口。

## 安装

旧版使用公网端口、DNS A 记录和 Origin Rules 的部署不能原地迁移，请先备份节点信息并清理旧部署，再按本页步骤安装 Tunnel 版本。

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/byJoey/xray-cf-lite/main/xray_cf_lite.sh)
```

首次运行后可使用快捷命令：

```bash
x
```

安装时依次输入：

- Tunnel 公开域名
- Xray 本地监听端口，默认 `8080`
- UUID，默认自动生成
- XHTTP 路径，默认使用 UUID 前八位
- Cloudflare Tunnel Token（隐藏输入）

## 功能

```text
1. 安装节点
2. 卸载本地服务配置
3. 查看节点链接
4. 修改 UUID/XHTTP 路径
5. 查看当前配置与服务状态
6. 重启 Xray 和 cloudflared-xray
```

## 服务隔离

脚本创建独立的 `cloudflared-xray` 服务，不调用 `cloudflared service install`，也不会覆盖已有的 `cloudflared.service` 或 `/etc/cloudflared/config.yml`。

Tunnel Token 保存在：

```text
/etc/xray-cf-lite/tunnel.token
```

文件权限为 `600`。服务通过官方 `--token-file` 参数读取 Token，不把 Token 写入命令行参数。

## 文件说明

| 文件 | 说明 |
|------|------|
| `/usr/local/etc/xray/config.json` | Xray 配置 |
| `/etc/xray-cf-lite/state.json` | 部署状态 |
| `/etc/xray-cf-lite/tunnel.token` | Tunnel Token，权限 600 |
| `/etc/systemd/system/cloudflared-xray.service` | systemd Tunnel 服务 |
| `/etc/init.d/cloudflared-xray` | OpenRC Tunnel 服务 |
| `./cf_lite_last_links.txt` | 节点链接快照 |

## XHTTP

- Xray 入站固定为 VLESS + XHTTP。
- Xray 只监听 `127.0.0.1`，传输安全设为 `none`；客户端到 Cloudflare 使用 TLS。
- 客户端节点使用 `stream-up`。
- Cloudflare Dashboard 中的 gRPC 开关需要提前开启。
- Published application 的 Path 必须留空，让请求完整转发给 Xray 校验随机路径。

## 卸载行为

卸载会停止并删除本地 `cloudflared-xray` 服务、Xray 配置、Token、状态和链接快照，但不会：

- 卸载 cloudflared
- 删除 Cloudflare Dashboard 中的 Tunnel
- 删除 Published application 或 DNS 记录
- 删除 Xray 二进制

如需彻底清理 Cloudflare 配置，请在 Dashboard 中手动删除对应 Published application 或 Tunnel。

## 参考

- [Cloudflare Tunnel](https://developers.cloudflare.com/tunnel/)
- [Tunnel Token](https://developers.cloudflare.com/tunnel/advanced/tunnel-tokens/)
- [Published applications](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/routing-to-tunnel/)
- [Xray Core XHTTP](https://xtls.github.io/config/transports/xhttp.html)
