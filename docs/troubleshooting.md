# 阿里云 ECS 运维排障记录

| 项 | 值 |
|---|---|
| 实例 ID | i-7xv3lercd83b5uvczjwtZ |
| 规格 | 2 vCPU / 2 GiB |
| 系统 | CentOS 7.9 64 位 |
| 地域 | 华南3（广州）可用区 A |
| 公网 IP | <SERVER_IP> |
| 记录时间 | 2026-10-29 |

---

# 第一部分 SSH 端口配置阶段

## 1. firewalld 状态返回 unknown

**现象**

```bash
systemctl is-active firewalld
# unknown
```

**根因**

`unknown` 表示 systemd 中不存在该 unit，即 firewalld 未安装。它与 `inactive`（已安装但未运行）是两种完全不同的状态。

阿里云部分 CentOS 7 镜像裁掉了 firewalld，仅依赖安全组做入口控制。

**确认**

```bash
rpm -q firewalld
# package firewalld is not installed
systemctl is-active iptables
iptables -S INPUT      # 期望只有 -P INPUT ACCEPT
```

**解决**

不安装 firewalld，直接把云平台安全组作为唯一入口防线。

理由：

- 安全组工作在 VPC 层，比实例内防火墙更外层、更可靠
- 后续安装 Docker 时，Docker 会直接改写 iptables 的 `FORWARD` 链和 `DOCKER` 链，绕过 firewalld 规则，二者共存会产生「看起来生效实际失效」的隐蔽问题
- 小内存实例无需额外常驻守护进程

> 注意：云上安全组不受实例内 iptables 改动影响，容器端口不会因 Docker 改写本机规则而裸奔到公网。

---

## 2. 22 端口消失

**现象**

```bash
sshd -T | grep -i '^port'
# port 2222

grep -nE '^[[:space:]]*Port' /etc/ssh/sshd_config
# 1:Port 2222
```

配置解析正常，但 22 不再监听。

**根因**

CentOS 7 的 `sshd_config` 默认写的是 `#Port 22`（注释态）。sshd 的规则是：

- 配置中**没有任何** `Port` 指令时，默认监听 22
- 一旦出现**至少一条**有效 `Port` 指令，默认 22 不再自动添加

执行 `sed -i '1i Port 2222'` 后，配置里唯一生效的 Port 是 2222，因此 22 自然消失。

**解决**

显式声明 22，让两条 Port 并存：

```bash
sed -i '1i Port 22' /etc/ssh/sshd_config
head -3 /etc/ssh/sshd_config
sshd -t && sshd -T | grep -i '^port'
systemctl reload sshd
ss -tlnp | grep sshd
```

期望看到 22 与 2222 各两行（IPv4 + IPv6）。

**最终状态**

```
LISTEN 0 128 *:2222 *:* users:(("sshd",pid=1682,fd=3))
LISTEN 0 128 *:22   *:* users:(("sshd",pid=1682,fd=5))
LISTEN 0 128 [::]:2222 [::]:* users:(("sshd",pid=1682,fd=4))
LISTEN 0 128 [::]:22   [::]:* users:(("sshd",pid=1682,fd=6))
```

---

## 3. 误判配置未生效

**现象**

`ss -tlnp | grep sshd` 只显示 22，据此判断 `Port 2222` 未生效。

**根因**

该 `ss` 输出是在改配置**之前**采集的。判断依据：输出中的 `pid=1682` 与 `systemctl status sshd` 显示的 Main PID 一致，而该进程启动于 19:40:26，改配置与 reload 均发生在之后。

**解决**

用「pid + 进程启动时间」交叉比对，重新采集实际状态：

```bash
ss -tlnp | grep sshd
systemctl status sshd --no-pager | head -15
```

**经验**

配置写对、命令返回 0，都不等于端口真的在监听。唯一事实来源是 `ss -tlnp` 的实际输出，且需确认输出对应的是当前进程。

---

## 4. 控制台远程连接失效

**现象**

阿里云控制台「远程连接」报错：

```
SSHD_PORT_NOT_LISTENING (ERROR)
SSHD 未监听端口 22
```

同时 sshd 日志出现：

```
config_ecs_instance_connect[2506]: GET_HOST_OK cn-guangzhou.axt.aliyun.com
sshd[2504]: error: Received disconnect from 100.104.200.24 port 42765 [preauth]
```

**根因**

Workbench / ECS Instance Connect 固定探测 22 端口，不随 sshd 配置变化。改端口后该通道必然失效。

`100.104.200.24` 为阿里云内网代理地址，`config_ecs_instance_connect` 是控制台远程连接所依赖的组件。

**解决**

1. 保留 `Port 22` 作为过渡，双端口共存
2. 救援通道优先级：

| 通道 | 是否依赖 SSH | 说明 |
|---|---|---|
| VNC / 管理终端 | 否 | 带外通道，最可靠 |
| 云助手（发送命令） | 否 | 通过 Agent 执行，不依赖 SSH |
| Workbench | 是（固定 22） | 改端口后不可用 |

**结论**

在云上改 SSH 端口的收益低于代价。安全的实质是「安全组限来源 IP + 禁用密码登录改用密钥」，而非端口号本身。

---

## 5. nslookup 命令不存在

**现象**

```bash
nslookup xxx
# -bash: nslookup: command not found
```

**根因**

`bind-utils` 未安装（最小化安装的 CentOS 7 不含该包）。

**解决**

```bash
yum install -y bind-utils
```

---

## 6. 安全组放行后仍连不上

**现象**

安全组已放行 `TCP 3001/3001`，但浏览器访问 `http://<SERVER_IP>:3001` 超时。

**根因**

授权对象填的是 `100.104.200.17`。这是阿里云内网代理网段地址（100.64.0.0/10 为共享地址空间），不是用户本地公网出口 IP。

由于是通过控制台 Workbench 连接的机器，`echo $SSH_CLIENT | awk '{print $1}'` 取到的是内网代理 IP，而非真实出口 IP。

**解决**

1. 授权对象改为真实公网 IP
2. 或临时设为 `0.0.0.0/0` 验证链路，验证通过后立即收紧

**经验**

`$SSH_CLIENT` 只在直连场景下等于真实客户端公网 IP；经跳板机、NAT、云厂商代理连接时均不可靠。

---

# 第二部分 Docker 部署阶段

## 1. 容器不存在

**现象**

```bash
docker logs uptime-kuma
# Error response from daemon: No such container: uptime-kuma
```

**根因**

`docker run` 本身执行失败，容器从未被创建。`docker logs` 报找不到容器是结果，不是原因。

