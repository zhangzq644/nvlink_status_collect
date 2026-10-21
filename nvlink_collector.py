#!/usr/bin/env python3
"""
NVLink Status Collector

Collects NVLink status and metrics from NVIDIA GPUs using NVML (pynvml),
and outputs them as Prometheus metrics to a .prom file for node_exporter
textfile collector.

Usage:
    python3 nvlink_collector.py [--interval 30] [--output /usr/local/node_exporter/extra_metrics_custom/nvlink_status.prom] [--log-level INFO]

Concurrency:
    A single-instance flock on <output>.lock prevents overlapping runs
    (e.g. cron firing while a previous run hangs in a blocking NVML call).
    The lock is released by the kernel when the process dies, so an
    external watchdog (`timeout -k 5 25` in cron) can safely SIGKILL hung
    instances.
"""

import argparse
import fcntl
import logging
import os
import signal
import sys
import tempfile
import time

try:
    import pynvml
except ImportError:
    print("ERROR: pynvml/nvidia-ml-py is not installed. Install it with: pip install nvidia-ml-py", file=sys.stderr)
    sys.exit(1)

# Prometheus metric name prefixes
METRIC_PREFIX = "nvlink"

# Safety cap for NVLink link discovery (defensive: prevents an unbounded
# probing loop if a driver bug reports success for arbitrary link indices)
MAX_LINKS = 64

# NVLink error counter types mapping
NVLINK_ERROR_COUNTERS = {
    "crc_data": pynvml.NVML_NVLINK_ERROR_DL_CRC_DATA,
    "crc_flit": pynvml.NVML_NVLINK_ERROR_DL_CRC_FLIT,
    "replay": pynvml.NVML_NVLINK_ERROR_DL_REPLAY,
    "recovery": pynvml.NVML_NVLINK_ERROR_DL_RECOVERY,
    "ecc_data": pynvml.NVML_NVLINK_ERROR_DL_ECC_DATA,
}

# Global flag for graceful shutdown
running = True


def signal_handler(signum, frame):
    """Handle SIGTERM/SIGINT for graceful shutdown."""
    global running
    logging.info("Received signal %s, shutting down gracefully...", signum)
    running = False


def sanitize_label_value(value):
    """Sanitize a string for use as a Prometheus label value."""
    if value is None:
        return "unknown"
    # Replace characters that could cause issues in Prometheus labels
    return str(value).replace('"', '\\"').replace('\\', '\\\\')


class MetricCollector:
    """Collects Prometheus metrics and outputs them in proper grouped format.

    Ensures HELP/TYPE declarations appear only once per metric name,
    with all data lines for the same metric grouped together.
    """

    def __init__(self):
        # {metric_name: {"help": str, "type": str, "values": [str]}}
        self._metrics = {}

    def add(self, name, labels, value, help_text=None, metric_type="gauge"):
        """Add a metric data point.

        Args:
            name: Metric name (without prefix)
            labels: Dict of label key-value pairs
            value: Metric value
            help_text: HELP text (registered on first call for this metric name)
            metric_type: Metric type (gauge, counter, etc.)
        """
        full_name = f"{METRIC_PREFIX}_{name}"

        if full_name not in self._metrics:
            self._metrics[full_name] = {
                "help": help_text or "",
                "type": metric_type,
                "values": [],
            }
        elif help_text and not self._metrics[full_name]["help"]:
            self._metrics[full_name]["help"] = help_text

        label_str = ""
        if labels:
            label_parts = [
                f'{k}="{sanitize_label_value(v)}"' for k, v in labels.items()
            ]
            label_str = "{" + ",".join(label_parts) + "}"

        self._metrics[full_name]["values"].append(f"{full_name}{label_str} {value}")

    def render(self):
        """Render all collected metrics as a properly formatted Prometheus string.

        Returns:
            Formatted metrics string with HELP/TYPE declared once per metric name
        """
        lines = []
        for full_name, meta in self._metrics.items():
            # HELP and TYPE declarations (once per metric name)
            if meta["help"]:
                lines.append(f"# HELP {full_name} {meta['help']}")
            lines.append(f"# TYPE {full_name} {meta['type']}")
            # All data lines for this metric
            lines.extend(meta["values"])

        return "\n".join(lines)


