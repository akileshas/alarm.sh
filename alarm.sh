#!/usr/bin/env bash

set -euo pipefail

readonly OS=$(source /etc/os-release 2>/dev/null && echo "${ID}" || echo "unknown")
readonly USER=$(whoami)
readonly HOST=$(hostnamectl hostname)
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_NAME="$(basename "${0}")"
readonly INPUT_SIGN=">>>"
readonly FZF_DEFAULT_OPTS=""
readonly FZF_WRAP_SIGN="↪ "
readonly FZF_PROMPT="${INPUT_SIGN} disk to install archlinuxarm: "
readonly LOGGER_TEXT_SHADE="\033[0m"
readonly LOGGER_LOG_SHADE="\033[1;34m"
readonly LOGGER_INFO_SHADE="\033[0;32m"
readonly LOGGER_WARN_SHADE="\033[1;33m"
readonly LOGGER_ERROR_SHADE="\033[1;31m"
readonly ARCHLINUXARM_REPO="http://os.archlinuxarm.org/os"
readonly ARCHLINUXARM_PKG="ArchLinuxARM-rpi-aarch64-latest.tar.gz"
readonly ARCHLINUXARM="${ARCHLINUXARM_REPO}/${ARCHLINUXARM_PKG}"
readonly LINUX_RPI_REPO="http://mirror.archlinuxarm.org/aarch64/core"
readonly MOUNTPOINT="/mnt/alarm"
readonly STAGING_DIR="/tmp/alarm"
readonly APK_DIR="${STAGING_DIR}/apk"
readonly LINUX_RPI_DIR="${STAGING_DIR}/linux-rpi"
readonly LINUX_RPI_APK_DIR="${LINUX_RPI_DIR}/apk"
readonly LINUX_RPI_EXTRACT_DIR="${LINUX_RPI_DIR}/extract"
readonly ARCHLINUXARM_FS="${APK_DIR}/${ARCHLINUXARM_PKG}"

DISK_DEV=""
DISK_PART_BOOT=""
DISK_PART_ROOT=""
LINUX_RPI=""
LINUX_RPI_PKG=""
LINUX_RPI_PKG_BASENAME=""
LINUX_RPI_KERNEL=""
LINUX_RPI_KERNEL_EXTRACT=""

__logger.log () {
    echo -e "${LOGGER_LOG_SHADE}[log]${LOGGER_TEXT_SHADE} $*" >&2
}

__logger.info () {
    echo -e "${LOGGER_INFO_SHADE}[info]${LOGGER_TEXT_SHADE} $*" >&2
}

__logger.warn () {
    echo -e "${LOGGER_WARN_SHADE}[warn]${LOGGER_TEXT_SHADE} $*" >&2
}

__logger.err () {
    echo -e "${LOGGER_ERROR_SHADE}[err]${LOGGER_TEXT_SHADE} $*" >&2
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
        if [[ "${exclude}" == "${item}" ]]; then
            return 0
        fi
    done
    return 1
}

__util.install () {
    local pkg="${1}"
    local confirm
    read -rp "${INPUT_SIGN} do you want to install '${pkg}'? [y/N]: " confirm
    confirm="${confirm,,}"
    if [[ "${confirm}" == "y" || "${confirm}" == "yes" ]]; then
        __logger.log "installing '${pkg}' ..."
        if sudo pacman -S --needed --noconfirm "${pkg}"; then
            __logger.log "installing '${pkg}' ... done."
            return 0
        else
            __logger.err "failed to install '${pkg}'."
            return 1
        fi
    else
        __logger.err "'${pkg}' is required but not installed."
        return 1
    fi
}

