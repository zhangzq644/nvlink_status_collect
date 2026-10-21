# NVLink Collector 两节点灰度验证清单

> 按序执行，每步给出**期望输出**；任何一步不符即停，按对应的"不通过时"处理。
> 灰度节点：`pod2-b200gpu95`（B200, IP 10.25.2.195）+ `pod11-b300gpu20`（B300, IP 10.25.2.20）
> 前置：镜像 `registry.cn-beijing.aliyuncs.com/prtr/nvlink_collector:1.0.0` 已推送（完成）；本清单命令默认配置 `export KUBECONFIG=/Users/zzq/.kube/zz1-shengshu1.yml`（或在集群可达的跳板机执行）。

## 状态速览表

| # | 验证点 | 阶段 | 命令来源 |
|---|---|---|---|
| S0 | 灰度节点现状确认（只读，无需打 label） | apply 前 | 步骤 0 |
| S1 | node_exporter 侧变更（textfile 参数+挂载） | apply 前 | 步骤 1（helmwave） |
| S2 | 灰度 DS apply & Pod Running | apply 时 | 步骤 2 |
| S3 | 采集日志正确（8 GPU / 18 links） | Pod 层 | 步骤 3 |
| S4 | 宿主机文件落盘 + mtime 刷新（hostPath 通道闭环） | 文件层 | 步骤 4 |
| S5 | node_exporter 9100 端口暴露 nvlink_* | 暴露层 | 步骤 5 |
| S6 | VictoriaMetrics 落库 & PromQL 查询 | 存储层 | 步骤 6 |
| S7 | 数值正确性抽查（对照 nvidia-smi） | 语义层 | 步骤 7 |
| S8 | 稳定性观察（重启次数/liveness/持续刷新） | 观察期 | 步骤 8 |
| S9 | 放量 & VMRule & 清理 | 收尾 | 步骤 9 |

## 前置事实（已由本仓验证过，供对照）

- 镜像 `Arch=amd64 OS=linux`，曾以无 hostPath 的临时 Pod 在 pod2-b200gpu95 实测：NVML init 成功、8×B200 全采集、`gpu_total_links=18`、常驻模式正常
- 29 个 GPU 节点中 6 个存在裸机版历史残留目录（root:root 0755 空目录，无 binary/cron 残留），23 个无目录 —— 均不阻塞，`DirectoryOrCreate` 会补建
- 该集群 node_exporter 的 vmservicescrape `scrape_interval: 1s`，vmagent 全局 20s —— S6 的 PromQL 最迟 ~1s 可见（通常即时）

## 步骤 0：灰度节点基线确认（只读，不在节点上打任何 label）

灰度节点由 DaemonSet YAML 内的 nodeAffinity 点名（`pod2-b200gpu95` + `pod11-b300gpu20`），**无需也无法通过节点 label 控制**——节点对象零改动。

```bash
# 确认两台灰度节点就绪、GPU present、非 cordoned
kubectl get node pod2-b200gpu95 pod11-b300gpu20 \
  -L nvidia.com/gpu.present,nvidia.com/gpu.model
```

**期望输出**：两行 STATUS 均为 `Ready`（不带 SchedulingDisabled），`GPU.PRESENT=true`，MODEL 分别为 `B200`/`B300`。

> 说明：灰度版 DS 的调度约束 = `nvidia.com/gpu.present=true` AND `kubernetes.io/hostname In [pod2-b200gpu95, pod11-b300gpu20]`，全部由 Pod spec（nodeAffinity）表达。
> 若需更换灰度节点：改 `k8s/nvlink-collector-daemonset-canary.yaml` 中 nodeAffinity 的 values 列表后重新 apply，同样不碰节点。

## 步骤 1：node_exporter 侧变更（helmwave，全量滚动但无副作用）

```bash
cd /Users/zzq/Paratera/projects/MajorCustomer/zz1-shengshu1-deploy/mon/vmc
helmwave build --tags vmc --plandir .helmwave/vmc
helmwave up   --tags vmc --plandir .helmwave/vmc
```

