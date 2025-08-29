#!/usr/bin/env bash

set -euo pipefail

readonly OS="$(. /etc/os-release 2>/dev/null && echo "${ID}" || echo "unknown")"
readonly FZF_DEFAULT_OPTS=""
readonly FZF_PROMPT=">>> disk to install archlinuxarm: "
readonly FZF_WRAP_SIGN="↪ "
readonly LOGGER_BLUE_SHADE="\033[0;34m"
readonly LOGGER_GREEN_SHADE="\033[0;32m"
readonly LOGGER_NOCOLOR_SHADE="\033[0m"
readonly LOGGER_RED_SHADE="\033[0;31m"
readonly LOGGER_YELLOW_SHADE="\033[1;33m"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_NAME="$(basename "${0}")"
readonly ARCHLINUXARM="http://os.archlinuxarm.org/os/ArchLinuxARM-rpi-aarch64-latest.tar.gz"
readonly LINUX_RPI_REPO="http://mirror.archlinuxarm.org/aarch64/core/"
readonly DOWNLOAD_DIR="/tmp/archlinuxarm"
readonly LINUX_RPI_DIR="${DOWNLOAD_DIR}/linux-rpi"
readonly LINUX_RPI_APK_DIR="${LINUX_RPI_DIR}/apk"
readonly LINUX_RPI_EXTRACT_DIR="${LINUX_RPI_DIR}/extract"
readonly ROOTFS_PKG="ArchLinuxARM-rpi-aarch64-latest.tar.gz"
readonly ROOTFS="${DOWNLOAD_DIR}/${ROOTFS_PKG}"
readonly MOUNTPOINT="/mnt/alarm"

DISK_DEV=""
DISK_PART_BOOT=""
DISK_PART_ROOT=""
LINUX_RPI=""
LINUX_RPI_PKG=""
LINUX_RPI_APK=""
LINUX_RPI_APK_EXTRACT=""

_M.export.help () {
    cat << EOF | sed 's/\\n/\n/g'
\n${SCRIPT_NAME} - ArchLinuxARM build script.\n
usage:
    bash ${SCRIPT_NAME} [options]
    bash ${SCRIPT_NAME} [command] [options]\n
options:
    -h, --help                  show help message.\n
commands:\n
EOF
}

__logger.info () {
    echo -e "${LOGGER_BLUE_SHADE}[info]${LOGGER_NOCOLOR_SHADE} $*" >&2
}

__logger.warn () {
    echo -e "${LOGGER_YELLOW_SHADE}[warn]${LOGGER_NOCOLOR_SHADE} $*" >&2
}

__logger.error () {
    echo -e "${LOGGER_RED_SHADE}[error]${LOGGER_NOCOLOR_SHADE} $*" >&2
}

__logger.success () {
    echo -e "${LOGGER_GREEN_SHADE}[success]${LOGGER_NOCOLOR_SHADE} $*" >&2
}

__util.ping () {
    local host="${1}"
    if ping -c 1 -W 1 "${host}" &>/dev/null; then
        return 0
    else
        return 1
    fi
}

__util.is_excluded () {
    local item="${1}"
    shift
    local exclude
    for exclude in "$@"; do
        [[ "${exclude}" == "${item}" ]] && return 0
    done
    return 1
}

__util.install () {
    local pkg="${1}"
    local confirm
    read -rp ">>> do you want to install '${pkg}'? [y/N]: " confirm
    confirm="${confirm,,}"
    if [[ "${confirm}" == "y" || "${confirm}" == "yes" ]]; then
        __logger.info "installing '${pkg}' ..."
        if sudo pacman -S --needed --noconfirm "${pkg}"; then
            __logger.info "installing '${pkg}' ... done."
        else
            __logger.error "failed to install '${pkg}'."
            return 1
        fi
    else
        __logger.error "'${pkg}' is required but not installed."
        return 1
    fi
}

