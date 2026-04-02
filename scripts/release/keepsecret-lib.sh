#!/usr/bin/env bash

set -eEuo pipefail

log_step() {
  printf '\n==> %s\n' "$*"
}

trim_value() {
  local raw="${1:-}"
  raw="${raw//$'\r'/}"
  raw="${raw#"${raw%%[![:space:]]*}"}"
  raw="${raw%"${raw##*[![:space:]]}"}"
  printf '%s' "${raw}"
}

normalize_value() {
  local raw
  raw="$(trim_value "${1:-}")"
  case "${raw}" in
    \"*\")
      raw="${raw#\"}"
      raw="${raw%\"}"
      ;;
    \'*\')
      raw="${raw#\'}"
      raw="${raw%\'}"
      ;;
  esac
  printf '%s' "${raw}"
}

normalize_bool() {
  local raw
  raw="$(normalize_value "${1:-false}")"
  case "${raw}" in
    true) printf 'true' ;;
    false|'') printf 'false' ;;
    *)
      echo "Invalid boolean value: ${1} (expected true or false)." >&2
      return 1
      ;;
  esac
}

require_commands() {
  local missing=()
  local cmd

  for cmd in "$@"; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
      missing+=("${cmd}")
    fi
  done

  if [ "${#missing[@]}" -gt 0 ]; then
    printf 'Missing required command(s): %s\n' "${missing[*]}" >&2
    return 1
  fi
}

keepsecret_install_build_deps() {
  local -a packages=()

  mapfile -t packages < <(printf '%s\n' "${KEEPSECRET_APT_PACKAGES:-}" | sed '/^[[:space:]]*$/d')
  if [ "${#packages[@]}" -eq 0 ]; then
    echo "KEEPSECRET_APT_PACKAGES is empty." >&2
    return 1
  fi

  log_step "Installing keepsecret build dependencies"
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${packages[@]}"
  rm -rf /var/lib/apt/lists/*

  require_commands cmake git grep ninja pkg-config
}

keepsecret_verify_wayland_desktop_file_alignment() {
  local source_dir="${1}"

  if ! grep -F 'QGuiApplication::setDesktopFileName(u"org.kde.keepsecret"_s);' "${source_dir}/src/main.cpp" >/dev/null 2>&1; then
    echo "Missing Wayland desktop file alignment in src/main.cpp." >&2
    return 1
  fi
}

keepsecret_resolve_package_version() {
  local tag
  local version

  tag="$(normalize_value "${CI_COMMIT_TAG:-}")"
  if [ -z "${tag}" ]; then
    echo "CI_COMMIT_TAG is required for release packaging." >&2
    return 1
  fi

  case "${tag}" in
    *-v*)
      version="${tag##*-v}"
      ;;
    *)
      version="${tag}"
      ;;
  esac

  version="$(normalize_value "${version}")"
  if [ -z "${version}" ] || ! printf '%s' "${version}" | grep -Eq '^[0-9A-Za-z][0-9A-Za-z._+-]*$'; then
    echo "Invalid release version: ${version:-<empty>}." >&2
    return 1
  fi

  printf '%s' "${version}"
}

keepsecret_prepare_release_patch_list() {
  local apply_patches

  if [ ! -f /tmp/release_patches.sh ]; then
    echo "Shared release patch helpers are not available." >&2
    return 1
  fi

  apply_patches="$(normalize_bool "${APPLY_PATCHES:-false}")"
  if [ "${apply_patches}" != "true" ]; then
    RELEASE_PATCHES=()
    return 0
  fi

  # shellcheck disable=SC1091
  . /tmp/release_patches.sh
  release_patch_prepare
  release_patch_collect
}

keepsecret_apply_selected_release_patches() {
  local patch_file

  keepsecret_prepare_release_patch_list
  if [ "${#RELEASE_PATCHES[@]}" -eq 0 ]; then
    echo "No selected release patches to apply."
    return 0
  fi

  for patch_file in "${RELEASE_PATCHES[@]}"; do
    echo "Applying keepsecret release patch ${patch_file}"
    git apply -p1 "${patch_file}"
  done
}

keepsecret_configure_compiler_cache() {
  if command -v sccache >/dev/null 2>&1 && [ -d /cache/sccache ]; then
    export SCCACHE_DIR='/cache/sccache'
    unset CCACHE_DIR || true
    unset CCACHE_BASEDIR || true
    export KEEPSECRET_CMAKE_C_LAUNCHER='sccache'
    export KEEPSECRET_CMAKE_CXX_LAUNCHER='sccache'
    return 0
  fi

  if command -v ccache >/dev/null 2>&1 && [ -d /cache/ccache ]; then
    unset SCCACHE_DIR || true
    export CCACHE_DIR='/cache/ccache'
    export KEEPSECRET_CMAKE_C_LAUNCHER='ccache'
    export KEEPSECRET_CMAKE_CXX_LAUNCHER='ccache'
    return 0
  fi

  unset SCCACHE_DIR || true
  unset CCACHE_DIR || true
  unset CCACHE_BASEDIR || true
  export KEEPSECRET_CMAKE_C_LAUNCHER=''
  export KEEPSECRET_CMAKE_CXX_LAUNCHER=''
}

keepsecret_configure_tree() {
  local source_dir="${1}"
  local build_dir="${2}"
  local install_prefix="${3}"

  keepsecret_configure_compiler_cache
  rm -rf -- "${build_dir}"
  cmake \
    -S "${source_dir}" \
    -B "${build_dir}" \
    -G Ninja \
    -D CMAKE_BUILD_TYPE=Release \
    -D BUILD_TESTING=OFF \
    -D CMAKE_INSTALL_PREFIX="${install_prefix}" \
    -D CMAKE_C_COMPILER_LAUNCHER="${KEEPSECRET_CMAKE_C_LAUNCHER}" \
    -D CMAKE_CXX_COMPILER_LAUNCHER="${KEEPSECRET_CMAKE_CXX_LAUNCHER}" \
    -W no-dev
}

keepsecret_build_tree() {
  local build_dir="${1}"
  cmake --build "${build_dir}" --parallel
}

keepsecret_stage_install_tree() {
  local build_dir="${1}"
  local destdir="${2}"
  local install_prefix="${3}"

  rm -rf -- "${destdir}"
  mkdir -p "${destdir}"
  env DESTDIR="${destdir}" cmake --install "${build_dir}" --prefix "${install_prefix}"

  if [ ! -x "${destdir%/}${install_prefix}/bin/keepsecret" ]; then
    echo "Installed keepsecret binary not found under ${destdir}${install_prefix}/bin/keepsecret." >&2
    return 1
  fi
}