**验证（全量 34 副本滚动，约 3-5 分钟）**：

```bash
kubectl -n mon rollout status ds/vmc-mon-prometheus-node-exporter
```

**期望输出**：`daemon set "vmc-mon-prometheus-node-exporter" successfully rolled out`

再验证 textfile 参数与挂载都带上了（挑灰度节点上的 Pod）：

```bash
# 期望: args 中含 --collector.textfile.directory=/usr/local/node_exporter/extra_metrics_custom
kubectl -n mon get pod -l app.kubernetes.io/name=prometheus-node-exporter \
  -o jsonpath='{range .items[?(@.spec.nodeName=="pod2-b200gpu95")]}{.spec.containers[0].args}{"\n"}{end}'
```

> **不通过时**：`kubectl -n mon describe ds vmc-mon-prometheus-node-exporter` 看滚动事件；helmwave up 前可先 `helmwave build` 确认 manifest diff（`.helmwave/vmc/manifest/vmc-mon@mon.yml` 中 grep textfile）。
> **影响面说明**：此步即使 collector 还没上，也只是全集群多挂一个空目录，node_exporter 读空目录不报错，无任何指标变化。

## 步骤 2：灰度 DS apply

```bash
kubectl apply -f k8s/nvlink-collector-daemonset-canary.yaml
kubectl -n mon rollout status ds/nvlink-collector --timeout=180s
kubectl -n mon get pod -l app=nvlink-collector -o wide
```

**期望输出**：`desired=2 current=2 ready=2`；两个 Pod 分别落在 `pod2-b200gpu95` 与 `pod11-b300gpu20`，状态 Running，RESTARTS 0。

> **不通过时**：
> - 卡 `ContainerCreating`：`kubectl -n mon describe pod <pod>` 看事件，若是 hostPath/权限类（audit 策略理论上不拦），把事件发我
> - `ErrImagePull`：检查 `aliyun-yht-private` secret 是否仍在：`kubectl -n mon get secret aliyun-yht-private`
> - Pod 起不来且日志有 `NVML Shared Library Not Found`：确认容器 env 里有 `NVIDIA_VISIBLE_DEVICES=all`（灰度 YAML 已含，若手改过需自查）

## 步骤 3：采集日志正确性

```bash
kubectl -n mon logs ds/nvlink-collector --all-containers --tail=30
```

**期望输出**（每台 8 卡）：

```
... [INFO] NVLink Status Collector starting
... [INFO] Collection interval: 30 seconds
... [INFO] Found 8 GPU device(s)
... [INFO] GPU 0: NVIDIA B200 - Collecting NVLink metrics
...(GPU 1~7 逐行)
... [INFO] Successfully wrote metrics to /usr/local/node_exporter/extra_metrics_custom/nvlink_status.prom
```

> **不通过时**：`Found 0 GPU` 或 ERROR 行→ 该节点驱动状态异常（`kubectl debug node/<n> -- chroot /host nvidia-smi`），疑似环境问题不影响其他节点，单独摘除该灰度节点。

## 步骤 4：宿主机文件落盘 + 持续刷新（hostPath 通道闭环——smoke 未覆盖的一环）

```bash
# 4a. 目录与文件（节点65/20 各跑一次，--rm 不留痕）
kubectl debug node/pod2-b200gpu95 -it --image=busybox:1.36 --profile=general -- \
  chroot /host ls -la /usr/local/node_exporter/extra_metrics_custom/

# 4b. mtime 应每 30s 变化（间隔执行两次，对比时间）
kubectl debug node/pod2-b200gpu95 -it --image=busybox:1.36 --profile=general -- \
  chroot /host sh -c 'stat -c "%y %s" /usr/local/node_exporter/extra_metrics_custom/nvlink_status.prom; sleep 35; stat -c "%y %s" /usr/local/node_exporter/extra_metrics_custom/nvlink_status.prom'
```

**期望输出**（4a，目录原不存在的节点显示刚创建的时间；文件属主 root，0644）：

