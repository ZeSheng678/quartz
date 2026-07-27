---
title: Docker 入门笔记
description: 容器化基础知识与常用操作
tags:
  - Docker
  - 容器
  - 运维
---

# Docker 入门笔记

容器化是现代运维的基础，参考 [[Linux 常用命令]] 中的系统监控部分。

## 核心概念

- **镜像 (Image)**: 只读模板，包含运行应用所需的一切
- **容器 (Container)**: 镜像的运行实例
- **Dockerfile**: 构建镜像的脚本

## 常用命令

```bash
# 拉取镜像
docker pull nginx:latest

# 运行容器
docker run -d -p 80:80 --name web nginx

# 查看日志
docker logs -f web

# 进入容器
docker exec -it web /bin/bash
```

## Docker Compose

```yaml
version: '3'
services:
  web:
    image: nginx:latest
    ports:
      - "80:80"
    volumes:
      - ./html:/usr/share/nginx/html
```

## 生产实践

> [!tip] 生产环境建议
> - 使用 `restart: unless-stopped` 确保容器自动重启
> - 限制资源：`--memory 512m --cpus 1`
> - 使用 Docker network 隔离服务

## 相关笔记

- [[K3s 集群部署记录]] - Kubernetes 中的容器编排
- [[Linux 常用命令]] - 基础系统操作
