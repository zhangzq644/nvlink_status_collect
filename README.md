# NVLink Status Collector

GPU NVLink 状态采集工具，通过 NVML API 采集 NVLink 链路状态和指标，输出为 Prometheus `.prom` 文件，配合 node_exporter textfile collector 实现集群监控。

## 背景

当 GPU 的 NVLink 链路全部处于 inactive 状态时，`nvidia-smi` 等工具会报错：

```
NVML: Unable to retrieve Nvlink information as all links are inActive
```

本工具通过直接调用 NVML API（`nvmlDeviceGetNvLinkState()`）获取每个 NVLink link 的 active/inactive 状态，即使所有 link 都 inactive 也能正常工作。

## 采集指标

### 核心指标

| 指标名 | 类型 | 说明 |
|---|---|---|
| `nvlink_link_state` | gauge | NVLink link 状态：1=active, 0=inactive |
| `nvlink_gpu_active_links` | gauge | 每个 GPU 的活跃 link 数量 |
| `nvlink_gpu_total_links` | gauge | 每个 GPU 的 link 总数 |
| `nvlink_scrape_error` | gauge | 采集状态：0=成功, 1=失败 |
| `nvlink_last_collection_timestamp` | gauge | 最后一次采集尝试的 Unix 时间戳(成功失败均更新),用于数据新鲜度告警 |

### 扩展指标（仅 active link 采集）

| 指标名 | 类型 | 说明 |
|---|---|---|
| `nvlink_link_version` | gauge | NVLink 版本号 |
| `nvlink_link_remote_pci` | gauge | 对端 GPU PCI 地址（值恒为1，看 remote_pci label） |
| `nvlink_link_tx_utilization_count` | counter | 发送利用率计数 |
| `nvlink_link_rx_utilization_count` | counter | 接收利用率计数 |
| `nvlink_link_error_crc_data` | counter | CRC 数据错误计数 |
| `nvlink_link_error_crc_flit` | counter | CRC FLIT 错误计数 |
| `nvlink_link_error_replay` | counter | Replay 错误计数 |
| `nvlink_link_error_recovery` | counter | Recovery 错误计数 |
| `nvlink_link_error_ecc_data` | counter | ECC 数据错误计数 |

### 指标示例

```prometheus
# HELP nvlink_scrape_error Indicates scrape error: 1=error, 0=success
# TYPE nvlink_scrape_error gauge
nvlink_scrape_error 0

# HELP nvlink_last_collection_timestamp Unix timestamp of last collection attempt
# TYPE nvlink_last_collection_timestamp gauge
nvlink_last_collection_timestamp 1756716000

# HELP nvlink_link_state NVLink link state: 1=active, 0=inactive
# TYPE nvlink_link_state gauge
nvlink_link_state{gpu="0",gpu_model="NVIDIA B300 SXM6 AC",link="0"} 1
nvlink_link_state{gpu="0",gpu_model="NVIDIA B300 SXM6 AC",link="1"} 0
nvlink_link_state{gpu="1",gpu_model="NVIDIA B300 SXM6 AC",link="0"} 1

# HELP nvlink_gpu_active_links Number of active NVLink links on this GPU
# TYPE nvlink_gpu_active_links gauge
nvlink_gpu_active_links{gpu="0",gpu_model="NVIDIA B300 SXM6 AC"} 4
nvlink_gpu_total_links{gpu="0",gpu_model="NVIDIA B300 SXM6 AC"} 18

# HELP nvlink_link_version NVLink version number
# TYPE nvlink_link_version gauge
nvlink_link_version{gpu="0",gpu_model="NVIDIA B300 SXM6 AC",link="0"} 4

# HELP nvlink_link_remote_pci NVLink remote PCI device info
# TYPE nvlink_link_remote_pci gauge
nvlink_link_remote_pci{gpu="0",gpu_model="NVIDIA B300 SXM6 AC",link="0",remote_pci="0000:07:00.0"} 1

# HELP nvlink_link_tx_utilization_count NVLink transmit utilization count
# TYPE nvlink_link_tx_utilization_count counter
nvlink_link_tx_utilization_count{gpu="0",gpu_model="NVIDIA B300 SXM6 AC",link="0"} 123456

# HELP nvlink_link_error_crc_data NVLink crc_data error counter
# TYPE nvlink_link_error_crc_data counter
nvlink_link_error_crc_data{gpu="0",gpu_model="NVIDIA B300 SXM6 AC",link="0"} 0
```

## 快速开始

### 前置条件

- Linux 系统 x86_64（GPU 节点，Ubuntu 24.04 LTS）
- NVIDIA 驱动已安装
- node_exporter 已配置 textfile collector

### 一键安装（自解压安装包）

```bash
# 上传安装包到 GPU 节点，执行安装（需要 root 权限）
sudo bash nvlink_status_collect_install.sh

# 自定义输出路径
sudo bash nvlink_status_collect_install.sh --output /path/to/output/nvlink_status.prom

# 卸载
sudo bash nvlink_status_collect_install.sh --uninstall
```

