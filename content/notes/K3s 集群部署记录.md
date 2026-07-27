---
title: K3s 集群部署记录
description: 轻量级 Kubernetes 在局域网的实践
tags:
  - Kubernetes
  - K3s
  - 运维
  - 部署
---

# K3s 集群部署记录

K3s 是 Rancher 推出的轻量级 Kubernetes 发行版，非常适合资源有限的环境。容器运行时参考 [[Docker 入门笔记]]。

## 集群架构

| 节点 | 角色 | IP |
|------|------|----|
| ext-215 | Server | 192.168.71.215 |
| ext-214 | Worker | 192.168.71.214 |

## 安装 Server 节点

```bash
# 安装 K3s Server
curl -sfL https://get.k3s.io | sh -s - server \
  --disable traefik \
  --write-kubeconfig-mode 644

# 查看节点状态
kubectl get nodes
```

## 添加 Worker 节点

```bash
# 在 Server 节点获取 token
sudo cat /var/lib/rancher/k3s/server/node-token

# 在 Worker 节点执行
curl -sfL https://get.k3s.io | K3S_URL=https://192.168.71.215:6443 \
  K3S_TOKEN=<token> sh -s - agent
```

## 常用运维命令

```bash
# 查看所有 Pod
kubectl get pods -A

# 查看服务日志
kubectl logs -f <pod-name> -n <namespace>

# 进入 Pod
kubectl exec -it <pod-name> -- /bin/sh
```

## 注意事项

> [!warning] 生产环境
> - K3s 默认使用 SQLite，生产环境建议切换到 PostgreSQL
> - 定期备份 `/var/lib/rancher/k3s/server/`
> - 使用 `--disable traefik` 后需自行部署 Ingress Controller

## 相关笔记

- [[Docker 入门笔记]] - 容器基础知识
- [[Linux 常用命令]] - 系统操作
