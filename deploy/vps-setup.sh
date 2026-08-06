#!/usr/bin/env bash
# deploy/vps-setup.sh — VPS deployment script for hf-mount
#
# Installs hf-mount, configures systemd services for auto-starting model mounts,
# and provides a vps-model-mount helper for quickly mounting additional repos.
#
# Usage: sudo ./deploy/vps-setup.sh
#
# Environment variables:
#   HF_MOUNT_USER          - System user for daemon (default: hf-mount)
#   INSTALL_DIR            - Binary install location (default: /usr/local/bin)
#   MOUNT_BASE_DIR         - Base directory for mounts (default: /mnt/models)
#   CACHE_DIR              - Cache directory (default: /var/cache/hf-mount)
#   STATE_DIR              - State directory (default: /var/lib/hf-mount)
#   LOG_DIR                - Log directory (default: /var/log/hf-mount)
#   TOKEN_DIR              - HF token directory (default: /etc/hf-mount)
#   CACHE_SIZE             - Max cache size in bytes (default: 50000000000 = 50GB)
#   HF_TOKEN               - HuggingFace API token
#   HF_TOKEN_FILE          - Path to token file
#   DEFAULT_REPOS          - Space-separated list of repos to pre-mount
#   BACKEND                - Force backend: fuse or nfs (default: auto-detect)
#   HF_MOUNT_REPO          - GitHub repo for binary download (default: huggingface/hf-mount)
#   HF_MOUNT_VERSION       - Version to install (default: latest)

set -euo pipefail

# ─── Configuration ────────────────────────────────────────────────────────

HF_MOUNT_USER="${HF_MOUNT_USER:-hf-mount}"
HF_MOUNT_GROUP="${HF_MOUNT_GROUP:-hf-mount}"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"
MOUNT_BASE_DIR="${MOUNT_BASE_DIR:-/mnt/models}"
CACHE_DIR="${CACHE_DIR:-/var/cache/hf-mount}"
STATE_DIR="${STATE_DIR:-/var/lib/hf-mount}"
LOG_DIR="${LOG_DIR:-/var/log/hf-mount}"
SERVICE_DIR="${SERVICE_DIR:-/etc/systemd/system}"
TOKEN_DIR="${TOKEN_DIR:-/etc/hf-mount}"
CACHE_SIZE="${CACHE_SIZE:-50000000000}"
HF_TOKEN="${HF_TOKEN:-}"
HF_TOKEN_FILE="${HF_TOKEN_FILE:-}"
DEFAULT_REPOS="${DEFAULT_REPOS:-openai/gpt-oss-20b meta-llama/Llama-3-8B}"
BACKEND="${BACKEND:-auto}"
HF_MOUNT_REPO="${HF_MOUNT_REPO:-huggingface/hf-mount}"
HF_MOUNT_VERSION="${HF_MOUNT_VERSION:-latest}"

# VPS-optimized mount options
POLL_INTERVAL_SECS="${POLL_INTERVAL_SECS:-10}"
POLL_LISTING_CONCURRENCY="${POLL_LISTING_CONCURRENCY:-8}"
METADATA_TTL_MS="${METADATA_TTL_MS:-5000}"
FLUSH_SHUTDOWN_TIMEOUT_MS="${FLUSH_SHUTDOWN_TIMEOUT_MS:-120000}"
ADVANCED_WRITES="${ADVANCED_WRITES:-true}"
READ_ONLY="${READ_ONLY:-true}"

# ─── Rollback / Cleanup ───────────────────────────────────────────────────

SERVICES=()
ROLLBACK_DIRS=()
CREATED_USER=false

