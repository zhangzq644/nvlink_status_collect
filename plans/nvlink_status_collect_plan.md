# NVLink 状态采集脚本 - 设计方案

## 1. 背景与目标

GPU 服务器出现报错：`NVML: Unable to retrieve Nvlink information as all links are inActive`，需要采集 NVLink links 状态用于集群运维监控。

**核心目标**：持续采集每台 GPU 节点的 NVLink 状态，输出为 Prometheus 指标文件，通过 node_exporter textfile collector 上报。

## 2. 技术选型

| 项目 | 选择 | 理由 |
|---|---|---|
| 语言 | Python3 | 开发快、运维人员易维护 |
| NVML 绑定 | nvidia-ml-py (pynvml 模块) | NVIDIA 官方维护，pip install 方便 |
| 输出方式 | .prom 文件 | 配合 node_exporter textfile collector |
| 进程管理 | 常驻进程 + systemd service | 30秒采集间隔，cron 无法实现 |
| 部署方式 | 每台 GPU 节点部署 | NVML 只能访问本地 GPU |

## 3. 采集指标设计

### 3.1 核心指标 - link 状态

```
# HELP nvlink_link_state NVLink link state: 1=active, 0=inactive
# TYPE nvlink_link_state gauge
nvlink_link_state{gpu="0",gpu_model="NVIDIA B300 SXM6 AC",link="0"} 1
nvlink_link_state{gpu="0",gpu_model="NVIDIA B300 SXM6 AC",link="1"} 0
```

### 3.2 汇总指标 - 每个 GPU 的 link 统计

```
# HELP nvlink_gpu_active_links Number of active NVLink links on this GPU
# TYPE nvlink_gpu_active_links gauge
nvlink_gpu_active_links{gpu="0",gpu_model="NVIDIA B300 SXM6 AC"} 4

# HELP nvlink_gpu_total_links Total number of NVLink links on this GPU
# TYPE nvlink_gpu_total_links gauge
nvlink_gpu_total_links{gpu="0",gpu_model="NVIDIA B300 SXM6 AC"} 18
```

### 3.3 扩展指标 - 尽力采集

```
# NVLink 版本
nvlink_link_version{gpu="0",gpu_model="NVIDIA B300 SXM6 AC",link="0"} 4

# 对端 PCI 信息（仅 active 时输出）
nvlink_link_remote_pci{gpu="0",gpu_model="NVIDIA B300 SXM6 AC",link="0",remote_pci="0000:07:00.0"} 1

# 利用率计数
nvlink_link_tx_utilization_count{gpu="0",gpu_model="NVIDIA B300 SXM6 AC",link="0"} 123456
nvlink_link_rx_utilization_count{gpu="0",gpu_model="NVIDIA B300 SXM6 AC",link="0"} 789012

# 错误计数器
nvlink_link_error_crc{gpu="0",gpu_model="NVIDIA B300 SXM6 AC",link="0"} 0
nvlink_link_error_replay{gpu="0",gpu_model="NVIDIA B300 SXM6 AC",link="0"} 0
nvlink_link_error_recovery{gpu="0",gpu_model="NVIDIA B300 SXM6 AC",link="0"} 0
```

### 3.4 采集状态指标

```
# HELP nvlink_scrape_error Indicates scrape error: 1=error, 0=success
# TYPE nvlink_scrape_error gauge
nvlink_scrape_error 0
```

## 4. 核心逻辑

### 4.1 动态发现 link 数量

不硬编码 link 数量，从 link=0 开始遍历，调用 `nvmlDeviceGetNvLinkState()`，当返回 `NVML_ERROR_INVALID_ARGUMENT` 时停止，自动适配不同 GPU 型号。

### 4.2 错误处理策略

- NVML 初始化失败：写入 `nvlink_scrape_error 1`，不保留上次数据
- 单个 API 调用失败：跳过该指标，不影响其他指标采集
- inactive link：状态指标输出 0，其他扩展指标不输出

### 4.3 文件写入策略

先写入临时文件，再原子替换（`mv`），避免 node_exporter 读到半写状态。

## 5. 部署架构

```mermaid
graph TD
    A[nvlink_collector.py 常驻进程] -->|每30秒采集| B[调用 pynvml NVML API]
    B --> C[生成 .prom 文件]
    C -->|原子 mv 替换| D[/usr/local/node_exporter/extra_metrics_custom/nvlink_status.prom]
    E[node_exporter] -->|textfile collector 读取| D
    E -->|metrics 端点| F[Prometheus]
    F --> G[Grafana 展示]
```

## 6. 交付物

| 文件 | 说明 |
|---|---|
| `nvlink_collector.py` | 采集脚本主程序 |
| `nvlink_collector.service` | systemd service 文件 |
| `install.sh` | 一键安装部署脚本 |
| `README.md` | 使用说明、指标说明、部署步骤 |

## 7. 项目目录结构

```
nvlink_status_collect/
├── nvlink_collector.py          # 采集脚本主程序
├── nvlink_collector.service     # systemd service 文件
├── install.sh                   # 一键安装部署脚本
├── README.md                    # 使用说明
└── plans/
    └── nvlink_status_collect_plan.md  # 本设计文档
```

## 8. 关键配置参数

| 参数 | 默认值 | 说明 |
|---|---|---|
| 采集间隔 | 30 秒 | 可通过命令行参数调整 |
| .prom 文件路径 | /usr/local/node_exporter/extra_metrics_custom/nvlink_status.prom | 可通过命令行参数调整 |
| 日志级别 | INFO | 可通过命令行参数调整 |

## 9. 告警建议

```yaml
# 所有 NVLink links 都 inactive
- alert: NVLinkAllLinksInactive
  expr: nvlink_gpu_active_links == 0
  for: 2m
  labels:
    severity: critical
  annotations:
    summary: "GPU {{ $labels.gpu }} all NVLink links inactive"

# 采集脚本异常
- alert: NVLinkScrapeError
  expr: nvlink_scrape_error == 1
  for: 1m
  labels:
    severity: warning
  annotations:
    summary: "NVLink status collection failed"
```
