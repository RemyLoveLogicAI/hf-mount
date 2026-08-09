# hf-mount

<img width="1400" height="386" alt="image" src="https://github.com/user-attachments/assets/d68eac8c-4e28-4d2d-93b2-b049da846397" />

Mount [Hugging Face Buckets](https://huggingface.co/docs/hub/storage-buckets) and repos as local filesystems. No download, no copy, no waiting.

```bash
hf-mount start bucket myuser/my-bucket /tmp/data
```

Also works with any model or dataset repo (read-only):

```bash
hf-mount start repo openai/gpt-oss-20b /tmp/gpt-oss
```

Commands will pick up your `HF_TOKEN` from the environment, or you can pass it explicitly with `--hf-token`.

Then use your local folders as usual:
```python
from transformers import AutoModelForCausalLM
model = AutoModelForCausalLM.from_pretrained("/tmp/gpt-oss")  # reads on demand, no download step
```

hf-mount exposes [Hugging Face Buckets](https://huggingface.co/docs/hub/storage-buckets) and [Hub repos](https://huggingface.co) as a local filesystem via FUSE or NFS. Files are fetched lazily on first read, so only the bytes your code actually touches ever hit the network.

Two backends are available:
- **NFS** (recommended) -- works everywhere, no root, no kernel extension
- **FUSE** -- tighter kernel integration, requires root or [macFUSE](https://osxfuse.github.io/) on macOS

Agentic storage: Agents don't require complex APIs or SDKs, they thrive on the filesystem: ls, cat, find, grep, and the power of composable UNIX pipelines.

![hf-mount demo gif](https://huggingface.co/datasets/huggingface/documentation-images/resolve/main/hf-mount/demo.gif)

## Install

### Homebrew (macOS, Linux)

```bash
brew install hf-mount
```

On macOS, this installs the NFS backend only (`hf-mount`, `hf-mount-nfs`). For the FUSE backend on macOS, download the binary manually or build from source — macFUSE is closed-source and not distributable through homebrew-core.

### Manual download

Binaries are available on [GitHub Releases](https://github.com/huggingface/hf-mount/releases):

| Platform | Daemon | NFS | FUSE |
| --- | --- | --- | --- |
| Linux x86_64 | `hf-mount-x86_64-linux` | `hf-mount-nfs-x86_64-linux` | `hf-mount-fuse-x86_64-linux` |
| Linux aarch64 | `hf-mount-aarch64-linux` | `hf-mount-nfs-aarch64-linux` | `hf-mount-fuse-aarch64-linux` |
| macOS Apple Silicon | `hf-mount-arm64-apple-darwin` | `hf-mount-nfs-arm64-apple-darwin` | `hf-mount-fuse-arm64-apple-darwin` |

### System dependencies (FUSE only)

The NFS backend has no system dependencies. For FUSE:

**Linux**: `sudo apt-get install -y fuse3` (pre-built binaries only need the runtime; building from source also requires `libfuse3-dev`)

**macOS**: install [macFUSE](https://osxfuse.github.io/) (`brew install macfuse`, requires reboot on first install)

### Build from source

Requires Rust 1.89+.

```bash
# NFS only (no system deps, works everywhere)
cargo build --release --features nfs

# FUSE (requires macFUSE on macOS, fuse3 on Linux)
cargo build --release --features fuse

# All backends
cargo build --release --features fuse,nfs
```

Binaries: `target/release/hf-mount`, `target/release/hf-mount-nfs`, `target/release/hf-mount-fuse`

## Best for / Not for

**Best for:**
- Loading models and datasets without downloading the full repo
- Browsing repo contents (`ls`, `cat`, `find`) without cloning
- Read-heavy ML workloads (training, inference, evaluation)
- Environments where disk space is limited

**Not for:**
- General-purpose networked filesystem (no multi-writer support, no cross-node file locking)
- Latency-sensitive random I/O (first reads require network round-trips)
- Workloads that need strong consistency (files can be stale for up to 10 s)
- Heavy concurrent writes from multiple mounts (last writer wins, no conflict detection)
- Editing files with text editors in default (streaming) mode (use `--advanced-writes`)

Advisory file locks (`flock`, `fcntl` POSIX record locks) are supported locally on a single mount on both backends — enough for Python `filelock`, `huggingface_hub`, `datasets`, and similar cache-coordination use cases within one machine. They are not coordinated across multiple clients.

See [Consistency model](#consistency-model) for details.

## Usage

### Mount a repo (read-only)

```bash
# Public model (no token needed)
hf-mount start repo openai/gpt-oss-20b /tmp/model

# Private model
hf-mount start --hf-token $HF_TOKEN repo myorg/my-private-model /tmp/model

# Dataset
hf-mount start repo datasets/open-index/hacker-news /tmp/hn

# Specific revision
hf-mount start repo openai-community/gpt2 /tmp/gpt2 --revision v1.0

# Subfolder only
hf-mount start repo openai-community/gpt2/onnx /tmp/onnx
```

### Mount a Bucket (read-write)

[Buckets](https://huggingface.co/docs/hub/storage-buckets) are S3-like object storage on the Hub, designed for large-scale mutable data (training checkpoints, logs, artifacts) without git version control.

```bash
hf-mount start --hf-token $HF_TOKEN bucket myuser/my-bucket /tmp/data

# Read-only
hf-mount start --hf-token $HF_TOKEN --read-only bucket myuser/my-bucket /tmp/data

# Subfolder only
hf-mount start --hf-token $HF_TOKEN bucket myuser/my-bucket/checkpoints /tmp/ckpts
```

### Manage mounts

```bash
hf-mount status                  # list running mounts
hf-mount stop /tmp/data          # stop and unmount
```

Logs are written to `~/.hf-mount/logs/`. PID files are stored in `~/.hf-mount/pids/`.

### FUSE backend

By default, `hf-mount` uses NFS. Pass `--fuse` for tighter kernel integration (page cache invalidation, per-file metadata revalidation). Requires `fuse3` on Linux or [macFUSE](https://osxfuse.github.io/) on macOS.

```bash
hf-mount start --fuse --hf-token $HF_TOKEN bucket myuser/my-bucket /mnt/data
```

### Foreground mode

For scripts, containers, or debugging, use the backend binaries directly (they run in the foreground):

```bash
hf-mount-nfs repo gpt2 /tmp/gpt2
hf-mount-fuse --hf-token $HF_TOKEN bucket myuser/my-bucket /mnt/data
```

### macOS: launch as a daemon with launchd

To have `hf-mount` start automatically on login, create a LaunchAgent:

```bash
label=co.huggingface.hf-mount

mkdir -p ~/Library/LaunchAgents

cat > ~/Library/LaunchAgents/$label.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$label</string>
    <key>ProgramArguments</key>
    <array>
        <string>$HOME/.local/bin/hf-mount-nfs</string>
        <string>repo</string>
        <string>openai/gpt-oss-20b</string>
        <string>/tmp/gpt-oss</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/hf-mount.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/hf-mount.log</string>
</dict>
</plist>
EOF

launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/$label.plist
```

To stop: `launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/$label.plist`

### Unmount

```bash
umount /tmp/data                 # NFS or FUSE (macOS)
fusermount -u /tmp/data          # FUSE (Linux)
hf-mount stop /tmp/data          # daemon mounts
```

### Graceful shutdown (SIGTERM / CSI sidecar)

On `SIGTERM` the sidecar bounds the dirty-data flush (`--flush-shutdown-timeout-ms`) and **disarms the kernel-cache invalidators** before draining. This is deliberate: a `FUSE_NOTIFY_INVAL_INODE` writev issued during teardown can block uninterruptibly in the kernel (waiting on a folio under writeback the exiting daemon can no longer complete), leaving a `D`-state thread that even `exit_group` can't reap — an unkillable pod. Disarming the invalidator avoids creating that wedge; the CSI driver aborting the FUSE connection on `NodeUnpublishVolume` is the kernel-level backstop for any already-in-flight notify.

The same `FUSE_NOTIFY_INVAL_INODE` writev can also wedge at **runtime** (not just on shutdown): when the poll loop detects a remote change to a file the app currently has open, a full page-cache invalidation blocks in-kernel on a folio lock held by the app's in-flight `read()`, which is itself waiting for the daemon — a deadlock. Two guards prevent this: invalidations targeting an inode with open handles drop **attributes only** (a negative-offset notify the kernel never lets touch pages), and the blocking writev runs on the runtime's blocking pool rather than a core worker, so it can never starve FUSE request servicing. The trade-off: a file with a long-lived open handle won't see remote content updates refreshed in its page cache until the handle closes. On close-and-reopen the kernel revalidates the (attr-only-invalidated) attributes and, via the negotiated `FUSE_AUTO_INVAL_DATA`, drops the stale pages itself when it sees the new mtime/size — so a stale read only persists if a remote content change preserves *both* mtime and size on a file that was open at the moment of the change.

### Options

| Flag | Default | Description |
| --- | --- | --- |
| `--hf-token` | `$HF_TOKEN` | HF API token (required for private repos/buckets) |
| `--hub-endpoint` | `https://huggingface.co` | Hub API endpoint |
| `--cache-dir` | `/tmp/hf-mount-cache` | Local cache directory |
| `--cache-size` | `10000000000` (~10 GB) | Max on-disk chunk cache size in bytes |
| `--cache-mode` | `chunk` | Disk cache layer: `chunk` (xet-core xorb-range cache) or `file` (whole-file cache keyed by xet hash, avoids chunk-range fragmentation on warm reloads). Mutually exclusive; `file` disables the chunk cache. |
| `--max-staging-size` | `0` (unlimited) | Max bytes for advanced-writes staging files before flushed files are garbage-collected (LRU by last-touched). `0` disables GC, so staging files persist as a read-after-write cache. Does not yet cover the HTTP download cache for non-Xet repo files. |
| `--read-only` | `false` | Mount read-only (always on for repos) |
| `--advanced-writes` | `false` | Enable staging files + async flush (random writes, seek, overwrite) |
| `--poll-interval-secs` | `30` | Remote change polling interval (0 to disable) |
| `--poll-listing-concurrency` | `4` | Max concurrent tree-listing requests per poll round. Main knob to throttle load on the Hub `/api` endpoint; lower it in shared environments where many mounts poll in parallel. |
| `--max-threads` | `16` | Maximum FUSE worker threads (Linux only) |
| `--metadata-ttl-ms` | `10000` | How long file metadata is cached before re-checking (ms) |
| `--metadata-ttl-minimal` | `false` | Re-check on every access (maximum freshness, lower throughput) |
| `--flush-debounce-ms` | `2000` | Advanced writes: flush debounce delay (ms) |
| `--flush-max-batch-window-ms` | `30000` | Advanced writes: max flush batch window (ms) |
| `--flush-shutdown-timeout-ms` | `45000` | Advanced writes: max time the SIGTERM flush drain may run before abandoning unflushed data to guarantee exit. Must be < the pod's `terminationGracePeriodSeconds`, or a slow Hub/CAS backend keeps the FUSE connection alive past grace and strands the pod. |
| `--no-disk-cache` | `false` | Disable local chunk cache (every read fetches from HF) |
| `--direct-io` | `false` | Bypass the kernel page cache (FOPEN_DIRECT_IO); every read goes through the FUSE handler. For benchmarking; not recommended in production (disables efficient mmap caching). |
| `--no-filter-os-files` | `false` | Stop filtering OS junk files (.DS_Store, Thumbs.db, etc.) |
| `--uid` / `--gid` | current user | Override UID/GID for mounted files |
| `--fuse-owner-only` | `false` | Restrict mount access to the mounting user only (FUSE only; by default all users can access, which requires `user_allow_other` in /etc/fuse.conf) |
| `--token-file` | | Path to a token file (re-read on each request for credential rotation) |
| `--inode-soft-limit` | `0` | Soft cap on the in-memory inode table (0 disables). See "Bounding inode memory" below. |
| `--lru-sweep-interval-ms` | `5000` | Background LRU sweep interval in milliseconds. Only meaningful when `--inode-soft-limit > 0`. |
| `--overlay` | `false` | Treat the mount point as a writable local layer over the remote source. Local files persist on disk; writes are never pushed to the remote. See "Overlay mode" below. |
| `--vps-mode` | `false` | Inject VPS-optimized defaults: 5 GB cache, 5 s metadata TTL, 10 s poll interval, 120 s flush shutdown timeout, and advanced writes. Can be overridden by explicit flags. |

### Bounding inode memory

Under workloads that enumerate large trees (a `find`, a documentation scraper, `du -sh`), the in-memory inode table can grow without bound: every path the kernel ever looked up stays resident. With `--inode-soft-limit N` set, two evictors cooperate to keep the table near `N`:

1. **Insert-time evictor** (synchronous): before adding a new entry when `len() >= N + 256`, drop the oldest-touched file/symlink/leaf-directory entries.
   - *Polite mode*: only entries the kernel has already released (`forget`-ed). Safe, no FUSE races.
   - *Force mode*: when above `2 × N` and polite found nothing, drop entries even if the kernel still caches the dentry. A racing kernel op sees ENOENT and re-looks up. **Dirty files, locally-created dirs/symlinks, and inodes with live file handles are never dropped** — the force path preserves all user data.
2. **Background LRU sweep** (every `--lru-sweep-interval-ms`): for inodes the kernel has cached but our table doesn't want, send `FUSE_NOTIFY_INVAL_ENTRY` so the kernel drops its dentry and sends us `forget`. Bounded to 1024 invalidations per sweep with EAGAIN backoff so we don't flood the notify channel.

Tuning: pick `N` below what a full-tree enumeration of your bucket would produce. For `hf-doc-build/doc-dev` with ~20k files, `--inode-soft-limit 10000` keeps sidecar RSS ~250 MiB with a 1 GiB cgroup cap.

### Overlay mode

`--overlay` makes the mount point itself a writable local layer on top of the remote source. Reads return whatever the remote has, plus anything you've put on local disk under the mount point. Writes go only to local disk — the remote is never touched. Local files survive an unmount/remount.

Useful when several machines or processes need to share a read-only remote view but each layer their own files on top — for example, a shared compilation cache where producer machines populate a bucket with compiled artifacts (torch.compile, vLLM, JAX/XLA, AWS Neuron) and every consumer mounts the same bucket with `--overlay`. Cache hits are served from the bucket without recompiling; cache misses compile locally and stay on the local disk, never pushed back to the bucket.

```bash
# Producer (writes compiled artifacts to the bucket — regular bucket mount)
hf-mount start bucket myorg/torch-compile-cache "$TORCHINDUCTOR_CACHE_DIR"

# Consumer (reads from the bucket, compiles locally on miss)
hf-mount start --overlay bucket myorg/torch-compile-cache "$TORCHINDUCTOR_CACHE_DIR"
```

What you can do:
- Read every file from the remote source.
- Read every file already present in the local layer; when a name exists in both, the local copy wins.
- Create new files and directories — they land in the local layer.
- Modify, rename, delete, or chmod any file or directory that lives in the local layer.

What you can't do:
- Modify, rename, delete, or chmod a file that exists only on the remote. These operations fail with a permission error. To diverge from a remote file, copy it under a new name through the mount; the copy is a regular local file you own.
- Shadow an existing remote name with a new local file once the mount is active. If you need a local file at a name that already exists on the remote, drop it in the mount-point directory *before* starting the mount — pre-existing files at the mount point stay visible and take precedence.
- Place symlinks in the local layer and expect them to show up. Symlinks are hidden from the merged view so the mount can't be tricked into reading or writing outside the mount point.

### Logging

```bash
RUST_LOG=hf_mount=debug hf-mount-fuse repo gpt2 /mnt/gpt2
```

## Features

- **FUSE & NFS backends** -- FUSE for standard Linux/macOS, NFS for environments without `/dev/fuse`
- **Lazy loading** -- files are fetched on demand, not eagerly downloaded
- **Subfolder mounting** -- mount only a subdirectory (e.g. `user/model/ckpt/v2`)
- **Simple writes** (default) -- append-only, in-memory, synchronous upload on close
- **Advanced writes** (`--advanced-writes`) -- staging files on disk, random writes + seek, async debounced flush
- **Remote sync** -- background polling detects remote changes and updates the local view
- **POSIX metadata** -- chmod, chown, timestamps, symlinks (in-memory only, lost on unmount)
- **Overlay mode** (`--overlay`) -- mount point doubles as a writable local layer; remote stays read-only

## Consistency model

hf-mount provides **eventual consistency** with remote changes. There is no push notification from the Hub; all freshness relies on client-side polling.

### Reads

Files can be stale for up to `--metadata-ttl-ms` (default 10 s) after a remote update. Two mechanisms detect changes:

1. **Metadata revalidation** (FUSE only) -- when the per-file TTL expires, the next access checks the Hub. If the file changed, cached data is invalidated.
2. **Background polling** (default every 30 s) -- lists the full tree and detects additions, modifications, and deletions.

### Writes

| | Streaming (default) | Advanced (`--advanced-writes`) |
| --- | --- | --- |
| Write pattern | Append-only (sequential) | Random writes, seek, overwrite |
| Storage | In-memory buffer | Local staging file on disk |
| Modify existing files | Overwrite only (O_TRUNC) | Yes (downloads file first) |
| Durability | On close | Async, debounced (2 s / 30 s max) |
| Disk space needed | None | Full file size per open file |

**Streaming mode** buffers writes in memory and uploads on `close()`. A crash before close means data loss.

> **Note:** Streaming mode does not support text editors (vim, nano, emacs). Editors that use
> unlink+create save patterns will be blocked (`EPERM`) to prevent data loss.
> Use `--advanced-writes` for interactive editing.

**Advanced mode** downloads the full file to local disk before allowing edits. After `close()`, dirty files are flushed asynchronously. A crash before flush completes means data loss.

### FUSE vs NFS

| | FUSE | NFS |
| --- | --- | --- |
| Metadata revalidation | Per-file, within TTL | No (NFS uses file handles) |
| Page cache invalidation | Supported | Not supported by NFS protocol |
| Staleness window | ~10 s | Up to poll interval (30 s) |
| Write mode | Streaming by default | Advanced always |

## How it works

hf-mount sits between your application and the Hugging Face Hub. It presents a standard filesystem interface (FUSE or NFS) and translates file operations into Hub API calls and storage fetches.

Reads go through an adaptive prefetch buffer that starts small and grows with sequential access. Writes are uploaded to HF storage and committed via the Hub API. A background poll loop keeps the local view in sync with remote changes.

Built on [xet-core](https://github.com/huggingface/xet-core) for content-addressed storage and efficient file transfers, and [fuser](https://github.com/cberner/fuser) for the FUSE implementation.

## Kubernetes

Use the [hf-csi-driver](https://github.com/huggingface/hf-csi-driver) to mount Buckets and repos as Kubernetes volumes. The CSI driver runs hf-mount inside a DaemonSet and exposes mounts to pods via the Container Storage Interface.

```bash
helm install hf-csi oci://ghcr.io/huggingface/charts/hf-csi-driver
```

See the [hf-csi-driver README](https://github.com/huggingface/hf-csi-driver#readme) for setup and examples.

## VPS Deployment

Running hf-mount on a VPS or container? The `--vps-mode` flag and the bundled deployment artifacts tune cache sizes, polling, and timeouts for always-on model serving.

### VPS Mode CLI flag

```bash
hf-mount start --vps-mode repo openai/gpt-oss-20b /mnt/models
```

`--vps-mode` injects these defaults (overridable by passing the flag explicitly after `--vps-mode`):

| Flag | VPS default | Why |
| --- | --- | --- |
| `--cache-size` | `5000000000` (5 GB) | Keeps disk usage bounded on small VPS disks |
| `--metadata-ttl-ms` | `5000` (5 s) | Faster metadata refresh for changing models |
| `--poll-interval-secs` | `10` | Detect remote changes sooner |
| `--flush-shutdown-timeout-ms` | `120000` (120 s) | Graceful flush on SIGTERM without stranding pods |
| `--advanced-writes` | on | Enables staging files for model write workloads |

Example with an explicit override:

```bash
hf-mount start --vps-mode --cache-size 20000000000 repo openai/gpt-oss-20b /mnt/models
```

### VPS resource requirements

| Component | Minimum | Recommended |
| --- | --- | --- |
| Disk (cache) | 5 GB | 20–50 GB per model family |
| RAM | 2 GB | 4–8 GB (prefetch buffers scale with concurrency) |
| Network | 100 Mbit/s | 1 Gbit/s+ for large model loads |
| CPU | 2 vCPU | 4+ vCPU for concurrent inference + polling |

### Recommended mount options for model hosting

For production model serving on a VPS, these options balance freshness, disk usage, and graceful shutdown:

```bash
hf-mount start repo openai/gpt-oss-20b /mnt/models \
  --cache-size 5000000000 \
  --metadata-ttl-ms 5000 \
  --poll-interval-secs 10 \
  --flush-shutdown-timeout-ms 120000 \
  --advanced-writes \
  --poll-listing-concurrency 8
```

### systemd unit file

Place this at `/etc/systemd/system/hf-mount-gpt-oss-20b.service`:

```ini
[Unit]
Description=hf-mount nfs mount for openai/gpt-oss-20b
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=hf-mount
Group=hf-mount
Environment=HOME=/var/lib/hf-mount
Environment=HF_TOKEN_FILE=/etc/hf-mount/hf-token
ExecStartPre=/bin/mkdir -p /mnt/models/openai-gpt-oss-20b
ExecStartPre=/bin/chown hf-mount:hf-mount /mnt/models/openai-gpt-oss-20b
ExecStart=/usr/local/bin/hf-mount-nfs repo openai/gpt-oss-20b /mnt/models/openai-gpt-oss-20b \
  --token-file /etc/hf-mount/hf-token \
  --cache-dir /var/cache/hf-mount \
  --cache-size 5000000000 \
  --poll-interval-secs 10 \
  --poll-listing-concurrency 8 \
  --metadata-ttl-ms 5000 \
  --flush-shutdown-timeout-ms 120000 \
  --advanced-writes \
  --read-only
ExecStop=/bin/kill -SIGTERM $MAINPID
TimeoutStopSec=180
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
```

Enable and start:

```bash
systemctl daemon-reload
systemctl enable --now hf-mount-gpt-oss-20b.service
journalctl -u hf-mount-gpt-oss-20b -f
```

A template unit file is also available at `deploy/hf-mount.service`.

### Docker Compose

```yaml
services:
  hf-mount-fuse:
    image: hf-mount:latest
    build: .
    container_name: hf-mount-fuse
    restart: unless-stopped
    volumes:
      - fuse-model-data:/mnt/models
      - fuse-hf-mount-cache:/cache
      - ./hf-token:/run/secrets/hf-token:ro
    devices:
      - /dev/fuse
    entrypoint: ["sh", "-c"]
    command: >
      repo openai/gpt-oss-20b /mnt/models
      --token-file /run/secrets/hf-token
      --cache-dir /cache
      --cache-size ${CACHE_SIZE}
      --metadata-ttl-ms ${METADATA_TTL_MS}
      --poll-interval-secs ${POLL_INTERVAL_SECS}
      --poll-listing-concurrency ${POLL_LISTING_CONCURRENCY}
      --cache-mode ${CACHE_MODE}
      ${READ_ONLY:+--read-only}
      ${ADVANCED_WRITES:+--advanced-writes}
      ${NO_DISK_CACHE:+--no-disk-cache}
      ${DIRECT_IO:+--direct-io}
      --max-threads ${MAX_THREADS}
      --flush-debounce-ms ${FLUSH_DEBOUNCE_MS}
      --flush-max-batch-window-ms ${FLUSH_MAX_BATCH_WINDOW_MS}
      --flush-shutdown-timeout-ms ${FLUSH_SHUTDOWN_TIMEOUT_MS}
      --read-fetch-timeout-ms ${READ_FETCH_TIMEOUT_MS}
      --inode-soft-limit ${INODE_SOFT_LIMIT}
      --lru-sweep-interval-ms ${LRU_SWEEP_INTERVAL_MS}
      ${NO_FILTER_OS_FILES:+--no-filter-os-files}
    healthcheck:
      test: ["CMD-SHELL", "test -d /mnt/models && mountpoint -q /mnt/models"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 15s
    deploy:
      resources:
        limits:
          cpus: "4"
          memory: 8g
        reservations:
          cpus: "1"
          memory: 2g
    ulimits:
      nofile:
        soft: 65536
        hard: 65536
    security_opt:
      - no-new-privileges

volumes:
  fuse-model-data:
    driver: local
  fuse-hf-mount-cache:
    driver: local
```

A full multi-service `docker-compose.yml` with FUSE and overlay examples is at `deploy/docker-compose.yml`.

### VPS setup script

The bundled `deploy/vps-setup.sh` automates the entire process: installs hf-mount, creates a system user, configures directories and token, pre-mounts default repos, and installs a `vps-model-mount` helper.

```bash
sudo ./deploy/vps-setup.sh
```

It respects these environment variables:

| Variable | Default | Description |
| --- | --- | --- |
| `HF_MOUNT_USER` | `hf-mount` | System user for daemon |
| `INSTALL_DIR` | `/usr/local/bin` | Binary location |
| `MOUNT_BASE_DIR` | `/mnt/models` | Mount root |
| `CACHE_DIR` | `/var/cache/hf-mount` | Disk cache |
| `CACHE_SIZE` | `5000000000` | Max cache size (bytes) |
| `DEFAULT_REPOS` | `openai/gpt-oss-20b meta-llama/Llama-3-8B` | Repos to pre-mount |
| `BACKEND` | `auto` | `fuse`, `nfs`, or `auto` |

After setup, mount additional repos with:

```bash
vps-model-mount meta-llama/Llama-3-8B
```

### Overlay mode for multi-VPS model caching

`--overlay` lets multiple VPS instances share a read-only remote model repo while caching compiled artifacts locally. Each VPS gets its own local layer — no cross-node coordination needed.

```bash
# All VPS instances mount the same remote repo
hf-mount start repo hf.co/torch-compile-cache /mnt/models --overlay
```

- Reads: served from remote if not in local cache.
- Writes: land in local disk only (compiled artifacts, sharded checkpoints).
- Survives unmount/remount: local layer persists across restarts.

Ideal for shared compilation caches (torch.compile, vLLM, JAX/XLA) where producers upload artifacts to a bucket and consumers compile locally on miss.

## Multi-VPS Shared Storage

### NFS server mode

Each hf-mount NFS backend runs a local userspace NFS server on `127.0.0.1`. The kernel NFS client then mounts that local server. This means:

- No rootless NFS server configuration needed — hf-mount handles it.
- The mount options (rsize, wsize, actimeo) are tuned automatically.
- NFS v3 over TCP is used for reliability behind firewalls.

For cross-VPS sharing, export the mount point from the host OS NFS server, or use a shared network filesystem (NFS, EFS, FSx) as the backing store for the mount point directory itself.

### NFS vs FUSE on VPS

| | NFS | FUSE |
| --- | --- | --- |
| Requires root | No (mount.nfs via sudo) | Yes (or macFUSE on macOS) |
| Page cache invalidation | Kernel-managed | Daemon-managed (FUSE notify) |
| Staleness window | Up to poll interval | ~metadata TTL (5 s default) |
| Write mode | Advanced always | Streaming or advanced |
| Container support | Needs `CAP_SYS_ADMIN` | Needs `/dev/fuse` |

On VPS/containers without `/dev/fuse`, NFS is the only option. On dedicated VPS with FUSE available, FUSE gives tighter metadata freshness.

### Using overlay mode for multi-VPS caching

When multiple VPS instances mount the same model repo with `--overlay`, each instance maintains an independent local cache on top of the shared remote source. This avoids thundering-herd downloads while keeping the remote as the source of truth.

```bash
# VPS instance 1
hf-mount start --vps-mode --overlay repo myorg/shared-models /mnt/models

# VPS instance 2 (same repo, independent local layer)
hf-mount start --vps-mode --overlay repo myorg/shared-models /mnt/models
```

Key behaviors:
- Local files always shadow remote files with the same path.
- Deleted remote files remain visible if they exist in the local layer.
- Symlinks in the local layer are hidden (security: prevents escape from mount point).
- Pre-existing files at the mount point take precedence before the mount starts.


## Testing

```bash
# Unit tests (no network, no token)
cargo test --lib --features fuse,nfs

# Integration tests (require HF_TOKEN and FUSE)
HF_TOKEN=... cargo test --release --features fuse,nfs --test fuse_ops -- --test-threads=1 --nocapture
HF_TOKEN=... cargo test --release --features fuse,nfs --test nfs_ops -- --test-threads=1 --nocapture

# Repo mount test (public repo, no token needed)
cargo test --release --features nfs --test repo_ops -- --test-threads=1 --nocapture

# Benchmarks
HF_TOKEN=... cargo test --release --features fuse,nfs --test bench -- --nocapture
```

## Troubleshooting

> I'm getting `Operation not permitted` on MacOS while opening or listing files in a mounted bucket using VSCode

You need to enable "Full disk access" to your VSCode (System settings > Privacy > Full disk access).

### VPS-specific issues

#### Mount timeouts

If `hf-mount status` shows the daemon starting but the mount never becomes ready:

1. Check the log file in `~/.hf-mount/logs/` (daemon mode) or `journalctl` (systemd).
2. Verify network connectivity to `huggingface.co` and `cdn-lfs.huggingface.co`.
3. Ensure `mount.nfs` (NFS) or `fusermount3` (FUSE) is installed.
4. For Docker, ensure `CAP_SYS_ADMIN` is granted for NFS, or `/dev/fuse` is passed through for FUSE.

```bash
# NFS in Docker
docker run --cap-add SYS_ADMIN ...

# FUSE in Docker
docker run --device /dev/fuse ...
```

#### Stale mounts

A mount can become stale if the daemon crashes or the network drops. Clean up manually:

```bash
# Find the mount
mount | grep hf-mount

# Unmount
fusermount3 -u /mnt/models        # FUSE (Linux)
umount /mnt/models                # NFS or macOS
diskutil unmount /mnt/models      # macOS

# Remove stale PID file
rm -f ~/.hf-mount/pids/<encoded-mount-point>.pid
```

If using systemd, restarting the service handles stale mounts automatically:

```bash
systemctl restart hf-mount-gpt-oss-20b
```

#### Permission errors

Ensure the mounting user owns the mount point and cache directories:

```bash
# For daemon mode (user-level)
mkdir -p /mnt/models
chown $(id -u):$(id -g) /mnt/models

# For systemd mode (system user)
mkdir -p /mnt/models
chown hf-mount:hf-mount /mnt/models
```

For NFS mounts, `mount.nfs` typically requires root (or `sudo -n`). The systemd service runs as `root` for NFS and as `hf-mount` for FUSE.

#### Container permission errors

In containers, mounting requires `CAP_SYS_ADMIN`. If you see `Operation not permitted` or `mount.nfs failed`:

```bash
# Correct: privileged container
docker run --privileged ...

# Or: add just the needed capability
docker run --cap-add SYS_ADMIN --security-opt seccomp=unconfined ...

# For FUSE, also pass the device
docker run --device /dev/fuse ...
```

#### High memory usage on large mounts

Enumerating very large repos (20k+ files) can grow the inode table. Bound it with:

```bash
hf-mount start repo big-repo /mnt/models --inode-soft-limit 10000
```

This keeps sidecar RSS around 250 MiB for a 20k-file mount. See "Bounding inode memory" for details.

#### Slow first reads

First reads require a CAS/CDN round-trip. Subsequent reads hit the local chunk cache. To improve cold-start latency:

- Increase `--cache-size` (default 5 GB in VPS mode).
- Pre-warm by listing the directory: `ls -R /mnt/models > /dev/null`.
- Ensure the VPS has at least 1 Gbit/s network for large model loads.

#### Pod gets stuck in Terminating

On Kubernetes, if a pod stays in `Terminating` after `SIGTERM`, the FUSE connection wasn't torn down in time. Ensure:

- `--flush-shutdown-timeout-ms` is less than the pod's `terminationGracePeriodSeconds`.
- The sidecar disarms cache invalidators before draining (see "Graceful shutdown").

## License

Apache-2.0