def discover_nvlink_count(handle):
    """Discover the number of NVLink links on a GPU by probing.

    Starts from link 0 and increments until NVML_ERROR_INVALID_ARGUMENT
    is returned, indicating the link index doesn't exist.

    Args:
        handle: NVML device handle

    Returns:
        Number of NVLink links on this GPU
    """
    link_count = 0
    while link_count < MAX_LINKS:
        try:
            pynvml.nvmlDeviceGetNvLinkState(handle, link_count)
            link_count += 1
        except pynvml.NVMLError as err:
            if err.value == pynvml.NVML_ERROR_INVALID_ARGUMENT:
                # Link index doesn't exist, we've found the max
                break
            else:
                # Unexpected error, log and stop probing
                logging.debug(
                    "Error probing link %d: %s, stopping discovery", link_count, err
                )
                break
    if link_count >= MAX_LINKS:
        logging.warning(
            "Link discovery hit safety cap at %d links; driver may be misbehaving",
            MAX_LINKS,
        )
    return link_count


def collect_nvlink_metrics(collector, handle, gpu_index, gpu_model):
    """Collect all NVLink metrics for a single GPU.

    Args:
        collector: MetricCollector instance to add metrics to
        handle: NVML device handle
        gpu_index: GPU index number
        gpu_model: GPU model name string
    """
    base_labels = {"gpu": str(gpu_index), "gpu_model": gpu_model}

    # Discover number of NVLink links
    total_links = discover_nvlink_count(handle)

    if total_links == 0:
        logging.warning("GPU %s (%s): No NVLink links found", gpu_index, gpu_model)
        collector.add(
            "gpu_total_links", base_labels, 0,
            help_text="Total number of NVLink links on this GPU",
        )
        collector.add(
            "gpu_active_links", base_labels, 0,
            help_text="Number of active NVLink links on this GPU",
        )
        return

    # Output total links metric
    collector.add(
        "gpu_total_links", base_labels, total_links,
        help_text="Total number of NVLink links on this GPU",
    )

    active_count = 0

    for link_idx in range(total_links):
        link_labels = {**base_labels, "link": str(link_idx)}

        # 1. Core metric: Link state (active/inactive)
        try:
            state = pynvml.nvmlDeviceGetNvLinkState(handle, link_idx)
            is_active = state == pynvml.NVML_NVLINK_STATE_ACTIVE
            state_value = 1 if is_active else 0
            if is_active:
                active_count += 1

            collector.add(
                "link_state", link_labels, state_value,
                help_text="NVLink link state: 1=active, 0=inactive",
            )
        except pynvml.NVMLError as err:
            logging.debug(
                "GPU %s link %d: Failed to get state: %s", gpu_index, link_idx, err
            )
            # If we can't get state, assume inactive
            collector.add(
                "link_state", link_labels, 0,
                help_text="NVLink link state: 1=active, 0=inactive",
            )
            continue

        # The following metrics are best-effort; skip on error
        if not is_active:
            # Skip extended metrics for inactive links
            continue

        # 2. NVLink version
        try:
            version = pynvml.nvmlDeviceGetNvLinkVersion(handle, link_idx)
            collector.add(
                "link_version", link_labels, version,
                help_text="NVLink version number",
            )
        except pynvml.NVMLError as err:
            logging.debug(
                "GPU %s link %d: Failed to get version: %s",
                gpu_index, link_idx, err,
            )

        # 3. Remote PCI info (peer GPU)
        try:
            pci_info = pynvml.nvmlDeviceGetNvLinkRemotePciInfo(handle, link_idx)
            remote_pci = pci_info.busId.decode("utf-8") if isinstance(pci_info.busId, bytes) else str(pci_info.busId)
            remote_labels = {**link_labels, "remote_pci": remote_pci}
            collector.add(
                "link_remote_pci", remote_labels, 1,
                help_text="NVLink remote PCI device info (value is always 1, use remote_pci label)",
            )
        except pynvml.NVMLError as err:
            logging.debug(
                "GPU %s link %d: Failed to get remote PCI info: %s",
                gpu_index, link_idx, err,
            )

        # 4. Utilization counters (counter 0 = TX, counter 1 = RX typically)
        for counter_idx in range(2):
            try:
                rx_count, tx_count = pynvml.nvmlDeviceGetNvLinkUtilizationCounter(
                    handle, link_idx, counter_idx
                )
                counter_labels = {**link_labels, "counter": str(counter_idx)}
                collector.add(
                    "link_tx_utilization_count", counter_labels, tx_count,
                    help_text="NVLink transmit utilization count",
                    metric_type="counter",
                )
                collector.add(
                    "link_rx_utilization_count", counter_labels, rx_count,
                    help_text="NVLink receive utilization count",
                    metric_type="counter",
                )
            except pynvml.NVMLError as err:
                logging.debug(
                    "GPU %s link %d counter %d: Failed to get utilization counters: %s",
                    gpu_index, link_idx, counter_idx, err,
                )

        # 5. Error counters
        for error_name, error_type in NVLINK_ERROR_COUNTERS.items():
            try:
                error_count = pynvml.nvmlDeviceGetNvLinkErrorCounter(
                    handle, link_idx, error_type
                )
                collector.add(
                    f"link_error_{error_name}", link_labels, error_count,
                    help_text=f"NVLink {error_name} error counter",
                    metric_type="counter",
                )
            except pynvml.NVMLError as err:
                logging.debug(
                    "GPU %s link %d: Failed to get %s error counter: %s",
                    gpu_index, link_idx, error_name, err,
                )

    # Output active links count metric
    collector.add(
        "gpu_active_links", base_labels, active_count,
        help_text="Number of active NVLink links on this GPU",
    )


