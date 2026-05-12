# Docker Socket Metrics Exporter

A lightweight Prometheus exporter designed to monitor Docker containers via the Unix socket. Optimized for rootless environments and restricted environments like the **42 Network**.

## 🚀 Installation

### 1. Rootless / 42 Cluster (Recommended)

In environments where you don't have root access, the Docker socket is located in your user-specific runtime directory. Use the `${UID}` variable to map it correctly:

```bash
docker run -d \
  --name docker-exporter \
  -p 8080:8080 \
  -v /var/run/user/${UID}/docker.sock:/var/run/docker.sock \
  ghcr.io/seraph919/docker-exporter:latest

```

### 2. Standard Docker (Root)

For local machines or VPS where Docker runs as a system-wide service:

```bash
docker run -d \
  --name docker-exporter \
  -p 8080:8080 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  ghcr.io/seraph919/docker-exporter:latest

```

---

## 🛠 Deployment with Docker Compose

Use this `docker-compose.yml` for a persistent setup. It uses the user-specific path to ensure compatibility with 42 cluster sessions:

```yaml
version: '3.8'

services:
  exporter:
    image: ghcr.io/seraph919/docker-exporter:latest
    container_name: docker-exporter
    ports:
      - "8080:8080"
    volumes:
      # Automatically maps to your 42 session socket
      - /var/run/user/${UID}/docker.sock:/var/run/docker.sock
    restart: always

```

---

## 📊 Metrics Reference

The exporter polls the `/containers/{id}/stats` endpoint and converts the JSON response into Prometheus-compatible plain text.

| Metric Name | Description |
| --- | --- |
| `container_memory_usage_bytes` | Current memory usage of the container. |
| `container_memory_limit_bytes` | Memory limit assigned to the container. |
| `container_cpu_usage_total_nanoseconds` | Total CPU time consumed. |
| `container_cpu_system_usage_nanoseconds` | System CPU usage. |
| `container_network_receive_bytes_total` | Incoming network traffic (eth0). |
| `container_network_transmit_bytes_total` | Outgoing network traffic (eth0). |
| `container_blkio_io_service_bytes_total` | Total Block I/O (Sum of all service bytes). |

---
## ⚙️ Requirements

* **Docker Engine** (Rootless or Standard)
* **Environment:** If using the 42 path, ensure your session is active (`docker ps` should work without sudo).
---
