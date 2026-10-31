NS      ?= monitoring
RELEASE ?= uptime-kuma
CHART   ?= ./charts/uptime-kuma-stack
DEPLOY  := deploy/uptime-kuma

.DEFAULT_GOAL := help

.PHONY: help status pods logs diff template lint upgrade history rollback backup-now backups shell restart

help: ## 显示所有可用命令
	@grep -E '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) \
		| awk -F':.*## ' '{printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

status: ## 一屏看全：Pod / Service / PVC / CronJob / release
	kubectl get pods,svc,pvc,cronjob,deploy -n $(NS)
	helm list -n $(NS)

pods: ## 只看 Pod（含节点与 IP）
	kubectl get pods -n $(NS) -o wide

logs: ## 应用日志（最近 80 行）
	kubectl logs -n $(NS) $(DEPLOY) --tail=80

template: ## 渲染 Chart，不部署
	helm template $(RELEASE) $(CHART) -n $(NS)

lint: ## Chart 语法检查
	helm lint $(CHART)

diff: ## 渲染结果与线上对象对比（server-side dry-run）
	helm template $(RELEASE) $(CHART) -n $(NS) | kubectl diff -f - || true

upgrade: ## 应用 values.yaml 的变更
	helm upgrade $(RELEASE) $(CHART) -n $(NS)
	kubectl rollout status $(DEPLOY) -n $(NS) --timeout=300s

history: ## 查看 release 历史
	helm history $(RELEASE) -n $(NS)

rollback: ## 回滚到指定 revision：make rollback REV=2
	@test -n "$(REV)" || { echo "用法: make rollback REV=<revision>"; exit 1; }
	helm rollback $(RELEASE) $(REV) -n $(NS)
	kubectl rollout status $(DEPLOY) -n $(NS) --timeout=300s

backup-now: ## 手动触发一次备份
	kubectl create job --from=cronjob/uptime-kuma-backup -n $(NS) backup-manual-$$(date +%H%M%S)
	kubectl get jobs -n $(NS) | tail -3

backups: ## 查看宿主机上的备份产物
	ls -lh /var/backups/uptime-kuma/

shell: ## 进入应用容器
	kubectl exec -it -n $(NS) $(DEPLOY) -- sh

restart: ## 滚动重启（会短暂中断）
	kubectl rollout restart $(DEPLOY) -n $(NS)
	kubectl rollout status $(DEPLOY) -n $(NS) --timeout=300s
