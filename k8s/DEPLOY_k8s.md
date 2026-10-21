# NVLink Status Collector — Kubernetes 部署方案（方案 1：DaemonSet + textfile）

适用集群：`zz1-shengshu1`（24 × B200/B300 GPU 节点，Victoria Metrics 监控栈，GPU Operator）。

本方案与裸机 cron 部署（`install.sh`）的关系：

| 裸机机制 | k8s 等价物 | 变化 |
|---|---|---|
| crontab 30s 双任务 + `--once` | DaemonSet 常驻循环（`--interval 30`） | 调度内聚到进程 |
| `timeout -k 5 25` 看门狗 | livenessProbe（mtime 检查）+ terminationGracePeriodSeconds 10s → SIGKILL | 同构，probe 独立于主进程，NVML ioctl 挂死也能检测 |
| flock 单实例锁 | DaemonSet 单副本（锁保留，防迁移期裸机版双写） | 弱化但仍保留 |
| `nvlink_last_collection_timestamp` 新鲜度告警 | 原样保留（VMRule） | 零变化 |
| `.prom` 文件协议 | 原样保留 + 宿主机 `kubernetes_node` label 语义 | 零变化 |

## 集群现状确认结论（2026-10-20 实测）

1. **监控栈是 Victoria Metrics 而非 Prometheus Operator**：vmagent（`mon/vmc-mon-vmstack`，scrapeInterval=20s）→ vminsert → vmselect/vmstorage；vmalert（`mon/vmc-mon-vmstack`，selectAllByDefault=true）+ vmalertmanager

> **2026-10-20 补充实测（镜像已构建推送并在真实 B200 节点验证通过）**：
> - 镜像：`registry.cn-beijing.aliyuncs.com/prtr/nvlink_collector:1.0.0`（linux/amd64，digest `sha256:cf374d…6069f4d`），构建命令见下文步骤 2
> - **NVML 注入机制实测**：该集群仅设 `runtimeClassName: nvidia` 时容器拿不到 `libnvidia-ml.so`（报 `NVML Shared Library Not Found`），必须同时声明 env `NVIDIA_VISIBLE_DEVICES=all` + `NVIDIA_DRIVER_CAPABILITIES=utility`；配齐后在 `pod2-b200gpu95`（B200×8）实测 8 卡全部采集成功，`nvlink_gpu_total_links=18`、`scrape_error=0`
> - **镜像拉取凭据**：prtr 为私有仓库，需 `imagePullSecrets: [{name: aliyun-yht-private}]`（与 node_exporter/gpfs-exporter 一致），DaemonSet YAML 已包含
2. **node_exporter 是 Helm 管理的 DS**：release `vmc-mon`，chart `prometheus-node-exporter-4.47.3`，镜像 `registry.cn-beijing.aliyuncs.com/prtr/node_exporter:1.9.1-1`（fork 版），**默认 textfile 目录为空**——不传参数时 `.prom` 文件不会被暴露，必须改 Helm values（见步骤 1）
3. **抓取路径已存在**：vmservicescrape `mon/vmc-mon-vmstack-prometheus-node-exporter` → vmagent，无需新增监控配置
4. **dcgm-exporter NVLink 覆盖不足**：实测 24 类 DCGM 指标中仅 `DCGM_FI_DEV_NVLINK_BANDWIDTH_TOTAL`（总量带宽），无每链路 state/crc/replay/recovery/ecc，自研 collector 的价值确认
5. **GPU 工具链完备**：GPU Operator cluster-policy ready，`nvidia` RuntimeClass 可用（dcgm-exporter 即此方式），GPU 节点无 taint，`nvidia.com/gpu.present=true` 标签齐全
6. **hostPath 白名单**：ValidatingAdmissionPolicy `workload-hardening`（binding `workload-hardening-audit`）当前为 **audit 模式（只告警不拒绝）**；`/usr/local/node_exporter/...` 不在白名单，Enforce 后需平台组加白
7. **告警自动化风险**：mon ns 有 `alert-node-quarantine`（告警驱动节点隔离）→ 新 VMRule 全部先 `severity: warning`

## 部署步骤

### 步骤 1：让 node_exporter 暴露 textfile 目录（一次性，Helm values，已完成 2026-10-21）

主 DS 的镜像默认 textfile 目录为空，必须显式指定。**不要直接 kubectl edit/patch**（Helm 管理会被 upgrade 覆盖）。

实际变更（已写入部署仓库 `zz1-shengshu1-deploy/mon/vmc/values/vmc.yml` 的 `prometheus-node-exporter` 段，已用 helmwave build 渲染验证通过）：

```yaml
prometheus-node-exporter:
  # ...原有 extraArgs 6 条完整保留（整列表覆盖语义，不能只写新增条目）...
  extraArgs:
    # ...原有 6 条...
    # 新增 ↓
    - --collector.textfile.directory=/usr/local/node_exporter/extra_metrics_custom

  # 新增：宿主机 textfile 目录挂载（chart 4.47.3 字段，模板已确认消费）
  extraHostVolumeMounts:
    - name: nvlink-textfile
      hostPath: /usr/local/node_exporter/extra_metrics_custom
      type: DirectoryOrCreate        # 非 GPU 节点自动建空目录，读到空不报错
      mountPath: /usr/local/node_exporter/extra_metrics_custom
      readOnly: true
```

使变更生效（helmwave 管理的 release `vmc-mon`，在部署仓库 `mon/vmc/` 目录下）：