cleanup() {
    echo ""
    echo "ERROR: Rolling back changes..."
    echo ""

    # Stop and remove services
    for svc in "${SERVICES[@]}"; do
        echo "  Stopping and removing service: $svc"
        systemctl stop "$svc" 2>/dev/null || true
        systemctl disable "$svc" 2>/dev/null || true
        rm -f "$SERVICE_DIR/$svc"
    done

    # Remove directories
    for dir in "${ROLLBACK_DIRS[@]}"; do
        echo "  Removing directory: $dir"
        rm -rf "$dir" 2>/dev/null || true
    done

    # Remove user (only if we created it)
    if [[ "$CREATED_USER" == "true" ]] && id "$HF_MOUNT_USER" &>/dev/null; then
        echo "  Removing user: $HF_MOUNT_USER"
        userdel "$HF_MOUNT_USER" 2>/dev/null || true
    fi

    # Remove installed binaries
    for bin in hf-mount hf-mount-nfs hf-mount-fuse vps-model-mount; do
        if [[ -f "$INSTALL_DIR/$bin" ]]; then
            echo "  Removing binary: $INSTALL_DIR/$bin"
            rm -f "$INSTALL_DIR/$bin"
        fi
    done

    systemctl daemon-reload 2>/dev/null || true
    echo ""
    echo "Rollback complete."
    exit 1
}

trap cleanup ERR

# ─── Utility Functions ───────────────────────────────────────────────────

log() {
    echo "[vps-setup] $*"
}

die() {
    echo "[vps-setup] ERROR: $*" >&2
    exit 1
}

human_size() { local bytes="$1"; command -v numfmt >/dev/null 2>&1 && numfmt --to=iec-i --suffix=B "$bytes" 2>/dev/null || echo "${bytes} bytes"; }

# Convert repo ID to safe service/mount name
repo_to_name() {
    echo "${1//\//-}"
}

# Build mount options string for a backend binary
build_mount_options() {
    local opts=()

    opts+=("--token-file" "$TOKEN_DIR/hf-token")
    opts+=("--cache-dir" "$CACHE_DIR")
    opts+=("--cache-size" "$CACHE_SIZE")
    opts+=("--poll-interval-secs" "$POLL_INTERVAL_SECS")
    opts+=("--poll-listing-concurrency" "$POLL_LISTING_CONCURRENCY")
    opts+=("--metadata-ttl-ms" "$METADATA_TTL_MS")
    opts+=("--flush-shutdown-timeout-ms" "$FLUSH_SHUTDOWN_TIMEOUT_MS")

    if [[ "$ADVANCED_WRITES" == "true" ]]; then
        opts+=("--advanced-writes")
    fi

    if [[ "$READ_ONLY" == "true" ]]; then
        opts+=("--read-only")
    fi

    echo "${opts[*]}"
}

# Wait for a mount point to become active
wait_for_mount() {
    local mount_point="$1"
    local timeout="${2:-120}"
    local start_time
    start_time=$(date +%s)

    log "Waiting for mount at $mount_point (timeout: ${timeout}s)..."

    while true; do
        if mountpoint -q "$mount_point" 2>/dev/null; then
            log "Mount ready: $mount_point"
            return 0
        fi

        local elapsed
        elapsed=$(($(date +%s) - start_time))
        if [[ $elapsed -gt $timeout ]]; then
            echo "ERROR: Mount at $mount_point not ready after ${timeout}s" >&2
            echo "Check logs: journalctl -u hf-mount-* -f" >&2
            return 1
        fi

        sleep 2
    done
}

# Validate that a mount is working
validate_mount() {
    local mount_point="$1"

    if ! mountpoint -q "$mount_point" 2>/dev/null; then
        echo "ERROR: $mount_point is not a mount point" >&2
        return 1
    fi

    if ! ls "$mount_point" >/dev/null 2>&1; then
        echo "ERROR: Cannot list files in $mount_point" >&2
        return 1
    fi

    log "Mount validation passed: $mount_point"
    return 0
}

# ─── Step 1: Check Root ──────────────────────────────────────────────────

check_root() {
    if [[ $EUID -ne 0 ]]; then
        die "This script must be run as root. Try: sudo ./deploy/vps-setup.sh"
    fi
}

# ─── Step 2: Check Prerequisites ─────────────────────────────────────────

check_prerequisites() {
    log "Checking prerequisites..."

    local missing=()

    for cmd in curl jq; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        log "Installing missing packages: ${missing[*]}"
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update -qq
            apt-get install -y -qq "${missing[@]}"
        elif command -v yum >/dev/null 2>&1; then
            yum install -y "${missing[@]}"
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y "${missing[@]}"
        else
            die "Cannot install missing packages. Please install: ${missing[*]}"
        fi
    fi
}

# ─── Step 3: Detect Backend ───────────────────────────────────────────────