直接原因是多行命令中反斜杠 `\` 后混入空格，导致命令被 shell 截断为多条，参数不完整而报错退出。

**排查**

```bash
docker ps -a
docker images | grep kuma
docker pull louislam/uptime-kuma:1
```

**解决**

改用单行命令，排除转义干扰：

```bash
docker run -d --restart=always --name uptime-kuma -p 3001:3001 -v uptime-kuma:/app/data louislam/uptime-kuma:1
```

**经验**

从富文本环境复制的多行命令，`\` 后可能夹带空格或不可见字符。排障时优先用单行版复现。

---

## 2. 镜像拉取超时

**现象**

```bash
docker pull louislam/uptime-kuma:1
# Error response from daemon: Get "https://registry-1.docker.io/v2/":
# net/http: request canceled while waiting for connection
# (Client.Timeout exceeded while awaiting headers)
```

**根因**

两个问题叠加：

1. 国内网络直连 Docker Hub 不可达
2. 报错中的域名是 `registry-1.docker.io`（官方源），而非配置的 mirror 域名，说明 Docker 请求并未走加速器，或加速器自身超时后 fallback 回官方源

**排查**

```bash
docker info | grep -A4 "Registry Mirrors"
curl -sS -m 10 -o /dev/null -w "%{http_code}\n" https://<mirror域名>/v2/
```

**状态码判据**

| 返回码 | 含义 |
|---|---|
| `200` / `401` | 服务在线且为标准 registry（401 是正常的认证要求） |
| `403` | 链路通，被策略拒绝 |
| `302` | 重定向，非标准 registry 端点 |
| `000` | 连接失败 / 超时 |

---

## 3. 阿里云 ACR 加速器返回 403

**现象**

```bash
curl -sS -m 10 -i https://<id>.mirror.aliyuncs.com/v2/
# HTTP/1.1 403 Forbidden
# This request is forbidden. Please proceed to https://help.aliyun.com/zh/acr/
# product-overview/product-change-acr-mirror-accelerator-function-adjustment-announcement
```

**根因**

阿里云 ACR 镜像加速器自 **2024-07-02** 起调整使用范围：

- 仅限阿里云用户在支持公网访问的阿里云产品上使用
- **仅支持拉取限定范围内的容器镜像**

`louislam/uptime-kuma` 属第三方镜像，不在白名单内，因此返回 403（而非超时）。403 说明 TCP/TLS 链路正常，只是被业务策略拒绝。

补充：该域名解析到公网 IP（47.x，杭州 ALB），从广州跨地域访问，本身质量也不理想。

**解决**

更换第三方镜像代理。实测各源 `/v2/` 状态：

| 源 | 状态码 | 可用性 |
|---|---|---|
| docker.m.daocloud.io | 401 | 可用 |
| docker.1ms.run | 401 | 可用 |
| docker.xuanyuan.me | 401 | 可用 |
| hub.rat.dev | 302 | 非标准端点 |
| dockerproxy.cn | 000 | 不可达 |

最终配置（多源按序 fallback）：

```bash
cat > /etc/docker/daemon.json <<'EOF'
{
  "registry-mirrors": [
    "https://docker.m.daocloud.io",
    "https://docker.1ms.run",
    "https://docker.xuanyuan.me"
  ],
  "log-driver": "json-file",
  "log-opts": { "max-size": "50m", "max-file": "3" },
  "exec-opts": ["native.cgroupdriver=systemd"],
  "live-restore": true
}
EOF
systemctl daemon-reload && systemctl restart docker
```

**daemon.json 各项作用**

| 配置 | 作用 | 缺失后果 |
|---|---|---|
| `registry-mirrors` | 走代理拉取镜像 | 直连 Docker Hub 超时 |
| `log-opts` | 日志轮转 50m × 3 | 容器日志无限增长写满磁盘 |
| `exec-opts` cgroupdriver=systemd | cgroup 驱动与 systemd 对齐 | 后续部署 K8s/k3s 时 kubelet 与运行时驱动不一致，容器无法启动 |
| `live-restore` | daemon 重启时容器不中断 | 每次升级 Docker 都中断全部服务 |

---

## 4. 邮件通知失败

**现象**

```
Mail command failed: 502 Invalid parameters
```

**根因**

QQ 邮箱 SMTP 拒绝 `MAIL FROM` 中的地址。QQ 要求发件人地址严格等于认证账号，以下情况均会触发 502：

- `From` 与 `SMTP Username` 不一致
- `From` 填写了带显示名的格式（如 `"告警" <xx@qq.com>`）
- `From` 地址格式不完整

**解决**

| 字段 | 值 |
|---|---|
| SMTP Host | smtp.qq.com |
| SMTP Port | 465 |
| Security | TLS（465 必须用隐式 TLS，不是 STARTTLS） |
| SMTP Username | 完整 QQ 邮箱地址 |
| SMTP Password | 16 位授权码（非登录密码） |
| From | 与 Username 完全一致的纯地址 |
| To | 接收告警的邮箱 |

备用方案：`587 + STARTTLS`。

**前置条件**

QQ 邮箱需在「设置 → 账户」中开启 IMAP/SMTP 服务并生成授权码。

---

## 5. 版本过旧告警

**现象**

页面提示：

```
⚠️ This Uptime Kuma version is outdated!
Current Version: 1.23.17 (Outdated!)
You are running the latest tag, which still points to Uptime Kuma v1.
```

**根因**

`:1` tag 指向 v1 系列，已停止维护，不再接收 bug 与安全修复。当前离线版本 `1.23.17`。

当前最新为 `2.5.8`（2026-10-26 发布），其更新日志包含安全修复：

```
Security Fixes
- GHSA-v2p3-6f5h-6hhf [Admin Only] RCE
```

**升级方案（尚未执行）**

```bash
# 1. 备份数据卷（v1→v2 涉及数据库结构迁移，必须先备份）
VOL=$(docker volume inspect uptime-kuma --format '{{.Mountpoint}}')
tar czf /root/kuma-data-$(date +%F).tar.gz -C "$VOL" .
ls -lh /root/kuma-data-*.tar.gz

# 2. 停旧容器并保留卷
docker stop uptime-kuma && docker rm uptime-kuma

# 3. 拉取 2.x 并使用同一数据卷启动
docker pull louislam/uptime-kuma:2
docker run -d --restart=always --name uptime-kuma \
  -p 3001:3001 -v uptime-kuma:/app/data \
  louislam/uptime-kuma:2