```bash
cd zz1-shengshu1-deploy/mon/vmc
helmwave build --tags vmc --plandir .helmwave/vmc    # 重新渲染 plan（build-vmc 脚本同款）
helmwave up --tags vmc --plandir .helmwave/vmc       # 部署（up-vmc 脚本同款）
```

> 验证：`kubectl -n mon rollout status ds/vmc-mon-prometheus-node-exporter`（34 副本滚动重启），之后集群内 `curl <node-ip>:9100/metrics | grep node_textfile`，`node_textfile_scrape_error 0` 即目录参数与挂载均生效。

### 步骤 2：构建并推送镜像（已完成 2026-10-20，重新构建时参考）

```bash
# 构建机需 docker login registry.cn-beijing.aliyuncs.com（prtr 推送凭据）
# 构建 linux/amd64（构建机为 Apple Silicon 时用 buildx 交叉构建，
# 该镜像仅 pip install + COPY，仿真构建安全）
docker buildx build --builder multiarch --platform linux/amd64 \
  -t registry.cn-beijing.aliyuncs.com/prtr/nvlink_collector:1.0.0 \
  -f k8s/Dockerfile --push .
```

已推送：`registry.cn-beijing.aliyuncs.com/prtr/nvlink_collector:1.0.0`（`Arch=amd64 OS=linux`，与 node_exporter 同仓库，节点已实测可拉取）。
构建机若无法直连外网（python 基础镜像/pip 源），在 Dockerfile 顶部加内部 pip mirror；本仓库 `packages/nvidia_ml_py-13.610.43-py3-none-any.whl` 可离线安装。

### 步骤 3：部署 DaemonSet

```bash
kubectl apply -f k8s/nvlink-collector-daemonset.yaml
kubectl -n mon rollout status ds/nvlink-collector --timeout=180s
kubectl -n mon get pod -l app=nvlink-collector -o wide   # 应有 24 副本（GPU 节点数）
kubectl -n mon logs ds/nvlink-collector --all-containers --since=2m | head -30
```

### 步骤 4：验证指标链路端到端

```bash
# a. 节点文件已生成
kubectl debug node/<gpu-node> -it --image=busybox --profile=general -- \
  cat /host/usr/local/node_exporter/extra_metrics_custom/nvlink_status.prom

# b. node_exporter 端点暴露 nvlink_* 指标（集群内执行）
kubectl run probe --rm -it --restart=Never --image=curlimages/curl:8.11.1 -- \
  -s http://<node-ip>:9100/metrics | grep nvlink_ | head

# c. VictoriaMetrics 可查询（约 1 个抓取周期后）
#    在 Grafana (vmc-mon-grafana) 或 vmselect API 执行 PromQL:
#    nvlink_link_state / nvlink_gpu_active_links / nvlink_last_collection_timestamp
```

### 步骤 5：部署告警规则

```bash
kubectl apply -f k8s/nvlink-collector-vmrule.yaml
kubectl -n mon get vmrule mon-alert-custom-rules-nvlink.rules   # STATUS 应为 operational
```

## 迁移注意事项

1. **同节点勿双栈运行**：若某 GPU 节点此前装过裸机 cron 版，先 `sudo bash install.sh --uninstall` 再上 DaemonSet，避免 flock 互踩造成新旧交替写 `.prom`（指标毛刺）。flock 在双栈共存时提供的是"交替跳过"而非数据一致性
2. **CPU 节点不部署**：nodeSelector `nvidia.com/gpu.present=true` 只覆盖 24 个 GPU 节点；无 NVLink 的 GPU（如未来 A100 PCIe）脚本会输出 `gpu_total_links 0` 并打 warning 日志，属预期
3. **`.prom` 残留语义**：Pod 崩溃后宿主机上旧文件残留由 `NVLinkMetricsStale` 告警兜底（这正是 timestamp 双信号设计的价值）
4. **workload-hardening 策略**：audit 模式下 hostPath 告警可忽略；若平台切 Enforce，把 `/usr/local/node_exporter/extra_metrics_custom` 加入白名单即可
5. **升级路径**：镜像 tag 变更 + `kubectl set image` 或 `kubectl apply` 新版本 YAML，RollingUpdate maxUnavailable=1 逐节点滚动

## 实测补充（2026-10-20）

- 集群 textfile 指标的节点标识 label 实际为 **`nodename`**（vmagent 服务发现注入），VMRule 模板已按此写；现有 `node: {{$labels.node}}` 惯例来自其它采集链路（如 k8 组件指标），对 textfile 指标不适用
- vmservicescrape `vmc-mon-vmstack-prometheus-node-exporter` 的 endpoint 级 `scrape_interval=1s`，数据新鲜度告警 120s 阈值有充分余量

## 故障排查速查

| 症状 | 检查 |
|---|---|
| Pod Running 但 `.prom` 不生成 | `kubectl -n mon logs ds/nvlink-collector`；NVML init 失败会显式打 ERROR（驱动未就绪/设备不可见） |
| liveness 反复杀 Pod（RESTARTS 增长） | NVML ioctl 挂死（同裸机版场景）：`kubectl -n mon describe pod` 看 last state；`dmesg \| grep -i nvrm` 查驱动；对照裸机版文档"采集挂死"章节 |
| node_exporter 有指标但 VM 查不到 | 步骤 1 的 textfile 参数是否生效：node_exporter metrics 里搜 `node_textfile_scrape_error` |
| 全部 GPU `active_links=0` | 优先怀疑真实硬件/驱动问题（这正是本项目要捕捉的故障），`nvidia-smi nvlink -s` 在节点上复核 |
