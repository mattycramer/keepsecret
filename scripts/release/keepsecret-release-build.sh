#!/usr/bin/env bash

set -eEuo pipefail

repo_root="${CI_PROJECT_DIR:-$(pwd)}"
source "${repo_root}/scripts/release/keepsecret-lib.sh"

export LANG=C.UTF-8 LC_ALL=C.UTF-8 TZ=UTC
cd "${repo_root}"

keepsecret_install_build_deps
keepsecret_verify_wayland_desktop_file_alignment "${repo_root}"

install_prefix="$(normalize_value "${KEEPSECRET_INSTALL_PREFIX:-/usr/local}")"
if [ -z "${install_prefix}" ]; then
  echo "KEEPSECRET_INSTALL_PREFIX must not be empty." >&2
  exit 1
fi

build_dir="${repo_root}/${KEEPSECRET_RELEASE_BUILD_DIR}"
destdir="${repo_root}/${KEEPSECRET_DESTDIR}"

keepsecret_configure_tree "${repo_root}" "${build_dir}" "${install_prefix}"
keepsecret_build_tree "${build_dir}"
keepsecret_stage_install_tree "${build_dir}" "${destdir}" "${install_prefix}"

package_version="$(keepsecret_resolve_package_version)"
artifact_prefix="$(normalize_value "${GL_RELEASE_ARTIFACT_PREFIX:-${KEEPSECRET_ARTIFACT_PREFIX}}")"
package_name="$(normalize_value "${GL_RELEASE_PACKAGE_NAME:-${KEEPSECRET_PACKAGE_NAME}}")"

if ! printf '%s' "${artifact_prefix}" | grep -Eq '^[0-9A-Za-z._+-]+$'; then
  echo "Invalid GL_RELEASE_ARTIFACT_PREFIX: ${artifact_prefix}" >&2
  exit 1
fi
if ! printf '%s' "${package_name}" | grep -Eq '^[0-9A-Za-z._-]+$'; then
  echo "Invalid GL_RELEASE_PACKAGE_NAME: ${package_name}" >&2
  exit 1
fi

tarball="${artifact_prefix}-${package_version}.tar.gz"
checksum="${artifact_prefix}-sha256-checksums-${package_version}.txt"

tar -czf "${tarball}" -C "${destdir}" .
sha256sum "${tarball}" > "${checksum}"

{
  printf 'GL_RELEASE_PACKAGE_NAME=%s\n' "${package_name}"
  printf 'GL_RELEASE_TAG_VERSION=%s\n' "${package_version}"
  printf 'GL_RELEASE_TARBALL=%s\n' "${tarball}"
  printf 'GL_RELEASE_CHECKSUM=%s\n' "${checksum}"
} > "${repo_root}/.gl_release_meta.env"

echo "Built keepsecret release assets: ${tarball} and ${checksum}"
