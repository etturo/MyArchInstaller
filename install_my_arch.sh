#!/bin/bash

handle_error(){
	echo ""
	echo "[ERROR] - Line $1"
	exit 1
}

trap 'handle_error $LINENO' ERR

# End the script if a command fails
set -e

# === SPINNER FUNCTION ===
spinner() {
	local pid=$!
	local delay=0.1
	local spinstr='|/-\'
	echo -n "   "

	# Hiding the cursor
	tput civis

	while ps -p $pid > /dev/null; do
		local temp=${spinstr#?}
   	   	printf " [%c]  " "$spinstr"
   	   	local spinstr=$temp${spinstr%"$temp"}
   	   	sleep $delay
   	   	printf "\b\b\b\b\b\b"
   	done

	printf "    \b\b\b\b"
	printf " [✓] \n"
	tput cnorm
}

# Wrapper function to run command quietly with spinner
run_quiet() {
	echo -n "$1..."
	("${@:2}") > /dev/null 2>&1 & 

	spinner 
}


# === Setup Password and UserName ===
get_credential() {
	echo "----------------------------------------------------------------"
	echo "USER CONDIGURATION"
	echo "----------------------------------------------------------------"

	read -p "Insert USERNAME: " USERNAME
	
	if [ -z "$USERNAME" ]; then
		USERNAME="etturo"
		echo "No name inserted, will be set: $USERNAME"
	fi

	while true; do
		echo -n "Insert the PASSWORD: "
		read -s PASSWORD
		echo ""

		echo -n "Confirm the PASSWORD: "
		read -s PASSWORD_CONFIRM
		echo ""

		if [ -n "$PASSWORD" ] && [ "$PASSWORD" == "$PASSWORD_CONFIRM" ]; then
			ROOT_PASSWORD="$PASSWORD"
			echo "Password set SUCCESSFULLY!"
			break
		else
			echo "Passwords doesn't match. Retry..."
		fi
	done

	echo "----------------------------------------------------------------"
	echo "Correctly got the credential. The installation will continue..."
	echo "----------------------------------------------------------------"
	sleep 2
}


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

# Running initial Setup
setup_internet
get_credential


# === Configuration Variables ===
DISK="/dev/sda"
HOSTNAME="SFINZIO"

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

# wipefs -a "$DISK"	# It removes the signature from the filesystem

# man sgdisk:
# 	 sgdisk -Z stands for Zap (destroy) all the data structures needed
# 	 for the partition on the disk, it wipe all the data on them.

# sgdisk -Z "$DISK" 2>/dev/null || true	# ignore the error if the disk is empty

# Running thoose command with the spinner visualizer
run_quiet "Erasing disk signatures (wipefs)" wipefs -a "$DISK"
run_quiet "Zapping partition table (sgdisk)" sgdisk -Z "$DISK"



# === Automatic Partitioning ===
if [ "$UEFI" -eq 1 ]; then
	# === UEFI Layout (GPT) ===
	# Part 1: EFI System (512M)
	# Part 2: Swap Memory (8G)
	# Part 3: Root
	
	echo "Creating Partitions GPT for UEFI layout"
	sfdisk "$DISK" > /dev/null 2>&1 <<ENDSF
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


# === System Configuration ===
echo "Internal configuration started..."

cat <<INTERNAL_EOF > /mnt/setup_internal.sh
#!/bin/bash

# Language and Time
ln -sf /usr/share/zoneinfo/Europe/Rome /etc/localtime
hwclock --systohc
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "$HOSTNAME" > /etc/hostname

# Host condiguration
echo "127.0.0.1	localhost" >> etc/hosts
echo "::1	localhost" >> etc/hosts
echo "127.0.1.1 $HOSTNAME.localdomain $HOSTNAME" >> etc/hosts

# Creating User and setting the password
echo "Creating user: $USERNAME"
useradd -m -G wheel -s /bin/bash "$USERNAME"

echo "$USERNAME:$PASSWORD" | chpasswd
echo "root:$ROOT_PASSORD" | chpasswd

# Setting SUDO
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/wheel

# Installing BootLoader (GRUB)
echo "Installing GRUB..."
if [ "$UEFI" -eq 1 ]; then
	grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
else
	grub-install --target=i386-pc "$DISK"
fi
grub-mkconfig -o /boot/grub/grub.cfg

# Starting Services
systemtcl enable NetworkManager
systemctl enable sshd

INTERNAL_EOF

echo "Entering the system (CHROOT)..."
chmod +x /mnt/setup_internal.sh
arch_chroot /mnt ./setup_internal.sh

# Cleaning
rm -f /mnt/setup_internal.sh

echo "========================================================================"
echo "---------------------- INSTALLATION COMPLETED --------------------------"
echo "========================================================================"
echo ""
echo "reboot the system and remove the installation media"
echo ""

EOF
