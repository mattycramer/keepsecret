#!/usr/bin/env bash

set -eEuo pipefail

repo_root="${CI_PROJECT_DIR:-$(pwd)}"
source "${repo_root}/scripts/release/keepsecret-lib.sh"

export LC_ALL=C TZ=UTC
cd "${repo_root}"

keepsecret_install_build_deps

source_tree="$(mktemp -d)"
stage_root="$(mktemp -d)"
trap 'keepsecret_cleanup_test_worktree "${repo_root}" "${source_tree}"; rm -rf -- "${stage_root}"' EXIT

keepsecret_create_test_worktree "${repo_root}" "${source_tree}"
cd "${source_tree}"
keepsecret_apply_selected_release_patches
keepsecret_verify_wayland_desktop_file_alignment "${source_tree}"

build_dir="${source_tree}/${KEEPSECRET_BUILD_DIR}"
keepsecret_configure_tree "${source_tree}" "${build_dir}" "${KEEPSECRET_INSTALL_PREFIX}"
keepsecret_build_tree "${build_dir}"
keepsecret_stage_install_tree "${build_dir}" "${stage_root}" "${KEEPSECRET_INSTALL_PREFIX}"