def collect_all_metrics():
    """Collect NVLink metrics from all GPUs on the system.

    Returns:
        Tuple of (metrics_string, has_error)
    """
    collector = MetricCollector()
    # Add scrape success indicator (will be updated to 1 on error by write_error_prom)
    collector.add(
        "scrape_error", {}, 0,
        help_text="Indicates scrape error: 1=error, 0=success",
    )
    # Freshness indicator: updated on every collection attempt (success or
    # failure). Together with scrape_error it forms two orthogonal signals:
    # timestamp answers "is the pipeline alive?", scrape_error answers
    # "did the collection succeed?".
    collector.add(
        "last_collection_timestamp", {}, int(time.time()),
        help_text="Unix timestamp of last collection attempt",
    )
    has_error = False

    try:
        pynvml.nvmlInit()
    except pynvml.NVMLError as err:
        logging.error("Failed to initialize NVML: %s", err)
        return None, True

    try:
        device_count = pynvml.nvmlDeviceGetCount()
        logging.info("Found %d GPU device(s)", device_count)

        if device_count == 0:
            logging.warning("No GPU devices found")
            return None, True

        for gpu_idx in range(device_count):
            try:
                handle = pynvml.nvmlDeviceGetHandleByIndex(gpu_idx)

                # Get GPU model name
                try:
                    gpu_model = pynvml.nvmlDeviceGetName(handle)
                    if isinstance(gpu_model, bytes):
                        gpu_model = gpu_model.decode("utf-8")
                except pynvml.NVMLError:
                    gpu_model = "unknown"

                logging.info(
                    "GPU %d: %s - Collecting NVLink metrics", gpu_idx, gpu_model
                )

                collect_nvlink_metrics(collector, handle, gpu_idx, gpu_model)

            except pynvml.NVMLError as err:
                logging.error("Failed to get info for GPU %d: %s", gpu_idx, err)
                has_error = True

    finally:
        try:
            pynvml.nvmlShutdown()
        except pynvml.NVMLError:
            pass

    rendered = collector.render()
    if not rendered:
        return None, True

    return rendered + "\n", has_error


def write_prom_file(content, output_path):
    """Write content to the .prom file atomically.

    Writes to a temporary file first, then atomically replaces the target file
    to prevent node_exporter from reading a partially written file.

    Args:
        content: String content to write
        output_path: Target .prom file path
    """
    # Ensure output directory exists
    output_dir = os.path.dirname(output_path)
    if output_dir and not os.path.exists(output_dir):
        try:
            os.makedirs(output_dir, mode=0o755, exist_ok=True)
            logging.info("Created output directory: %s", output_dir)
        except OSError as err:
            logging.error("Failed to create output directory %s: %s", output_dir, err)
            return False

    # Write to temporary file in the same directory (for atomic rename)
    try:
        output_dir = os.path.dirname(output_path) or "."
        fd, tmp_path = tempfile.mkstemp(dir=output_dir, suffix=".prom.tmp")
        try:
            with os.fdopen(fd, "w") as f:
                f.write(content)
            # mkstemp creates files with 0600; widen to 0644 so node_exporter
            # (typically a non-root user) can read the .prom file
            os.chmod(tmp_path, 0o644)
            # Atomic rename
            os.rename(tmp_path, output_path)
            logging.info("Successfully wrote metrics to %s", output_path)
            return True
        except Exception:
            # Clean up temp file on error
            if os.path.exists(tmp_path):
                os.unlink(tmp_path)
            raise
    except OSError as err:
        logging.error("Failed to write .prom file: %s", err)
        return False


def write_error_prom(output_path):
    """Write an error state to the .prom file.

    When collection fails, write the scrape error indicator plus the
    collection timestamp (without retaining previous data). The timestamp
    must also be updated on the error path, otherwise staleness alerting
    cannot distinguish "collection failing but pipeline alive" from
    "pipeline dead".

    Args:
        output_path: Target .prom file path
    """
    content = (
        f"# HELP {METRIC_PREFIX}_scrape_error Indicates scrape error: 1=error, 0=success\n"
        f"# TYPE {METRIC_PREFIX}_scrape_error gauge\n"
        f"{METRIC_PREFIX}_scrape_error 1\n"
        f"# HELP {METRIC_PREFIX}_last_collection_timestamp Unix timestamp of last collection attempt\n"
        f"# TYPE {METRIC_PREFIX}_last_collection_timestamp gauge\n"
        f"{METRIC_PREFIX}_last_collection_timestamp {int(time.time())}\n"
    )
    write_prom_file(content, output_path)


