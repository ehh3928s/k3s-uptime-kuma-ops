# 运维手册

面向日常操作。所有命令默认在服务器上执行，标注 `[本地]` 的在运维机上执行。

```bash
NS=monitoring
REL=uptime-kuma
```

---

## 1. 接入

```bash
# [本地] 建立隧道，前台占用，Ctrl+C 断开
ssh -N -L 8080:127.0.0.1:30001 aliyun

# [本地] 后台运行
ssh -fN -L 8080:127.0.0.1:30001 aliyun

# [本地] 确认隧道活着
lsof -iTCP:8080 -sTCP:LISTEN

# [本地] 关闭后台隧道
pkill -f 'ssh -fN -L 8080'
```

浏览器打开 `http://127.0.0.1:8080`。

> 隧道断开不影响服务运行，只是访问不了。

---

## 2. 日常巡检

```bash
# 一屏看全
kubectl get pods,svc,pvc,cronjob,deploy -n $NS
helm list -n $NS

# 节点与资源
kubectl get nodes -o wide
free -m
df -h /var/lib/rancher /var/backups

# 应用日志
kubectl logs -n $NS deploy/uptime-kuma --tail=80
kubectl logs -n $NS deploy/uptime-kuma --since=1h | grep -iE 'error|fail'

# 最近事件
kubectl get events -n $NS --sort-by=.lastTimestamp | tail -20
```

健康标准：

| 指标 | 期望 |
|---|---|
| Pod | `1/1 Running`，RESTARTS 不增长 |
| Deployment | `1/1 READY`，`UP-TO-DATE 1` |
| PVC | `Bound`，AGE 与首次部署一致（不应变） |
| 内存 | available > 300 MiB |
| CronJob | `LAST SCHEDULE` 是当天 03:00 之后 |

---

## 3. 备份

### 3.1 查看自动备份结果

```bash
ls -lh /var/backups/uptime-kuma/
stat -c '%U:%G %n' /var/backups/uptime-kuma/kuma-*.db | tail -3
kubectl get jobs -n $NS
kubectl logs -n $NS job/$(kubectl get jobs -n $NS -o jsonpath='{.items[0].metadata.name}')
```

期望：文件属主 `node:node`（即 1000:1000），日志里有 `integrity_check => ok`。

### 3.2 手动触发一次

```bash
kubectl create job --from=cronjob/uptime-kuma-backup -n $NS backup-manual-$(date +%H%M)
kubectl logs -n $NS -f job/backup-manual-$(date +%H%M)
```

### 3.3 恢复演练（不要等真出事才验证）

⚠️ **以下操作会覆盖线上数据，必须在维护窗口执行，且先做一次完整备份。**

```bash
# 1. 备份当前状态（双保险）
kubectl scale deploy/uptime-kuma -n $NS --replicas=0
kubectl wait --for=delete pod -l app=uptime-kuma -n $NS --timeout=120s

# 2. 把备份文件拷进 PV（PV 路径用下面命令查）
PV_PATH=$(kubectl get pvc uptime-kuma-data -n $NS -o jsonpath='{.spec.volumeName}')
echo "/var/lib/rancher/k3s/storage/${PV_PATH}_${NS}_uptime-kuma-data"

# 3. 用容器内 sqlite3 校验备份文件（宿主机 3.7.17 太旧，读不了 v2 的库）
kubectl run sqlite-verify --rm -i --restart=Never -n $NS \
  --image=louislam/uptime-kuma:2.5.8 \
  --overrides='{"spec":{"securityContext":{"runAsUser":1000,"runAsGroup":1000,"fsGroup":1000}}}' \
  -- sqlite3 /app/data/kuma.db "PRAGMA integrity_check; SELECT COUNT(*) FROM heartbeat;"

# 4. 恢复时替换三件套（.db / -wal / -shm 必须一起处理）
#    详见 docs/troubleshooting.md 第五部分 §7
```

### 3.4 备份策略参数

| 参数 | 值 | 位置 |
|---|---|---|
| 调度 | `0 3 * * *` | `values.yaml` → `backup.schedule` |
| 保留 | 7 天 | `backup.keepDays` |
| 落盘 | `/var/backups/uptime-kuma` | `backup.hostPath` |
| 并发 | `Forbid` | `backup.concurrencyPolicy` |
| 超时 | 600s | `backup.activeDeadlineSeconds` |

---

