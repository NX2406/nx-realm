# NXR · Realm 转发面板

基于 [realm](https://github.com/zhboner/realm) 的端口转发管理脚本，为"前置 → IX → 落地"多跳中转设计。在前置机上登记好各节点后，一条命令就能把整条链路部署到每台机器，并持续做健康检查。

终端菜单和命令行两种用法功能一致，单文件 Bash 脚本，无需数据库和 Web 服务。

## 功能

- **单机转发规则**：TCP / UDP / TCP+UDP，指定出站源 IP 或网卡、入站网卡，PROXY protocol，DNS 解析策略，超时设置。
- **主备与负载均衡**：一条规则可带备用目标（自动探测、自动切换、可选切回），或多个目标轮询 / 按来源 IP 分流（可带权重），故障成员自动摘除、恢复后自动加回。
- **多节点链路**：前置机通过 SSH 把规则下发到 IX、中转、落地，从最后一跳往前部署，任何一跳失败会自动清理已部署的部分。
- **一个前置 · 多个 IX · 多个出口**：同一跳可写多台 IX 共同承担（主备或负载均衡）；出口也可以写多个，还可以给每台 IX 指定专用出口地址。批量开线路向导一次生成"一前置 × 多 IX × 多出口"的全部线路。
- **来源 IP 白名单**：链路里第 2 跳起只接受上一跳节点的连接，端口被扫到也无法盗用（nftables，没有则回退 iptables）。单条规则也可以手动设置。
- **跳间加密**：TLS、WebSocket、WSS（realm 内置传输层，无需额外程序）。
- **流量统计**：按规则统计上下行流量（nftables 计数器，回退 iptables）。
- **防火墙联动**：添加规则自动放行 ufw / firewalld / iptables，删除规则自动关闭。
- **诊断工具**：逐跳检测链路、TCP 延迟测试、规则日志、拓扑总览。
- **迁移**：导入已有 realm TOML 配置；导出全部规则为 nxr 命令；备份与恢复。

每条规则是一个独立的 realm 进程（systemd 模板 `nxr@端口`，Alpine 上为 OpenRC 服务），修改一条规则不会中断其他规则。

## 安装

```bash
bash <(curl -sL https://raw.githubusercontent.com/NX2406/nx-realm/main/nxr.sh)
```

国内机器访问 GitHub 不稳定时：

```bash
bash <(curl -sL https://ghfast.top/https://raw.githubusercontent.com/NX2406/nx-realm/main/nxr.sh)
```

安装后输入 `nxr` 打开菜单。添加第一条规则时会自动下载 realm（国内自动走 GitHub 加速，并校验 SHA256）。

已在 x86_64 上测试：Debian 12、Ubuntu 24.04、Rocky Linux 9、Alpine 3.22（OpenRC）；Debian 11、Rocky Linux 8 早期测过，本轮未复测。脚本也会为 arm64 下载对应的 realm。

2026-11 在一台 Debian 12 前置机（KVM）加四个 LXC 节点（Debian 12、Ubuntu 24.04 + ufw、Rocky Linux 9 + firewalld、Alpine 3.22）上做了完整实测：单机规则、主备与负载均衡、节点管理、多 IX / 多出口链路、跳间加密、部署失败回滚、导入导出、备份恢复、更新与卸载。

## 原理

```
客户端 ──▶ 前置机 :11111 ──▶ IX :22222 ──▶ 落地 :33333
          （nxr 控制端）    （nxr 节点）
```

- 每一跳就是该机器上的一条 realm 转发规则，监听本跳端口、转发到下一跳。
- 前置机保存节点清单和 SSH 密钥（`/etc/nxr/ssh/id_ed25519`）。部署时先检查各节点上的 nxr 是否与本机一致，不一致就自动同步，然后通过 SSH 在节点上执行 `nxr add ...`。
- 链路记录保存在前置机 `/etc/nxr/chains/`，删除链路时会到每台节点清理对应规则。
- 节点只需要能 SSH 登录（root，或有免密 sudo 的用户），支持跳板机。

## 快速上手

### 单机转发

```bash
nxr add --port 11111 --remote 203.0.113.20:22222
nxr add --port 443 --remote a.com:443 --backup b.com:443,c.com:443          # 主备
nxr add --port 8443 --remote 10.0.0.1:443 --extra 10.0.0.2:443 --balance roundrobin --health   # 负载均衡
nxr list
```

### 前置 → IX → 落地

在前置机上登记 IX 节点，并安装控制端公钥（只需输入一次该节点的 SSH 密码）：

```bash
nxr node add ix-hk 203.0.113.10        # 可加 --port 2222 --user ubuntu --jump 跳板节点
nxr node key ix-hk
nxr node test
```

也可以在菜单"节点管理"里按向导添加，向导会自动完成公钥安装。

一条命令部署整条链路：

```bash
nxr chain add --name hk --hop local:11111 --hop ix-hk:22222 --target 10.0.0.1:33333
```

- `--hop` 按顺序写每一跳，`local` 表示本机（前置）。
- `ix-hk:22222@203.0.113.10` 中 `@` 后面是上一跳连接本跳时使用的地址（默认取节点登记的地址），`%eth1` 可指定本跳出站网卡。
- `--target` 是落地地址。

### 一个前置 · 多个 IX · 多个出口

```bash
# 两台 IX 轮询分担，出口主备
nxr chain add --name multi --hop local:11112 --hop ix-a:22222,ix-b:22222 \
  --target 10.0.0.1:33333,10.0.0.2:33333 --mode roundrobin --target-mode failover

# 每台 IX 走自己专用的出口（例如各自内网里的落地）
nxr chain add --hop local:11113 --hop ix-a:22223,ix-b:22223 \
  --target ix-a=192.168.1.10:33333 --target ix-b=192.168.2.10:33333
```

- `--mode` 决定前置如何在多台 IX 之间分流，`--target-mode` 决定 IX 如何在多个出口之间分流：`failover`（主备）、`roundrobin`（轮询）、`iphash`（按来源 IP，只在前置这一跳有效）。
- 交互菜单里的"批量开线路"可以一次生成"一前置 × 多 IX × 多出口"的全部组合，端口自动避开已占用端口。

### 来源 IP 白名单

链路部署时默认开启：第 2 跳起的每台机器只接受上一跳节点的连接（上一跳各网卡地址加公网出口地址），其他来源一律丢弃。不需要时加 `--no-acl`。

```bash
nxr chain add ... --no-acl                       # 部署链路时不加白名单
# 以下在 IX 节点上执行
nxr edit 22222 --allow 203.0.113.20,10.0.0.0/8        # 手动设置某条规则的白名单
nxr edit 22222 --allow -                         # 取消
```

如果前置机有多个出口 IP（例如多线 NAT），检测时某一跳显示"不可达"，可以在该节点上用 `nxr edit 端口 --allow` 补上地址，或取消白名单。

### 跳间加密

```bash
nxr chain add --hop local:11114 --hop ix-hk:22224 --target 10.0.0.1:33333 --transport tls --sni www.bing.com
```

可选 `tls`、`ws`、`wss`。加密只作用于 TCP，仅 UDP 的链路不能加密。

### 检测与管理

```bash
nxr chain topo          # 拓扑总览
nxr chain check all     # 逐跳检测（服务状态 + 下一跳 TCP 可达性与延迟）
nxr chain show c1
nxr chain del c1
```

## 常用命令

```
nxr                          交互菜单
nxr add | edit | del | list | show | enable | disable | restart | log
nxr chain create | batch | add | topo | list | show | check | del
nxr node list | add | test | key | sync | del
nxr probe 主机 端口          TCP 延迟测试
nxr import-realm [文件]      导入已有 realm 配置
nxr export | backup
nxr restore [文件] [-y]      从备份恢复（不指定文件时用最新的）
nxr optimize [--revert]      转发网络优化（BBR、缓冲区等）
nxr update [--force]
nxr uninstall [-y] [--purge]
```

完整参数见 `nxr help`。

## 文件位置

| 路径 | 内容 |
| --- | --- |
| `/etc/nxr/rules/` | 规则（每条一个文件，是渲染 realm 配置的依据） |
| `/etc/nxr/realm/` | 生成的 realm TOML |
| `/etc/nxr/nodes/`、`/etc/nxr/chains/` | 节点与链路记录（只在前置机上） |
| `/etc/nxr/ssh/` | 控制端 SSH 密钥与 known_hosts |
| `/var/log/nxr/` | 规则日志 |

## 注意事项

- realm 的负载均衡本身不做健康检查，nxr 通过定时任务（systemd timer 每 30 秒，Alpine 上 cron 每分钟）探测并重写配置来实现故障摘除。仅 UDP 的规则无法探测。
- 按来源 IP 分流（iphash）只在前置这一跳有意义，之后各跳看到的来源都是上一跳机器，会自动改为轮询。
- 云服务器需要在安全组放行规则端口；本机防火墙由 nxr 自动处理。
- 卸载：`nxr uninstall`，会停止并删除全部规则、服务、定时任务和 nftables 表。配置目录（节点、链路记录和 SSH 密钥，连同日志）、nxr 安装的 realm 程序、转发优化会逐项询问，默认保留；`-y` 只确认卸载本身，这三项按默认保留；`--purge` 一并清除。卸载不会清理远程节点上的规则，需要的话先 `nxr chain del`。

## 致谢

- [zhboner/realm](https://github.com/zhboner/realm)：转发核心。
