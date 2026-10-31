#!/usr/bin/env bash
# ==============================================================================
# CentOS 7.9 ECS 初始化脚本
# 目标环境: 阿里云 ECS / 华南3(广州) / 2 vCPU 2 GiB / CentOS 7.9 64位
# 用途: yum 源修复 + 基础工具 + 时间同步 + swap + 内核参数
#
# 用法:
#   scp centos7-ecs-init.sh root@<你的IP>:/root/
#   ssh root@<你的IP>
#   bash /root/centos7-ecs-init.sh
#
# 注意: 本脚本不修改 SSH 端口、不动防火墙/安全组, 这两项见文末手动步骤
# ==============================================================================

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[!!]${NC} $*"; }
err()  { echo -e "${RED}[EE]${NC} $*"; }

# 必须以 root 运行
if [[ $EUID -ne 0 ]]; then
    err "请用 root 运行: sudo bash $0"
    exit 1
fi

# ------------------------------------------------------------------------------
# 0. 环境确认
# ------------------------------------------------------------------------------
echo "===== 0. 环境确认 ====="
OS_VER=$(rpm -q --qf '%{VERSION}' centos-release 2>/dev/null || echo "unknown")
log "CentOS 版本: ${OS_VER}"
log "内核版本: $(uname -r)"
log "内存: $(free -m | awk '/Mem:/{print $2}') MB"
log "根分区可用: $(df -h / | awk 'NR==2{print $4}')"

if [[ "${OS_VER}" != 7* ]]; then
    warn "当前不是 CentOS 7, 后续步骤可能不适用, 建议先确认"
    read -rp "继续执行? [y/N] " ans
    [[ "${ans}" != "y" ]] && exit 1
fi

# ------------------------------------------------------------------------------
# 1. yum 源检测与修复
#    CentOS 7 已 EOL(2024-06-30), 官方 mirrorlist 失效
# ------------------------------------------------------------------------------
echo ""
echo "===== 1. yum 源检测 ====="

if timeout 90 yum -q makecache >/dev/null 2>&1; then
    log "yum 源当前可用, 跳过修复"
else
    warn "yum 源不可用, 开始切换到阿里云 vault 源"

    mkdir -p /etc/yum.repos.d/bak.$(date +%Y%m%d)
    cp -a /etc/yum.repos.d/CentOS-*.repo /etc/yum.repos.d/bak.$(date +%Y%m%d)/ 2>/dev/null
    log "原 repo 已备份至 /etc/yum.repos.d/bak.$(date +%Y%m%d)/"

    cat > /etc/yum.repos.d/CentOS-Base.repo <<'EOF'
[base]
name=CentOS-7 - Base - aliyun vault
baseurl=https://mirrors.aliyun.com/centos-vault/7.9.2009/os/$basearch/
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7
enabled=1

[updates]
name=CentOS-7 - Updates - aliyun vault
baseurl=https://mirrors.aliyun.com/centos-vault/7.9.2009/updates/$basearch/
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7
enabled=1

[extras]
name=CentOS-7 - Extras - aliyun vault
baseurl=https://mirrors.aliyun.com/centos-vault/7.9.2009/extras/$basearch/
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7
enabled=1
EOF

    yum clean all
    if yum -q makecache; then
        log "yum 源修复成功"
    else
        err "yum 源修复失败, 请检查网络或安全组出方向规则"
        exit 1
    fi
fi

# ------------------------------------------------------------------------------
# 2. 基础工具
# ------------------------------------------------------------------------------
echo ""
echo "===== 2. 安装基础工具 ====="
yum install -y epel-release >/dev/null 2>&1 || warn "epel-release 安装失败, 后续部分包可能不可用"
yum install -y vim wget curl lsof net-tools bind-utils telnet tree htop git \
               chrony bash-completion yum-utils >/dev/null 2>&1 \
    && log "基础工具安装完成" || warn "部分工具安装失败, 不影响后续步骤"

# ------------------------------------------------------------------------------
# 3. 时间同步
#    阿里云内网 NTP, 走内网不计公网流量
# ------------------------------------------------------------------------------
echo ""
echo "===== 3. 时间同步 ====="
systemctl enable chronyd >/dev/null 2>&1
systemctl restart chronyd >/dev/null 2>&1
sed -i 's/^server .*/#&/' /etc/chrony.conf 2>/dev/null
grep -q 'ntp.cloud.aliyuncs.com' /etc/chrony.conf || \
    echo 'server ntp.cloud.aliyuncs.com iburst' >> /etc/chrony.conf