__M.util.get_disk () {
    local disk
    local choice=$(lsblk -dno NAME,SIZE \
                 | awk '{
                     name=$1; size=$2
                     name_w=9; size_w=8
                     lpad_n=int((name_w-length(name))/2)
                     rpad_n=name_w-length(name)-lpad_n
                     lpad_s=int((size_w-length(size))/2)
                     rpad_s=size_w-length(size)-lpad_s
                     printf("[%*s%s%*s](%*s%s%*s)\n",
                         lpad_n,"",name,rpad_n,"",
                         lpad_s,"",size,rpad_s,"")
                 }' \
                 | fzf --bind="esc:ignore,ctrl-j:down,ctrl-k:up" \
                       --wrap-sign="${FZF_WRAP_SIGN}" \
                       --preview-window="up:wrap:60%" \
                       --prompt="${FZF_PROMPT}" \
                       --layout="default" \
                       --height=25 \
                       --ignore-case \
                       --border \
                       --wrap \
                       --preview="
                    disk=\$(echo {} | sed -E \"s/^\[ *([^ ]+) *\].*/\1/\")
                    lsblk -o NAME,MAJ:MIN,RM,SIZE,RO,TYPE,MOUNTPOINTS \"/dev/\$disk\"
                 ")
    if [[ -n "${choice}" ]]; then
        disk=$(echo "${choice}" | awk -F'[][]' '{print $2}' | xargs)
        echo "/dev/${disk}"
        return 0
    else
        echo "none"
        return 1
    fi
}

__M.util.get_linux_rpi_pkg () {
    local response
    if ! response=$(curl -fsSL "${LINUX_RPI_REPO}" 2>/dev/null); then
        __logger.err "failed to fetch index from '${LINUX_RPI_REPO}'."
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
    else
        echo "${pkgs}"
        return 0
    fi
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
                __logger.err "unknown option '${1}' in __M.util.cleanup"
                return 1
                ;;
        esac
    done
    __logger.log "cleaning up ..."
    if ! __util.is_excluded "umount" "${exclude_list[@]}"; then
        if ! sudo umount -R "${MOUNTPOINT}" 2>/dev/null; then
            __logger.err "failed to umount filesystems under '${MOUNTPOINT}'."
        else
            __logger.log "umounted all filesystems under '${MOUNTPOINT}'."
        fi
    fi
    __logger.log "cleaning up ... done."
}

__M.checker.sys () {
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
                __logger.err "unknown option '${1}' in __M.checker.sys"
                return 1
                ;;
        esac
    done
    if [[ "${standalone_call}" == true ]]; then
        __logger.log "checking system requirements ..."
    fi
    if __util.is_excluded "arch" "${exclude_list[@]}"; then
        __logger.warn "\b(arch) check: excluded."
    else
        if grep -qi "arch" /etc/os-release 2>/dev/null; then
            __logger.info "\b(arch) check: passed."
        else
            __logger.err "\b(arch) check: failed."
            __logger.err "supported only for 'archlinux' (detected: '${OS}')."
            return 1
        fi
    fi
    if __util.is_excluded "user" "${exclude_list[@]}"; then
        __logger.warn "\b(user) check: excluded."
    else
        if [[ "${USER}" == "alarm" ]]; then
            __logger.info "\b(user) check: passed."
        else
            __logger.err "\b(user) check: failed."
            __logger.err "user must be 'alarm' (detected: '${USER}')."
            return 1
        fi
    fi
    if __util.is_excluded "ping" "${exclude_list[@]}"; then
        __logger.warn "\b(ping) check: excluded."
    else
        if __util.ping "8.8.8.8"; then
            __logger.info "\b(ping) check: passed."
        else
            __logger.err "\b(ping) check: failed."
            __logger.err "no internet connection available."
            return 1
        fi
    fi
    if __util.is_excluded "paru" "${exclude_list[@]}"; then
        __logger.warn "\b(paru) check: excluded."
    else
        if command -v paru &>/dev/null; then
            __logger.info "\b(paru) check: passed."
        else
            __logger.err "\b(paru) check: failed."
            __logger.err "'paru' AUR helper is not installed."
            return 1
        fi
    fi
    if [[ "${standalone_call}" == true ]]; then
        __logger.log "checking system requirements ... done."
    fi
}

__M.checker.pkgs () {
    local standalone_call=false
    while [[ $# -gt 0 ]]; do
        case "${1}" in
            --standalone-call)
                standalone_call=true
                shift
                ;;
            *)
                __logger.err "unknown option '${1}' in __M.checker.pkgs"
                return 1
                ;;
        esac
    done
    local -A requirements=(
        ["aria2c"]="aria2"
        ["fzf"]="fzf"
        ["mkfs.vfat"]="dosfstools"
        ["mkfs.ext4"]="e2fsprogs"
        ["bsdtar"]="libarchive"
        ["awk"]="gawk"
        ["xargs"]="findutils"
        ["curl"]="curl"
        ["grep"]="grep"
        ["sort"]="coreutils"
        ["uniq"]="coreutils"
        ["wipefs"]="util-linux"
        ["parted"]="parted"
        ["du"]="coreutils"
        ["cut"]="coreutils"
        ["tar"]="tar"
        ["find"]="findutils"
        ["head"]="coreutils"
    )
    if [[ "${standalone_call}" == true ]]; then
        __logger.log "checking package requirements ..."
    fi
    local bin
    for bin in "${!requirements[@]}"; do
        local pkg="${requirements[${bin}]}"
        if command -v "${bin}" &>/dev/null; then
            __logger.info "\b(pkgs)(${bin}) check: passed."
        else
            __logger.err "\b(pkgs)(${bin}) check: failed."
            __logger.err "'${bin}' not found (required from package: ${pkg})."
            __util.install "${pkg}"
            if command -v "${bin}" &>/dev/null; then
                __logger.info "\b(pkgs)($bin) check: passed after installation."
            else
                __logger.err "\b(pkgs)($bin) check: failed."
                __logger.err "still '${bin}' not found after attempted installation."
                return 1
            fi
        fi
    done
    if [[ "${standalone_call}" == true ]]; then
        __logger.log "checking package requirements ... done."
    fi
}

__M.installer.setup () {
    local standalone_call=false
    while [[ $# -gt 0 ]]; do
        case "${1}" in
            --standalone-call)
                standalone_call=true
                shift
                ;;
            *)
                __logger.err "unknown option '${1}' in __M.installer.setup"
                return 1
                ;;
        esac
    done
    if [[ "${standalone_call}" == true ]]; then
        __logger.log "installing archlinuxarm ..."
    fi
    DISK_DEV="$(__M.util.get_disk)"
    if [[ "${DISK_DEV}" == "none" ]]; then
        __logger.err "no disk selected."
        return 1
    fi
    DISK_PART_BOOT="${DISK_DEV}p1"
    DISK_PART_ROOT="${DISK_DEV}p2"
    __logger.log "disk selected: ${DISK_DEV}."
    __logger.log "boot partition: ${DISK_PART_BOOT}."
    __logger.log "root partition: ${DISK_PART_ROOT}."
    __logger.log "creating staging directory ..."
    if ! mkdir -p "${STAGING_DIR}"; then
        __logger.err "failed to create staging directory: '${STAGING_DIR}'."
        return 1
    fi
    __logger.log "creating staging directory ... done."
    __logger.log "creating apk directory ..."
    if ! mkdir -p "${APK_DIR}"; then
        __logger.err "failed to create apk directory: '${APK_DIR}'."
        return 1
    fi
    __logger.log "creating apk directory ... done."
    if [[ -f "${ARCHLINUXARM_FS}" && -s "${ARCHLINUXARM_FS}" ]]; then
        __logger.warn "found cached archlinuxarm filesystem: '${ARCHLINUXARM_FS}' ($(du -h "${ARCHLINUXARM_FS}" | cut -f1))."
        if bsdtar -tf "${ARCHLINUXARM_FS}" &>/dev/null; then
            local confirm
            read -rp "${INPUT_SIGN} use cached archlinuxarm filesystem? [y/N]: " confirm
            confirm="${confirm,,}"
            if [[ "${confirm}" == "y" || "${confirm}" == "yes" ]]; then
                __logger.log "using cached archlinuxarm filesystem."
            else
                __logger.log "discarding cache ..."
                if ! rm -f "${ARCHLINUXARM_FS}"; then
                    __logger.err "failed to discard the cache."
                    return 1
                fi
                __logger.log "discarding cache ... done."
            fi
        else
            __logger.warn "cache is corrupted."
            __logger.log "discarding cache ..."
            if ! rm -f "${ARCHLINUXARM_FS}"; then
                __logger.err "failed to discard the cache."
                return 1
            fi
            __logger.log "discarding cache ... done."
        fi
    fi
    if [[ ! -f "${ARCHLINUXARM_FS}" ]]; then
        __logger.log "downloading archlinuxarm filesystem ..."
        if ! ( aria2c -x 16 -s 16 -k 1M \
                --dir="${APK_DIR}" \
                -o "${ARCHLINUXARM_PKG}" \
                "${ARCHLINUXARM}" ); then
            __logger.err "failed to download archlinuxarm filesystem."
            return 1
        fi
        __logger.log "downloading archlinuxarm filesystem ... done."
    fi
    if [[ "${USER}" == "root" ]]; then
        __logger.log "running as '${USER}' user."
    else
        __logger.log "getting sudo access ..."
        if sudo -v; then
            __logger.info "\b(sudo) verification: passed."
        else
            __logger.err "\b(sudo) verification: failed."
            return 1
        fi
        __logger.log "getting sudo access ... done."
    fi
    __logger.warn "disk selected: ${DISK_DEV}."
    local confirm
    read -rp "${INPUT_SIGN} wipe this disk and create new partition table? [y/N]: " confirm
    confirm="${confirm,,}"
    if [[ "${confirm}" != "y" && "${confirm}" != "yes" ]]; then
        __logger.err "disk wip cancelled."
        return 1
    fi
    __logger.log "wiping the disk ..."
    if ! ( sudo wipefs -a "${DISK_DEV}" && sudo parted -s "${DISK_DEV}" mklabel gpt ); then
        __logger.err "failed to wip the disk."
        return 1
    fi
    __logger.log "wiping the disk ... done."
    __logger.log "partitioning the disk ..."
    if ! ( sudo parted -s "${DISK_DEV}" \
                mkpart primary fat32 1MiB 1025MiB \
                set 1 boot on \
                set 1 esp on \
                mkpart primary ext4 1025MiB 100% ); then
        __logger.err "failed to partition disk."
        return 1
    fi
    __logger.log "partitioning the disk ... done."
    __logger.log "formatting boot partition ..."
    if ! sudo mkfs.vfat -F 32 "${DISK_PART_BOOT}"; then
        __logger.err "failed to format boot partition."
        return 1
    fi
    __logger.log "formatting boot partition ... done."
    __logger.log "formatting root partition ..."
    if ! sudo mkfs.ext4 -E lazy_itable_init=0,lazy_journal_init=0 -F "${DISK_PART_ROOT}"; then
        __logger.err "failed to format root partition."
        return 1
    fi
    __logger.log "formatting root partition ... done."
    __logger.log "creating root mount directory ..."
    if ! sudo mkdir -p "${MOUNTPOINT}"; then
        __logger.err "failed to create root mount directory: '${MOUNTPOINT}'."
        return 1
    fi
    __logger.log "creating root mount directory ... done."
    __logger.log "mounting root partition ..."
    if ! sudo mount "${DISK_PART_ROOT}" "${MOUNTPOINT}"; then
        __logger.err "failed to mount root partition."
        return 1
    fi
    __logger.log "mounting root partition ... done."
    __logger.log "creating boot mount directory ..."
    if ! sudo mkdir -p "${MOUNTPOINT}/boot"; then
        __logger.err "failed to create boot mount directory: '${MOUNTPOINT}/boot'."
        __M.util.cleanup --exclude=""
        return 1
    fi
    __logger.log "creating boot mount directory ... done."
    __logger.log "mounting boot partition ..."
    if ! sudo mount "${DISK_PART_BOOT}" "${MOUNTPOINT}/boot"; then
        __logger.err "failed to mount boot partition."
        __M.util.cleanup --exclude=""
        return 1
    fi
    __logger.log "mounting boot partition ... done."
    __logger.log "extracting archlinuxarm filesystem ..."
    if ! sudo bsdtar -xpf "${ARCHLINUXARM_FS}" -C "${MOUNTPOINT}"; then
        __logger.err "failed to extract archlinuxarm filesystem."
        __M.util.cleanup --exclude=""
        return 1
    fi
    __logger.log "extracting archlinuxarm filesystem ... done."
    __logger.log "removing u-boot ..."
    if ! sudo rm -rf "${MOUNTPOINT}/boot/"*; then
        __logger.err "failed to remove the u-boot."
        __M.util.cleanup --exclude=""
        return 1
    fi
    __logger.log "removing u-boot ... done."
    __logger.log "creating linux-rpi directories ..."
    if ! mkdir -p "${LINUX_RPI_APK_DIR}" "${LINUX_RPI_EXTRACT_DIR}"; then
        __logger.err "failed to create linux-rpi directories: '${LINUX_RPI_APK_DIR}', '${LINUX_RPI_EXTRACT_DIR}'."
        __M.util.cleanup --exclude=""
        return 1
    fi
    __logger.log "creating linux-rpi directories ... done."
    LINUX_RPI_PKG="$(__M.util.get_linux_rpi_pkg)"
    LINUX_RPI_PKG_BASENAME="${LINUX_RPI_PKG%.pkg.tar.*}"
    if [[ "${LINUX_RPI_PKG_BASENAME}" == "none" ]]; then
        __logger.err "no linux-rpi package found at '${LINUX_RPI_REPO}'."
        __M.util.cleanup --exclude=""
        return 1
    fi
    LINUX_RPI="${LINUX_RPI_REPO}/${LINUX_RPI_PKG}"
    LINUX_RPI_KERNEL="${LINUX_RPI_APK_DIR}/${LINUX_RPI_PKG}"
    LINUX_RPI_KERNEL_EXTRACT="${LINUX_RPI_EXTRACT_DIR}/${LINUX_RPI_PKG_BASENAME}"
    if [[ -f "${LINUX_RPI_KERNEL}" && -s "${LINUX_RPI_KERNEL}" ]]; then
        __logger.warn "found cached linux-rpi kernel package: '${LINUX_RPI_PKG}'."
        if tar -tf "${LINUX_RPI_KERNEL}" &>/dev/null; then
            local confirm
            read -rp "${INPUT_SIGN} use cached linux-rpi kernel package? [y/N]: " confirm
            confirm="${confirm,,}"
            if [[ "${confirm}" == "y" || "${confirm}" == "yes" ]]; then
                __logger.log "using cached linux-rpi kernel package."
            else
                __logger.log "discarding cache ..."
                if ! rm -f "${LINUX_RPI_KERNEL}"; then
                    __logger.err "failed to discard the cache."
                    __M.util.cleanup --exclude=""
                    return 1
                fi
                __logger.log "discarding cache ... done."
            fi
        else
            __logger.warn "cache is corrupted."
            __logger.log "discarding cache ..."
            if ! rm -f "${LINUX_RPI_KERNEL}"; then
                __logger.err "failed to discard the cache."
                __M.util.cleanup --exclude=""
                return 1
            fi
            __logger.log "discarding cache ... done."
        fi
    fi
    if [[ ! -f "${LINUX_RPI_KERNEL}" ]]; then
        __logger.log "downloading linux-rpi kernel ..."
        if ! ( aria2c -x 16 -s 16 -k 1M \
                --dir="${LINUX_RPI_APK_DIR}" \
                -o "${LINUX_RPI_PKG}" \
                "${LINUX_RPI}" ); then
            __logger.err "failed to download linux-rpi kernel."
            __M.util.cleanup --exclude=""
            return 1
        fi
        __logger.log "downloading linux-rpi kernel ... done."
    fi
    if [[ -d "${LINUX_RPI_KERNEL_EXTRACT}/boot" ]]; then
        __logger.warn "found cached extracted linux-rpi kernel '/boot' directory."
        if ls "${LINUX_RPI_KERNEL_EXTRACT}/boot/"kernel*.img &>/dev/null; then
            __logger.warn "found cached extracted linux-rpi kernel image."
            local confirm
            read -rp "${INPUT_SIGN} use cached extracted kernel image? [y/N]: " confirm
            confirm="${confirm,,}"
            if [[ "${confirm}" == "y" || "${confirm}" == "yes" ]]; then
                __logger.log "using cached extracted kernel image."
            else
                __logger.log "discarding cache ..."
                if ! rm -rf "${LINUX_RPI_KERNEL_EXTRACT}"; then
                    __logger.err "failed to discard the cache."
                    __M.util.cleanup --exclude=""
                    return 1
                fi
                __logger.log "discarding cache ... done."
            fi
        else
            __logger.warn "'boot/' exists but no kernel image found."
            __logger.log "discarding cache ..."
            if ! rm -rf "${LINUX_RPI_KERNEL_EXTRACT}"; then
                __logger.err "failed to discard the cache."
                __M.util.cleanup --exclude=""
                return 1
            fi
            __logger.log "discarding cache ... done."
        fi
    fi
    if [[ ! -d "${LINUX_RPI_KERNEL_EXTRACT}"
         || -z "$(find "${LINUX_RPI_KERNEL_EXTRACT}" -mindepth 1 -print -quit 2>/dev/null)" ]]; then
        __logger.log "creating extracting directory ..."
        if ! mkdir -p "${LINUX_RPI_KERNEL_EXTRACT}"; then
            __logger.err "failed to create extract directory: '${LINUX_RPI_KERNEL_EXTRACT}'."
            __M.util.cleanup --exclude=""
            return 1
        fi
        __logger.log "creating extracting directory ... done."
        __logger.log "extracting linux-rpi kernel package ..."
        if ! tar -xf "${LINUX_RPI_KERNEL}" -C "${LINUX_RPI_KERNEL_EXTRACT}"; then
            __logger.err "failed to extract linux-rpi kernel package."
            __M.util.cleanup --exclude=""
            return 1
        fi
        __logger.log "extracting linux-rpi kernel package ... done."
    fi
    local -a kernels
    mapfile -t kernels < <(find "${LINUX_RPI_KERNEL_EXTRACT}/boot" -maxdepth 1 -type f -name "kernel*.img" 2>/dev/null)
    if [[ ${#kernels[@]} -eq 0 ]]; then
        __logger.err "no kernel image found in extracted linux-rpi kernel package."
        __M.util.cleanup --exclude=""
        return 1
    fi
    __logger.log "found kernels: $(printf "'%s', " "${kernels[@]}" | sed 's/, $//')."
    __logger.log "copying kernel image ..."
    if ! sudo cp -rf "${LINUX_RPI_KERNEL_EXTRACT}/boot/"* "${MOUNTPOINT}/boot/"; then
        __logger.err "failed to copy kernel image."
        __M.util.cleanup --exclude=""
        return 1
    fi
    __logger.log "copying kernel image ... done."
    __logger.log "syncing filesystems ..."
    if ! sync; then
        __logger.err "failed to sync filesystems."
        __M.util.cleanup --exclude=""
        return 1
    fi
    __logger.log "syncing filesystems ... done."
    __logger.log "umounting filesystems ..."
    if ! sudo umount -R "${MOUNTPOINT}"; then
        __logger.err "failed to umount filesystems under '${MOUNTPOINT}'."
        return 1
    fi
    __logger.log "umounting filesystems ... done."
    if [[ "${standalone_call}" == true ]]; then
        __logger.log "installing archlinuxarm ... done."
    fi
}

__M.installer.post () {
    local standalone_call=false
    while [[ $# -gt 0 ]]; do
        case "${1}" in
            --standalone-call)
                standalone_call=true
                shift
                ;;
            *)
                __logger.err "unknown option '${1}' in __M.installer.post"
                return 1
                ;;
        esac
    done
    if [[ "${standalone_call}" == true ]]; then
        __logger.log "post-installing archlinuxarm ..."
        __logger.log "getting sudo access ..."
        if sudo -v; then
            __logger.info "\b(sudo) verification: passed."
        else
            __logger.err "\b(sudo) verification: failed."
            return 1
        fi
        __logger.log "getting sudo access ... done."
    fi
    __logger.log "initializing pacman keyring ..."
    if ! sudo pacman-key --init; then
        __logger.err "failed to initialize pacman keyring."
        return 1
    fi
    __logger.log "initializing pacman keyring ... done."
    __logger.log "populating pacman keyring with 'archlinuxarm' keys ..."
    if ! sudo pacman-key --populate archlinuxarm; then
        __logger.err "failed to populate pacman keyring with 'archlinuxarm' keys."
        return 1
    fi
    __logger.log "populating pacman keyring with 'archlinuxarm' keys ... done."
    __logger.log "checking for conflicting packages ..."
    local -a conflicts=()
    if pacman -Q linux-aarch64 &>/dev/null; then
        conflicts+=("linux-aarch64")
    fi
    if pacman -Q uboot-raspberrypi &>/dev/null; then
        conflicts+=("uboot-raspberrypi")
    fi
    __logger.log "checking for conflicting packages ... done."
    if [[ ${#conflicts[@]} -eq 0 ]]; then
        __logger.log "no conflicting packages found."
    else
        __logger.warn "conflicting packages detected: $(printf "'%s', " "${conflicts[@]}" | sed 's/, $//')."
        local confirm
        read -rp "${INPUT_SIGN} remove the conflict packages [y/N]: " confirm
        confirm="${confirm,,}"
        if [[ "${confirm}" == "y" || "${confirm}" == "yes" ]]; then
            __logger.log "removing conflicting packages ..."
            if ! sudo pacman -R --noconfirm "${conflicts[@]}"; then
                __logger.err "failed to remove the conflict packages."
                return 1
            fi
            __logger.log "removing conflicting packages ... done."
        else
            __logger.err "removal of conflicting packages cancelled."
            return 1
        fi
    fi
    __logger.log "installing linux-rpi kernel ..."
    if ! sudo pacman -Syyu --overwrite "/boot/*" --noconfirm linux-rpi; then
        __logger.err "failed to install linux-rpi kernel."
        return 1
    fi
    __logger.log "installing linux-rpi kernel ... done."
    __logger.log "updating the system ..."
    if ! sudo pacman -Syyu; then
        __logger.err "failed to update the system."
        return 1
    fi
    __logger.log "updating the system ... done."
    if [[ "${standalone_call}" == true ]]; then
        __logger.log "post-installing archlinuxarm ... done."
    fi
}

_M.export.init () {
    __logger.log "getting sudo access ..."
    if sudo -v; then
        __logger.info "\b(sudo) verification: passed."
    else
        __logger.err "\b(sudo) verification: failed."
        return 1
    fi
    _M.export.sync
    _M.export.check
    __logger.log "getting sudo access ... done."
}

_M.export.check () {
    if [[ $# -eq 0 ]]; then
        __logger.log "checking requirements ..."
        __M.checker.sys --exclude="user"
        __M.checker.pkgs
        __logger.log "checking requirements ... done."
        return 0
    fi
    local only_pkgs=false
    local only_sys=false
    local exclude_items=""
    local skip_pkgs=false
    while [[ $# -gt 0 ]]; do
        case "${1}" in
            --exclude=*)
                exclude_items="${1#--exclude=}"
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
                __logger.err "unknown option '${1}' in _M.export.check"
                return 1
                ;;
        esac
    done
    if [[ -n "${exclude_items}" ]]; then
        local -a exclude_list=()
        local -a filtered_exclude_list=()
        IFS=',' read -ra exclude_list <<< "${exclude_items}"
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
            exclude_items="${filtered_exclude_string%,}"
        else
            exclude_items=""
        fi
    fi
    if [[ "${only_pkgs}" == true && "${only_sys}" == true ]]; then
        __logger.err "cannot use '--only-pkgs' and '--only-sys' together."
        return 1
    fi
    if [[ "${only_pkgs}" == true ]]; then
        if [[ "${skip_pkgs}" == true ]]; then
            __logger.warn "\b(pkgs) check: excluded."
        else
            __M.checker.pkgs --standalone-call
        fi
    elif [[ "${only_sys}" == true ]]; then
        if [[ "${skip_pkgs}" == true ]]; then
            __logger.warn "\b(pkgs) check: excluded."
        fi
        if [[ -n "${exclude_items}" ]]; then
            __M.checker.sys --standalone-call --exclude="${exclude_items},user"
        else
            __M.checker.sys --standalone-call --exclude="user"
        fi
    else
        __logger.log "checking requirements ..."
        if [[ -n "${exclude_items}" ]]; then
            __M.checker.sys --exclude="${exclude_items},user"
        else
            __M.checker.sys --exclude="user"
        fi
        if [[ "${skip_pkgs}" == true ]]; then
            __logger.warn "\b(pkgs) check: excluded."
        else
            __M.checker.pkgs
        fi
        __logger.log "checking requirements ... done."
    fi
}

_M.export.sync () {
    _M.export.check --only-sys
    __logger.log "synchronizing the system ..."
    if ! sudo pacman -Syy; then
        __logger.err "failed to synchronize the 'pacman' packages."
        return 1
    fi
    if ! paru -Syy; then
        __logger.err "failed to synchronize the 'AUR' packages with 'paru'."
        return 1
    fi
    __logger.log "synchronizing the system ... done."
}

_M.export.install () {
    if [[ $# -eq 0 ]]; then
        __logger.log "installing archlinuxarm ..."
        _M.export.init
        __M.installer.setup
        __logger.log "installing archlinuxarm ... done. [ʘ‿ʘ]"
        return 0
    fi
    while [[ $# -gt 0 ]]; do
        case "${1}" in
            --setup)
                __logger.log "installing archlinuxarm ..."
                _M.export.init
                __M.installer.setup
                __logger.log "installing archlinuxarm ... done. [ʘ‿ʘ]"
                shift
                ;;
            --post)
                __logger.log "post-installing archlinuxarm ..."
                __M.checker.sys --exclude=""
                __M.installer.post
                __logger.log "post-installing archlinuxarm ... done. [ʘ‿ʘ]"
                shift
                ;;
            *)
                __logger.err "unknown option '${1}' in _M.export.install"
                return 1
                ;;
        esac
    done
}

_M.export.help () {
    cat << EOF | sed 's/\\n/\n/g'
\n'${SCRIPT_NAME}' - ArchLinux ARM build script for Raspberry Pi.\n
usage:
    bash ${SCRIPT_NAME} [options]
    bash ${SCRIPT_NAME} [command] [options]\n
options:
    -h, --help                  show help message.\n
commands:
    init                        initialize system (sync packages and run checks).
    sync                        sync pacman and AUR package databases.
    check [options]             run system and package requirement checks.
        --only-sys              check only system requirements (arch, user, ping, paru).
        --only-pkgs             check only package requirements and install missing.
        --exclude=items         exclude checks (comma-separated: 'arch,user,ping,paru,pkgs').
    install [options]           install archlinux arm to selected disk.
        --setup                 run only main installation process.
        --post                  run only post-installation steps.\n
EOF
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
            __logger.err "unknown option or command '${1}' in _M.main"
            __logger.err "use 'bash ${SCRIPT_NAME} help' for usage information."
            return 1
            ;;
    esac
}

_M.main "$@"
