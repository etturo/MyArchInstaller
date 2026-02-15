#!/bin/bash

handle_error(){
	echo "[ERROR] - Line $1"
	exit 1
}

trap 'handle_error $LINENO' ERR

# End the script if a command fails
set -e

# === Check Internet Connection ===

setup_internet() {
	echo "Checking internet connection..."

	if ping -c 1 archlinux.org > /dev/null 2>&1; then
		echo "Internet already set. Proceeding..."
		return
	fi
	
	echo "Internet NOT set."

	# Searching the name of the wifi board
	WIFI_DEV=$(ls /sys/class/net | grep ^wl | head -n 1)
	
	if [ -z "$WIFI_DEV" ]; then
		echo "No wifi board connected and no LAN cable connection"
		echo "Impossible to continue the installation"
		exit 1
	fi

	echo "Wifi found: $WIFI_DEV"
	
	ip link set "$WIFI_DEV" up
	sleep 2

	while ! ping -c 1 archlinux.org > /dev/null 2>&1; do
		echo "---------------------------------------------------------"
		echo "Scanning networks..."
		iwctl station "$WIFI_DEV" scan
		iwctl station "$WIFI_DEV" get-networks
		echo "---------------------------------------------------------"

		read -p "Write the NAME of the network (SSID): " SSID
		read -s -p "Write the PASSWORD of the network: " WIFI_PASS
		echo ""

		echo "Trying to connect to that network ($SSID)..."

		iwctl --passphrase "$WIFI_PASS" station "$WIFI_DEV" connect "$SSID" || true
		echo "Waiting for the IP address..."
		echo "5 seconds left..."
		sleep 1
		echo "4 seconds left..."
		sleep 1
		echo "3 secons left..."
		sleep 1
		echo "2 seconds left..."
		sleep 1
		echo "1 seconds left..."
		sleep 1

		if ping -c 1 archlinux.org > /dev/null 2>&1; then
			echo "Connection SUCCESSFULL"
			break
		else
			echo "Connection Failed. Wrong Password or low signal."
			echo "Retry"
		fi
	done
}


setup_internet


# === Configuration Variables ===
DISK="/dev/sda"
HOSTNAME="SFINZIO"
USERNAME="etturo"

echo "Beginnning installation on $DISK"

if [ -d "/sys/firmware/efi/efivars" ]; then
	UEFI=1
	echo "Mode: UEFI"
else
	UEFI=0
	echo "Mode: BIOS (Legacy)"
fi

# Difference on naming based on the prefix
if [[ "$DISK" =~ [0-9]$ ]]; then PREFIX="p"; else PREFIX=""; fi

# Unmounting possible previous mounted partitions
echo "Unmounting active volumes..."
umount -R /mnt 2>/dev/null || true
swapoff -a 2>/dev/null || true


# === Disk Cleaning ===
echo "Erasing the whole disk ($DISK)..."
# man wipefs:
#	wipefs can erase filesystem, raid or partition-table signatures
#       (magic strings) from the specified device to make the signatures
#       invisible for libblkid. wipefs does not erase the filesystem
#       itself nor any other data from the device.

wipefs -a "$DISK"	# It removes the signature from the filesystem

# man sgdisk:
# 	 sgdisk -Z stands for Zap (destroy) all the data structures needed
# 	 for the partition on the disk, it wipe all the data on them.

sgdisk -Z "$DISK" 2>/dev/null || true	# ignore the error if the disk is empty


# === Automatic Partitioning ===
if [ "$UEFI" -eq 1 ]; then
	# === UEFI Layout (GPT) ===
	# Part 1: EFI System (512M)
	# Part 2: Swap Memory (8G)
	# Part 3: Root
	
	echo "Creating Partitions GPT for UEFI layout"
	sfdisk "$DISK" <<ENDSF
label: gpt
,512M,U
,8G,S
,,L
ENDSF
	PART_EFI="${DISK}${PREFIX}1"
	PART_SWAP="${DISK}${PREFIX}2"
	PART_ROOT="${DISK}${PREFIX}3"
else
	# === BIOS Layout (MBR) ===
	# Part 1: Swap (8G)
	# Part 2: Root - Bootable
	
	echo "Creating DOS Partition for BIOS"
	sfdisk "$DISK" <<ENDSF
label: dos
,8G,82
,,83,*
ENDSF
	PART_SWAP="${DISK}${PREFIX}1"
	PART_ROOT="${DISK}${PREFIX}2"
fi

echo "Wating Kernel syncronization..."
udevadm settle

# === Mounting and Formatting ===
echo "Formatting partitions..."

mkswap "$PART_SWAP"
swapon "$PART_SWAP"

mkfs.ext4 -F "$PART_ROOT"
mount "$PART_ROOT" /mnt

if [ "$UEFI" -eq 1 ]; then
	mkfs.fat -F32 "$PART_EFI"
	mkdir -p /mnt/boot
	mount "$PART_EFI" /mnt/boot
fi

echo "The disk is ready and mounted on /mnt"

echo "Updating pacstrap Arch..."
pacman -Sy --noconfirm archlinux-keyring

echo "Downloading and Installing base packets..."
pacstrap -K /mnt base linux-zen linux-zen-headers linux-firmware vim nano networkmanager git sudo base-devel openssh man-db

echo "Generating fstab..."
genfstab -U /mnt >> /mnt/etc/fstab