__M.check.sys () {
    local standalone_call=false
    local -a exclude_list=()
    while [[ $# -gt 0 ]]; do
        case "${1}" in
            --exclude=*)
                local value="${1#--exclude=}"
                if [[ -n "${value}" ]]; then
                    IFS=',' read -ra exclude_list <<< "${value}"
                fi
                shift
                ;;
            --standalone-call)
                standalone_call=true
                shift
                ;;
            *)
                __logger.error "unknown option '${1}' in __M.check.sys."
                return 1
                ;;
        esac
    done
    if [[ "${standalone_call}" == true ]]; then
        __logger.info "checking system packages ..."
    fi
    if __util.is_excluded "arch" "${exclude_list[@]}"; then
        __logger.warn "\b(arch) check: excluded."
    else
        if grep -qi "arch" /etc/os-release 2>/dev/null; then
            __logger.success "\b(arch) check: passed."
        else
            __logger.error "\b(arch) check: failed."
            __logger.error "supported only for 'archlinux' (detected: ${OS})."
            return 1
        fi
    fi
    if __util.is_excluded "ping" "${exclude_list[@]}"; then
        __logger.warn "\b(ping) check: excluded."
    else
        if __util.ping "8.8.8.8"; then
            __logger.success "\b(ping) check: passed."
        else
            __logger.error "\b(ping) check: failed."
            __logger.error "no internet connection available."
            return 1
        fi
    fi
    if __util.is_excluded "paru" "${exclude_list[@]}"; then
        __logger.warn "\b(paru) check: excluded."
    else
        if command -v paru &>/dev/null; then
            __logger.success "\b(paru) check: passed."
        else
            __logger.error "\b(paru) check: failed."
            __logger.error "'paru' AUR helper is not installed."
            return 1
        fi
    fi
    if [[ "${standalone_call}" == true ]]; then
        __logger.info "checking system packages ... done."
    fi
}

__M.check.pkgs () {
    local standalone_call=false
    while [[ $# -gt 0 ]]; do
        case "${1}" in
            --standalone-call)
                standalone_call=true
                shift
                ;;
            *)
                __logger.error "unknown option '${1}' in __M.check.pkgs."
                return 1
                ;;
        esac
    done
    local -a pkgs=(
        "aria2"
        "dosfstools"
        "e2fsprogs"
        "libarchive"
        "fzf"
        "gawk"
        "findutils"
        "curl"
        "grep"
        "coreutils"
        "coreutils"
        "util-linux"
        "parted"
        "libarchive"
        "coreutils"
        "coreutils"
        "tar"
        "findutils"
        "coreutils"
    )
    local -a bins=(
        "aria2c"
        "mkfs.vfat"
        "mkfs.ext4"
        "bsdtar"
        "fzf"
        "awk"
        "xargs"
        "curl"
        "grep"
        "sort"
        "uniq"
        "wipefs"
        "parted"
        "bsdtar"
        "du"
        "cut"
        "tar"
        "find"
        "head"
    )
    if [[ "${standalone_call}" == true ]]; then
        __logger.info "checking required packages ..."
    fi
    local i
    for i in "${!bins[@]}"; do
        local bin="${bins[${i}]}"
        local pkg="${pkgs[${i}]}"
        if command -v "${bin}" &>/dev/null; then
            __logger.success "\b(pkgs)(${bin}) check: passed."
        else
            __logger.error "\b(pkgs)(${bin}) check: failed."
            __logger.warn "'${bin}' not found (required from package: ${pkg})"
            __util.install "${pkg}"
            if command -v "${bin}" &>/dev/null; then
                __logger.success "\b(pkgs)(${bin}) check: passed after install."
            else
                __logger.error "\b(pkgs)(${bin}) still missing after attempted install."
                return 1
            fi
        fi
    done
    if [[ "${standalone_call}" == true ]]; then
        __logger.info "checking required packages ... done."
    fi
}

