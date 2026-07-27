---
title: Linux 常用命令
description: 运维工程师必备的 Linux 命令速查手册
tags:
  - Linux
  - 运维
  - 命令速查
---

# Linux 常用命令

运维工作中高频使用的命令汇总，详见 [[index|首页]]。

## 文件操作

```bash
# 查找文件
find / -name "*.log" -mtime -7

# 查看文件大小
du -sh /var/log/*

# 批量重命名
for f in *.txt; do mv "$f" "${f%.txt}.md"; done
```

## 系统监控

```bash
# 实时进程监控
htop

# 磁盘使用
df -h

# 内存使用
free -h

# 网络连接
ss -tlnp
```

## 网络排查

```bash
# 端口检测
nc -zv 192.168.71.212 22

# DNS 解析
dig example.com

# 抓包
tcpdump -i eth0 port 443
```

## 相关笔记

- [[Docker 入门笔记]] - 容器化技术
- [[K3s 集群部署记录]] - Kubernetes 集群
