# NVLink Status Collector - k8s 镜像构建
#
# 构建方法（在能访问 GPU 节点构建机的环境执行）:
#   docker build -t cr.shengshu1.zz1.paratera.com/train/nvlink-collector:1.0.0 -f k8s/Dockerfile .
#   docker push cr.shengshu1.zz1.paratera.com/train/nvlink-collector:1.0.0
#
# 设计要点:
#   - 不打包 NVIDIA 驱动库: libnvidia-ml.so 由 nvidia RuntimeClass 在 Pod 启动时
#     从宿主机注入，永远与节点驱动版本匹配
#   - 用 slim 而非 PyInstaller: 容器内自带 python 解释器即可，无需 onefile 解压
#   - liveness probe 需要 shell，故基于 debian slim 而非 distroless

FROM python:3.12-slim-bookworm

# nvidia-ml-py 版本固定，与 packages/nvidia_ml_py-13.610.43-py3-none-any.whl 对应
# (13.610.43 ≈ NVML API 13, 兼容 CUDA 13.x 驱动)
RUN pip install --no-cache-dir nvidia-ml-py==13.610.43

COPY nvlink_collector.py /app/nvlink_collector.py

WORKDIR /app

# 常驻模式入口（k8s 下不使用 --once + cron, 由 DaemonSet 保证单实例）
ENTRYPOINT ["python3", "/app/nvlink_collector.py"]