__M.util.get_disk () {
    local disk choice
    choice=$(lsblk -dno NAME,SIZE \
           | awk '{
               name=$1; size=$2
               name_w=9; size_w=8
               lpad_n=int((name_w - length(name)) / 2)
               rpad_n=name_w - length(name) - lpad_n
               lpad_s=int((size_w - length(size)) / 2)
               rpad_s=size_w - length(size) - lpad_s
               printf "[%*s%s%*s](%*s%s%*s)\n",
                       lpad_n, "", name, rpad_n, "",
                       lpad_s, "", size, rpad_s, ""
           }' \
           | fzf --bind=esc:ignore,ctrl-j:down,ctrl-k:up \
                 --preview-window=up:wrap:60% \
                 --wrap-sign="${FZF_WRAP_SIGN}" \
                 --prompt="${FZF_PROMPT}" \
                 --layout=default \
                 --ignore-case \
                 --height=25 \
                 --border \
                 --wrap \
                 --preview '
                     disk=$(echo {} | sed -E "s/^\[ *([^ ]+) *\].*/\1/")
                     lsblk -o NAME,MAJ:MIN,RM,SIZE,RO,TYPE,MOUNTPOINTS "/dev/$disk"
                 ')
    if [[ -n "${choice}" ]]; then
        disk=$(echo "${choice}" | awk -F'[][]' '{print $2}' | xargs)
        echo "/dev/${disk}"
        return 0
    else
        echo "none"
        return 1
    fi
}

__M.util.get_linux_rpi () {
    local response
    if ! response=$(curl -fsSL "${LINUX_RPI_REPO}" 2>/dev/null); then
        __logger.error "failed to fetch index from '${LINUX_RPI_REPO}'."
        return 1
    fi
    local pkgs
    pkgs=$(echo "${response}" \
        | grep -oE "linux-rpi-[0-9]+\.[0-9]+\.[0-9]+-[0-9]+-aarch64\.pkg\.tar\.[gx]z" \
        | sort -V \
        | uniq \
        | tail -n1)
    if [[ -z "${pkgs}" ]]; then
        echo "none"
        return 1
    fi
    echo "${pkgs}"
    return 0
}

__M.util.cleanup () {
    local -a exclude_list=()
    while [[ $# -gt 0 ]]; do
        case "${1}" in
            --exclude=*)
                local value="${1#--exclude=}"
                if [[ -n "${value}" ]]; then
                    IFS=',' read -ra exclude_list <<< "${value}"
                fi
                shift
                ;;
            *)
                __logger.error "unknown option '${1}' in __M.util.cleanup."
                return 1
                ;;
        esac
    done
    __logger.info "cleaning up ..."
    if ! __util.is_excluded "umount" "${exclude_list[@]}"; then
        if ! sudo umount -R "${MOUNTPOINT}" 2>/dev/null; then
            __logger.warn "failed to unmount filesystems under '${MOUNTPOINT}'."
        else
            __logger.info "unmounted all filesystems under '${MOUNTPOINT}'."
        fi
    fi
    __logger.info "cleaning up ... done."
}