detect_backend() {
    log "Detecting available backend..."

    local has_fuse=false
    local has_nfs=false

    # Check FUSE availability
    if [[ -e /dev/fuse ]] && command -v fusermount3 >/dev/null 2>&1; then
        has_fuse=true
        log "FUSE backend available (fusermount3 + /dev/fuse)"
    else
        log "FUSE backend not available (missing /dev/fuse or fusermount3)"
    fi

    # Check NFS availability
    if command -v mount.nfs >/dev/null 2>&1 || command -v mount.nfs4 >/dev/null 2>&1; then
        has_nfs=true
        log "NFS backend available (mount.nfs)"
    else
        log "NFS backend not available (missing mount.nfs)"
    fi

    # Honor explicit override
    case "$BACKEND" in
        fuse)
            if [[ "$has_fuse" != "true" ]]; then
                die "FUSE backend requested but not available (install fuse3)"
            fi
            DEFAULT_BACKEND="fuse"
            ;;
        nfs)
            if [[ "$has_nfs" != "true" ]]; then
                die "NFS backend requested but not available (install nfs-common)"
            fi
            DEFAULT_BACKEND="nfs"
            ;;
        auto|*)
            if [[ "$has_fuse" == "true" ]]; then
                DEFAULT_BACKEND="fuse"
            elif [[ "$has_nfs" == "true" ]]; then
                DEFAULT_BACKEND="nfs"
            else
                die "Neither FUSE nor NFS backend is available. Install fuse3 or nfs-common."
            fi
            ;;
    esac

    log "Default backend: $DEFAULT_BACKEND"
}

# ─── Step 4: Install hf-mount ─────────────────────────────────────────────

install_hf_mount() {
    log "Installing hf-mount..."

    # Check if already installed with matching version
    if [[ -x "$INSTALL_DIR/hf-mount" ]]; then
        local current_version
        current_version=$("$INSTALL_DIR/hf-mount" --version 2>/dev/null | head -1 || echo "unknown")
        log "hf-mount already installed: $current_version"

        if [[ "$HF_MOUNT_VERSION" != "latest" ]] && [[ "$current_version" == *"$HF_MOUNT_VERSION"* ]]; then
            log "Version matches, skipping installation"
            return 0
        fi
    fi

    local tmpdir
    tmpdir=$(mktemp -d)
    ROLLBACK_DIRS+=("$tmpdir")

    # Try building from source with cargo
    if command -v cargo >/dev/null 2>&1; then
        log "Building hf-mount from source with cargo..."

        if [[ -f "Cargo.toml" ]]; then
            log "Building from current directory..."
            cargo build --release --features "fuse,nfs"
            cp target/release/hf-mount target/release/hf-mount-nfs target/release/hf-mount-fuse "$INSTALL_DIR/"
        else
            log "Cloning repository for build..."
            git clone --depth 1 "https://github.com/${HF_MOUNT_REPO}.git" "$tmpdir/repo"
            pushd "$tmpdir/repo" >/dev/null
            cargo build --release --features "fuse,nfs"
            cp target/release/hf-mount target/release/hf-mount-nfs target/release/hf-mount-fuse "$INSTALL_DIR/"
            popd >/dev/null
        fi
    else
        log "Cargo not found, downloading pre-built binary..."
        download_binary "$tmpdir"
    fi

    # Ensure all required binaries exist
    local required_bins=("hf-mount" "hf-mount-nfs" "hf-mount-fuse")
    for bin in "${required_bins[@]}"; do
        if [[ ! -x "$INSTALL_DIR/$bin" ]]; then
            die "$INSTALL_DIR/$bin not found after installation"
        fi
    done

    log "hf-mount installed successfully"
}

