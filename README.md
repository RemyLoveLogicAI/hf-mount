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
| `--vps-mode` | `false` | Enable VPS-optimized defaults: `--cache-size=50 GB`, `--poll-interval-secs=10`, `--metadata-ttl-ms=5 s`, `--flush-shutdown-timeout-ms=120 s`, `--poll-listing-concurrency=8`, `--advanced-writes`. See "VPS Deployment" below. |

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

hf-mount is designed to run as a long-lived daemon on VPS instances, containers, and dedicated servers for model hosting workloads. The NFS backend is recommended (no root, no kernel extension, works everywhere).

### Quick start

```bash
# Install from source or download a release binary
# Then mount a model repo with VPS-optimized defaults:
hf-mount start --vps-mode --hf-token $HF_TOKEN repo openai/gpt-oss-20b /mnt/model

# Or for a read-write bucket:
hf-mount start --vps-mode --hf-token $HF_TOKEN bucket myorg/my-bucket /mnt/data
```

### VPS-optimized mount options

Model hosting on a dedicated VPS benefits from tuning four knobs:

| Option | Default | VPS recommended | Why |
| --- | --- | --- | --- |
| `--cache-size` | 10 GB | 50 GB | Models like Llama-3-8B are ~16 GB; a larger cache holds more shards on disk, reducing repeat fetches |
| `--metadata-ttl-ms` | 10 000 ms | 5 000 ms | Shorter TTL catches remote model updates faster |
| `--poll-interval-secs` | 30 s | 10 s | More frequent polling for fresher content |
| `--flush-shutdown-timeout-ms` | 45 000 ms | 120 000 ms | Gives the daemon more time to flush staged writes on SIGTERM (e.g. pod drain) |
| `--poll-listing-concurrency` | 4 | 8 | Higher concurrency keeps poll rounds fast on dedicated hardware |
| `--advanced-writes` | false | true (via `--vps-mode`) | Needed for staging files on disk when writing |

### `--vps-mode` flag

Pass `--vps-mode` to apply all of the above in one shot:

```bash
hf-mount start --vps-mode --hf-token $HF_TOKEN repo meta-llama/Llama-3-8B /mnt/llama
```

This is equivalent to:

```bash
hf-mount start \
  --cache-size 50000000000 \
  --metadata-ttl-ms 5000 \
  --poll-interval-secs 10 \
  --flush-shutdown-timeout-ms 120000 \
  --poll-listing-concurrency 8 \
  --advanced-writes \
  --hf-token $HF_TOKEN \
  repo meta-llama/Llama-3-8B /mnt/llama
```

You can still override individual flags after `--vps-mode`; clap uses the last value seen.

### Resource requirements for model hosting

| Resource | Minimum | Recommended | Notes |
| --- | --- | --- | --- |
| Disk | 20 GB | 100 GB+ | Cache needs room for model shards plus staging files. A 70B model repo is ~140 GB; size accordingly |
| Memory | 512 MB | 2 GB+ | Each open file handle holds a prefetch buffer (~8 MB worst case). The handle pool caps at 64 entries |
| Network | 10 Mbps | 100 Mbps+ | First reads stream shards from the Hub. Warm reads hit local cache. Consecutive model loads benefit from high bandwidth |
| CPU | 1 core | 4+ cores | The poll loop and xet-core reconstruction are CPU-bound during initial model load |

### systemd unit file

Run hf-mount as a systemd service so it starts on boot and restarts on failure:

```ini
# /etc/systemd/system/hf-mount-model.service
[Unit]
Description=hf-mount model hosting (NFS backend)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=HF_TOKEN=your_token_here
Environment=CACHE_DIR=/var/cache/hf-mount
ExecStartPre=/usr/bin/mkdir -p /mnt/model /var/cache/hf-mount
ExecStart=/usr/local/bin/hf-mount start --vps-mode repo openai/gpt-oss-20b /mnt/model
ExecStop=/usr/local/bin/hf-mount stop /mnt/model
Restart=on-failure
RestartSec=10
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now hf-mount-model.service
```

To use the FUSE backend instead, change the binary to `hf-mount-fuse` and add `--fuse` to the `ExecStart` line.

### Docker Compose

```yaml
# docker-compose.yml
version: "3.9"

services:
  hf-mount:
    image: huggingface/hf-mount:latest
    privileged: true
    environment:
      HF_TOKEN: ${HF_TOKEN}
      CACHE_DIR: /cache
    volumes:
      - model-cache:/cache
      - model-mount:/mnt/model
    command: >
      hf-mount start --vps-mode
      repo openai/gpt-oss-20b /mnt/model
    restart: unless-stopped
    deploy:
      resources:
        limits:
          memory: 4g
          cpus: "2"

volumes:
  model-cache:
  model-mount:
```

The container must run `--privileged` (or with `--cap-add SYS_ADMIN`) because the NFS backend shells out to `mount.nfs`. On Docker Desktop / non-Linux hosts, use the FUSE backend instead:

```yaml
services:
  hf-mount:
    image: huggingface/hf-mount:latest
    devices:
      - /dev/fuse
    environment:
      HF_TOKEN: ${HF_TOKEN}
    volumes:
      - model-cache:/cache
      - model-mount:/mnt/model
    command: >
      hf-mount start --vps-mode --fuse
      repo openai/gpt-oss-20b /mnt/model
    restart: unless-stopped
```

## Multi-VPS Shared Storage

When running inference across multiple VPS instances, sharing a single mount via NFS avoids redundant downloads and keeps model shards consistent.

### NFS server mode

hf-mount's NFS backend exports the mounted repo/bucket as an NFS server on `127.0.0.1`. On a single VPS this is mounted locally. For multi-VPS sharing, run one "NFS server" VPS that other VPS instances mount over the network.

1. On the server VPS, mount the model with hf-mount (NFS backend, default):

   ```bash
   hf-mount start --vps-mode --hf-token $HF_TOKEN repo meta-llama/Llama-3-8B /mnt/llama
   ```

2. Install and start a system NFS server on the same VPS, exporting `/mnt/llama`:

   ```bash
   # Debian/Ubuntu
   sudo apt-get install -y nfs-kernel-server
   echo "/mnt/llama *(rw,sync,no_subtree_check,no_root_squash)" | sudo tee -a /etc/exports
   sudo exportfs -ra
   sudo systemctl enable --now nfs-server
   ```

3. On each client VPS, mount the server's export:

   ```bash
   sudo mount -t nfs server-vps.internal:/mnt/llama /mnt/llama
   ```

   Or add to `/etc/fstab`:

   ```fstab
   server-vps.internal:/mnt/llama  /mnt/llama  nfs  defaults,_netdev  0  0
   ```

### Overlay mode for multi-VPS caching

When each VPS has its own local disk but you want a shared remote view with per-VPS local caching, use `--overlay`:

```bash
# On each VPS independently:
hf-mount start --vps-mode --overlay --hf-token $HF_TOKEN \
  repo meta-llama/Llama-3-8B /mnt/llama
```

Each VPS reads from the same remote repo but writes compiled artifacts, torch.compile caches, or tokenizer caches to its own local disk under `/mnt/llama`. The local layer survives unmount/remount.

### Overlay for shared compilation caches

```bash
# Producer: regular bucket mount, writes compiled artifacts to the bucket
hf-mount start --hf-token $HF_TOKEN bucket myorg/torch-compile-cache "$TORCHINDUCTOR_CACHE_DIR"

# Consumers: overlay mount, reads from bucket, compiles locally on miss
hf-mount start --vps-mode --overlay --hf-token $HF_TOKEN \
  bucket myorg/torch-compile-cache "$TORCHINDUCTOR_CACHE_DIR"
```

## Troubleshooting

### Mount timeouts

If a mount hangs or fails with a timeout:

1. Check that the Hub is reachable: `curl -I https://huggingface.co`
2. Verify your `HF_TOKEN` is valid: `huggingface-cli whoami`
3. Increase the per-chunk read timeout: `--read-fetch-timeout-ms 60000`
4. Check disk space on the cache directory: `df -h /tmp/hf-mount-cache`
5. For NFS mounts, verify `mount.nfs` is installed: `which mount.nfs`

### Stale mounts after remote changes

Files appear old after a remote update:

1. Lower `--metadata-ttl-ms` to 5 000 ms or less
2. Lower `--poll-interval-secs` to 10 s for more frequent background polling
3. Use `--vps-mode` which sets both to their VPS-recommended values
4. Verify the poll loop is running: check `~/.hf-mount/logs/` for `poll` messages

### Permission errors

If you see `EACCES` or `Operation not permitted`:

1. Check the UID/GID of the mount process matches the accessing user, or pass `--uid`/`--gid`
2. For FUSE, ensure `user_allow_other` is set in `/etc/fuse.conf` (Linux)
3. For NFS in containers, run with `--privileged` or `--cap-add SYS_ADMIN`
4. On macOS, grant Full Disk Access to the terminal or IDE in System Settings > Privacy > Full Disk Access

### Too many open files

If you see `EMFILE` or `ENFILE` errors:

1. Raise the fd limit: `ulimit -n 65536`
2. Or set it in the systemd unit: `LimitNOFILE=65536`
3. Reduce `--max-threads` (FUSE) or `--poll-listing-concurrency`

### Container mount failures (NFS)

Inside Docker or Kubernetes, NFS mounts can fail with `Operation not permitted`:

1. Run the container with `--privileged` or `--cap-add SYS_ADMIN`
2. Ensure the seccomp profile allows the `mount` syscall
3. As an alternative, use the FUSE backend with `--fuse` and mount `/dev/fuse`

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

## License

Apache-2.0