```

**回滚**

```bash
docker stop uptime-kuma && docker rm uptime-kuma
VOL=$(docker volume inspect uptime-kuma --format '{{.Mountpoint}}')
rm -rf "$VOL"/* && tar xzf /root/kuma-data-<日期>.tar.gz -C "$VOL"
# 重新以 :1 启动
```

**版本策略经验**

生产环境锁定大版本 tag（`:2`）而非 `:latest`，既获得安全更新，又避免跨大版本意外升级。

---

# 第三部分 安全收紧与远程访问

## 1. 本地连接 2222 超时

**现象**

```bash
nc -vz <SERVER_IP> 2222
# 无输出，长时间卡住，最终超时
```

**根因**

安全组 `2222/2222` 规则的授权对象未包含本地真实公网出口 IP。

补充背景：此前所有 SSH 操作均通过控制台 Workbench 完成，该通道经阿里云内网代理（`100.104.x.x`）接入，**从不经过安全组的公网入方向规则**，因此规则配错也一直未被发现。

**连通性结果判据**

| 结果 | 含义 | 排查方向 |
|---|---|---|
| `succeeded` | 链路正常 | 进入应用层排查 |
| `Connection refused`（立即返回） | 包到达主机，但无进程监听 | sshd 未监听该端口、服务未启动 |
| **超时 / 卡住** | **包被静默丢弃** | **安全组未放行、路由不可达** |

云安全组默认行为是 **DROP**（静默丢弃）而非 REJECT，因此表现为超时而非拒绝。这一差异是区分「防火墙拦截」与「服务未监听」的关键。

**解决**

```bash
# 1. 在本地（不是服务器上）查真实出口 IP
curl -s https://ip.sb
# <YOUR_IP>

# 2. 安全组入方向 → 2222/2222 → 授权对象改为
#    <YOUR_IP>/32
```

**经验**

`$SSH_CLIENT`、`$SSH_CONNECTION` 在经跳板机、NAT、云厂商代理接入时不可靠，必须从客户端侧查询出口 IP。

---

## 2. SSH 隧道命令执行位置错误

**现象**

```bash
# 在服务器上执行
ssh -p 2222 -N -L 3001:127.0.0.1:3001 root@<SERVER_IP>
# root@<SERVER_IP>'s password:   ← 出现密码提示
# Permission denied, please try again.
# bind: Address already in use      ← 端口转发失败
```

**根因**

`ssh -L` 是**客户端侧**的本地端口转发，必须在发起连接的机器上执行。

在服务器上执行该命令，等于让服务器 SSH 到自己的公网 IP，出现三个连锁结果：

1. 弹出密码提示（服务器连自己也要认证）
2. `-L 3001` 要求在服务器本地监听 3001，而该端口已被 uptime-kuma 容器占用 → `bind: Address already in use`
3. 即使成功也没有意义，没有客户端参与转发

**解决**

在本地 Mac / Windows 终端执行：

```bash
ssh -p 2222 -N -L 8080:127.0.0.1:3001 root@<SERVER_IP>
```

- `-N`：只做转发，不打开远端 shell
- `-L 本地端口:目标地址:目标端口`
- 执行后光标停住不返回是**成功状态**，不可 Ctrl+C 或关窗口
- 本地换用 8080 而非 3001，避免与本地已有服务冲突

**验证（另开终端）**

```bash
# macOS / Linux
lsof -nP -iTCP:8080 -sTCP:LISTEN
# Windows
netstat -ano | findstr :8080
```

浏览器访问 `http://127.0.0.1:8080`。

---

## 3. 容器端口收窄至回环地址

**问题**

`docker run -p 3001:3001` 默认绑定 `0.0.0.0`，即监听全部网卡。此时即使安全组未放行，端口仍暴露在实例的所有网络接口上，形成「只靠安全组一层防护」的状态。

**解决**

重建容器，显式绑定回环地址：

```bash
docker stop uptime-kuma && docker rm uptime-kuma

docker run -d --restart=always --name uptime-kuma \
  -p 127.0.0.1:3001:3001 \
  -v uptime-kuma:/app/data \
  louislam/uptime-kuma:1
```

数据在命名卷中，删除容器不丢数据。

**验证**

```bash
docker ps
# 期望: 127.0.0.1:3001->3001/tcp        ← 正确
# 异常: 0.0.0.0:3001->3001/tcp          ← 未生效，公网仍可达
```

**收尾（双向验证）**

删除安全组 `3001` 入方向规则后：

```bash
# ① 公网地址应不可达
curl -m 5 -sS http://<SERVER_IP>:3001
# 期望: Connection timed out

# ② 隧道地址应正常
curl -m 5 -sS -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8080
# 期望: 302
```

两者同时成立，才是「外部不可达、仅本人可访问」的最终状态。

---

## 4. zsh 中 `#` 注释报错

**现象**

```bash
# ① 公网地址应该连不上
zsh: command not found: #
```

**根因**

zsh 交互模式默认未开启 `INTERACTIVE_COMMENTS`，`#` 不被识别为注释符，被当作命令执行。bash 交互模式默认开启该选项，故换 shell 后才暴露。

**解决**

执行时去掉注释行，或开启选项：

```bash
setopt interactivecomments   # 当前会话生效
# 永久生效: 写入 ~/.zshrc
```

---

# 第四部分 SSH 密钥认证加固

## 1. ssh-copy-id 执行位置错误

**现象**

```bash
ssh-copy-id -i ~/.ssh/id_ed25519.pub -p 2222 root@<SERVER_IP>
# /usr/bin/ssh-copy-id: ERROR: failed to open ID file
# '/root/.ssh/id_ed25519.pub': No such file or directory
```

**根因**

命令在**服务器**上执行，`~` 展开为服务器的 `/root`。公钥实际位于客户端 `/Users/mikudayo/.ssh/`。

**判据**

报错中的路径与预期不符，是第一信号：

| 报错路径 | 实际位置 |
|---|---|
| `/root/.ssh/...` | 服务器（错误） |
| `/Users/mikudayo/.ssh/...` | Mac 本地（正确） |

提示符对照：

```
mikudayo@xxx ~ %                        ← Mac 本地
[root@<hostname> ~]#       ← 服务器
```

**经验**

本地侧命令（`ssh` / `ssh-copy-id` / `scp` / 查出口 IP 的 `curl`）必须在客户端执行；
服务器侧命令（`docker` / `systemctl` / `ss` / `sshd -T`）才在服务器执行。

判断口诀：命令涉及 `~/.ssh`、本地路径、或“把文件传给 root@公网IP”，一定属于本地。

同类错误此前已发生一次（`ssh -L` 在服务器上执行导致 `bind: Address already in use`），属于高频操作失误。

---

## 2. 密钥认证的有效性验证

**问题**

`ssh -i key ...` 成功登录，不能证明密钥生效——sshd 会按顺序尝试多种认证方式，可能是公钥失败后回退到密码并成功。

**正确验证方式**

禁用密码、强制只用公钥，一次性排除歧义：

```bash
ssh -o PreferredAuthentications=publickey \
    -o PasswordAuthentication=no \
    -i ~/.ssh/id_ed25519 -p 2222 root@<SERVER_IP> \
    'echo "key auth OK"'
```

输出 `key auth OK` 才是密钥确实可用。

**会话归属确认**

```bash
echo $SSH_CONNECTION
# <YOUR_IP> 57788 <SERVER_PRIVATE_IP> 2222
#                                  ↑ 端口必须为 2222
```

端口显示 `22` 说明当前处在控制台 Workbench 会话中（来源 `100.104.x.x`），与该判断无关。

---

## 3. 修改 sshd 认证策略

**诊断先行（不可跳过）**

```bash
cp -a /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$(date +%F)

# 实际生效值
sshd -T | grep -iE '^(passwordauthentication|permitrootlogin|pubkeyauthentication)'

# 配置文件原文 + 是否存在 Match 块
grep -nE '^[[:space:]]*(PasswordAuthentication|PermitRootLogin|PubkeyAuthentication)|^Match' /etc/ssh/sshd_config
```

三种结果对应三种改法：

| 情况 | 改法 |
|---|---|
| 配置文件无显式行 | 追加到文件末尾 |
| 有显式行（本次：142、143 行） | **原位替换**，避免重复行 |
| 存在 `Match` 块 | 需改在对应块内，块内优先级高于顶层 |

**修改**

```bash
sed -i -E 's/^[[:space:]]*PermitRootLogin[[:space:]]+yes[[:space:]]*$/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
sed -i -E 's/^[[:space:]]*PasswordAuthentication[[:space:]]+yes[[:space:]]*$/PasswordAuthentication no/' /etc/ssh/sshd_config

sshd -t && echo "语法通过" && systemctl reload sshd && echo "reload 完成"
```

`&&` 串联保证：语法检查失败时不执行 reload，sshd 继续以旧配置运行，连接不会中断。

**`PermitRootLogin` 三个取值的取舍**

| 值 | 含义 | 结果 |
|---|---|---|
| `yes` | root 可用密码登录 | 可被爆破 ❌ |
| `prohibit-password` | root **仅密钥**登录 | 爆破失效，本人可进 ✅ |
| `no` | root 完全禁止 SSH | 自己也被锁在门外 ❌ |

**输出差异说明**

`sshd -T` 显示 `permitrootlogin without-password`，是 `prohibit-password` 的同义别名（OpenSSH 7.4 统一输出旧名），**不代表配置未生效**。

**reload 与 restart 的区别**

`reload` 仅重新读取配置，已有连接保持不变；`restart` 会中断全部连接。改认证策略必须用 `reload`。

---

## 4. 双向验证

只验证「密钥能登」不充分，必须同时证明「密码进不去」。

```bash
# 反向：强制密码认证，应被拒绝
ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no -p 2222 root@<SERVER_IP>
# root@<SERVER_IP>: Permission denied (publickey,gssapi-keyex,gssapi-with-mic).

# 正向：密钥应正常
ssh aliyun 'echo "密钥登录正常"'
# 密钥登录正常
```

**关键判据**：失败信息括号内的可用方法列表中**不含 `password`**，说明服务器根本不提供密码登录；
若列表中出现 `password`，则只是密码输错，认证方式仍然开放。

---

## 5. 本地 SSH config 简化连接

`~/.ssh/config`（权限必须 600）：

```
Host aliyun
    HostName <SERVER_IP>
    Port 2222
    User root
    IdentityFile ~/.ssh/id_ed25519
    ServerAliveInterval 60
    ServerAliveCountMax 3
```

| 配置 | 作用 |
|---|---|
| `ServerAliveInterval 60` | 每 60 秒发送保活包。SSH 隧道闲置十几分钟后被 NAT 断开是常见故障，此项必需 |
| `ServerAliveCountMax 3` | 连续 3 次无响应（3 分钟）才判定断线，避免瞬时抖动导致断连 |

配置后：

```bash
ssh aliyun                                    # 登录
ssh -N -L 8080:127.0.0.1:3001 aliyun          # 建隧道
```

**注意**：`ssh -N` 执行后终端不返回提示符，属正常状态（`-N` 意为不执行远程命令），不可 Ctrl+C 或关闭窗口。

---

## 6. 回滚

配置写坏或密钥失效时：

```bash
# 服务器上（经 VNC / Workbench 进入）
cp /etc/ssh/sshd_config.bak.2026-10-30 /etc/ssh/sshd_config
sshd -t && systemctl reload sshd
```

**救援通道优先级**

| 通道 | 依赖 SSH | 受 `PasswordAuthentication no` 影响 |
|---|---|---|
| Mac `ssh aliyun`（密钥） | 是 | 否（公钥认证） |
| 控制台 Workbench | 是（内网 Instance Connect） | 否（使用临时密钥注入） |
| 控制台 VNC / 管理终端 | 否（带外） | 否 |

三层通道中至少两层不受配置影响，因此关闭密码登录的风险可控。

---

# 第五部分 k3s 部署与数据迁移

环境：CentOS 7.9 / 2 vCPU / 2 GiB，目标把 uptime-kuma 从 Docker 单容器迁移到 K8s（Deployment + Service + PVC）。

## 1. 安装脚本卡在 Downloading binary

**现象**

```bash
curl -sfL https://get.k3s.io | INSTALL_K3S_MIRROR=cn sh -s - --disable traefik
# [INFO]  Downloading binary ...    ← 卡住 3 分钟以上无进展
```

**根因（两条叠加）**

1. 新版安装脚本已**移除** `INSTALL_K3S_MIRROR` 变量，改用 `INSTALL_K3S_ARTIFACT_URL`。传入旧变量时脚本**静默忽略，不报错**，所以看起来“配了国内镜像”其实没生效。
2. 脚本实际从 `github.com/k3s-io/k3s/releases/download` 下载约 70MB 二进制，国内直连 GitHub Releases 拉大文件基本必卡。

脚本内的 URL 拼接逻辑：

```bash
INSTALL_K3S_ARTIFACT_URL=${INSTALL_K3S_ARTIFACT_URL:-https://github.com/k3s-io/k3s/releases/download}
VERSION_URLSAFE="$(printf '%s' "${VERSION_K3S}" | sed 's/+/%2B/g')"
BIN_URL=${INSTALL_K3S_ARTIFACT_URL}/${VERSION_URLSAFE}/k3s${SUFFIX}
```

注意 `+` 被转义成 `%2B`，手动拼 URL 时必须保持这个编码。

**解决：手动下载 + 让脚本跳过下载**

```bash
# 1. 找一个可用的 GitHub 代理（逐个测 /v2 或 HEAD 状态码）
for p in "https://ghfast.top/https://github.com" "https://gh-proxy.com/https://github.com" \
         "https://ghproxy.net/https://github.com" "https://github.moeyy.xyz/https://github.com"; do
  printf "%-46s " "${p#*//}"
  curl -sSI -m 12 -o /dev/null -w "%{http_code}\n" \
    "$p/k3s-io/k3s/releases/download/v1.30.14%2Bk3s2/k3s" 2>/dev/null || echo fail