download_binary() {
    local tmpdir="$1"
    local arch
    arch=$(uname -m)
    local os
    os=$(uname -s | tr '[:upper:]' '[:lower:]')

    case "$os" in
        linux) os="linux" ;;
        darwin) os="apple-darwin" ;;
        *) die "Unsupported OS: $os" ;;
    esac

    case "$arch" in
        x86_64|amd64) arch="x86_64" ;;
        aarch64) arch="aarch64" ;;
        arm64)
            if [[ "$os" == "apple-darwin" ]]; then
                arch="arm64"
            else
                arch="aarch64"
            fi
            ;;
        *) die "Unsupported architecture: $arch" ;;
    esac

    local tag="v${HF_MOUNT_VERSION}"
    if [[ "$HF_MOUNT_VERSION" == "latest" ]]; then
        tag="latest"
    fi

    local base_url
    if [[ "$tag" == "latest" ]]; then
        base_url="https://github.com/${HF_MOUNT_REPO}/releases/latest/download"
    else
        base_url="https://github.com/${HF_MOUNT_REPO}/releases/download/${tag}"
    fi

    local found=0
    for bin in hf-mount hf-mount-nfs hf-mount-fuse; do
        local url="${base_url}/${bin}-${arch}-${os}"
        log "Downloading ${bin} from $url"

        if curl -fsSL "$url" -o "$tmpdir/${bin}"; then
            local checksum_url="${base_url}/${bin}-${arch}-${os}.sha256"
            if curl -fsSL "$checksum_url" -o "$tmpdir/${bin}.sha256" 2>/dev/null; then
                if command -v sha256sum >/dev/null 2>&1; then
                    (cd "$tmpdir" && sha256sum -c "${bin}.sha256" 2>/dev/null) || {
                        log "Warning: Checksum verification failed for ${bin}, removing"
                        rm -f "$tmpdir/${bin}" "$tmpdir/${bin}.sha256"
                        continue
                    }
                elif command -v shasum >/dev/null 2>&1; then
                    local expected
                    expected=$(awk '{print $1}' "$tmpdir/${bin}.sha256")
                    local actual
                    actual=$(shasum -a 256 "$tmpdir/${bin}" | awk '{print $1}')
                    if [[ "$expected" != "$actual" ]]; then
                        log "Warning: Checksum verification failed for ${bin}, removing"
                        rm -f "$tmpdir/${bin}" "$tmpdir/${bin}.sha256"
                        continue
                    fi
                else
                    log "Warning: No checksum tool available, skipping verification for ${bin}"
                fi
            else
                log "Warning: Could not download checksum for ${bin}, skipping verification"
            fi

            cp "$tmpdir/${bin}" "$INSTALL_DIR/"
            chmod +x "$INSTALL_DIR/$bin"
            found=$((found + 1))
        else
            log "Warning: Failed to download ${bin} from $url"
        fi
    done

    if [[ $found -eq 0 ]]; then
        die "No hf-mount binaries could be downloaded"
    fi
}

# ─── Step 5: Create System User ───────────────────────────────────────────

create_system_user() {
    log "Creating system user: $HF_MOUNT_USER"

    if id "$HF_MOUNT_USER" &>/dev/null; then
        log "User $HF_MOUNT_USER already exists"
        return 0
    fi

    if ! getent group "$HF_MOUNT_GROUP" &>/dev/null; then
        log "Creating group: $HF_MOUNT_GROUP"
        groupadd --system "$HF_MOUNT_GROUP"
    fi

    useradd --system --home-dir "$STATE_DIR" --shell /usr/sbin/nologin --gid "$HF_MOUNT_GROUP" "$HF_MOUNT_USER"
    CREATED_USER=true
    log "User $HF_MOUNT_USER created with group $HF_MOUNT_GROUP"

    if getent group fuse >/dev/null 2>&1; then
        usermod -aG fuse "$HF_MOUNT_USER"
        log "Added $HF_MOUNT_USER to fuse group"
    fi
}

# ─── Step 6: Setup Directories ────────────────────────────────────────────

setup_directories() {
    log "Setting up directories..."

    local dirs=(
        "$MOUNT_BASE_DIR"
        "$CACHE_DIR"
        "$STATE_DIR"
        "$LOG_DIR"
        "$TOKEN_DIR"
    )

    for dir in "${dirs[@]}"; do
        # Only roll back directories this invocation created, so re-runs never
        # tear down pre-existing mounts/cache/state owned by other services.
        local preexisted=false
        [[ -e "$dir" ]] && preexisted=true

        mkdir -p "$dir"
        chown "$HF_MOUNT_USER:$HF_MOUNT_GROUP" "$dir"
        chmod 755 "$dir"

        [[ "$preexisted" != "true" ]] && ROLLBACK_DIRS+=("$dir")
    done

    # Cache subdirectory for xorb chunks
    mkdir -p "$CACHE_DIR/xorbs"
    chown "$HF_MOUNT_USER:$HF_MOUNT_GROUP" "$CACHE_DIR/xorbs"

    log "Directories created and configured"
}

