#!/bin/bash
set -euo pipefail

rm -rf /home/w00921547/wangyuqi-mooncake/etcd-data && mkdir -p /home/w00921547/wangyuqi-mooncake/etcd-data

exec etcd \
  --name=solo \
  --data-dir=/home/w00921547/wangyuqi-mooncake/etcd-data \
  --listen-client-urls=http://0.0.0.0:17779 \
  --advertise-client-urls=http://0.0.0.0:17779 \
  --listen-peer-urls=http://0.0.0.0:17780 \
  --initial-advertise-peer-urls=http://0.0.0.0:17780 \
  --initial-cluster=solo=http://0.0.0.0:17780 \
  --initial-cluster-state=new \
  --auto-compaction-mode=periodic \
  --auto-compaction-retention=5m \
  --max-request-bytes=33554432