done

# 2. 带进度下载（能看到速度和剩余时间，失败原因也可见）
curl -fL --retry 3 --retry-delay 2 -o /tmp/k3s \
  "https://gh-proxy.com/https://github.com/k3s-io/k3s/releases/download/v1.30.14%2Bk3s2/k3s"

# 3. 放到位并注册服务，完全不碰网络
chmod 755 /tmp/k3s && mv /tmp/k3s /usr/local/bin/k3s
curl -sfL https://get.k3s.io | \
  INSTALL_K3S_SKIP_DOWNLOAD=true \
  INSTALL_K3S_VERSION="v1.30.14+k3s2" \
  INSTALL_K3S_SKIP_SELINUX_RPM=true \
  sh -s - --disable traefik --disable servicelb --write-kubeconfig-mode 644
```

| 变量/参数 | 作用 |
|---|---|
| `INSTALL_K3S_SKIP_DOWNLOAD=true` | 不再下载与校验 hash，直接用 `/usr/local/bin/k3s` |
| `INSTALL_K3S_VERSION=...` | 显式指定版本，绕开被污染的版本探测接口 |
| `INSTALL_K3S_SKIP_SELINUX_RPM=true` | 跳过从 `rpm.rancher.io` 装策略包（另一个国内卡点） |
| `--disable traefik --disable servicelb` | 2G 内存下省约 70MB |

**判断原则**：任何“静默卡住、无报错”的下载环节，都改为**手动下载 + 跳过脚本下载**。进度条和错误可见，比脚本内部静默重试可靠。

## 2. update.k3s.io 返回 HTML 页面

**现象**

```bash
curl -sfL --max-time 15 https://update.k3s.io/v1-release/channels/stable
# 返回一整页 <!DOCTYPE html> ... github.githubassets.com ...
```

**根因**：该域名被重定向到 GitHub 页面。安装脚本用 `curl -w '%{url_effective}'` 从重定向后的 URL 中截取版本号，拿到的是 HTML，版本推断必然失败。

**解决**：用 `INSTALL_K3S_VERSION` 显式指定版本，不再依赖版本探测。版本号可从 GitHub API 查：

```bash
curl -s https://api.github.com/repos/k3s-io/k3s/git/matching-refs/tags/v1.30
```

## 3. 版本选择：cgroup v1 硬约束

Kubernetes 自 **1.35** 起正式移除 cgroup v1 支持（KEP-4176），而 CentOS 7 内核 3.10 只有 cgroup v1，没有 v2。

| 版本 | CentOS 7 可用性 | 说明 |
|---|---|---|
| v1.37.x（当时最新） | ❌ | cgroup v1 已移除，kubelet 启动失败或永久 NotReady |
| v1.34.x | ⚠️ | 处于 cgroup v1 维护末期，CentOS 7 验证不足 |
| **v1.30.14+k3s2** | ✅ | cgroup v1 完整支持，CentOS 7 大量成功案例 |

**结论**：老内核上装 K8s，**先查该版本是否仍支持 cgroup v1，再谈新特性**。版本旧不影响 Deployment / Service / PVC / Helm 这些核心 API（1.20 至今基本稳定）。

验证 cgroup 版本：

```bash
stat -fc %T /sys/fs/cgroup/
# cgroup2fs → v2；tmpfs → v1
```

## 4. 镜像拉取慢 ≠ 拉取失败

**现象**：Pod 卡在 `ContainerCreating` 超过 7 分钟，Events 只有一条 `Pulling image`，无任何报错。

**误判点**：容易直接判定“拉取失败”去换源，但实际可能只是慢。

**客观判断方法**：测 containerd 内容目录的增长

```bash
du -sh /var/lib/rancher/k3s/agent/containerd/io.containerd.content.v1.content
sleep 15
du -sh /var/lib/rancher/k3s/agent/containerd/io.containerd.content.v1.content
```

| 结果 | 判断 |
|---|---|
| 第二次比第一次大几 MB 以上 | 正在下载，继续等，**不要中断 Pod 或重启 k3s** |
| 两次完全相同 | 真的卡死，需要换源或改用导入方式 |

**速度参考**：系统镜像（coredns 约 60MB）耗时 1m21s，即约 0.8 MB/s。据此估算 400MB 的 uptime-kuma v2 镜像需 8–10 分钟，与实测吻合。

## 5. `ctr` 符号链接指向 Docker 的 containerd

安装输出中会出现：

```
[INFO]  Skipping /usr/local/bin/ctr symlink to k3s, command exists in PATH at /usr/bin/ctr
```

**含义**：`ctr` 指向 Docker 自带的 containerd，而非 k3s 的。两套 containerd 数据完全独立，直接 `ctr images ls` 看到的是 Docker 的镜像。

**正确用法**：

```bash
k3s ctr images ls          # k3s 的 containerd
crictl images              # 不受影响，/usr/local/bin/crictl 已指向 k3s
```

## 6. uptime-kuma v2 引入 setup 向导

**现象**：Pod 启动后日志停住：

```
[SETUP-DATABASE] INFO: db-config.json is not found or invalid: ENOENT ...
[SETUP-DATABASE] INFO: Starting Setup Database
[SETUP-DATABASE] INFO: Waiting for user action...
```

**根因**：v2 新增 `db-config.json` 配置文件用于声明数据库类型（sqlite / mariadb）。空 PV 上没有这个文件，v2 不会像 v1 那样直接建库，而是进入 Web 端初始化向导。

**生成的配置**：

```json
{ "type": "sqlite", "port": 3306, "hostname": "", "username": "",
  "password": "", "dbName": "kuma", "ssl": false, "ca": "" }