# ─── Step 7: Setup HF Token ───────────────────────────────────────────────

setup_hf_token() {
    log "Configuring HuggingFace token..."

    local token=""

    # Priority: HF_TOKEN env var > HF_TOKEN_FILE env var > existing file > interactive
    if [[ -n "$HF_TOKEN" ]]; then
        token="$HF_TOKEN"
        log "Using token from HF_TOKEN environment variable"
    elif [[ -n "$HF_TOKEN_FILE" ]] && [[ -f "$HF_TOKEN_FILE" ]]; then
        token=$(cat "$HF_TOKEN_FILE")
        log "Using token from $HF_TOKEN_FILE"
    elif [[ -f "$TOKEN_DIR/hf-token" ]]; then
        log "Token already configured at $TOKEN_DIR/hf-token"
        return 0
    fi

    if [[ -z "$token" ]] && [[ -t 0 ]]; then
        read -rp "Enter your HuggingFace token (leave empty for public repos only): " token
    fi

    if [[ -n "$token" ]]; then
        echo "$token" > "$TOKEN_DIR/hf-token"
        chmod 600 "$TOKEN_DIR/hf-token"
        chown "$HF_MOUNT_USER:$HF_MOUNT_GROUP" "$TOKEN_DIR/hf-token"
        log "Token saved to $TOKEN_DIR/hf-token"
    else
        log "No token provided — mounts will be read-only public"
    fi
}

# ─── Step 8: Setup Cache ──────────────────────────────────────────────────

setup_cache() {
    log "Setting up cache directory..."

    chown "$HF_MOUNT_USER:$HF_MOUNT_GROUP" "$CACHE_DIR"

    log "Cache directory ready at $CACHE_DIR (max size: $(human_size "$CACHE_SIZE"))"
}

# ─── Step 9: Create Systemd Service ───────────────────────────────────────

create_systemd_service() {
    local name="$1"       # e.g. "openai-gpt-oss-20b"
    local repo="$2"       # e.g. "openai/gpt-oss-20b"
    local backend="$3"    # "fuse" or "nfs"

    local mount_point="$MOUNT_BASE_DIR/$name"
    local service_name="hf-mount-${name}.service"
    local service_file="$SERVICE_DIR/${service_name}"

    log "Creating systemd service: $service_name"

    local opts
    opts=$(build_mount_options "$backend")

    local backend_bin="hf-mount-${backend}"

    local svc_user="${HF_MOUNT_USER}"
    local svc_group="${HF_MOUNT_GROUP}"
    if [[ "$backend" == "nfs" ]]; then
        svc_user="root"
        svc_group="root"
    fi

    cat > "$service_file" <<EOF
[Unit]
Description=hf-mount ${backend} mount for ${repo}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${svc_user}
Group=${svc_group}
Environment=HOME=${STATE_DIR}
Environment=HF_TOKEN_FILE=${TOKEN_DIR}/hf-token
ExecStartPre=/bin/mkdir -p ${mount_point}
ExecStartPre=/bin/chown ${HF_MOUNT_USER}:${HF_MOUNT_GROUP} ${mount_point}
ExecStart=${INSTALL_DIR}/${backend_bin} repo ${repo} ${mount_point} ${opts}
ExecStop=/bin/kill -SIGTERM \$MAINPID
TimeoutStopSec=180
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    chmod 644 "$service_file"
    SERVICES+=("$service_name")

    log "Service file created: $service_file"
}

# ─── Step 10: Pre-mount Default Repos ─────────────────────────────────────

pre_mount_repos() {
    log "Pre-mounting default repositories..."

    for repo in $DEFAULT_REPOS; do
        local name
        name=$(repo_to_name "$repo")
        local mount_point="$MOUNT_BASE_DIR/$name"

        # Create mount point directory
        mkdir -p "$mount_point"
        chown "$HF_MOUNT_USER:$HF_MOUNT_GROUP" "$mount_point"

        # Create and enable systemd service
        create_systemd_service "$name" "$repo" "$DEFAULT_BACKEND"

        systemctl daemon-reload
        systemctl enable "hf-mount-${name}.service"

        log "Starting mount for $repo..."
        if ! systemctl start "hf-mount-${name}.service"; then
            echo "WARNING: Failed to start service for $repo" >&2
            continue
        fi

        # Wait for mount and validate
        if wait_for_mount "$mount_point" 120; then
            if ! validate_mount "$mount_point"; then
                echo "WARNING: Mount validation failed for $repo" >&2
            fi
        else
            echo "ERROR: Mount failed for $repo at $mount_point" >&2
            echo "  Check logs: journalctl -u hf-mount-${name} -f" >&2
        fi
    done
}

