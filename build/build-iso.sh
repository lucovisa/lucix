#!/usr/bin/env bash
# =============================================================================
# Lucix — сборщик ISO. Этап 1: загрузочная Ubuntu 26.04 + Cinnamon (live).
#
# Запуск (от root):   sudo -E ./build/build-iso.sh
# Версия:             LUCIX_VERSION=2026.10.22-alpha1 sudo -E ./build/build-iso.sh
# Результат:          out/lucix-<версия>-amd64.iso  (+ .sha256)
#
# Что делает:
#   1. debootstrap  -> минимальная Ubuntu в папке chroot
#   2. apt          -> ставит Cinnamon, ядро, casper (live-загрузка)
#   3. overlay/     -> копирует наши конфиги поверх системы
#   4. mksquashfs   -> сжимает систему в filesystem.squashfs
#   5. grub-mkrescue-> собирает гибридную ISO (BIOS + UEFI)
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT_DIR/build/config.env"

LUCIX_VERSION="${LUCIX_VERSION:-$(date -u +%Y.%m.%d)-dev}"
WORK="${WORK_DIR:-/mnt/lucix-work}"
CHROOT="$WORK/chroot"
ISO_DIR="$WORK/iso"
OUT_DIR="$ROOT_DIR/out"
ISO_NAME="lucix-${LUCIX_VERSION}-${ARCH}.iso"

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31m[x] %s\033[0m\n' "$*" >&2; exit 1; }

# ---------- проверки ----------
[[ $EUID -eq 0 ]] || die "Запусти от root: sudo -E $0"
[[ "$LUCIX_VERSION" =~ ^[A-Za-z0-9._-]+$ ]] || die "Версия может содержать только буквы, цифры, точку, дефис и _"
for cmd in debootstrap mksquashfs xorriso grub-mkrescue; do
  command -v "$cmd" >/dev/null || die "Не найдена команда '$cmd'. Установи: debootstrap squashfs-tools xorriso grub-pc-bin grub-efi-amd64-bin grub-common mtools"
done

# ---------- работа с chroot ----------
mount_chroot() {
  mkdir -p "$CHROOT"/{dev/pts,proc,sys,run}
  mount --bind /dev "$CHROOT/dev"
  mount --bind /dev/pts "$CHROOT/dev/pts"
  mount -t proc proc "$CHROOT/proc"
  mount -t sysfs sysfs "$CHROOT/sys"
  mount -t tmpfs tmpfs "$CHROOT/run"
}

umount_chroot() {
  [[ -d "$CHROOT" ]] || return 0
  local m
  for m in run sys proc dev/pts dev; do
    umount -lf "$CHROOT/$m" 2>/dev/null || true
  done
}
trap umount_chroot EXIT

chroot_run() {
  chroot "$CHROOT" /usr/bin/env -i \
    HOME=/root TERM=xterm LC_ALL=C \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    DEBIAN_FRONTEND=noninteractive \
    "$@"
}

# Рабочий DNS внутри chroot (некоторые пакеты превращают resolv.conf в битую ссылку)
ensure_dns() {
  if [[ -L "$CHROOT/etc/resolv.conf" || ! -s "$CHROOT/etc/resolv.conf" ]]; then
    rm -f "$CHROOT/etc/resolv.conf"
    printf 'nameserver 1.1.1.1\nnameserver 9.9.9.9\n' > "$CHROOT/etc/resolv.conf"
  fi
}

apt_chroot() {
  ensure_dns
  chroot_run apt-get -y \
    -o Dpkg::Options::=--force-confdef \
    -o Dpkg::Options::=--force-confold \
    "$@"
}

# Читает список пакетов без комментариев и пустых строк
read_list() {
  grep -vE '^[[:space:]]*(#|$)' "$1" | sed 's/[[:space:]]*#.*$//; s/[[:space:]]*$//'
}

# ---------- 0. подготовка ----------
log "Lucix $LUCIX_VERSION ($LUCIX_STAGE) | Ubuntu $UBUNTU_VERSION ($UBUNTU_SUITE) | $ARCH"
umount_chroot
rm -rf "$WORK"
mkdir -p "$WORK" "$ISO_DIR/casper" "$ISO_DIR/boot/grub" "$ISO_DIR/.disk" "$OUT_DIR"

# ---------- 1. debootstrap ----------
log "1/6 debootstrap: базовая система"
DEBOOTSTRAP_SCRIPT=()
if [[ ! -e "/usr/share/debootstrap/scripts/$UBUNTU_SUITE" ]]; then
  warn "Хост не знает релиз '$UBUNTU_SUITE', использую сценарий gutsy"
  DEBOOTSTRAP_SCRIPT=(/usr/share/debootstrap/scripts/gutsy)
fi
debootstrap --arch="$ARCH" --variant=minbase \
  --components=main,restricted,universe,multiverse \
  --include=ubuntu-keyring,ca-certificates \
  "$UBUNTU_SUITE" "$CHROOT" "$UBUNTU_MIRROR" "${DEBOOTSTRAP_SCRIPT[@]}"

# ---------- 2. apt-источники и окружение ----------
log "2/6 Настройка apt и окружения chroot"
rm -f "$CHROOT/etc/apt/sources.list"
mkdir -p "$CHROOT/etc/apt/sources.list.d"
cat > "$CHROOT/etc/apt/sources.list.d/ubuntu.sources" <<EOF
Types: deb
URIs: ${UBUNTU_MIRROR}
Suites: ${UBUNTU_SUITE} ${UBUNTU_SUITE}-updates ${UBUNTU_SUITE}-backports
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: ${UBUNTU_SECURITY_MIRROR}
Suites: ${UBUNTU_SUITE}-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF

echo 'Acquire::Retries "5";' > "$CHROOT/etc/apt/apt.conf.d/80lucix-build"
# Запрещаем службам стартовать внутри chroot
printf '#!/bin/sh\nexit 101\n' > "$CHROOT/usr/sbin/policy-rc.d"
chmod +x "$CHROOT/usr/sbin/policy-rc.d"
ensure_dns
mount_chroot

echo 'lightdm shared/default-x-display-manager select lightdm' | chroot_run debconf-set-selections

# ---------- 3. пакеты ----------
log "3/6 Установка пакетов"
apt_chroot update
apt_chroot full-upgrade --no-install-recommends

mapfile -t CORE < <(read_list "$ROOT_DIR/build/packages/core.list")
log "    core (${#CORE[@]} шт.): если здесь ошибка — какого-то пакета нет в Ubuntu $UBUNTU_VERSION"
apt_chroot install --no-install-recommends "${CORE[@]}"

mapfile -t EXTRAS < <(read_list "$ROOT_DIR/build/packages/extras.list")
log "    extras (${#EXTRAS[@]} шт.)"
: > "$OUT_DIR/skipped-packages.txt"
if ! apt_chroot install --no-install-recommends "${EXTRAS[@]}"; then
  warn "Пачкой не встало, ставлю по одному"
  for pkg in "${EXTRAS[@]}"; do
    if ! apt_chroot install --no-install-recommends "$pkg"; then
      warn "пропущен: $pkg"
      echo "$pkg" >> "$OUT_DIR/skipped-packages.txt"
    fi
  done
fi

# ---------- 4. наши настройки ----------
log "4/6 Overlay Lucix и финальная настройка"
cp -a --no-preserve=ownership "$ROOT_DIR/overlay/." "$CHROOT/"

cat > "$CHROOT/etc/lucix-release" <<EOF
NAME=${LUCIX_NAME}
VERSION=${LUCIX_VERSION}
STAGE=${LUCIX_STAGE}
BASE=Ubuntu ${UBUNTU_VERSION} LTS (${UBUNTU_SUITE})
EOF

# Локали: английская по умолчанию + русская
chroot_run locale-gen en_US.UTF-8 ru_RU.UTF-8
chroot_run update-locale LANG=en_US.UTF-8

# Пересобираем initramfs, чтобы в него попали casper.conf и наши настройки
chroot_run update-initramfs -u -k all

# systemd-resolved последним (он трогает resolv.conf)
mapfile -t LAST < <(read_list "$ROOT_DIR/build/packages/last.list")
apt_chroot install --no-install-recommends "${LAST[@]}" || warn "systemd-resolved не поставился"

# Список пакетов для будущего установщика
chroot_run dpkg-query -W --showformat='${Package}\t${Version}\n' > "$ISO_DIR/casper/filesystem.manifest"

# ---------- 5. уборка и ядро ----------
log "5/6 Уборка, вытаскиваем ядро и initrd, сжимаем систему"
chroot_run apt-get clean
rm -rf "$CHROOT"/var/lib/apt/lists/* "$CHROOT"/tmp/* "$CHROOT"/root/.bash_history
rm -f "$CHROOT/usr/sbin/policy-rc.d" "$CHROOT/etc/apt/apt.conf.d/80lucix-build"
: > "$CHROOT/etc/machine-id"
rm -f "$CHROOT/var/lib/dbus/machine-id"
rm -f "$CHROOT/etc/resolv.conf"
ln -s ../run/systemd/resolve/stub-resolv.conf "$CHROOT/etc/resolv.conf"

KERNEL="$(find "$CHROOT/boot" -maxdepth 1 -name 'vmlinuz-*' | sort -V | tail -n1)"
[[ -n "$KERNEL" ]] || die "В chroot не найдено ядро (vmlinuz-*)"
KVER="${KERNEL##*/vmlinuz-}"
INITRD="$CHROOT/boot/initrd.img-$KVER"
[[ -f "$INITRD" ]] || die "Не найден $INITRD"
log "    ядро: $KVER"
cp "$KERNEL" "$ISO_DIR/casper/vmlinuz"
cp "$INITRD" "$ISO_DIR/casper/initrd"
chmod 644 "$ISO_DIR/casper/vmlinuz" "$ISO_DIR/casper/initrd"