```
drwxr-xr-x 2 root root 4096 <今天> .
drwxr-xr-x 4 root root 4096 <今天> ..
-rw-r--r-- 1 root root  <大小约 40-80KB> <mtime 距今<30s> nvlink_status.prom
-rw-r--r-- 1 root root  4 <同批时间> nvlink_status.prom.lock
```

**期望输出**（4b）：两次 `stat` 的 `%y`（mtime）相差约 30s，`%s`（大小）相近。

> **不通过时**：
> - 文件不存在：回到步骤 3 看是否 `Failed to write`；或挂载点错（`kubectl describe pod` 的 Mounts 段核对路径）
> - mtime 不动但 Pod 还在：liveness 探针约 90-120s 后会杀掉它（RESTARTS+1），说明 NVML ioctl 挂死被正确捕获——这正是设计行为，但灰度期间就该查 `kubectl debug node/<n> -- chroot /host dmesg | grep -i nvrm`

## 步骤 5：node_exporter 端口暴露验证

```bash
kubectl run nvlink-check --rm -it --restart=Never --image=curlimages/curl:8.11.1 -- \
  -s http://10.25.2.195:9100/metrics | grep -E "^nvlink_(scrape_error|last_collection|gpu_(active|total)_links|link_state)" | head -20
# B300 节点同命令换 IP: 10.25.2.20
```

**期望输出**：

```
nvlink_scrape_error 0
nvlink_last_collection_timestamp 17925xxx（≈当前 unix 时间）
nvlink_gpu_total_links{gpu="0",...,gpu_model="NVIDIA B200",nodename="pod2-b200gpu95",...} 18
nvlink_gpu_active_links{gpu="0",...} 18        ← 空闲机器全链路一般全 active
...（8 行 total_links + 8 行 active_links）
nvlink_link_state{gpu="0",...,link="0",...} 1
...（144 行/每节点 = 8卡 × 18链路）
```

> **不通过时**：
> - 只有 scrape_error/timestamp、没有 link 指标：node_exporter 的 textfile 目录参数没生效（回步骤 1 验证）
> - 完全没有 nvlink_*：vm Scrape 对象可能把 job 名改了，`grep` 前先 `| head -5` 原样看一眼（textfile 里的指标名还会带上 node_exporter 自动加的 job/instance 等 label，指标本身都以 nvlink_ 开头）
> - `node_textfile_scrape_error 1`：说明 .prom 解析失败，`cat` 一份文件原文发我

## 步骤 6：VictoriaMetrics 落库验证（延迟 ≤ 1 个抓取周期）

```bash
kubectl run vm-check --rm -it --restart=Never --image=curlimages/curl:8.11.1 -- \
  -s "http://vmselect-vmc-mon-vmstack.mon.svc.cluster.local.:8481/select/0/prometheus/api/v1/query" \
  --data-urlencode 'query=count(nvlink_link_state{nodename=~"pod2-b200gpu95|pod11-b300gpu20"})'
```

**期望输出**：`"value":["<now>","288"]`（2 节点 × 8 卡 × 18 链路 = 288 序列；也可能因重名 label 合并略有出入，数量级对即可）

再抽查新鲜度：

```bash
kubectl run vm-check2 --rm -it --restart=Never --image=curlimages/curl:8.11.1 -- \
  -s "http://vmselect-vmc-mon-vmstack.mon.svc.cluster.local.:8481/select/0/prometheus/api/v1/query" \
  --data-urlencode 'query=time() - nvlink_last_collection_timestamp{nodename="pod2-b200gpu95"}'
```

**期望输出**：value 即"距最后采集的秒数"，`< 90`（interval 30s + 采集耗时 + 查询路径延迟的合法区间；`staleness` 告警阈值是 120s）

> **不通过时**：9100 有但 VM 没有 → 查 vmagent：`kubectl -n mon logs deploy/vmagent-vmc-mon-vmstack -c vmagent --tail=50 | grep -iE "error|nvlink"`

