# corplink-rs-dockerization

容器化的 [PinkD/corplink-rs](https://github.com/PinkD/corplink-rs)（飞连 / Feilian 的 Rust 第三方客户端），并内置 [go-gost](https://github.com/go-gost/gost) 作为 **SOCKS5 + HTTP 代理**把 VPN 通道对外暴露。

镜像托管在 GitHub Container Registry，定时跟随 upstream master/tag 自动构建。

- 镜像仓库: `ghcr.io/yanickxia/corplink-rs-dockerization`
- 支持架构:
  - **默认镜像 (debian-slim)**: `linux/amd64`, `linux/arm64`
  - **路由器镜像 (alpine-slim)**: `linux/amd64`, `linux/arm64`, `linux/arm/v7`
- 参考项目: [iBug/docker-corplink](https://github.com/iBug/docker-corplink)

> ⚠️ 使用前请先阅读 [PinkD/corplink-rs 的 README](https://github.com/PinkD/corplink-rs/blob/master/README.md)，了解配置字段和注意事项。本镜像**不改变 corplink-rs 的行为**，只是把它容器化 + 附加了一个 gost 代理。

---

## 特性

- 🐳 开箱即用的容器镜像，已包含 `corplink-rs` 和 `gost`
- 🌐 多架构：`amd64`、`arm64`（默认镜像）；`amd64` / `arm64` / `armv7`（路由器镜像）
- 🛰️ 定时 CI：每 6 小时检查 upstream master 是否有新提交或新 tag，有就自动构建并推送
- 🏷️ 上游 tag 自动镜像到本仓库（比如 upstream 发 `5.4`，本仓库也会得到 `5.4` / `v5.4` / `5.4-router` tag）
- 🧦 内置 SOCKS5 + HTTP 代理（gost），可用作浏览器代理 / 家里的 VPN 出口网关
- 🪶 额外提供 alpine-based 的路由器镜像，适合运行在 OpenWRT / iStoreOS / 群晖 / GL.iNet 等资源受限设备上

---

## 镜像 Tag 一览

| Tag | 说明 |
|---|---|
| `latest` | 默认镜像，跟随 upstream master |
| `master-<sha>` | 某一次 master 构建的精确版本 |
| `<upstream-tag>` / `v<upstream-tag>` | 与 upstream release tag 对齐（如 `5.4` / `v5.4`） |
| `latest-router` / `router` | 路由器镜像,跟随 upstream master |
| `master-<sha>-router` | 路由器镜像的 master 精确版本 |
| `<upstream-tag>-router` | 路由器镜像对齐的 release 版本 |

---

## 快速开始

### 1. 准备配置

创建一个目录，写入 `config.json`（参考 [config/config.example.json](./config/config.example.json)）：

```bash
mkdir -p ./config
cp config/config.example.json ./config/config.json
$EDITOR ./config/config.json
```

**最小配置示例**：

```json
{
  "company_name": "your-company-code",
  "username": "your_username",
  "password": "your_password",
  "platform": "ldap"
}
```

完整的字段说明见 [PinkD/corplink-rs 的 README](https://github.com/PinkD/corplink-rs/blob/master/README.md#配置文件实例)。

### 2. 启动容器

#### 方式 A：docker run

```bash
docker run -d \
  --name corplink \
  --restart unless-stopped \
  --device /dev/net/tun \
  --cap-add NET_ADMIN \
  -v "$PWD/config:/config" \
  -p 1080:1080 \
  -p 8080:8080 \
  ghcr.io/yanickxia/corplink-rs-dockerization:latest
```

#### 方式 B：docker compose（推荐）

仓库自带 [`docker-compose.yml`](./docker-compose.yml)，直接：

```bash
docker compose up -d
docker compose logs -f
```

### 3. 使用代理

- **SOCKS5 代理**: `socks5://<host>:1080`
- **HTTP 代理**:   `http://<host>:8080`

验证：

```bash
# 直连 vs 走 VPN 出口对比
curl ifconfig.me
curl -x socks5h://localhost:1080 ifconfig.me
```

浏览器 / 终端配置代理后，出口 IP 就会是飞连 VPN 网关。

---

## 路由器部署

如果你想把它跑在家里的路由器（群晖、iStoreOS、OpenWRT on x86、GL.iNet ARMv7 等）上，用路由器镜像可以省一些内存和存储：

```bash
docker run -d \
  --name corplink \
  --restart unless-stopped \
  --device /dev/net/tun \
  --cap-add NET_ADMIN \
  -v /root/corplink:/config \
  -p 1080:1080 -p 8080:8080 \
  ghcr.io/yanickxia/corplink-rs-dockerization:latest-router
```

路由器版本与默认版本功能一致,但：
- 基于 Alpine 3.19，而非 debian-slim
- 使用 `tini` 作为 PID 1（而非 s6-svscan），常驻内存更低
- 额外支持 `linux/arm/v7`（ARMv7 32 位）

### 做成整个 LAN 的 VPN 出口网关

在路由器上：

```bash
# 让 LAN 内其它设备把 gost 当作代理出口
# 1) 在路由器 LAN DHCP 分发一个 PAC / 代理配置
# 2) 或在客户端里手动填入 socks5://<router-ip>:1080
```

如果想做**透明代理**（不用在客户端配代理），可自行挂一份 `/config/gost.yml` 使用 `gost` 的 `redirect` / `tproxy` 插件；参考 [gost 文档](https://gost.run/)。

---

## 配置参考

### 环境变量

| 变量 | 默认值 | 说明 |
|---|---|---|
| `TZ` | `UTC` | 时区 |
| `GOST_SOCKS_PORT` | `1080` | SOCKS5 监听端口 |
| `GOST_HTTP_PORT` | `8080` | HTTP 代理监听端口 |
| `GOST_USER` | *(空)* | 可选，代理用户名（设置后两个代理都会开启 basic auth） |
| `GOST_PASS` | *(空)* | 可选,代理密码 |

#### 通过环境变量配置 corplink-rs（可选）

除了挂载 `config.json`,你也可以完全通过 `CORPLINK_*` 环境变量来配置。容器每次启动时会把这些变量**合并**进 `/config/config.json`：

- 用户字段 (`company_name` / `username` / ... ) 如果 env 里设置了就覆盖
- corplink-rs 运行时生成的字段 (`device_id` / `public_key` / `private_key` / `state` / `cookies.json`) 永远**保留**,不会被 env 清掉
- 空字符串 (`-e FOO=`) 会被**忽略**,不会把已有字段改成空串
- 字面量字符串 `"null"` 会被写成 JSON `null`
- 数组字段用逗号分隔,例如 `10.68.0.0/16,192.168.1.0/24`
- 多次启动是幂等的:配置没变化就不会重写文件

支持的变量：

| 变量 | JSON 字段 | 类型 |
|---|---|---|
| `CORPLINK_COMPANY_NAME` | `company_name` | string |
| `CORPLINK_USERNAME` | `username` | string |
| `CORPLINK_PASSWORD` | `password` | string |
| `CORPLINK_PLATFORM` | `platform` | string (`ldap` / `feishu` / `oidc` / ...) |
| `CORPLINK_CODE` | `code` | string (2FA/TOTP) |
| `CORPLINK_SERVER` | `server` | string (URL) |
| `CORPLINK_DEVICE_NAME` | `device_name` | string |
| `CORPLINK_INTERFACE_NAME` | `interface_name` | string |
| `CORPLINK_VPN_SERVER_NAME` | `vpn_server_name` | string |
| `CORPLINK_VPN_SELECT_STRATEGY` | `vpn_select_strategy` | string |
| `CORPLINK_ROUTE_MODE` | `route_mode` | string (`full` / `split`) |
| `CORPLINK_DEBUG_WG` | `debug_wg` | bool (`true`/`false`/`1`/`0`/`yes`/`no`) |
| `CORPLINK_USE_VPN_DNS` | `use_vpn_dns` | bool |
| `CORPLINK_AUTO_SETUP_ROUTES` | `auto_setup_routes` | bool |
| `CORPLINK_VPN_DISALLOWED_ROUTES` | `vpn_disallowed_routes` | CSV → string[] |

示例(纯 env 配置,不挂 config.json 也行,容器第一次启动会自动创建):

```bash
docker run -d \
  --name corplink \
  --device /dev/net/tun --cap-add NET_ADMIN \
  -v "$PWD/config:/config" \
  -e CORPLINK_COMPANY_NAME=bytedance \
  -e CORPLINK_USERNAME=alice \
  -e CORPLINK_PLATFORM=ldap \
  -e CORPLINK_ROUTE_MODE=full \
  -e CORPLINK_VPN_DISALLOWED_ROUTES=10.68.0.0/16 \
  -p 1080:1080 -p 8080:8080 \
  ghcr.io/yanickxia/corplink-rs-dockerization:latest
```

### 挂载点

| 路径 | 说明 |
|---|---|
| `/config/config.json` | **必需**,corplink-rs 配置文件 |
| `/config/gost.yml` | *可选*,自定义 gost 配置（存在则优先于 env 自动生成的配置） |
| `/config/cookies.json` | corplink 运行时自动生成的会话 cookie |

### 高级 gost 配置

默认情况下,容器会基于 `GOST_SOCKS_PORT` / `GOST_HTTP_PORT` 自动生成一个简单的 SOCKS5 + HTTP 组合代理。

如果你要做用户认证、TLS、透明代理、端口转发等高级用法,把 YAML 写到 `./config/gost.yml`（参考 [config/gost.example.yml](./config/gost.example.yml) 或 [gost 官方文档](https://gost.run/en/concepts/)）,容器会自动使用该文件启动：

```bash
cp config/gost.example.yml ./config/gost.yml
$EDITOR ./config/gost.yml
docker compose restart
```

---

## 从源码构建

本地构建（只构建当前架构，调试用）：

```bash
docker buildx build \
  --load \
  --build-arg CORPLINK_REF=master \
  -t corplink-rs:dev .
```

多架构构建并推送（需要先 `docker login ghcr.io`）：

```bash
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  --build-arg CORPLINK_REF=master \
  -t ghcr.io/<you>/corplink-rs-dockerization:latest \
  --push .

# 路由器镜像
docker buildx build \
  --file Dockerfile.router \
  --platform linux/amd64,linux/arm64,linux/arm/v7 \
  --build-arg CORPLINK_REF=master \
  -t ghcr.io/<you>/corplink-rs-dockerization:latest-router \
  --push .
```

### 构建参数

| Build Arg | 默认值 | 说明 |
|---|---|---|
| `CORPLINK_REF` | `master` | corplink-rs 的 git ref,可为分支 / tag / commit SHA |
| `GO_VERSION` | `1.22.5` | 编译 libwg 用的 Go 版本 |
| `GOST_VERSION` | `3.2.6` | gost 预编译二进制版本 |

---

## CI / 定时构建说明

本仓库配了一条 GitHub Actions workflow（[`.github/workflows/build.yml`](./.github/workflows/build.yml)）：

1. **`schedule: '0 */6 * * *'`**：每 6 小时跑一次 `detect` job
2. `detect` job 调 GitHub API,拿 upstream `master` 最新 SHA 和最新 tag,并与本仓库上已有的 `upstream-<sha>` 标签比对
3. 如果 upstream master 有新提交,或者 upstream 发了新 tag,就触发 `build-default` + `build-router` 两个并行 job,`buildx` 多架构构建并推到 GHCR
4. 构建成功后 `record` job 会：
   - 在本仓库打一个 `upstream-<short-sha>` 的 lightweight 标签,用于下一次 detect 跳过重复构建
   - 如果这次构建的是 upstream 的 release tag,也会把该 tag（含 `v` 前缀变体）镜像到本仓库

`workflow_dispatch` 触发提供两个输入：

- `force: true`：忽略"已经构建过"的判断,强制重跑
- `ref: <branch|tag|sha>`：指定一个上游 ref 单独构建

### 开启前置条件

1. 本仓库需要能写 `packages` 权限 —— 默认的 `GITHUB_TOKEN` 就够用
2. 第一次推镜像后,到 `https://github.com/users/<you>/packages/container/corplink-rs-dockerization/settings` 把可见性调成 **Public**(可选,默认 Private)

---

## 故障排查

| 现象 | 解决 |
|---|---|
| 容器日志刷 `waiting for /config/config.json` | 没挂配置文件,请检查 `-v` 参数 |
| `TUN device: operation not permitted` | 没加 `--cap-add NET_ADMIN` 或 `--device /dev/net/tun` |
| `curl -x socks5h://localhost:1080` 挂起 | corplink 没连上 VPN,先 `docker logs corplink` 看登录流程 |
| 连上 VPN 但出口 IP 没变 | 检查 corplink 配置 `route_mode` / `vpn_disallowed_routes`,或看 `ip route` |
| 路由器镜像起不来,报 `not found` | 设备不是 armv7/arm64/amd64,或者内核缺 tun 模块 |

查日志：

```bash
docker logs -f corplink

# 进入容器排查
docker exec -it corplink sh
ip -br addr      # 看 tun 接口是否起来
ip route         # 看路由表
```

---

## 鸣谢

- [PinkD/corplink-rs](https://github.com/PinkD/corplink-rs) —— 飞连的 Rust 客户端实现
- [iBug/docker-corplink](https://github.com/iBug/docker-corplink) —— 容器化思路参考
- [go-gost/gost](https://github.com/go-gost/gost) —— 多协议代理
- [s6-overlay](https://github.com/just-containers/s6-overlay) —— 容器 init 系统

---

## License

与 upstream 一致,GPL-2.0-or-later。本仓库的打包脚本（Dockerfile / CI / README）可随意使用、修改、分发。
