#!/bin/bash
set -euo pipefail

THIS_SCRIPT=$0

function errcho
{
    echo "$@" >&2
}

function fail
{
    [[ $# -gt 0 ]] && errcho "fatal: $@" || errcho 'unspecified fatal error'
    exit 1
}

function usage_exit
{
    [[ $# -gt 0 ]] && errcho "bad usage: $@"
    errcho
    errcho "usage: $THIS_SCRIPT <volume size> <volume path>"
    errcho
    errcho "volume size:    the disk image size in bytes."
    errcho "                Optional suffixes k or K (kilobyte, 1024) M (megabyte, 1024k) and G (gigabyte, 1024M) and T (terabyte, 1024G) are supported.  b is ignored."
    exit 2
}

function info
{
    echo "$@"
}

function debug
{
    #echo "$@"
    :
}

function get_packages
{
    local list_file="${THIS_SCRIPT}.packages.txt"
    [[ -f "$list_file" ]] || fail "Package list file '$list_file' not found"
    local result=""
    local package
    while read -r package
    do
        result+=",${package}"
    done <"$list_file"
    echo ${result:1}
}

[[ $# -eq 2 ]] || usage_exit "2 parameters expected, got $#"
VOL_SIZE="$1"
TGT_FILE="$2"

[[ ! -e "$TGT_FILE" ]] || fail "'$TGT_FILE' already exists"
TGT_FILE_PARENT=$(dirname "$TGT_FILE")
[[ -d "$TGT_FILE_PARENT" ]] || fail "'$TGT_FILE_PARENT' folder does not exists"

#####
# Create and attach qcow2 file

info "Creating $VOL_SIZE qcow2 volume at '$TGT_FILE'"
qemu-img create -q -f qcow2 "$TGT_FILE" "$VOL_SIZE"

info "Loading nbd kernel module"
modprobe nbd max_part=16

info "Finding free nbd block device"
let i=0 || true
while [[ -e "/dev/nbd${i}" ]] && lsof "/dev/nbd${i}" >/dev/null
do
    debug "'/dev/nbd${i}' already in use"
    let ++i
    debug "try '/dev/nbd${i}'"
done

NBD_DEV="/dev/nbd${i}"
[[ -e "$NBD_DEV" ]] || fail "No free nbd device"

info "Connecting '$TGT_FILE' to '$NBD_DEV'"
qemu-nbd --connect="$NBD_DEV" "$TGT_FILE"

#####
# Partition and format qcow2 disk

info "Creating partition"
sfdisk --quiet "$NBD_DEV" <<<'type=83, bootable'
PART_DEV="${NBD_DEV}p1"
[[ -e "$PART_DEV" ]] || fail "Expected partition '$PART_DEV' not found"

info "Formating partition"
mkfs.ext4 -q "$PART_DEV"

#####
# Mount partition

MOUNT_DIR=$(mktemp -d --suffix='.mount')
[[ "${#MOUNT_DIR}" -gt 1 ]] || fail "Unexpected MOUNT_DIR value '${MOUNT_DIR}'"
info "Mounting '$PART_DEV' to '$MOUNT_DIR'"
mount -o noatime,nodiratime "$PART_DEV" "$MOUNT_DIR"

#####
# Debootstraping

function last_line
{
    local line
    local lastlen=0
    local i
    while read -r line
    do
        echo -ne "\r${line}"
        for ((i=${#line}; i<lastlen; ++i))
        do
            echo -n ' '
        done
        lastlen=${#line}
    done
    echo
}

PACKAGES=$(get_packages)
info "Lauching debootstrap process"
debootstrap --arch amd64 --include="$PACKAGES" bullseye "${MOUNT_DIR}" http://ftp.fr.debian.org/debian/ | last_line

#####
# Configuring target system

mkdir -m 0700 "${MOUNT_DIR}/root/.ssh"
AUTH_KEYS="${MOUNT_DIR}/root/.ssh/authorized_keys"

if [[ -f "${HOME}/.ssh/authorized_keys" ]]
then
    info "Copying current user SSH authorized_keys"
    cp "${HOME}/.ssh/authorized_keys" "${AUTH_KEYS}"
fi

for idfile in ${HOME}/.ssh/id_*.pub
do
    [[ -f "$idfile" ]] || continue
    info "Copying '$idfile' SSH to authorized_keys"
    cat "$idfile" >> "${AUTH_KEYS}"
done
unset idfile

if [[ -f "$AUTH_KEYS" ]]
then
    chown root:root "$AUTH_KEYS"
    chmod 0600 "$AUTH_KEYS"
fi

#####
# Fix boot process

mount --bind /dev "${MOUNT_DIR}/dev"
mount --bind /sys "${MOUNT_DIR}/sys"
mount --bind /proc "${MOUNT_DIR}/proc"

info "Enable serial console"
chroot "$MOUNT_DIR" systemctl enable serial-getty@ttyS0.service

#set boot drive by uuid
info "Configuring '${MOUNT_DIR}/etc/fstab'"
DISK_UUID=$(blkid --match-tag UUID --output value $PART_DEV)
echo '# <file system> <mount point>   <type>  <options>       <dump>  <pass>' > "${MOUNT_DIR}/etc/fstab"
echo "UUID=\"${DISK_UUID}\" / ext4 noatime,nodiratime,errors=remount-ro 0 1" >> "${MOUNT_DIR}/etc/fstab"

info "Configuring grub"
#FIXME: too error prone as we comment out at the same time we insert the new value, which would insert nothing if nothing to comment out
#set GRUB_CMDLINE_LINUX_DEFAULT="console=tty0 console=ttyS0"
sed -i -E 's/^(GRUB_CMDLINE_LINUX_DEFAULT=.*)$/#\1\nGRUB_CMDLINE_LINUX_DEFAULT="console=tty0 console=ttyS0"/' "${MOUNT_DIR}/etc/default/grub"
#set GRUB_TERMINAL="serial console"
if grep -qE '^GRUB_TERMINAL' "${MOUNT_DIR}/etc/default/grub"
then
    sed -i -E 's/^(GRUB_TERMINAL=.*)$/#\1\nGRUB_TERMINAL="serial console"/' "${MOUNT_DIR}/etc/default/grub"
else
    sed -i -E 's/^(#GRUB_TERMINAL=.*)$/\1\nGRUB_TERMINAL="serial console"/' "${MOUNT_DIR}/etc/default/grub"
fi
chroot "$MOUNT_DIR" update-grub2
chroot "$MOUNT_DIR" grub-install "${NBD_DEV}"

info "Unmounting '${MOUNT_DIR}'"
umount "${MOUNT_DIR}/proc"
umount "${MOUNT_DIR}/sys"
umount "${MOUNT_DIR}/dev"
umount "${MOUNT_DIR}"

info "Detaching '${NBD_DEV}'"
qemu-nbd -d "${NBD_DEV}"