```

**迁移启示**：跨版本迁移时 `db-config.json` **必须保留**，删掉会让服务重新进入 setup 向导。

## 7. 跨版本数据迁移（1.23 → 2.5）

### 关键约束：WAL 三文件必须一起处理

SQLite 在 WAL 模式下，新写入先进 `kuma.db-wal`，再 checkpoint 回主库。实测：

```
kuma.db       60K
kuma.db-wal   1.1M      ← 数据主要在这里
kuma.db-shm   32K
```

**只替换 `kuma.db`、保留旧 `-wal`，会按旧 WAL 记录去改新库，直接导致数据库损坏。** 三个文件必须作为一组删除或替换。

### 完整步骤

```bash
PV=$(ls -d /var/lib/rancher/k3s/storage/pvc-*_monitoring_uptime-kuma-data)

# 1. 两份备份：当前 v2 空库 + 原 v1 数据
tar czf /root/kuma-v2-fresh-$(date +%F).tar.gz -C "$PV" .
ls -lh /root/kuma-*.tar.gz

# 2. 停 Pod，等它真正消失（必须等，否则文件可能正处于写入中）
kubectl scale deploy uptime-kuma -n monitoring --replicas=0
kubectl wait --for=delete pod -l app=uptime-kuma -n monitoring --timeout=60s

# 3. 替换：删三件套（保留 db-config.json），解压 v1 数据，修正属主
rm -f "$PV/kuma.db" "$PV/kuma.db-wal" "$PV/kuma.db-shm"
tar xzf /root/kuma-data-2026-10-30.tar.gz -C "$PV"
chown -R 1000:1000 "$PV"

