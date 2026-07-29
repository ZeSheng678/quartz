---
title: Kubernetes 故障排查索引
tags:
  - Kubernetes
  - 运维
  - 排障手册
category: 索引
status: active
---

# Kubernetes 故障排查索引

这个页面按故障现象组织 Kubernetes 排障入口。优先阅读标准化排障页。

## 快速入口

| 问题类型 | 适合先看 |
|---|---|
| Pod 创建后不运行 | [[Kubernetes Pod Pending 排查]], [[Kubernetes Pod 调度失败排查]] |
| Pod 启动后反复崩溃 | [[Kubernetes Pod CrashLoopBackOff 排查]] |
| 节点资源压力 | [[Kubernetes Pod Evicted 排查]], [[Kubernetes Node NotReady 排查]] |
| 存储挂载失败 | [[Kubernetes PV 挂载失败排查]] |
| 集群内服务访问失败 | [[Kubernetes Service 无响应排查]] |
| 域名或外部入口访问失败 | [[Kubernetes Ingress 路由失效排查]] |
| 资源配额或扩缩容异常 | [[Kubernetes ResourceQuota 资源超限排查]], [[Kubernetes HPA 缩放延迟排查]] |
| 定时任务异常 | [[Kubernetes CronJob 调度异常排查]] |

## Pod 问题

| 故障现象 | 标准化笔记 | 常用命令 | 关键词 |
|---|---|---|---|
| Pod 一直 Pending | [[Kubernetes Pod Pending 排查]] | `kubectl describe pod` | 调度、资源不足、污点 |
| Pod 调度失败 | [[Kubernetes Pod 调度失败排查]] | `kubectl get events` | scheduler、nodeSelector、affinity |
| Pod CrashLoopBackOff | [[Kubernetes Pod CrashLoopBackOff 排查]] | `kubectl logs --previous` | 启动失败、探针、配置 |
| helm-install Job CrashLoopBackOff | [[HelmChartConfig类型错误导致helm-install-traefikCrashLoopBackOff]] | `kubectl logs -n kube-system` | k3s、HelmChartConfig、expose 类型 |
| Pod 被驱逐 Evicted | [[Kubernetes Pod Evicted 排查]] | `kubectl describe node` | 磁盘、内存、资源压力 |

## Node 问题

| 故障现象 | 标准化笔记 | 常用命令 | 关键词 |
|---|---|---|---|
| Node NotReady | [[Kubernetes Node NotReady 排查]] | `kubectl describe node` | kubelet、网络、磁盘 |

## 存储问题

| 故障现象 | 标准化笔记 | 常用命令 | 关键词 |
|---|---|---|---|
| PV 挂载失败 | [[Kubernetes PV 挂载失败排查]] | `kubectl describe pvc` | PV、PVC、StorageClass、CSI |

## 网络访问链路

| 故障现象 | 标准化笔记 | 常用命令 | 关键词 |
|---|---|---|---|
| Service 无响应 | [[Kubernetes Service 无响应排查]] | `kubectl get endpoints` | Service、Endpoint、selector |
| Ingress 路由失效 | [[Kubernetes Ingress 路由失效排查]] | `kubectl describe ingress` | Ingress、路由、证书 |

## 资源与调度策略

| 故障现象 | 标准化笔记 | 常用命令 | 关键词 |
|---|---|---|---|
| ResourceQuota 超限 | [[Kubernetes ResourceQuota 资源超限排查]] | `kubectl describe quota` | 配额、Namespace、资源限制 |
| HPA 缩放延迟 | [[Kubernetes HPA 缩放延迟排查]] | `kubectl describe hpa` | HPA、指标、扩缩容 |
| CronJob 调度异常 | [[Kubernetes CronJob 调度异常排查]] | `kubectl describe cronjob` | CronJob、Job、调度 |

## 快速排查命令

```bash
kubectl get pods -A -o wide
kubectl get nodes -o wide
kubectl get events -A --sort-by=.lastTimestamp
kubectl describe pod <pod-name> -n <namespace>
kubectl logs <pod-name> -n <namespace> --previous
kubectl describe node <node-name>
kubectl get svc,endpoints -n <namespace>
kubectl get ingress -A
kubectl get pvc,pv
kubectl top nodes
kubectl top pods -A
```

## 维护说明

- 新增 Kubernetes 故障笔记时，优先按 [[排障复盘模板]] 写成标准化排障页。
- 索引里的入口优先指向标准化笔记，按故障现象组织。