systemctl restart chronyd >/dev/null 2>&1
sleep 2
chronyc sources >/dev/null 2>&1 && log "chrony 已启用, 当前时间: $(date '+%F %T')" || warn "chrony 状态异常"

# ------------------------------------------------------------------------------
# 4. swap
#    2G 内存跑 K8s/容器必须留 swap 缓冲, 否则容易触发 OOM Killer
# ------------------------------------------------------------------------------
echo ""
echo "===== 4. 配置 swap ====="

if swapon --show | grep -q '/swapfile'; then
    log "swap 已存在, 跳过"
else
    AVAIL_GB=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
    if [[ "${AVAIL_GB}" -lt 6 ]]; then
        warn "根分区可用仅 ${AVAIL_GB}G, 不足 6G, 跳过 swap 创建"
    else
        if fallocate -l 2G /swapfile 2>/dev/null; then
            log "swapfile 已分配 (fallocate)"
        else
            warn "fallocate 失败, 改用 dd"
            dd if=/dev/zero of=/swapfile bs=1M count=2048 status=progress
        fi
        chmod 600 /swapfile
        mkswap /swapfile >/dev/null
        swapon /swapfile
        grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
        log "swap 已启用: $(free -m | awk '/Swap:/{print $2}') MB"
    fi
fi

# ------------------------------------------------------------------------------
# 5. 内核参数
# ------------------------------------------------------------------------------
echo ""
echo "===== 5. 内核参数 ====="
cat > /etc/sysctl.d/99-ecs-tuning.conf <<'EOF'
# swap 使用倾向, 2G 小内存机器设为 10, 尽量用物理内存
vm.swappiness = 10
# 文件句柄上限, 容器与反向代理场景常用
fs.file-max = 655350
# 连接跟踪表, 容器网络需要
net.netfilter.nf_conntrack_max = 655350
# 加快 TIME_WAIT 回收
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_max_tw_buckets = 20000
EOF
sysctl --system >/dev/null 2>&1 && log "内核参数已生效 (swappiness=$(cat /proc/sys/vm/swappiness))" || warn "内核参数加载异常"

# ------------------------------------------------------------------------------
# 6. 关闭无用服务
# ------------------------------------------------------------------------------
echo ""
echo "===== 6. 精简开机服务 ====="
for svc in postfix NetworkManager-dispatcher tuned irqbalance; do
    if systemctl is-enabled "${svc}" >/dev/null 2>&1; then
        systemctl disable --now "${svc}" >/dev/null 2>&1 && log "已关闭 ${svc}"
    fi
done

# ------------------------------------------------------------------------------
# 完成
# ------------------------------------------------------------------------------
echo ""
echo "=============================================================="
log "初始化完成"
echo "--------------------------------------------------------------"
free -h
echo "--------------------------------------------------------------"
cat <<'EOF'

接下来需要手动完成的两件事(脚本不代劳, 因为做错会失联):

【A. SSH 加固 —— 顺序不能错】
  1. 先在阿里云控制台「安全组」放行新端口(例如 2222)的入方向
  2. 再改配置:
       vi /etc/ssh/sshd_config
         Port 2222
         PermitRootLogin prohibit-password
         PasswordAuthentication no
  3. sshd -t               # 先做语法检查, 必须无输出
  4. systemctl reload sshd
  5. 保持当前 SSH 窗口不要关, 另开一个窗口测试新端口能否登录
  6. 确认能登录后, 再关闭旧窗口, 最后在安全组删掉 22 端口规则

  如果改完登录不上: 阿里云控制台 → 实例 → 远程连接(VNC) 进去回滚

【B. 安全组最小放行】
  入方向只开: 22(或自定义SSH端口) + 80 + 443
  其余端口一律不开; 需要临时调试的用「安全组 + 时间限制」方式

【C. 安装云监控插件(可选)】
  控制台当前显示「云盘使用率 安装插件」, 装完可在控制台直接看内存和磁盘:
    wget https://cms-agent-cn-guangzhou.oss-cn-guangzhou.aliyuncs.com/release/cms_install_for_linux.sh
    bash cms_install_for_linux.sh

下一步建议: 装 Docker → 跑 uptime-kuma 出第一个成果, 再上 k3s
EOF