# 4. 启动并观察迁移日志
kubectl scale deploy uptime-kuma -n monitoring --replicas=1
kubectl logs -n monitoring deploy/uptime-kuma --tail=60
```

### 属主问题

Docker 卷里的文件属主是 `1000:1000`（容器内 node 用户）。tar 解压后变成 `root:root`，容器内进程无写权限，表现为**Pod 起来就崩、报 `attempt to write a readonly database`**。`chown -R 1000:1000` 是必须步骤。

### 迁移成功的日志特征

```
[DB] INFO: Database Type: sqlite
[DB] INFO: Connected to the database
[DB] INFO: Migrating Aggregate Table
[DB] INFO: [DON'T STOP] Migrating monitor 1s' data - 2026-10-29 - total migration progress 0.00%
[DB] INFO: Aggregate Table Migration Completed
[SERVER] INFO: Listening on: ...
```

`Aggregate Table Migration` 是 v2 的新特性：把原始心跳数据按天/小时聚合，降低存储压力。

### 浏览器报 Invalid token 是正常的

```
[AUTH] INFO: Login by token. IP=10.42.0.1
[AUTH] ERROR: invalid signature
```

`10.42.0.1` 是集群网桥地址。浏览器仍持有登录 v2 空库时获得的 token，而数据库 JWT 密钥已换成 v1 的，签名校验失败。**这恰好反证数据替换生效**。用 v1 的账号重新登录即可。

## 8. livenessProbe 与长时迁移的冲突

当前配置：

```yaml
livenessProbe:
  initialDelaySeconds: 90
  periodSeconds: 30
  failureThreshold: 3
```

本次迁移仅耗时约 12 秒，未触发。但 `Aggregate Table Migration` 耗时**与历史心跳数据量成正比**——若库中存有数月、数十个监控项的数据，迁移可能持续数分钟。届时 liveness 探针会在容器尚未就绪时反复失败并**杀掉容器重启**，迁移永远跑不完。

**规避方式**：

- 升级前先 `kubectl scale --replicas=0`，让迁移只在单次启动中完成，或临时调大 `initialDelaySeconds`
- 更稳的做法：把数据迁移做成独立的 InitContainer 或一次性 Job，与主容器探针解耦

**这是一个典型的“健康检查配置不当反而放大故障”案例**：探针本为保障可用性，参数与启动耗时特性不匹配时会成为故障源。

---

# 第六部分 定时备份与恢复验证

## 1. CronJob 设计要点

复用 `louislam/uptime-kuma:2` 镜像（内部自带 `sqlite3 3.40.1`），无需另拉镜像。

| 设计 | 原因 |
|---|---|
| `sqlite3 .backup` 而非 `cp` | 官方在线备份命令，取一致性快照。`cp` 在 WAL 模式下可能拷到“主库已更新、WAL 未合并”的中间态 |
| PVC 用**读写**挂载 | SQLite 以 WAL 模式打开库需写 `-shm` 索引文件，只读挂载必报 `attempt to write a readonly database` |
| `concurrencyPolicy: Forbid` | 上一轮未完成时不启动新的，避免并发写同一目录 |
| 备份后 `PRAGMA integrity_check` | 不合格立即删文件并使任务失败——不做校验的备份等于没有备份 |
| `activeDeadlineSeconds: 600` | 防止任务挂死长期占用资源 |
| `successfulJobsHistoryLimit` / `failedJobsHistoryLimit` | 限制 Job 对象堆积 |

## 2. 容器默认以 root 运行

**现象**

```bash
kubectl exec -n monitoring deploy/uptime-kuma -- id
# uid=0(root) gid=0(root) groups=0(root)
```

镜像默认 root，不指定 `securityContext` 时备份产物为 `root:root`，与 PV 内文件属主 `1000:1000` 不一致。

**真实风险**：以 root 打开 SQLite 库，可能把 `-wal` / `-shm` 属主改成 root。一旦发生，Deployment 的 Pod 重启后 node 用户无法写入，表现为启动即崩。

**解决**

```yaml
securityContext:
  runAsUser: 1000
  runAsGroup: 1000
  runAsNonRoot: true     # K8s 启动前校验，镜像若强制 root 会直接拒绝运行
  fsGroup: 1000
containers:
  - securityContext:
      allowPrivilegeEscalation: false
      capabilities:
        drop: [ALL]
```

`runAsNonRoot: true` 是一道**运行前校验**，比事后靠 `ls` 发现可靠。本次实测该镜像以 uid 1000 启动完全正常，说明它并**不要求** root 权限。

**宿主机目录权限**：`hostPath` 的 `DirectoryOrCreate` 会以 root 创建目录（755），uid 1000 写不进去，且报错不直观。必须先手工：

```bash
mkdir -p /var/backups/uptime-kuma
chown 1000:1000 /var/backups/uptime-kuma
```

## 3. 容器时区为 UTC

**现象**：北京时间 11:27 执行，备份文件名是 `kuma-20261031-032731.db`。

**根因**：CronJob 的 `schedule` 时区取 k3s 控制器（宿主机 CST），但容器内 `date` 是 UTC。两者不一致会导致**文件名与日志时间对不上**。

**解决**：容器加 `TZ=Asia/Shanghai`（需镜像内存在 tzdata，实测 `TZDATA_OK`）。

## 4. 宿主机 sqlite3 版本过旧导致假故障

**现象**

```bash
sqlite3 /var/backups/uptime-kuma/kuma-20261031-113300.db "select count(*) from monitor;"
# Error: malformed database schema (heartbeat_important_index) - near "where": syntax error
```

**根因**：CentOS 7 自带 `sqlite3` 为 **3.7.17**（2013 年），而 v2 库使用了**部分索引**语法：

```sql
CREATE INDEX heartbeat_important_index ON heartbeat(...) WHERE important = 1
```

`WHERE` 子句在 SQLite **3.8.0** 才引入，老版本解析建表语句时即失败。

**不是备份损坏**——容器内 3.40.1 每次 `integrity_check` 都返回 ok。

**解决：用与生产一致的版本验证**

```bash
PV=$(ls -d /var/lib/rancher/k3s/storage/pvc-*_monitoring_uptime-kuma-data)
cp /var/backups/uptime-kuma/kuma-20261031-113300.db "$PV/verify.db"
chown 1000:1000 "$PV/verify.db"
kubectl exec -n monitoring deploy/uptime-kuma -- \
  sqlite3 /app/data/verify.db "select count(*) from monitor; select count(*) from heartbeat;"
rm -f "$PV/verify.db"
```

预期：

```
1        ← monitor 表
718      ← heartbeat 表
```

**原则**：验证数据文件必须用与生产一致的版本，否则会造出假的“备份损坏”，进而做出错误处置（删正常备份、重跑、不敢恢复）。

## 5. 恢复演练是必选项

完整闭环：**备份 → 完整性校验 → 独立可读性验证 → 清理临时文件**。

只做到“文件生成了、大小不为 0”不足以称为备份策略。必做：

1. 备份后自动 `PRAGMA integrity_check`
2. 定期抽取一份，在**同版本环境**中打开并统计关键表行数
3. 验证后立即清理临时文件

## 6. 已知局限（需诚实记录）

| 局限 | 影响 | 改进方向 |
|---|---|---|
| 备份与原件在同一块磁盘 | 磁盘故障、误删、实例释放时同时丢失 | 推送到阿里云 OSS 做异地备份 |
| 单节点单副本 | 任何维护都是全量中断（本次迁移实测中断约 12 小时） | 多节点 + 副本数 ≥2，或用 PDB 控制中断窗口 |
| 镜像拉取依赖第三方代理 | 代理失效会导致新 Pod 无法启动 | 搭建私有镜像仓库或 ACR 同步 |
| `local-path` 存储 | 数据与节点绑定，Pod 无法漂移 | 生产应使用云盘 / CSI 存储 |

**监控曲线上的中断段是真实记录**：`docker stop`（10-30 21:1x）到 K8s 内恢复（10-31 09:41），约 12 小时停机窗口，uptime-kuma 如实记录。若为生产环境，需能对着这条曲线说明：中断起止时间、影响范围、MTTR、根因（迁移期间无冗余实例）。

---

# 第七部分 Helm 化与资源接管

## 1. kubectl 能连集群，helm 报 localhost:8080

### 现象

```bash
helm install uptime-kuma ./uptime-kuma-stack -n monitoring --take-ownership
# Error: INSTALLATION FAILED: Kubernetes cluster unreachable:
# Get "http://localhost:8080/version": dial tcp [::1]:8080: connect: connection refused

kubectl get nodes     # 同一个 shell，正常返回 Ready
```

### 根因

k3s 自带的 `kubectl` 是打过补丁的二进制，读不到默认配置时会自动回退到 `/etc/rancher/k3s/k3s.yaml`。
上游 `helm` 走标准 client-go 加载链路：

```
--kubeconfig  →  $KUBECONFIG  →  $HOME/.kube/config  →  http://localhost:8080（占位地址）
```

这台机器上 `/root/.kube/config` 根本不存在，于是两者走不同分支：kubectl 命中 k3s 回退路径，helm 掉到占位地址。

### 定位

```bash
for f in /root/.kube/config /etc/rancher/k3s/k3s.yaml; do
  [ -f "$f" ] && echo "=== $f" && KUBECONFIG="$f" helm list -n monitoring
done
# === /root/.kube/config  NOT FOUND
# === /etc/rancher/k3s/k3s.yaml → 正常输出表头，无报错
```

### 解决

```bash
mkdir -p /root/.kube
ln -sf /etc/rancher/k3s/k3s.yaml /root/.kube/config
chmod 600 /etc/rancher/k3s/k3s.yaml   # 该文件含 cluster-admin 凭证
```

用软链而非 `export KUBECONFIG`，好处是所有 Kubernetes 工具（helm / kubectx / k9s）统一生效，不依赖当前 shell 是否加载过 profile。

### 经验

「同一个集群，一个工具能连、另一个不能」几乎都是 kubeconfig 解析路径差异，不要先怀疑集群。先确认配置文件在哪、谁读到了它。

## 2. 接管 kubectl 创建的对象

### 问题

对象是 `kubectl apply` 出来的，集群里没有 Helm release 记录。Helm 3.17 之前，`helm install` 直接拒绝：

```
rendered manifests contain a resource that already exists
```

删掉重建是最省事的做法，但会牵连 PVC —— 2 GiB 数据库有丢失风险。

### 方案：让 Chart 长得和线上一样，再 take-ownership

三个约束缺一不可：

| 约束 | 做法 | 不做的后果 |
|---|---|---|
| 对象名一致 | `fullnameOverride: uptime-kuma`，PVC 名写死 | Helm 视为新对象，多出一套副本 |
| selector 一致 | Pod 标签只用 `app: uptime-kuma` | Deployment 的 selector 不可变，改不上，只能删除重建 |
| spec 零漂移 | 安全上下文 / extraEnv 默认关闭，image tag 保持原值 | 任何 spec 变更都会立即触发 Pod 重建 |

### 接管前必须 diff

```bash
helm template uptime-kuma ./uptime-kuma-stack -n monitoring > /tmp/rendered.yaml
kubectl diff -f /tmp/rendered.yaml
```

`kubectl diff` 是 server-side dry-run，只做计算不落盘。

健康的接管 diff 只应有两类增量：

```
+ app.kubernetes.io/instance: uptime-kuma
+ app.kubernetes.io/managed-by: Helm
+ app.kubernetes.io/name: uptime-kuma
+ helm.sh/chart: uptime-kuma-stack-1.0.0

+ helm.sh/resource-policy: keep        ← 仅 PVC 上
```

只要 `spec:` 下面出现任何 `-` 或 `+`，说明模板与线上有漂移，先改模板，不要 install。

### 执行（需 Helm ≥ 3.17）

```bash
helm install uptime-kuma ./uptime-kuma-stack -n monitoring --take-ownership
```

### 成功的判据不是 STATUS，而是 Pod 没重建

```
uptime-kuma-6676f76cfb-54jkd   1/1   Running   0   9h
```

`STATUS: deployed` 只代表 Helm 记了账。真正的判据是 **Pod 名不变、AGE 连续增长** —— 说明没有产生新 ReplicaSet，Helm 只补了 metadata，没碰 Pod 模板。这才是「接管」，不是「悄无声息地重建了一次」。

同时 Deployment 的 `UP-TO-DATE` 应保持 1（变成 2 就是滚动过了），PVC 的 `AGE` 与 `VOLUME` 不变。

## 3. 幂等校验：接管后必须先空跑一次 upgrade

```bash
helm upgrade uptime-kuma ./uptime-kuma-stack -n monitoring
```

判定：`REVISION` 从 1 变 2，但 **Pod 名与 AGE 不变**。

这证明 Helm 存储的 manifest 与集群实际状态完全收敛。缺这一步，后面每次升级都会夹带一批「说不清是谁改的」变更。

## 4. 浮动 tag 与镜像 GC

原 Deployment 用 `louislam/uptime-kuma:2`，这是 major 浮动 tag，三个问题：

- 节点重启或镜像被 GC 后重拉，可能拿到未验证的新小版本
- `values.yaml` 里写的还是 `2`，事后无法追溯镜像何时变过
- k3s 默认开启镜像 GC（磁盘用量 >85% 触发，清到 80%），未被引用的镜像会被删

### 直接改 tag 会触发全量重拉

改成 `2.5.8` 会被 k3s 视为一个从未见过的镜像，去外网拉 400 MB —— 而本机实测公共代理速度约 0.8 MB/s。

### 正解：先在本地补 tag

```bash
# 1. 从镜像内部读真实版本，不信界面显示
kubectl exec -n monitoring <pod> -- cat /app/package.json | grep -m2 '"version"'
# "version": "2.5.8",

# 2. 给同一份镜像数据补一个精确名字（纯本地，不联网）
k3s ctr -n k8s.io images tag \
  docker.io/louislam/uptime-kuma:2 \
  docker.io/louislam/uptime-kuma:2.5.8

# 3. 验证两个 tag 指向同一 digest
k3s ctr -n k8s.io images ls | grep -i kuma | awk '{print $1, $3}'
# docker.io/louislam/uptime-kuma:2       sha256:20abea8c...
# docker.io/louislam/uptime-kuma:2.5.8   sha256:20abea8c...   ← 必须相同
```

digest 相同意味着共享同一份 blob，磁盘占用不翻倍。改完 values 再 `helm upgrade`，新 Pod 从本地缓存启动，20 秒 ready，全程未联网。

> `k3s ctr` 会打印 `DEPRECATION: CRI API v1alpha2 is deprecated` 警告，属正常输出（k3s 内置 containerd 的 CRI 版本提示），不影响结果。

## 5. 收尾核查

| 检查项 | 命令 | 期望 |
|---|---|---|
| release 状态 | `helm list -n monitoring` | `deployed`，REVISION 递增 |
| 镜像已固定 | `kubectl get deploy -n monitoring -o jsonpath='{.items[0].spec.template.spec.containers[0].image}'` | `:2.5.8` |
| 滚动完成 | `kubectl rollout status deploy/uptime-kuma -n monitoring` | `successfully rolled out` |
| PVC 未重建 | `kubectl get pvc -n monitoring` | `AGE` 与部署时一致 |
| 卸载不丢数据 | PVC 带 `helm.sh/resource-policy: keep` | `helm uninstall` 后 PVC 仍在 |
| 回滚能力 | `helm rollback uptime-kuma <revision>` | 有历史 revision 可退 |

**回滚即时间机器**：`helm history uptime-kuma -n monitoring` 列出全部 revision，`helm rollback uptime-kuma 2` 直接退回上一次的完整 manifest。这是 Helm 相对手写 YAML 最实际的价值 —— 不是「能装」，是「能退」。

---

# 附：可复用判断规则

## 1. unknown ≠ inactive

| 返回值 | 含义 | 处理差异 |
|---|---|---|
| `unknown` | unit 不存在（未安装） | 考虑是否安装，或改用其他方案 |
| `inactive` | 已安装但未运行 | 直接 start |
| `failed` | 启动失败 | 查 journalctl |

## 2. 配置正确 ≠ 生效

验证链路必须逐层递进，每层都能定位不同问题：

```
sshd -t           语法是否正确
sshd -T           配置解析结果是否符合预期
systemctl reload  是否成功加载
ss -tlnp          实际监听是否到位
```

只看其中一层，会把「配置没写进去」和「写了但被拦截」混为一谈。

## 3. HTTP 状态码语义区分

| 码 | 语义 | 排查方向 |
|---|---|---|
| `000` | 网络不通 | DNS、路由、安全组、端口 |
| `401` | 要求认证（正常） | 服务健康 |
| `403` | 策略拒绝（链路通） | 权限、白名单、策略配置 |
| `502` | 上游协议错误 | 参数格式、地址一致性 |

`403` 与 `000` 的排查方向完全相反，混淆会浪费大量时间。

## 4. 云上改端口的取舍

| 维度 | 改端口 | 保留 22 + 收紧安全组 |
|---|---|---|
| 抗爆破 | 仅减少扫描噪音 | 非白名单 IP 完全不可达 |
| 控制台远程连接 | 失效 | 正常 |
| 自救能力 | 依赖 VNC / 云助手 | 控制台直连 |
| 运维复杂度 | 换网络需同步改安全组 | 低 |

**核心结论**：安全实质来自「安全组限制来源 IP」+「禁用密码登录、改用密钥认证」，端口号本身不构成有效防线。

## 5. 端口连通性三态

| 结果 | 语义 | 说明 |
|---|---|---|
| `succeeded` | 通 | 进入应用层排查 |
| `Connection refused`（立即） | 包到达主机，无进程监听 | 服务未启动 / 端口未监听 |
| 超时（卡住） | 包被 DROP | 安全组 / 防火墙 / 路由拦截 |

云安全组默认 DROP，不返回拒绝，因此「超时」优先怀疑安全组，而非服务故障。

## 6. 本地端口转发的执行位置

`ssh -L` 属于**客户端**能力：监听端口建立在执行命令的那台机器上。

- 在本地执行 → 本地端口转发到远端：正确
- 在服务器执行 → 服务器连自己，转发无意义，且目标端口常被业务占用报 `bind: Address already in use`

判断方法：看到 `root@本机公网IP's password:` 提示，就说明位置错了。

## 7. 公网 IP 的两个陷阱

| 陷阱 | 表现 | 正解 |
|---|---|---|
| 用 `$SSH_CLIENT` 取客户端 IP | 经 Workbench / 跳板机 / NAT 时得到内网地址（100.64/10 段） | 在客户端执行 `curl ip.sb` |
| 家宽出口 IP 是动态的 | 换网络后安全组规则失效，表现为超时 | 用 SSH 隧道，不依赖来源 IP |

## 8. 一个工具能连集群 ≠ 所有工具都能连

`kubectl` 正常但 `helm` / `k9s` / `kubectx` 报 `localhost:8080`，说明只有 kubectl 走通了配置加载。

| 工具 | kubeconfig 来源 |
|---|---|
| k3s 自带 kubectl | `$KUBECONFIG` → `~/.kube/config` → **`/etc/rancher/k3s/k3s.yaml`**（k3s 补丁的额外回退） |
| helm / 上游 client-go 工具 | `--kubeconfig` → `$KUBECONFIG` → `~/.kube/config` → `localhost:8080` |

`localhost:8080` 这个占位地址出现，等价于「一个 kubeconfig 都没找到」，与集群是否健康无关。
最省事的修法是在 `~/.kube/config` 建软链指向 k3s 的配置，一次性对齐所有工具。

---

# 当前成果（K8s 阶段）

## 运行状态

```bash
kubectl get pods -n monitoring
# NAME                           READY   STATUS    RESTARTS   AGE
# uptime-kuma-79c98d79cc-m9b8v   1/1     Running   0          20s

helm list -n monitoring
# NAME        NAMESPACE   REVISION  STATUS    CHART                    APP VERSION
# uptime-kuma monitoring  3         deployed  uptime-kuma-stack-1.1.0  2.5.8
```

| 层 | 内容 | 状态 |
|---|---|---|
| 主机 | 阿里云 ECS，CentOS 7.9，2 vCPU / 2 GiB / 40 GiB | ✅ |
| 容器运行时 | k3s 内置 containerd；**Docker 已 `disable --now`**（避免两套运行时争内存） | ✅ |
| 编排 | k3s v1.30.14+k3s2（适配 cgroup v1），已禁用 traefik / servicelb | ✅ |
| 工作负载 | Deployment（`strategy: Recreate`）+ Service(NodePort 30001) + PVC(2Gi, local-path) | ✅ |
| 编排管理 | **Helm release `uptime-kuma`**（Chart `uptime-kuma-stack-1.1.0`），原 kubectl 对象已接管，PVC 未重建 | ✅ |
| 镜像版本 | 已从浮动 `:2` 固定为 `:2.5.8`，本地 tag 与镜像 digest 一致，重启不再走外网 | ✅ |
| 健康检查 | readinessProbe（初始 20s）+ livenessProbe（初始 90s） | ✅ |
| 资源限制 | requests 128Mi / limits 384Mi，CPU 50m–500m | ✅ |
| 数据 | v1.23.17 → v2.5.8 跨版本迁移成功，历史心跳保留 | ✅ |
| 备份 | CronJob 每日 03:00，`sqlite3 .backup` + `integrity_check` + 7 天轮转 | ✅ |
| 备份权限 | uid 1000 运行，`runAsNonRoot`，drop ALL capabilities | ✅ |
| 恢复验证 | 从备份中读出 monitor=1 / heartbeat=718，证明数据可读 | ✅ |
| SSH 认证 | ed25519 密钥；`PasswordAuthentication no`、`PermitRootLogin prohibit-password` | ✅ |
| 内存余量 | available ≈ 800 MiB（k3s + 应用合计占用约 780 MiB） | ✅ |

## 日常访问

```bash
# 1. 本地建隧道（端口 30001 是 NodePort，不是 3001）
ssh -N -L 8080:127.0.0.1:30001 aliyun

# 2. 浏览器打开
http://127.0.0.1:8080
```

## 常用运维命令

```bash
# 状态
kubectl get pods,pvc,svc,cronjob -n monitoring
kubectl describe pod -n monitoring -l app=uptime-kuma
kubectl logs -n monitoring deploy/uptime-kuma --tail=50

# 手动触发一次备份
kubectl create job --from=cronjob/uptime-kuma-backup -n monitoring backup-manual
kubectl logs -n monitoring job/backup-manual

# 查看备份产物（宿主机）
ls -lh /var/backups/uptime-kuma/

# 应用配置变更（改 values.yaml 后重新 upgrade）
helm upgrade uptime-kuma /root/uptime-kuma-stack -n monitoring

# 回滚（先看历史，再退到指定 revision）
helm history uptime-kuma -n monitoring
helm rollback uptime-kuma 2 -n monitoring

# 渲染结果与线上对比（不改集群）
helm template uptime-kuma /root/uptime-kuma-stack -n monitoring | kubectl diff -f -
```

> 原先的 `k8s-uptime-kuma.yaml` / `k8s-uptime-kuma-backup.yaml` 已被 Chart 取代，保留仅作历史参考，**不要再 `kubectl apply`** —— 会与 Helm 的状态打架。

## 遗留与改进项

| 项 | 优先级 | 说明 |
|---|---|---|
| 备份未异地化 | 中 | 当前与原件同盘，磁盘故障即双失。应推送至阿里云 OSS |
| 单节点单副本 | 中 | 任何维护都是全量中断（本次迁移实测中断约 12 小时） |
| 主容器仍以 root 运行 | 低 | 本次已验证镜像支持 uid 1000（`runAsNonRoot` 未拒绝），可迁至非 root，但需先确认 nscd 等启动步骤不依赖 root |
| 无 Ingress | 低 | 当前走 NodePort + SSH 隧道；接入域名与 TLS 需启用 traefik 或装 nginx-ingress（约 +50–80MB 内存） |
| 镜像依赖第三方代理 | 中 | `docker.m.daocloud.io` 等公共代理若失效，新 Pod 无法启动。长期应搭私有仓库或用 ACR 同步 |
| Chart 未进版本库 | 中 | Chart 目前只在 Mac 本地与服务器 `/root` 各一份，改动无从对比、无历史。应推 GitHub |
| 无多环境 values | 低 | 只有单份 `values.yaml`，将来区分测试/生产需 `values-{env}.yaml` + `-f` 叠加 |