安装包会自动：
1. 解压二进制文件和安装脚本到临时目录
2. 部署二进制文件到 `/usr/local/bin/nvlink_collector`
3. 创建 .prom 文件输出目录
4. 安装 cron 双任务（30 秒采集间隔）

### 测试运行

```bash
# 单次采集测试，输出到临时文件
/usr/local/bin/nvlink_collector --once --output /tmp/nvlink_test.prom

# 查看采集结果
cat /tmp/nvlink_test.prom
```

## 构建安装包

### 构建环境要求

- Ubuntu 24.04 x86_64（或相同架构的 Linux）
- Python 3.10+
- pip

### 构建步骤

```bash
# 1. 构建 PyInstaller 二进制
bash build_binary.sh

# 2. 打包成自解压安装包
bash pack_installer.sh

# 输出: nvlink_status_collect_install.sh
```

构建完成后，将 `nvlink_status_collect_install.sh` 分发到目标 GPU 节点即可。

## 使用说明

### 命令行参数

```
nvlink_collector [OPTIONS]

Options:
  --interval SEC    采集间隔，单位秒（默认: 30）
  --output PATH     .prom 文件输出路径（默认: /usr/local/node_exporter/extra_metrics_custom/nvlink_status.prom）
  --log-level LEVEL 日志级别: DEBUG|INFO|WARNING|ERROR（默认: INFO）
  --once            单次运行模式，采集一次后退出（用于 cron 模式）
  -h, --help        显示帮助信息
```

### Cron 任务管理

```bash
# 查看已安装的 cron 任务
crontab -l

# 手动编辑 cron（注意保留 NVLINK_COLLECTOR 标记行）
crontab -e
```

Cron 配置（30 秒间隔，双任务）：
```cron
* * * * * timeout -k 5 25 /usr/local/bin/nvlink_collector --once --output /usr/local/node_exporter/extra_metrics_custom/nvlink_status.prom # NVLINK_COLLECTOR
* * * * * sleep 30; timeout -k 5 25 /usr/local/bin/nvlink_collector --once --output /usr/local/node_exporter/extra_metrics_custom/nvlink_status.prom # NVLINK_COLLECTOR
```

### 防挂死机制

采集脚本由 crontab 定时调度，为防止单次执行卡住导致进程堆积，采用三层防护：

1. **看门狗（cron 层）**：`timeout -k 5 25` 在 25 秒后发 SIGTERM，再过 5 秒发 SIGKILL 强杀。SIGKILL 兜底是必须的——卡在 NVML ioctl 阻塞调用中的进程无法被 SIGTERM 终止（Python 信号处理器在 ctypes 阻塞期间不执行）。正常采集约 5 秒，25 秒提供 5 倍余量。

2. **单实例锁（Python 层）**：进程启动时通过 `fcntl.flock()` 非阻塞获取 `<output>.lock` 锁文件。拿不到锁说明上一次执行还在运行，记录 warning 并以退出码 0 退出（避免 cron 报错邮件）。进程死亡（包括被 SIGKILL）后锁由内核自动释放，不会永久阻塞后续任务。

3. **数据新鲜度告警（可观测层）**：`nvlink_last_collection_timestamp` 指标在每次采集尝试（无论成功失败）时更新。配合 `NVLinkMetricsStale` 告警规则，可检测出进程挂死、cron 失效、磁盘满等所有导致 `.prom` 停更的场景——这些场景下 `nvlink_scrape_error` 保持旧值不变，传统告警无法发现。

> **设计要点**：`nvlink_last_collection_timestamp`（"采集管线还活着吗"）与 `nvlink_scrape_error`（"采集成功了吗"）是两个正交信号。前者的语义是"最后一次采集尝试"而非"最后一次成功采集"，确保驱动故障和管线死亡两种异常可以被区分开。

## node_exporter 配置

确保 node_exporter 启动时配置了 `--collector.textfile.directory` 参数：

```bash
node_exporter --collector.textfile.directory=/usr/local/node_exporter/extra_metrics_custom
```

如果 node_exporter 已在运行，检查其启动参数是否包含 textfile collector 目录配置。

## 告警规则建议

```yaml
groups:
  - name: nvlink_alerts
    rules:
      # 所有 NVLink links 都 inactive
      - alert: NVLinkAllLinksInactive
        expr: nvlink_gpu_active_links == 0
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "GPU {{ $labels.gpu }} ({{ $labels.gpu_model }}) all NVLink links inactive"
          description: "GPU {{ $labels.gpu }} has 0 active NVLink links out of {{ $labels.gpu_total_links }} total. This may indicate a hardware or driver issue."

      # 采集脚本异常
      - alert: NVLinkScrapeError
        expr: nvlink_scrape_error == 1
        for: 1m
        labels:
          severity: warning
        annotations:
          summary: "NVLink status collection failed"
          description: "The NVLink collector script is failing to collect metrics. Check the cron jobs and binary."

      # 采集管线挂死/停更（进程被 timeout 杀掉、cron 失效、磁盘满等）
      - alert: NVLinkMetricsStale
        expr: time() - nvlink_last_collection_timestamp > 120
        for: 1m
        labels:
          severity: warning
        annotations:
          summary: "NVLink metrics are stale"
          description: "The .prom file has not been updated for over 2 minutes. Check cron jobs, hung processes (ps aux | grep nvlink_collector), lock files and disk space."

      # NVLink 错误计数增加
      - alert: NVLinkErrorsDetected
        expr: increase(nvlink_link_error_crc_data[5m]) > 0 or increase(nvlink_link_error_crc_flit[5m]) > 0 or increase(nvlink_link_error_replay[5m]) > 0 or increase(nvlink_link_error_recovery[5m]) > 0 or increase(nvlink_link_error_ecc_data[5m]) > 0
        for: 1m
        labels:
          severity: warning
        annotations:
          summary: "NVLink errors detected on GPU {{ $labels.gpu }} link {{ $labels.link }}"
          description: "NVLink error counters are increasing, indicating potential hardware issues."
```