## 4. 升级与回滚

### 4.1 改配置（不换镜像）

```bash
# 1. 改 values.yaml
# 2. 先看会改什么
helm template $REL ./charts/uptime-kuma-stack -n $NS | kubectl diff -f -

# 3. 确认无误再升级
helm upgrade $REL ./charts/uptime-kuma-stack -n $NS

# 4. 观察
kubectl rollout status deploy/uptime-kuma -n $NS --timeout=300s
```

### 4.2 升级镜像版本

```bash
# 1. 先拉到本地（走代理，可能很慢）
k3s ctr -n k8s.io images pull docker.io/louislam/uptime-kuma:2.6.0

# 2. 确认 digest 已存在
k3s ctr -n k8s.io images ls | grep uptime-kuma

# 3. 确认 v2 到 v2 之间是否会触发数据迁移，读官方 release notes

# 4. 改 values: image.tag / backup.image.tag
helm upgrade $REL ./charts/uptime-kuma-stack -n $NS
```

### 4.3 回滚

```bash
helm history $REL -n $NS
helm rollback $REL <REVISION> -n $NS
kubectl rollout status deploy/uptime-kuma -n $NS
```

回滚只改 Pod spec，**不动 PVC**（PVC 带 `helm.sh/resource-policy: keep`）。

⚠️ 回滚镜像版本时注意：如果新版本已经跑过数据迁移（改了表结构），退回旧版本可能因为 schema 不兼容起不来。**跨版本回滚前必须先备份数据**。

---

## 5. 故障处置

| 现象 | 快速判断 | 处置 |
|---|---|---|
| `ImagePullBackOff` | `kubectl describe pod` 看 Events | tag 不存在或网络不通；用 `k3s ctr images ls` 确认本地是否有该 tag |
| `ContainerCreating` 很久 | 大镜像拉取中，不是故障 | `du -sh /var/lib/rancher/k3s/agent/containerd/io.containerd.content.v1.content` 看是否在增长 |
| `CrashLoopBackOff` | 看日志 | 常见于数据库损坏或权限错误（`readonly database`） |
| `Pending` | `kubectl describe pod` | 资源不足或 PVC 未绑定 |
| 页面 502/无法访问 | `curl -sI http://127.0.0.1:30001` | 302=服务正常，检查隧道；000=服务异常 |
| 内存告警 | `free -m` | 调低 `resources.limits` 或清理旧镜像 `k3s crictl rmi --prune` |
| 磁盘满 | `df -h` | 清理 `/var/backups`、旧镜像、`journalctl --vacuum-size=200M` |

### 快速定位三连

```bash
kubectl get pod -n $NS -l app=uptime-kuma -o wide
kubectl describe pod -n $NS -l app=uptime-kuma | tail -30
kubectl logs -n $NS deploy/uptime-kuma --tail=100 --previous
```

`--previous` 看的是**上一个容器实例**的日志，容器反复重启时这条最关键。

---

## 6. 变更前检查清单

任何会改 Pod spec 的操作前，逐条确认：

- [ ] `kubectl diff` 结果在预期内（只改该改的）
- [ ] 已确认 PVC 的 AGE 不会归零（归零 = 数据卷被重建）
- [ ] 已记录当前 `helm history` 的 REVISION，知道回滚目标
- [ ] 已确认当前 Pod 名与 AGE（用于判断是否重建）
- [ ] 数据库有可用备份且验证过 `integrity_check`
- [ ] 知道这次变更会不会中断服务、中断多久
- [ ] 有回退命令并且验证过语法

---

## 7. 常用命令速查

```bash
# 进入容器
kubectl exec -it -n $NS deploy/uptime-kuma -- sh

# 重启（会导致短暂中断）
kubectl rollout restart deploy/uptime-kuma -n $NS

# 强制重建 Pod（不改 spec）
kubectl delete pod -n $NS -l app=uptime-kuma

# 端口从容器内验证
kubectl exec -n $NS deploy/uptime-kuma -- wget -qO- http://127.0.0.1:3001 | head -3

# Helm 渲染结果（不部署）
helm template $REL ./charts/uptime-kuma-stack -n $NS

# Helm 存储的 manifest（线上真实来源）
helm get manifest $REL -n $NS

# 查看 release 的 values
helm get values $REL -n $NS

# 镜像磁盘占用
k3s ctr -n k8s.io images ls | grep uptime-kuma
```