# ─── Step 11: Create vps-model-mount Helper ───────────────────────────────

create_vps_model_mount() {
    log "Creating vps-model-mount helper script..."

    local helper_path="$INSTALL_DIR/vps-model-mount"

    cat > "$helper_path" <<'HELPER_EOF'
#!/usr/bin/env bash
# vps-model-mount — Quickly mount a HuggingFace model repo on VPS
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_DIR="/etc/systemd/system"
MOUNT_BASE_DIR="${MOUNT_BASE_DIR:-/mnt/models}"
CACHE_DIR="${CACHE_DIR:-/var/cache/hf-mount}"
STATE_DIR="${STATE_DIR:-/var/lib/hf-mount}"
TOKEN_DIR="${TOKEN_DIR:-/etc/hf-mount}"
HF_MOUNT_USER="${HF_MOUNT_USER:-hf-mount}"
HF_MOUNT_GROUP="${HF_MOUNT_GROUP:-hf-mount}"
CACHE_SIZE="${CACHE_SIZE:-50000000000}"
POLL_INTERVAL_SECS="${POLL_INTERVAL_SECS:-10}"
POLL_LISTING_CONCURRENCY="${POLL_LISTING_CONCURRENCY:-8}"
METADATA_TTL_MS="${METADATA_TTL_MS:-5000}"
FLUSH_SHUTDOWN_TIMEOUT_MS="${FLUSH_SHUTDOWN_TIMEOUT_MS:-120000}"
ADVANCED_WRITES="${ADVANCED_WRITES:-true}"
READ_ONLY="${READ_ONLY:-true}"

usage() {
    cat <<EOF
Usage: vps-model-mount <repo_id> [options]

Quickly mount a HuggingFace repo on a VPS with systemd auto-start.

Examples:
  vps-model-mount openai/gpt-oss-20b
  vps-model-mount meta-llama/Llama-3-8B --backend fuse
  vps-model-mount user/dataset --backend nfs --read-write

Options:
  --backend <fuse|nfs>   Backend to use (default: auto-detect)
  --read-only            Mount read-only (default)
  --read-write           Mount read-write (requires write permissions)
  --list                 List currently mounted repos
  --unmount <repo_id>    Unmount a repo
  --help                 Show this help
EOF
    exit 1
}

list_mounts() {
    echo "Currently mounted repositories:"
    echo ""
    systemctl list-units --type=service --state=running "hf-mount-*.service" --no-pager 2>/dev/null || true
    echo ""
    echo "Or check with: hf-mount status"
}

unmount_repo() {
    local repo="$1"
    local name="${repo//\//-}"
    local service="hf-mount-${name}.service"
    local mount_point="${MOUNT_BASE_DIR}/${name}"

    echo "Unmounting ${repo}..."
    systemctl stop "$service" 2>/dev/null || true
    systemctl disable "$service" 2>/dev/null || true
    rm -f "$SERVICE_DIR/$service"
    systemctl daemon-reload

    # Ensure unmount
    if mountpoint -q "$mount_point" 2>/dev/null; then
        umount "$mount_point" 2>/dev/null || fusermount3 -u "$mount_point" 2>/dev/null || true
    fi

    echo "Unmounted: ${repo}"
}

auto_detect_backend() {
    if [[ -e /dev/fuse ]] && command -v fusermount3 >/dev/null 2>&1; then
        echo "fuse"
    else
        echo "nfs"
    fi
}

wait_for_mount() {
    local mount_point="$1"
    local timeout="${2:-120}"
    local start_time
    start_time=$(date +%s)

    while true; do
        if mountpoint -q "$mount_point" 2>/dev/null; then
            return 0
        fi

        local elapsed
        elapsed=$(($(date +%s) - start_time))
        if [[ $elapsed -gt $timeout ]]; then
            echo "ERROR: Mount at ${mount_point} not ready after ${timeout}s" >&2
            echo "Check logs: journalctl -u hf-mount-* -f" >&2
            return 1
        fi

        sleep 2
    done
}

validate_mount() {
    local mount_point="$1"

    if ! mountpoint -q "$mount_point" 2>/dev/null; then
        echo "ERROR: ${mount_point} is not a mount point" >&2
        return 1
    fi

    if ! ls "$mount_point" >/dev/null 2>&1; then
        echo "ERROR: Cannot list files in ${mount_point}" >&2
        return 1
    fi

    return 0
}

main() {
    if [[ $# -eq 0 ]]; then
        usage
    fi

    local repo=""
    local backend=""
    local read_only="true"

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --list)
                list_mounts
                exit 0
                ;;
            --unmount)
                if [[ $# -lt 2 ]]; then
                    echo "Error: --unmount requires a repo_id" >&2
                    exit 1
                fi
                unmount_repo "$2"
                exit 0
                ;;
            --backend)
                if [[ $# -lt 2 ]]; then
                    echo "Error: --backend requires a value (fuse or nfs)" >&2
                    exit 1
                fi
                backend="$2"
                shift 2
                ;;
            --read-only)
                read_only="true"
                shift
                ;;
            --read-write)
                read_only="false"
                shift
                ;;
            --help|-h)
                usage
                ;;
            -*)
                echo "Error: Unknown option: $1" >&2
                usage
                ;;
            *)
                if [[ -z "$repo" ]]; then
                    repo="$1"
                else
                    echo "Error: Unexpected argument: $1" >&2
                    usage
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$repo" ]]; then
        echo "Error: repo_id is required" >&2
        usage
    fi

    # Validate repo format
    if [[ ! "$repo" =~ ^[^/]+/[^/]+$ ]]; then
        echo "Error: repo_id must be in format 'owner/name'" >&2
        exit 1
    fi

    # Auto-detect backend if not specified
    if [[ -z "$backend" ]]; then
        backend=$(auto_detect_backend)
    fi

    if [[ "$backend" != "fuse" && "$backend" != "nfs" ]]; then
        echo "Error: Invalid backend '${backend}'. Use 'fuse' or 'nfs'." >&2
        exit 1
    fi

    local name="${repo//\//-}"
    local mount_point="${MOUNT_BASE_DIR}/${name}"
    local service="hf-mount-${name}.service"

    # Check if already mounted
    if mountpoint -q "$mount_point" 2>/dev/null; then
        echo "Already mounted: ${repo} at ${mount_point}"
        exit 0
    fi

    # Check if service already exists
    if systemctl is-enabled --quiet "$service" 2>/dev/null; then
        echo "Service ${service} already exists, restarting..."
        systemctl restart "$service"
        wait_for_mount "$mount_point" 120
        validate_mount "$mount_point"
        echo ""
        echo "Successfully restarted: ${repo}"
        echo "  Mount point: ${mount_point}"
        echo "  Backend:     ${backend}"
        echo "  Service:     ${service}"
        exit 0
    fi

    # Create mount point
    mkdir -p "$mount_point"
    chown "$HF_MOUNT_USER:$HF_MOUNT_GROUP" "$mount_point"

    # Build options (reuse configured values)
    local opts=()
    opts+=("--token-file" "$TOKEN_DIR/hf-token")
    opts+=("--cache-dir" "$CACHE_DIR")
    opts+=("--cache-size" "${CACHE_SIZE}")
    opts+=("--poll-interval-secs" "${POLL_INTERVAL_SECS}")
    opts+=("--poll-listing-concurrency" "${POLL_LISTING_CONCURRENCY}")
    opts+=("--metadata-ttl-ms" "${METADATA_TTL_MS}")
    opts+=("--flush-shutdown-timeout-ms" "${FLUSH_SHUTDOWN_TIMEOUT_MS}")

    if [[ "$ADVANCED_WRITES" == "true" ]]; then
        opts+=("--advanced-writes")
    fi

    if [[ "$read_only" == "true" ]]; then
        opts+=("--read-only")
    fi

    local backend_bin="hf-mount-${backend}"

    local svc_user="${HF_MOUNT_USER}"
    local svc_group="${HF_MOUNT_GROUP}"
    if [[ "$backend" == "nfs" ]]; then
        svc_user="root"
        svc_group="root"
    fi

    # Create systemd service
    cat > "$SERVICE_DIR/$service" <<EOF