def acquire_lock(output_path):
    """Acquire a non-blocking exclusive lock to serialize collection runs.

    Uses flock() on a lock file adjacent to the output .prom file
    (<output_path>.lock). The lock is held until process exit and is
    released by the kernel automatically if the process dies (including
    via SIGKILL from an external watchdog), so a hung instance can never
    permanently block later runs.

    The current PID is written into the lock file for troubleshooting.

    Args:
        output_path: Target .prom file path

    Returns:
        The lock file descriptor (held until process exit), or None if
        another instance holds the lock or the lock file cannot be opened.
    """
    lock_path = output_path + ".lock"
    lock_dir = os.path.dirname(lock_path)
    if lock_dir and not os.path.exists(lock_dir):
        try:
            os.makedirs(lock_dir, mode=0o755, exist_ok=True)
        except OSError as err:
            logging.warning(
                "Cannot create lock directory %s: %s, skipping run", lock_dir, err
            )
            return None

    try:
        fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o644)
    except OSError as err:
        logging.warning("Cannot open lock file %s: %s, skipping run", lock_path, err)
        return None

    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        os.close(fd)
        logging.warning("Lock %s is held by another instance", lock_path)
        return None

    # Best-effort: record PID for troubleshooting
    try:
        os.ftruncate(fd, 0)
        os.write(fd, f"{os.getpid()}\n".encode())
    except OSError:
        pass

    return fd


def main():
    """Main entry point for the NVLink status collector."""
    parser = argparse.ArgumentParser(
        description="NVLink Status Collector - Collects NVLink metrics and outputs Prometheus .prom file"
    )
    parser.add_argument(
        "--interval",
        type=int,
        default=30,
        help="Collection interval in seconds (default: 30)",
    )
    parser.add_argument(
        "--output",
        type=str,
        default="/usr/local/node_exporter/extra_metrics_custom/nvlink_status.prom",
        help="Output .prom file path (default: /usr/local/node_exporter/extra_metrics_custom/nvlink_status.prom)",
    )
    parser.add_argument(
        "--log-level",
        type=str,
        default="INFO",
        choices=["DEBUG", "INFO", "WARNING", "ERROR"],
        help="Log level (default: INFO)",
    )
    parser.add_argument(
        "--once",
        action="store_true",
        help="Run once and exit (useful for testing or cron mode)",
    )

    args = parser.parse_args()

    # Configure logging
    logging.basicConfig(
        level=getattr(logging, args.log_level),
        format="%(asctime)s [%(levelname)s] %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )

    # Register signal handlers for graceful shutdown
    signal.signal(signal.SIGTERM, signal_handler)
    signal.signal(signal.SIGINT, signal_handler)

    # Acquire single-instance lock (per output file), held for the whole
    # process lifetime. Prevents overlapping cron runs from piling up when
    # a previous run hangs in a blocking NVML call. The kernel releases the
    # lock automatically when the process dies (even via SIGKILL).
    lock_fd = acquire_lock(args.output)
    if lock_fd is None:
        # Exit 0 so cron does not treat the skipped run as an error;
        # the specific reason was already logged by acquire_lock()
        logging.warning("Could not acquire lock, skipping this run")
        sys.exit(0)

    logging.info("NVLink Status Collector starting")
    logging.info("Collection interval: %d seconds", args.interval)
    logging.info("Output file: %s", args.output)

    while running:
        start_time = time.time()

        metrics_content, has_error = collect_all_metrics()

        if has_error or metrics_content is None:
            logging.error("Collection failed, writing error state to .prom file")
            write_error_prom(args.output)
        else:
            write_prom_file(metrics_content, args.output)

        if args.once:
            logging.info("Single run mode, exiting")
            break

        # Calculate sleep time accounting for collection duration
        elapsed = time.time() - start_time
        sleep_time = max(0, args.interval - elapsed)
        logging.debug(
            "Collection took %.2f seconds, sleeping for %.2f seconds",
            elapsed,
            sleep_time,
        )

        # Sleep in small increments to allow graceful shutdown
        sleep_end = time.time() + sleep_time
        while running and time.time() < sleep_end:
            time.sleep(min(1.0, sleep_end - time.time()))

    logging.info("NVLink Status Collector stopped")

    # Release the single-instance lock (also happens implicitly on exit)
    if lock_fd is not None:
        os.close(lock_fd)


if __name__ == "__main__":
    main()
