#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DEPLOY_SCRIPT="$ROOT_DIR/deploy/vps-setup.sh"

test_syntax() {
    bash -n "$DEPLOY_SCRIPT" || {
        echo "FAIL: deploy/vps-setup.sh has syntax errors" >&2
        return 1
    }
    echo "PASS: syntax check"
}

test_no_backend_param() {
    grep -A3 "build_mount_options() {" "$DEPLOY_SCRIPT" | grep -q "local backend" && {
        echo "FAIL: build_mount_options still has unused backend parameter" >&2
        return 1
    }
    echo "PASS: build_mount_options has no unused backend parameter"
}

test_helper_uses_install_dir() {
    grep -qF "ExecStart=\${INSTALL_DIR}/\${backend_bin}" "$DEPLOY_SCRIPT" || {
        echo "FAIL: helper script still uses SCRIPT_DIR instead of INSTALL_DIR" >&2
        return 1
    }
    echo "PASS: helper uses INSTALL_DIR"
}

test_no_numfmt_direct() {
    local direct_numfmt
    direct_numfmt=$(grep -n "numfmt" "$DEPLOY_SCRIPT" | grep -v "human_size" | grep -v "command -v numfmt" || true)
    if [[ -n "$direct_numfmt" ]]; then
        echo "FAIL: found direct numfmt calls outside human_size function:" >&2
        echo "$direct_numfmt" >&2
        return 1
    fi
    echo "PASS: no direct numfmt calls outside human_size"
}

test_gitignore_excludes_docs() {
    grep -q "^_docs/" "$ROOT_DIR/.gitignore" || {
        echo "FAIL: _docs/ not in .gitignore" >&2
        return 1
    }
    echo "PASS: _docs/ excluded in .gitignore"
}

test_no_docs_in_pr() {
    if git -C "$ROOT_DIR" ls-files | grep -q "^_docs/"; then
        echo "FAIL: _docs/ files still tracked in git" >&2
        return 1
    fi
    echo "PASS: no _docs/ files tracked in git"
}

test_checksum_verification() {
    grep -q "sha256sum\|shasum" "$DEPLOY_SCRIPT" || {
        echo "FAIL: no checksum verification in download_binary" >&2
        return 1
    }
    echo "PASS: checksum verification present"
}

main() {
    echo "Running deploy script tests..."
    test_syntax
    test_no_backend_param
    test_helper_uses_install_dir
    test_no_numfmt_direct
    test_gitignore_excludes_docs
    test_no_docs_in_pr
    test_checksum_verification
    echo "All tests passed."
}

main "$@"