## 支持的 GPU 型号

脚本通过动态发现机制自动适配不同 GPU 型号的 NVLink link 数量，无需硬编码。

### 支持 NVLink 的 GPU（可采集到 link 状态）

| GPU 型号 | 架构 | NVLink 版本 | Link 数量 | 封装形式 |
|---|---|---|---|---|
| V100 SXM2 | Volta | v2 | 6 | SXM2 |
| A100 SXM4 40GB | Ampere | v3 | 12 | SXM4 |
| A100 SXM4 80GB | Ampere | v3 | 12 | SXM4 |
| A30 | Ampere | v3 | 有限 | SXM4 |
| H100 SXM5 | Hopper | v4 | 18 | SXM5 |
| H200 | Hopper | v4 | 18 | SXM5 |
| B200 | Blackwell | v5 | 18 | SXM6 |
| B300 SXM6 | Blackwell | v5 | 18 | SXM6 |
| RTX 2080 Ti | Turing | v2 | 2(SLI) | PCIe |
| RTX 3090 | Ampere | v3 | 2(SLI) | PCIe |

### 不支持 NVLink 的 GPU（脚本会正常输出 0 links）

| GPU 型号 | 说明 |
|---|---|
| A100 PCIe | PCIe 版本无 NVLink |
| RTX 4090 | 消费级，无 NVLink |
| RTX 5090 | 消费级，无 NVLink |
| L40/L40S | 无 NVLink |

> **注意**：NVLink 主要存在于 SXM 封装的数据中心级 GPU 上。PCIe 版本的消费级显卡通常不支持 NVLink。

## 故障排查

### 采集失败，scrape_error = 1

1. 检查 NVIDIA 驱动是否正常：`nvidia-smi`
2. 手动运行测试：`/usr/local/bin/nvlink_collector --once --output /tmp/test.prom`
3. 检查 cron 任务：`crontab -l`

### 指标数据陈旧（触发 NVLinkMetricsStale 告警）

指标超过 2 分钟未更新，说明采集管线停更（进程挂死被看门狗杀掉、cron 失效、磁盘满等）：

1. 检查是否有残留进程：`ps aux | grep nvlink_collector`（正常情况单次执行 5 秒内结束，不应有长驻进程）
2. 检查 cron 任务是否存在：`crontab -l | grep NVLINK`
3. 检查磁盘空间：`df -h`
4. 检查锁文件状态：`ls -la /usr/local/node_exporter/extra_metrics_custom/nvlink_status.prom.lock`，文件内容为持锁进程 PID（锁本身由内核管理，进程死后自动释放，无需手动删除）
5. 手动运行测试：`/usr/local/bin/nvlink_collector --once`
6. 若手动运行也挂死（超过 30 秒无输出），说明 NVML/驱动层阻塞，用 `timeout -k 5 25 /usr/local/bin/nvlink_collector --once` 复现并检查 `dmesg | grep -i nvrm` 中的驱动错误

### .prom 文件未更新

1. 检查 cron 任务是否存在：`crontab -l | grep NVLINK`
2. 检查输出目录权限：`ls -la /usr/local/node_exporter/extra_metrics_custom/`
3. 检查磁盘空间：`df -h`
4. 手动运行测试：`/usr/local/bin/nvlink_collector --once`

### node_exporter 未采集到指标

1. 确认 textfile collector 目录配置正确
2. 确认 .prom 文件名以 `.prom` 结尾
3. 确认 .prom 文件权限可读
4. 检查 node_exporter 日志

## 项目结构

```
nvlink_status_collect/
├── nvlink_collector.py          # 采集脚本源码
├── build_binary.sh              # 构建二进制文件脚本
├── pack_installer.sh            # 打包自解压安装包脚本
├── install.sh                   # 安装脚本（cron 部署）
├── README.md                    # 本文档
└── plans/
    └── nvlink_status_collect_plan.md  # 设计方案文档
```

## 依赖

- NVIDIA 驱动（含 NVML 库）
- node_exporter（含 textfile collector）

> **注意**：二进制版本已内置 Python 运行时和 pynvml 依赖，目标机器无需安装 Python 或 pip。