## 步骤 7：数值正确性抽查（对照驱动输出）

```bash
# 独立信源: nvidia-smi 的链路状态（灰度节点各跑）
kubectl debug node/pod2-b200gpu95 -it --image=busybox:1.36 --profile=general -- \
  chroot /host nvidia-smi nvlink -s | head -30
```

**对照方法**：`nvidia-smi nvlink -s` 输出中每卡 18 行 `Link 0~17` 的 Active/Inactive，数一下 GPU 0 的 active 数，与步骤 5 中 `nvlink_gpu_active_links{gpu="0"}` 对比。误差为 0 才算过（同一代驱动同一时刻的两次读数；若前后差 ±1 条，隔 30s 采一轮再对一次均值）。

> **观察项（不强求）**：togofth/NVLINK 错误计数类指标（`nvlink_link_error_*`）应全为 0 或极小；非 0 且持续增长才值得关注——本身也是这套监控的目的。

## 步骤 8：稳定性观察（观察期 ≥ 4 小时，建议过夜）

```bash
# 8a. 无重启（期望 RESTARTS 稳定 0；liveness 误杀会体现在这里）
kubectl -n mon get pod -l app=nvlink-collector

# 8b. liveness/readiness 无异常事件
kubectl -n mon describe ds nvlink-collector | grep -A8 Events
kubectl -n mon get event --field-selector involvedObject.kind=Pod -n mon | grep nvlink

# 8c. 资源占用（确认 limits 足够）
kubectl -n mon top pod -l app=nvlink-collector
```

**期望**：RESTARTS 0；无 Liveness 失败的 Warning 事件；内存 ≪ 128Mi（实测约 30-60MB）、CPU 短暂尖峰 ≪ 500m。

## 步骤 9：放量 + VMRule + 清理

全部通过后（建议灰度跑满一个工作日）：

```bash
# 9a. 全量替换（先删灰度版再上全量版，两者 DS 同名不可共存）
kubectl delete -f k8s/nvlink-collector-daemonset-canary.yaml
kubectl apply  -f k8s/nvlink-collector-daemonset.yaml
kubectl -n mon rollout status ds/nvlink-collector --timeout=600s
# 期望: desired=29（全部 GPU 节点），逐台滚动几分钟

# 9b. 全量后 10 分钟做一次步骤 6 的放大版抽查
#     count(nvlink_link_state) 应≈ 29节点×8卡×18链路=4176（数量级对即可）

# 9c. 部署告警规则（此时数据分析面已全量）
kubectl apply -f k8s/nvlink-collector-vmrule.yaml
kubectl -n mon get vmrule mon-alert-custom-rules-nvlink.rules   # STATUS=operational

# 9d. 无需任何节点清理（灰度控制全程在 Pod spec 的 nodeAffinity 里，节点对象未动过）
```

**放量后关注点**（24h 内）：alertmanager 是否出现 NVLink 相关告警（正常应无；有 `discoverd_nvlink_*` 告警先看是真故障还是规则问题）；`alert-node-quarantine` 无异常联动（其消费的是 critical 告警，VMRule 全部 warning，理论无联动）。

## 回滚预案

| 环节 | 回滚命令 | 影响面 |
|---|---|---|
| collector 灰度期出问题 | `kubectl delete -f k8s/nvlink-collector-daemonset-canary.yaml` | 仅 2 灰度节点；残留一个不再更新的 `.prom` 文件（mtime 停更、不炸告警——VMRule 还未上，无告警噪音） |
| collector 全量期出问题 | `kubectl delete -f k8s/nvlink-collector-daemonset.yaml` | 同上，29 节点文件残留停更 |
| node_exporter 变更出问题 | 部署仓库 git revert vmc.yml → `helmwave build/up` | 回到无 textfile 目录状态，node_exporter 恢复原参数（滚动一轮，监控面短暂抖动） |
| VMRule 出问题 | `kubectl delete -f k8s/nvlink-collector-vmrule.yaml` | 秒级从 vmalert 卸载规则 |