__M.install.setup () {
    local standalone_call=false
    while [[ $# -gt 0 ]]; do
        case "${1}" in
            --standalone-call)
                standalone_call=true
                shift
                ;;
            *)
                __logger.error "unknown option '${1}' in __M.install.setup."
                return 1
                ;;
        esac
    done
    if [[ "${standalone_call}" == true ]]; then
        __logger.info "setting up archlinuxarm installation ..."
    fi
    DISK_DEV="$(__M.util.get_disk)"
    if [[ "${DISK_DEV}" == "none" ]]; then
        __logger.error "no disk selected."
        return 1
    fi
    readonly DISK_PART_BOOT="${DISK_DEV}p1"
    readonly DISK_PART_ROOT="${DISK_DEV}p2"
    __logger.info "disk selected: ${DISK_DEV}."
    __logger.info "boot partition: ${DISK_PART_BOOT}."
    __logger.info "root partition: ${DISK_PART_ROOT}."
    __logger.info "creating download directory ..."
    if ! mkdir -p "${DOWNLOAD_DIR}"; then
        __logger.error "failed to create download directory: ${DOWNLOAD_DIR}."
        return 1
    fi
    __logger.info "creating download directory ... done."
    if [[ -f "${ROOTFS}" && -s "${ROOTFS}" ]]; then
        __logger.info "found cached rootfs: ${ROOTFS} ($(du -h "${ROOTFS}" | cut -f1))"
        if bsdtar -tf "${ROOTFS}" &>/dev/null; then
            local confirm
            read -rp ">>> use cached rootfs '${ROOTFS}'? [y/N]: " confirm
            confirm="${confirm,,}"
            if [[ "${confirm}" == "y" || "${confirm}" == "yes" ]]; then
                __logger.info "using cached rootfs."
            else
                __logger.info "discarding cache ..."
                if ! rm -f "${ROOTFS}"; then
                    __logger.error "failed to discard the cache."
                    return 1
                fi
                __logger.info "discarding cache ... done."
            fi
        else
            __logger.warn "cache is corrupted."
            __logger.info "discarding cache ..."
            if ! rm -f "${ROOTFS}"; then
                __logger.error "failed to discard the cache."
                return 1
            fi
            __logger.info "discarding cache ... done."
        fi
    fi
    if [[ ! -f "${ROOTFS}" ]]; then
        __logger.info "downloading archlinuxarm ..."
        if ! ( aria2c -x 16 -s 16 -k 1M \
                --dir="${DOWNLOAD_DIR}" \
                -o "${ROOTFS_PKG}" \
                "${ARCHLINUXARM}" ); then
            __logger.error "failed to download archlinuxarm."
            return 1
        fi
        __logger.info "downloading archlinuxarm ... done."
    fi
    local user
    user=$(whoami)
    if [[ "${user}" == "root" ]]; then
        __logger.info "running as '${user}' user."
    else
        __logger.info "getting sudo access ..."
        if sudo -v; then
            __logger.success "\b(sudo) verification: passed."
        else
            __logger.error "\b(sudo) verification: failed."
            return 1
        fi
        __logger.info "getting sudo access ... done."
    fi
    __logger.warn "disk selected: ${DISK_DEV}."
    local confirm
    read -rp ">>> wipe this disk and create new partition table? [y/N]: " confirm
    confirm="${confirm,,}"
    if [[ "${confirm}" != "y" && "${confirm}" != "yes" ]]; then
        __logger.error "disk wipe cancelled."
        return 1
    fi
    __logger.info "wiping the disk ..."
    if ! ( sudo wipefs -a "${DISK_DEV}" && sudo parted -s "${DISK_DEV}" mklabel gpt); then
        __logger.error "failed to wip the disk."
        return 1
    fi
    __logger.info "wiping the disk ... done."
    __logger.info "partitioning the disk ..."
    if ! ( sudo parted -s "${DISK_DEV}" \
                mkpart primary fat32 1MiB 1025MiB \
                set 1 boot on \
                set 1 esp on \
                mkpart primary ext4 1025MiB 100% ); then
        __logger.error "failed to partition disk."
        return 1
    fi
    __logger.info "partitioning the disk ... done."
    __logger.info "formatting boot partition ..."
    if ! sudo mkfs.vfat -F 32 "${DISK_PART_BOOT}"; then
        __logger.error "failed to format boot partition."
        return 1
    fi
    __logger.info "formatting boot partition ... done."
    __logger.info "formatting root partition ..."
    if ! sudo mkfs.ext4 -E lazy_itable_init=0,lazy_journal_init=0 -F "${DISK_PART_ROOT}"; then
        __logger.error "failed to format root partition."
        return 1
    fi
    __logger.info "formatting root partition ... done."
    __logger.info "creating root mount directory ..."
    if ! sudo mkdir -p "${MOUNTPOINT}"; then
        __logger.error "failed to create root mount directory: ${MOUNTPOINT}."
        return 1
    fi
    __logger.info "creating root mount directory ... done."
    __logger.info "mounting root partition ..."
    if ! sudo mount "${DISK_PART_ROOT}" "${MOUNTPOINT}"; then
        __logger.error "failed to mount root partition."
        return 1
    fi
    __logger.info "mounting root partition ... done."
    __logger.info "creating boot mount directory ..."
    if ! sudo mkdir -p "${MOUNTPOINT}/boot"; then
        __logger.error "failed to create boot mount directory: ${MOUNTPOINT}/boot."
        __M.util.cleanup
        return 1
    fi
    __logger.info "creating boot mount directory ... done."
    __logger.info "mounting boot partition ..."
    if ! sudo mount "${DISK_PART_BOOT}" "${MOUNTPOINT}/boot"; then
        __logger.error "failed to mount boot partition."
        __M.util.cleanup
        return 1
    fi
    __logger.info "mounting boot partition ... done."
    __logger.info "extracting archlinuxarm ..."
    if ! sudo bsdtar -xpf "${ROOTFS}" -C "$MOUNTPOINT"; then
        __logger.error "failed to extract archlinuxarm."
        __M.util.cleanup
        return 1
    fi
    __logger.info "extracting archlinuxarm ... done."
    __logger.info "removing u-boot ..."
    if ! sudo rm -rf "${MOUNTPOINT}/boot/*"; then
        __logger.error "failed to remove the u-boot."
        __M.util.cleanup
        return 1
    fi
    __logger.info "removing u-boot ... done."
    __logger.info "creating linux-rpi directories ..."
    if ! mkdir  -p "${LINUX_RPI_APK_DIR}" "${LINUX_RPI_EXTRACT_DIR}"; then
        __logger.error "failed to create linux-rpi directories: ${LINUX_RPI_APK_DIR}, ${LINUX_RPI_EXTRACT_DIR}."
        __M.util.cleanup
        return 1
    fi
    __logger.info "creating linux-rpi directories ... done."
    LINUX_RPI_PKG="$(__M.util.get_linux_rpi)"
    LINUX_RPI="${LINUX_RPI_PKG%.pkg.tar.xz}"
    if [[ "${LINUX_RPI_PKG}" == "none" ]]; then
        __logger.error "no linux-rpi packages found at '${LINUX_RPI_REPO}'."
        __M.util.cleanup
        return 1
    fi
    LINUX_RPI_APK="${LINUX_RPI_APK_DIR}/${LINUX_RPI_PKG}"
    if [[ -f "${LINUX_RPI_APK}" && -s "${LINUX_RPI_APK}" ]]; then
        __logger.info "found cached linux-rpi kernel package: ${LINUX_RPI_PKG}."
        if tar -tf "${LINUX_RPI_APK}" &>/dev/null; then
            local confirm
            read -rp ">>> use cached linux-rpi kernel package '${LINUX_RPI_PKG}'? [y/N]: " confirm
            confirm="${confirm,,}"
            if [[ "${confirm}" == "y" || "${confirm}" == "yes" ]]; then
                __logger.info "using cached linux-rpi kernel package."
            else
                __logger.info "discarding cache ..."
                if ! rm -f "${LINUX_RPI_APK}"; then
                    __logger.error "failed to discard the cache."
                    __M.util.cleanup
                    return 1
                fi
                __logger.info "discarding cache ... done."
            fi
        else
            __logger.warn "cache is corrupted."
            __logger.info "discarding cache ..."
            if ! rm -f "${LINUX_RPI_APK}"; then
                __logger.error "failed to discard the cache."
                __M.util.cleanup
                return 1
            fi
            __logger.info "discarding cache ... done."
        fi
    fi
    if [[ ! -f "${LINUX_RPI_APK}" ]]; then
        __logger.info "downloading linux-rpi kernel ..."
        if ! ( aria2c -x 16 -s 16 -k 1M \
                --dir="${LINUX_RPI_APK_DIR}" \
                -o "${LINUX_RPI_PKG}" \
                "${LINUX_RPI_REPO}/${LINUX_RPI_PKG}" ); then
            __logger.error "failed to download linux-rpi kernel."
            __M.util.cleanup
            return 1
        fi
        __logger.info "downloading linux-rpi kernel ... done."
    fi
    LINUX_RPI_APK_EXTRACT="${LINUX_RPI_EXTRACT_DIR}/${LINUX_RPI}"
    if [[ -d "${LINUX_RPI_APK_EXTRACT}/boot" ]]; then
        __logger.info "found extracted linux-rpi kernel '/boot' directory."
        if ls "${LINUX_RPI_APK_EXTRACT}/boot/"kernel*.img &>/dev/null; then
            local confirm
            read -rp ">>> use cached extracted kernel (boot/)? [y/N]: " confirm
            confirm="${confirm,,}"
            if [[ "${confirm}" == "y" || "${confirm}" == "yes" ]]; then
                __logger.info "using cached extracted kernel."
            else
                __logger.info "discarding cache ..."
                if ! rm -rf "${LINUX_RPI_APK_EXTRACT}"; then
                    __logger.error "failed to discard the cache."
                    __M.util.cleanup
                    return 1
                fi
                __logger.info "discarding cache ... done."
            fi
        else
            __logger.warn "boot/ exists but no kernel*.img found."
            __logger.info "discarding cache ..."
            if ! rm -rf "${LINUX_RPI_APK_EXTRACT}"; then
                __logger.error "failed to discard the cache."
                __M.util.cleanup
                return 1
            fi
            __logger.info "discarding cache ... done."
        fi
    fi
    if [[ ! -d "${LINUX_RPI_APK_EXTRACT}"
            || -z "$(find "${LINUX_RPI_APK_EXTRACT}" -mindepth 1 -print -quit 2>/dev/null)" ]]; then
        __logger.info "creating extracting directory ..."
        if ! mkdir -p "${LINUX_RPI_APK_EXTRACT}"; then
            __logger.error "failed to create extract directory: ${LINUX_RPI_APK_EXTRACT}."
            __M.util.cleanup
            return 1
        fi
        __logger.info "creating extracting directory ... done."
        __logger.info "extracting linux-rpi kernel package ..."
        if ! tar xf "${LINUX_RPI_APK}" -C "${LINUX_RPI_APK_EXTRACT}"; then
            __logger.error "failed to extract linux-rpi kernel package."
            __M.util.cleanup
            return 1
        fi
        __logger.info "extracting linux-rpi kernel package ... done."
    fi
    local kernels
    mapfile -t kernels < <(find "${LINUX_RPI_APK_EXTRACT}/boot" -maxdepth 1 -type f -name "kernel*.img" 2>/dev/null)
    if [[ ${#kernels[@]} -eq 0 ]]; then
        __logger.error "no kernel*.img found in extracted linux-rpi kernel package."
        __M.util.cleanup
        return 1
    fi
    __logger.info "found kernels : ${kernels[*]}"
    __logger.info "copying kernel image ..."
    if ! sudo cp -rf "${LINUX_RPI_APK_EXTRACT}/boot/"* "${MOUNTPOINT}/boot/"; then
        __logger.error "failed to copy kernel image."
        __M.util.cleanup
        return 1
    fi
    __logger.info "copying kernel image ... done."
    __logger.info "syncing filesystems ..."
    if ! sync; then
        __logger.error "failed to sync filesystems."
        __M.util.cleanup
        return 1
    fi
    __logger.info "syncing filesystems ... done."
    __logger.info "unmounting filesystems ..."
    if ! sudo umount -R "${MOUNTPOINT}"; then
        __logger.error "failed to unmount filesystems."
        return 1
    fi
    __logger.info "unmounting filesystems ... done."
    if [[ "${standalone_call}" == true ]]; then
        __logger.info "setting up archlinuxarm installation ... done."
    fi
}

__M.install.post () {
    return
}

_M.export.check () {
    if [[ $# -eq 0 ]]; then
        __logger.info "checking requirements ..."
        __M.check.sys
        __M.check.pkgs
        __logger.info "checking requirements ... done."
        return 0
    fi
    local only_pkgs=false
    local only_sys=false
    local exclude_args=""
    local skip_pkgs=false
    while [[ $# -gt 0 ]]; do
        case "${1}" in
            --exclude=*)
                exclude_args="${1}"
                shift
                ;;
            --only-pkgs)
                only_pkgs=true
                shift
                ;;
            --only-sys)
                only_sys=true
                shift
                ;;
            *)
                __logger.error "unknown option '${1}' in _M.export.check."
                return 1
                ;;
        esac
    done
    if [[ -n "${exclude_args}" ]]; then
        local exclude_value="${exclude_args#--exclude=}"
        local -a exclude_list=()
        local -a filtered_exclude_list=()
        IFS=',' read -ra exclude_list <<< "${exclude_value}"
        for item in "${exclude_list[@]}"; do
            if [[ "${item}" == "pkgs" ]]; then
                skip_pkgs=true
            else
                filtered_exclude_list+=("${item}")
            fi
        done
        if [[ ${#filtered_exclude_list[@]} -gt 0 ]]; then
            local filtered_exclude_string
            printf -v filtered_exclude_string '%s,' "${filtered_exclude_list[@]}"
            filtered_exclude_string="${filtered_exclude_string%,}"
            exclude_args="--exclude=${filtered_exclude_string}"
        else
            exclude_args=""
        fi
    fi
    if [[ "${only_pkgs}" == true && "${only_sys}" == true ]]; then
        __logger.error "cannot use --only-pkgs and --only-sys together."
        return 1
    fi
    if [[ "${only_pkgs}" == true ]]; then
        if [[ "${skip_pkgs}" == true ]]; then
            __logger.warn "\b(pkgs) check: excluded."
        else
            __M.check.pkgs --standalone-call
        fi
    elif [[ "${only_sys}" == true ]]; then
        if [[ "${skip_pkgs}" == true ]]; then
            __logger.warn "\b(pkgs) check: excluded."
        fi
        if [[ -n "${exclude_args}" ]]; then
            __M.check.sys --standalone-call "${exclude_args}"
        else
            __M.check.sys --standalone-call
        fi
    else
        __logger.info "checking requirements ..."
        if [[ -n "${exclude_args}" ]]; then
            __M.check.sys "${exclude_args}"
        else
            __M.check.sys
        fi
        if [[ "${skip_pkgs}" == true ]]; then
            __logger.warn "\b(pkgs) check: excluded."
        else
            __M.check.pkgs
        fi
        __logger.info "checking requirements ... done."
    fi
}

_M.export.sync () {
    _M.export.check --only-sys
    __logger.info "updating and synchronizing the system ..."
    if ! sudo pacman -Syu --noconfirm; then
        __logger.error "failed to update system packages with 'pacman'."
        return 1
    fi
    if ! paru -Syu --noconfirm; then
        __logger.error "failed to update AUR packages with 'paru'."
        return 1
    fi
    __logger.info "updating and synchronizing the system ... done."
}

_M.export.init () {
    if sudo -v; then
        __logger.success "\b(sudo) verification: passed."
    else
        __logger.error "\b(sudo) verification: failed."
        return 1
    fi
}

_M.export.install () {
    __logger.info "installing archlinuxarm ..."
    if [[ $# -eq 0 ]]; then
        __M.install.setup
        __logger.info "installing archlinuxarm ... done. [ʘ‿ʘ]"
        return 0
    fi
    while [[ $# -gt 0 ]]; do
        case "${1}" in
            --setup)
                __M.install.setup
                shift
                ;;
            --post)
                __M.install.post
                shift
                ;;
            *)
                __logger.error "unknown option '${1}' in _M.export.install."
                return 1
                ;;
        esac
    done
    __logger.info "installing archlinuxarm ... done. [ʘ‿ʘ]"
}

_M.main () {
    if [[ $# -eq 0 ]]; then
        _M.export.init
        return 0
    fi
    case "${1}" in
        -h|--help|help)
            _M.export.help
            shift
            ;;
        init)
            _M.export.init
            shift
            ;;
        sync)
            _M.export.sync
            shift
            ;;
        check)
            shift
            _M.export.check "$@"
            ;;
        install)
            shift
            _M.export.install "$@"
            ;;
        *)
            __logger.error "unknown option or command '${1}' in _M.main."
            __logger.info "use 'bash ${SCRIPT_NAME} help' for usage information."
            return 1
            ;;
    esac
}

_M.main "$@"
