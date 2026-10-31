# legacy 目录说明

这里的文件是 **Helm 化之前**用于 `kubectl apply` 的裸 YAML，仅作历史参考保留。

| 文件 | 原用途 | 现状 |
|---|---|---|
| `k8s-uptime-kuma.yaml` | Namespace + PVC + Deployment + Service | 已被 `charts/uptime-kuma-stack` 取代 |
| `k8s-uptime-kuma-backup.yaml` | 备份 CronJob | 已被 `charts/uptime-kuma-stack/templates/backup-cronjob.yaml` 取代 |

## ⚠️ 不要再 apply

这些对象现在由 Helm release `uptime-kuma` 管理（带 `app.kubernetes.io/managed-by: Helm` 标签）。如果再用 `kubectl apply -f` 应用这里的文件：

1. 对象的 `spec` 会被覆盖回旧值（比如镜像 tag 从 `2.5.8` 退回 `2`）
2. Helm 的 release 记录与实际状态产生漂移
3. 下次 `helm upgrade` 会出现一批"说不清来源"的变更

需要变更请走 `helm upgrade`，见 [`../runbook.md`](../runbook.md)。

## 保留价值

对比这两份文件与 Chart 的模板，能直观看出从「手写资源清单」到「参数化模板」的差异：

- 裸 YAML：镜像 tag、端口、资源限制全部硬编码，改一处要改多行
- Chart：`values.yaml` 统一暴露，`--set` 可临时覆盖，`helm history` 可追溯每次变更

另外，`k8s-uptime-kuma.yaml` 里没有 `securityContext`、没有 `TZ`、没有 `startingDeadlineSeconds` —— 这些都是踩坑后逐步补上的，Chart 版本已经包含。