[Unit]
Description=hf-mount ${backend} mount for ${repo}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${svc_user}
Group=${svc_group}
Environment=HOME=${STATE_DIR}
Environment=HF_TOKEN_FILE=${TOKEN_DIR}/hf-token
ExecStartPre=/bin/mkdir -p ${mount_point}
ExecStartPre=/bin/chown ${HF_MOUNT_USER}:${HF_MOUNT_GROUP} ${mount_point}
ExecStart=${INSTALL_DIR}/${backend_bin} repo ${repo} ${mount_point} ${opts[*]}
ExecStop=/bin/kill -SIGTERM \$MAINPID
TimeoutStopSec=180
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    # Enable and start
    systemctl daemon-reload
    systemctl enable "$service"
    systemctl start "$service"

    # Wait for mount
    if wait_for_mount "$mount_point" 120; then
        validate_mount "$mount_point"
    else
        echo "ERROR: Failed to mount ${repo}" >&2
        exit 1
    fi

    echo ""
    echo "Successfully mounted: ${repo}"
    echo "  Mount point: ${mount_point}"
    echo "  Backend:     ${backend}"
    echo "  Service:     ${service}"
    echo "  Stop with:   systemctl stop ${service}"
    echo "  Logs with:   journalctl -u ${service} -f"
}

