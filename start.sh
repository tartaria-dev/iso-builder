#!/usr/bin/env bash

_SCRIPTDIR=$(dirname "$0")
SQUASHFS_CTR_IMG=${1:-$SQUASHFS_CTR_IMG}
OUT_DIR=${2:-./out}
ISO_NAME=${3:-${ISO_NAME:-tartaria}}

if [ "$EUID" -ne 0 ]; then
  echo "This script must be ran as root."
  exit 1
elif [ -z $1 ] && [ -z $SQUASHFS_CTR_IMG ]; then
  echo -e "You need to specify an OCI image.\nExample: ${0} docker.io/archlinux/archlinux:latest"
  exit 1
elif ! which podman rsync &>/dev/null; then
  echo -e "This script requires both podman and rsync to run. Please install the missing packages via your system's package manager, and then run this script again."
  exit 1
fi

set -ouex pipefail

# These 2 functions help group sections in github's CI
function github-step() {
  set -euo pipefail
  local command="$*"
  echo "::group::$*"
}
function github-step-end() {
  echo "::endgroup::"
}


fail_invalid_image() {
  echo -e "\nThe image \"${SQUASHFS_CTR_IMG}\" failed to be pulled."
  exit 1
}

# Make sure the image exists. If not, pull it
podman image exists "${SQUASHFS_CTR_IMG}" || podman pull "${SQUASHFS_CTR_IMG}" || fail_invalid_image

# Create container from image and mount it to modify its rootfs non-destructively
CONTAINER_ID=$(podman create "${SQUASHFS_CTR_IMG}")
trap "echo -e 'Cleaning up podman images\n' && podman rm -f ${CONTAINER_ID}" EXIT
SQUASHFS_CTR_IMAGE_MOUNTPOINT=$(podman mount ${CONTAINER_ID})

# podman-chroot function to run commands within the OCI
function podman-chroot(){
  set -euo pipefail
  local command="$1"
  podman run --rm -it --privileged \
    --no-hostname --no-hosts \
    --security-opt label=type:unconfined_t \
    --tmpfs /tmp:rw \
    --tmpfs /run:rw \
    --volume $_SCRIPTDIR:/app \
    --rootfs $SQUASHFS_CTR_IMAGE_MOUNTPOINT \
    /usr/bin/bash -c "$command"
}

github-step "System Setup"

# configure liveuser
podman-chroot 'sed -i "/vt = 1/a \\\n[initial_session]\ncommand = \"niri-session\"\nuser = \"liveuser\"" /etc/greetd/config.toml'
podman-chroot "echo 'polkit.addRule(function(action, subject) { if (subject.user == \"liveuser\") { return polkit.Result.YES; } });' | tee /etc/polkit-1/rules.d/49-liveuser.rules > /dev/null"
podman-chroot "sed -i '1i spawn-sh-at-startup \"bootc-installer\"' /usr/share/tartaria/cherries/dot_config/niri/config.kdl"

# create temp build user
podman-chroot 'useradd -U builder'
podman-chroot 'mkdir -p /etc/sudoers.d /buildhome && echo "builder ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/builder'
podman-chroot 'chown builder:builder /buildhome'

# install build pkgs
podman-chroot 'pacman -S --noconfirm --needed sudo ninja meson blueprint-compiler mutter go >/dev/null'

# remove usrlocal symlink, replace with dir
sudo rm -f $SQUASHFS_CTR_IMAGE_MOUNTPOINT/usr/local
sudo mkdir -p $SQUASHFS_CTR_IMAGE_MOUNTPOINT/usr/local/bin

# clone bootc-installer and install it
podman-chroot 'runuser -u builder -- bash -c "git clone --quiet --recurse-submodules -b latest-dev --depth 1 https://github.com/tuna-os/bootc-installer /buildhome/bootc-installer"'
podman-chroot 'runuser -u builder -- bash -c "cd /buildhome/bootc-installer && git apply /app/patches/force-sudo.patch && meson setup build --prefix=/usr --reconfigure && ninja -C build && sudo ninja -C build install"'

