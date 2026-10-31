# uptime-kuma-stack

Uptime Kuma on k3s —— SQLite 落在 `local-path` PVC，附带每日 `sqlite3 .backup` 备份 CronJob。

## 这个 Chart 为什么长这样

线上那套对象最初是 `kubectl apply` 出来的，集群里没有 Helm release 记录。
直接 `helm install` 会撞上 `rendered manifests contain a resource that already exists`。

所以 Chart 刻意做了三件事，让「接管」而不是「重建」：

1. **资源名固定**：`fullnameOverride: uptime-kuma`，PVC 名写死 `uptime-kuma-data`，渲染结果与已有对象同名。
2. **selector 不动**：Pod 标签只用 `app: uptime-kuma`，与已有 Deployment 的 `matchLabels` 完全一致（selector 不可变，改了就得上删除重建）。
3. **接管期 spec 零差异**：`podSecurityContext` / `containerSecurityContext` / `extraEnv` 默认全部关闭。任何一处差异都会触发 Pod 重建，接管阶段不希望发生。

> 1.0.0 接管时 `image.tag` 保持浮动的 `"2"` 以做到零漂移；1.1.0 起已固定为 `2.5.8`。

PVC 带 `helm.sh/resource-policy: keep`，`helm uninstall` 不会删数据卷。

## 安装（接管已有资源）

```bash
# 1. 先看渲染结果对不对，再动手
helm template uptime-kuma ./uptime-kuma-stack -n monitoring

# 2. 接管（Helm 3.17+ 的 --take-ownership 跳过归属校验）
helm install uptime-kuma ./uptime-kuma-stack \
  -n monitoring \
  --take-ownership

# 3. 确认
helm list -n monitoring
kubectl get deploy,svc,pvc,cronjob -n monitoring
```

`helm install` 后 Deployment 若显示 `READY 1/1` 且 `AGE` 没归零，说明 Pod 未被重建，接管成功。

## 升级

```bash
helm upgrade uptime-kuma ./uptime-kuma-stack -n monitoring
```

升级镜像版本（重点是**先打 tag 再 upgrade**，否则 k3s 会去外网重拉几百 MB）：

```bash
# 1. 先把新版本拉到本地并打上目标 tag
k3s ctr -n k8s.io images pull docker.io/louislam/uptime-kuma:2.6.0
k3s ctr -n k8s.io images tag docker.io/louislam/uptime-kuma:2.6.0 docker.io/louislam/uptime-kuma:2.6.0

# 2. 改 values 里的 image.tag，再 upgrade
helm upgrade uptime-kuma ./uptime-kuma-stack -n monitoring
```

> ⚠️ 改 `image.tag` 会改 Pod spec，触发一次重建。`strategy: Recreate` 下服务会中断十几秒，数据在 PVC 上不受影响。

打开安全加固（同样会触发一次重建）：

```bash
helm upgrade uptime-kuma ./uptime-kuma-stack -n monitoring \
  --set podSecurityContext.enabled=true \
  --set containerSecurityContext.enabled=true
```

## 卸载

```bash
helm uninstall uptime-kuma -n monitoring
```

PVC 因 `resource-policy: keep` 会保留。真要连数据一起删：

```bash
kubectl delete pvc uptime-kuma-data -n monitoring
```

## 主要参数

| 参数 | 默认值 | 说明 |
|---|---|---|
| `image.repository` | `louislam/uptime-kuma` | 镜像 |
| `image.tag` | `2.5.8` | 已固定；升级前先给新镜像打 tag |
| `service.type` | `NodePort` | 暴露方式 |
| `service.nodePort` | `30001` | 节点端口 |
| `persistence.name` | `uptime-kuma-data` | PVC 名，写死不跟 fullname |
| `persistence.existingClaim` | `""` | 填值则只引用、不渲染 PVC |
| `persistence.size` | `2Gi` | 存储容量 |
| `persistence.keepOnUninstall` | `true` | 卸载时保留 PVC |
| `resources.limits.memory` | `384Mi` | 内存上限（2C2G 机器上别再调高） |
| `probes.liveness.initialDelaySeconds` | `90` | v1→v2 大迁移耗时长，给足启动时间 |
| `backup.schedule` | `0 3 * * *` | 备份计划 |
| `backup.keepDays` | `7` | 备份保留天数 |
| `backup.hostPath` | `/var/backups/uptime-kuma` | 备份落盘目录，需 `chown 1000:1000` |
| `backup.runAsUser` | `1000` | 必须与 PVC 文件属主一致 |