umount_chroot
mksquashfs "$CHROOT" "$ISO_DIR/casper/filesystem.squashfs" -comp xz -b 1M -noappend -no-progress
du -sx --block-size=1 "$CHROOT" | cut -f1 > "$ISO_DIR/casper/filesystem.size"

# ---------- 6. ISO ----------
log "6/6 Сборка ISO (BIOS + UEFI)"
echo "${LUCIX_NAME} ${LUCIX_VERSION} (${LUCIX_STAGE}) - Ubuntu ${UBUNTU_VERSION} base" > "$ISO_DIR/.disk/info"

cat > "$ISO_DIR/boot/grub/grub.cfg" <<EOF
set default=0
set timeout=5
search --no-floppy --set=root --file /casper/vmlinuz

menuentry "${LUCIX_NAME} ${LUCIX_VERSION} (live)" {
    linux  /casper/vmlinuz boot=casper ---
    initrd /casper/initrd
}
menuentry "${LUCIX_NAME} (safe graphics)" {
    linux  /casper/vmlinuz boot=casper nomodeset ---
    initrd /casper/initrd
}
EOF

grub-mkrescue -o "$OUT_DIR/$ISO_NAME" "$ISO_DIR"
( cd "$OUT_DIR" && sha256sum "$ISO_NAME" > "$ISO_NAME.sha256" )

log "Готово!"
ls -lh "$OUT_DIR"
if [[ -s "$OUT_DIR/skipped-packages.txt" ]]; then
  warn "Пропущенные необязательные пакеты:"
  cat "$OUT_DIR/skipped-packages.txt" >&2
fi