main "$@"
HELPER_EOF

    chmod +x "$helper_path"
    chown root:root "$helper_path"

    log "Helper script installed: $helper_path"
}

# ─── Step 12: Install NFS dependencies if needed ──────────────────────────

install_nfs_deps() {
    log "Installing NFS dependencies (nfs-common)..."
    if command -v apt-get >/dev/null 2>&1; then
        apt-get install -y -qq nfs-common 2>/dev/null || true
    elif command -v yum >/dev/null 2>&1; then
        yum install -y nfs-utils 2>/dev/null || true
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y nfs-utils 2>/dev/null || true
    fi
}

# ─── Step 13: Install FUSE dependencies if needed ─────────────────────────

install_fuse_deps() {
    log "Installing FUSE dependencies (fuse3)..."
    if command -v apt-get >/dev/null 2>&1; then
        apt-get install -y -qq fuse3 2>/dev/null || true
    elif command -v yum >/dev/null 2>&1; then
        yum install -y fuse3 2>/dev/null || true
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y fuse3 2>/dev/null || true
    fi
}

# ─── Main ─────────────────────────────────────────────────────────────────

main() {
    echo ""
    echo "=========================================="
    echo "  hf-mount VPS Setup"
    echo "=========================================="
    echo ""

    check_root
    check_prerequisites
    install_nfs_deps
    install_fuse_deps
    detect_backend
    create_system_user
    setup_directories
    setup_hf_token
    install_hf_mount
    setup_cache
    pre_mount_repos
    create_vps_model_mount

    echo ""
    echo "=========================================="
    echo "  VPS setup complete!"
    echo "=========================================="
    echo ""
    echo "Mounted repositories:"
    for repo in $DEFAULT_REPOS; do
        local name
        name=$(repo_to_name "$repo")
        echo "  ${repo} -> ${MOUNT_BASE_DIR}/${name}"
    done
    echo ""
    echo "Configuration:"
    echo "  Backend:      ${DEFAULT_BACKEND}"
    echo "  Cache dir:    ${CACHE_DIR}"
    echo "  Cache size:   $(human_size "$CACHE_SIZE")"
    echo "  Token file:   ${TOKEN_DIR}/hf-token"
    echo "  Binaries:     ${INSTALL_DIR}/"
    echo ""
    echo "Helper script: ${INSTALL_DIR}/vps-model-mount"
    echo ""
    echo "To mount additional models:"
    echo "  vps-model-mount <owner>/<model-name>"
    echo ""
    echo "To check status:"
    echo "  hf-mount status"
    echo "  systemctl status 'hf-mount-*.service'"
    echo ""
    echo "To view logs:"
    echo "  journalctl -u hf-mount-* -f"
    echo ""
}

main "$@"