# clone fisherman and install it to /usr/local/bin/fisherman
podman-chroot 'runuser -u builder -- bash -c "git clone --quiet https://github.com/projectbluefin/fisherman /buildhome/fisherman && cd /buildhome/fisherman && git switch --detach 35c8f6f"'
podman-chroot 'runuser -u builder -- bash -c "cd /buildhome/fisherman/fisherman && git apply /app/patches/fisherman-var-tmp-fix.patch GOCACHE=/buildhome/gocache GOPATH=/buildhome/gopath GOPROXY=off go build -o /buildhome/fisherman/fisherman-bin ./cmd/fisherman && sudo install -Dm755 /buildhome/fisherman/fisherman-bin /usr/local/bin/fisherman"'

# cleanup
podman-chroot 'userdel builder && rm -rf /buildhome /etc/sudoers.d'
podman-chroot 'pacman -Rns --noconfirm ninja meson blueprint-compiler go'

# install/remove some pkgs
podman-chroot 'pacman -Rns --noconfirm gnome-keyring valent mkosi flatpak cups cups-browsed hplip samba smbclient tuned tuned-ppd ddcutil fprintd gpu-screen-recorder ttf-arphic-uming ttf-baekmuk wqy-microhei ttf-croscore ttf-droid gnu-free-fonts powertop libva-intel-driver bazaar flatseal'
podman-chroot 'pacman -S --noconfirm --needed firefox fuse-overlayfs'

# create bootc-installer conf dir
podman-chroot 'mkdir -p /etc/bootc-installer'

# copy distro logo to icon dir
podman-chroot 'cp /usr/share/pixmaps/tartaria-text-logo.svg /usr/share/icons/default-icons-grey-dark/apps/scalable/distributor-logo-tartaria.svg'

# remove unecessary files
podman-chroot 'rm -rf /usr/lib/subsystem/rootfs/rootfs.dsk /usr/lib/flatpak-sysapps/flatpak-sysapps.dsk'

# add installer recipe
podman-chroot 'cp /app/recipe.json /etc/bootc-installer/recipe.json'
podman-chroot "sed -i 's/TAG/${ISO_NAME#*-}/g' /etc/bootc-installer/recipe.json"

# configure bootloader/composefs in recipe
if [[ "$ISO_NAME" == *mahleb || "$ISO_NAME" == *saffron ]]; then
  podman-chroot "sed -i 's/BOOTLOADER/systemd/g' /etc/bootc-installer/recipe.json"
  podman-chroot "sed -i 's/COMPOSEFS/true/g' /etc/bootc-installer/recipe.json"
else
  podman-chroot "sed -i 's/BOOTLOADER/grub2/g' /etc/bootc-installer/recipe.json"
  podman-chroot "sed -i 's/COMPOSEFS/false/g' /etc/bootc-installer/recipe.json"
fi

# Add contents from skel to /etc/skel
rsync -rltDxv $_SCRIPTDIR/skel/ $SQUASHFS_CTR_IMAGE_MOUNTPOINT/etc/skel/

# We create a /var/tmp directory that ISN'T a tmpfs, and we set podman's storage driver to vfs.
# We also set the timezone to UTC, and remove a possible existing /etc/machine-id to prevent any weirdness with systemd-firstboot.
podman-chroot 'ln -sf /usr/share/zoneinfo/UTC /etc/localtime && mkdir -p /var/tmp'

# Create tmpfiles.d entry for systemd-resolved and enable it. 
# We will remove /etc/resolv.conf in build_iso.sh, as if we try to do so here, it won't let us. Podman currently manages /etc/resolv.conf through a mountpoint.
podman-chroot 'systemctl enable systemd-resolved.service'
podman-chroot 'echo "L /etc/resolv.conf - - - - ../run/systemd/resolve/stub-resolv.conf" | tee /usr/lib/tmpfiles.d/resolved.conf'

# Disable zram-generator as zram breaks hard under an ISO environment
podman-chroot 'echo "# Disabled for live sessions" > /usr/lib/systemd/zram-generator.conf'
podman-chroot 'echo "# Disabled for live sessions" > /etc/systemd/zram-generator.conf'

github-step-end

github-step "Load image into ISO"

# original approach from the repo this was forked from is incredibly ineffecient in terms of space
# so now we have whatever this is

# podman refuses to work with vfs for whatever reason, so fuse-overlayfs it is
podman-chroot 'cat > /etc/containers/storage.conf <<EOF
[storage]
driver = "overlay"

[storage.options.overlay]
mount_program = "/usr/bin/fuse-overlayfs"
EOF'

# unmount, commit, remove old base image
podman unmount ${CONTAINER_ID}
podman commit ${CONTAINER_ID} iso-base:latest
podman rm ${CONTAINER_ID}
podman rmi $SQUASHFS_CTR_IMG

# reset vars
SQUASHFS_CTR_IMG="iso-base:latest"
CONTAINER_ID=$(podman create "${SQUASHFS_CTR_IMG}")
SQUASHFS_CTR_IMAGE_MOUNTPOINT=$(podman mount ${CONTAINER_ID})

# re-arm trap
trap "echo -e 'Cleaning up podman images\n' && podman rm -f ${CONTAINER_ID}" EXIT

# pull image to ISO
podman-chroot "podman pull ghcr.io/tartaria-dev/tartaria:${ISO_NAME#*-}"

github-step-end

github-step "Create Live User"

## Create liveuser & its home directory. Also install sudo and give liveuser sudo abilities
podman-chroot "pacman -Sy --needed --noconfirm sudo && \
  cat >> /etc/sudoers <<EOF
liveuser      ALL=(ALL:ALL) NOPASSWD: ALL
EOF
"

podman-chroot "useradd -UG wheel -d /var/home/liveuser liveuser && \
[ -d /var/home ] || mkdir -p /var/home && \
cp -r /etc/skel /var/home/liveuser && \
passwd -d liveuser"

# For some reason chowning /var/home/liveuser doesn't work here? We'll do it at boot with a systemd service
podman-chroot "cat > /usr/lib/systemd/system/liveuser-homedir.service <<EOF
[Unit]
Description=Ensure liveuser home directory has proper permissions

[Service]
Type=oneshot
ExecStart=chown -R liveuser:liveuser /var/home/liveuser

[Install]
WantedBy=sysinit.target
EOF
"
podman-chroot "systemctl enable liveuser-homedir.service"

github-step-end

github-step "Build initramfs"

# Build an initramfs for the resulting ISO to use. We will need dracut.
# Your image should have a kernel inside of it. If it doesn't, you will need to install one using custom_pre_hooks. 
# It is recommended that you include a kernel inside of an image instead.
podman-chroot "pacman -Sy --needed --noconfirm dracut parted"
podman-chroot "[ -d /var/roothome ] || mkdir -p /var/roothome"
echo "Building initramfs"
podman-chroot 'kver=$(find /usr/lib/modules -maxdepth 1 -printf "%P" | head -1) DRACUT_NO_XATTR=1 && dracut \
    --kver="$kver" \
    --zstd \
    --reproducible \
    --no-hostonly \
    --no-hostonly-cmdline \
    --add "dmsquash-live dmsquash-live-autooverlay" \
    --filesystems "iso9660 vfat" \
    --force-drivers "usb_storage uas xhci_pci ahci" \
    --force \
    /live-initramfs.img'

github-step-end

github-step "Cleanup"

# Since we created /var/tmp and it isn't a tmpfs, we need to remove everything inside of it.
podman-chroot "rm -rf /var/tmp/*"

github-step-end

# Build the iso
[ -d "$OUT_DIR" ] || mkdir -p "$OUT_DIR" && \
podman run \
    --rm \
    -it \
    --privileged \
    --security-opt label=type:unconfined_t \
    --env ISO_ENVIRONMENT=true \
    --env GRUB_FILE_PATH=/grub.cfg \
    --env ISO_NAME="${ISO_NAME}" \
    --env SQUASHFS_CTR_IMAGE_MOUNTPOINT="${SQUASHFS_CTR_IMAGE_MOUNTPOINT}" \
    -v "$_SCRIPTDIR"/grub.cfg:/grub.cfg:ro \
    -v "$_SCRIPTDIR"/build_iso.sh:/build_iso.sh:ro \
    -v "$OUT_DIR":/out \
    -v "${SQUASHFS_CTR_IMAGE_MOUNTPOINT}":/rootfs \
    quay.io/fedora/fedora:42 /build_iso.sh
