#!/usr/bin/env bash

if [ "$(id -u)" -ne 0 ]; then
	echo "This script must be run as root" >&2
	exit 1
fi

clear

echo "---"
echo "--- Preparing System ---"
echo "---"

timedatectl set-ntp true
sed -i "s/^#\(Color\)/\1\nILoveCandy/" /etc/pacman.conf
sed -i "s/^#\(ParallelDownloads\)/\1/" /etc/pacman.conf
reflector --country Russia --delay 24 --score 10 --sort rate --save /etc/pacman.d/mirrorlist

clear

echo "---"
echo "--- Disk Partitioning ---"
echo "---"

while true; do
	lsblk -o NAME,FSTYPE,SIZE | grep -v -E '^(sr|loop)'
	read -r -p "Select installation disk: " installation_disk_selector
	if [ ! -b "/dev/$installation_disk_selector" ]; then
		echo "Error: Not a valid block device: $installation_disk_selector" >&2
		continue
	fi
		break
done

while true; do
	read -r -p "Enter swap size (MiB): " swap_partition_size_selector
	if [[ -z "$swap_partition_size_selector" ]] || [[ "$swap_partition_size_selector" -eq 0 ]]; then
		echo "Error: Swap size must be greater than 0" >&2
		continue
	fi
		swap_partition_size_calculated=$((514 + swap_partition_size_selector))
		root_partition_size_calculated=$((1 + swap_partition_size_calculated))
		break
done

sgdisk -Z /dev/"$installation_disk_selector" > /dev/null
sgdisk -a 2048 -o /dev/"$installation_disk_selector" > /dev/null

sgdisk -n 1:1MiB:513MiB -c 1:"EFI" -t 1:ef00 /dev/"$installation_disk_selector" > /dev/null
sgdisk -n 2:514MiB:"${swap_partition_size_calculated}"MiB -c 2:"SWAP" -t 2:8200 /dev/"$installation_disk_selector" > /dev/null
sgdisk -n 3:${root_partition_size_calculated}MiB:0 -c 3:"ROOT" -t 3:8304 /dev/"$installation_disk_selector" > /dev/null

partprobe /dev/"$installation_disk_selector" > /dev/null

if [[ "/dev/${installation_disk_selector}" =~ "/dev/sd" ]]; then
	efi_partition="/dev/${installation_disk_selector}1"
	swap_partition="/dev/${installation_disk_selector}2"
	root_partition="/dev/${installation_disk_selector}3"
elif [[ "/dev/${installation_disk_selector}" =~ "/dev/vd" ]]; then
	efi_partition="/dev/${installation_disk_selector}1"
	swap_partition="/dev/${installation_disk_selector}2"
	root_partition="/dev/${installation_disk_selector}3"
else
	efi_partition="/dev/${installation_disk_selector}p1"
	swap_partition="/dev/${installation_disk_selector}p2"
	root_partition="/dev/${installation_disk_selector}p3"
fi

while true; do
	echo "Available filesystems:"
	echo "1) ext4"
	echo "2) xfs"
	read -r -p "Select root filesystem: " root_filesystem_selector
	case $root_filesystem_selector in
		ext4)
			mkfs.fat -F 32 "$efi_partition" > /dev/null
			mkswap "$swap_partition" > /dev/null
			yes | mkfs.ext4 "$root_partition" > /dev/null
			root_filesystem_progs="e2fsprogs"
			fsck_check="0 2"
			break
			;;
		xfs)
			mkfs.fat -F 32 "$efi_partition" > /dev/null
			mkswap "$swap_partition" > /dev/null
			mkfs.xfs -f "$root_partition" > /dev/null
			root_filesystem_progs="xfsprogs"
			fsck_check="0 0"
			break
			;;
		*)
			echo "Invalid selection" >&2
			;;
	esac
done

clear

echo "---"
echo "--- Mounting Filesystems ---"
echo "---"

swapon "$swap_partition"
mount "$root_partition" /mnt
mkdir -p /mnt/boot
mount -o umask=0022 "$efi_partition" /mnt/boot

clear

echo "---"
echo "--- Installing Base System ---"
echo "---"

if grep -q "AuthenticAMD" /proc/cpuinfo; then
	microcode="amd-ucode"
else
	microcode="intel-ucode"
fi

while true; do
	echo "Select kernel for installation:"
	echo "1) zen"
	echo "2) lts"
	read -r -p "Select kernel: " kernel_choice
	case $kernel_choice in
		zen)
			kernel_headers="linux-zen-headers"
			kernel_name="linux-zen"
			break
			;;
		lts)
			kernel_headers="linux-lts-headers"
			kernel_name="linux-lts"
			break
			;;
		*)
			echo "Invalid selection" >&2
			;;
	esac
done

pacstrap -K /mnt base base-devel "$kernel_name" "$kernel_headers" "$microcode" linux-firmware man-db > /dev/null
arch-chroot /mnt pacman -Syu --noconfirm > /dev/null
arch-chroot /mnt pacman -S --noconfirm "$root_filesystem_progs" dosfstools exfatprogs > /dev/null
arch-chroot /mnt pacman -S --noconfirm reflector git wget curl > /dev/null
arch-chroot /mnt pacman -S --noconfirm p7zip zip unzip > /dev/null
arch-chroot /mnt pacman -S --noconfirm openssh > /dev/null
arch-chroot /mnt pacman -S --noconfirm bash-completion vim > /dev/null

case $(systemd-detect-virt) in
	kvm)
		echo "KVM detected - installing guest tools"
		pacstrap /mnt qemu-guest-agent > /dev/null
		systemctl enable qemu-guest-agent --root=/mnt > /dev/null
		;;
	vmware)
		echo "VMware detected - installing guest tools"
		pacstrap /mnt open-vm-tools > /dev/null
		systemctl enable vmtoolsd --root=/mnt > /dev/null
		systemctl enable vmware-vmblock-fuse --root=/mnt > /dev/null
		;;
	oracle)
		echo "VirtualBox detected - installing guest tools"
		pacstrap /mnt virtualbox-guest-utils > /dev/null
		systemctl enable vboxservice --root=/mnt > /dev/null
		;;
	microsoft)
		echo "Hyper-V detected - installing guest tools"
		pacstrap /mnt hyperv > /dev/null
		systemctl enable hv_fcopy_daemon --root=/mnt > /dev/null
		systemctl enable hv_kvp_daemon --root=/mnt > /dev/null
		systemctl enable hv_vss_daemon --root=/mnt > /dev/null
		;;
	none)
		echo "Running on bare metal - no guest tools needed"
		;;
	*)
		echo "Unknown virtualization detected"
		;;
esac

while true; do
	echo "Network configuration options:"
	echo "1) networkmanager"
	echo "2) systemd-networkd"
	read -r -p "Select network configuration: " network_choice
	case $network_choice in
		networkmanager)
			arch-chroot /mnt pacman -S --noconfirm networkmanager > /dev/null
			systemctl enable NetworkManager --root=/mnt > /dev/null
			break
			;;
		systemd-networkd)
			arch-chroot /mnt pacman -S --noconfirm systemd-resolvconf > /dev/null
			systemctl enable systemd-networkd.service --root=/mnt > /dev/null
			systemctl enable systemd-resolved.service --root=/mnt > /dev/null
			interfaces=$(ls /sys/class/net | grep -v lo)
			for iface in $interfaces; do
				echo "Configuring interface: $iface"
				read -r -p "Enter static IP address for $iface (e.g., 192.168.1.100/24): " ip_address
				read -r -p "Enter gateway for $iface (e.g., 192.168.1.1): " gateway
				read -r -p "Enter DNS servers (space separated, e.g., 8.8.8.8 1.1.1.1): " dns_servers
				cat > "/mnt/etc/systemd/network/10-$iface.network" <<EOF
[Match]
Name=$iface

[Network]
Address=$ip_address
Gateway=$gateway
DNS=${dns_servers// / }
EOF
			done

			cat > /mnt/etc/resolv.conf <<EOF
# Generated by systemd-networkd
nameserver ${dns_servers%% *}
EOF
			chattr +i /mnt/etc/resolv.conf
			break
			;;
		*)
			echo "Invalid selection" >&2
			;;
	esac
done

clear

echo "---"
echo "--- System Configuration ---"
echo "---"

cat > /mnt/etc/fstab <<EOF
# $efi_partition
UUID=$(blkid -s UUID -o value "$efi_partition")					/boot			vfat	defaults	0 0

# $swap_partition
UUID=$(blkid -s UUID -o value "$swap_partition")	none			swap	sw		0 0

# $root_partition
UUID=$(blkid -s UUID -o value "$root_partition")	/			$root_filesystem_selector	defaults	$fsck_check
EOF

arch-chroot /mnt ln -sf "/usr/share/zoneinfo/$(curl -s http://ip-api.com/line?fields=timezone)" /etc/localtime
arch-chroot /mnt hwclock --systohc

read -r -p "Enter locale (leave empty for en_US.UTF-8): " locale_selector
locale_selector=${locale_selector:-en_US.UTF-8}
sed -i "/^#en_US.UTF-8/s/^#//" /mnt/etc/locale.gen

if [ "$locale_selector" != "en_US.UTF-8" ]; then
	sed -i "/^#${locale_selector}/s/^#//" /mnt/etc/locale.gen
fi

arch-chroot /mnt locale-gen > /dev/null
echo "LANG=$locale_selector" > /mnt/etc/locale.conf

read -r -p "Enter keymap (leave empty for default): " keymap_selector
{
	[ -n "$keymap_selector" ] && echo "KEYMAP=$keymap_selector"
	echo "FONT=cyr-sun16"
} > /mnt/etc/vconsole.conf

while true; do
	read -r -p "Enter hostname: " hostname_selector
	if [ -n "$hostname_selector" ]; then
		echo "$hostname_selector" > /mnt/etc/hostname
		break
	fi
		echo "Hostname cannot be empty" >&2
done

cat > /mnt/etc/hosts <<EOF
127.0.0.1   localhost
127.0.1.1   $hostname_selector.lan $hostname_selector

::1         localhost ip6-localhost ip6-loopback
EOF

cat > /mnt/etc/sysctl.d/10-swappiness.conf <<EOF
vm.swappiness=30
EOF

if lsblk --discard | grep -q 'DISC'; then
	systemctl enable fstrim.timer --root=/mnt > /dev/null
fi

sed -i "s/^#\(Color\)/\1\nILoveCandy/" /mnt/etc/pacman.conf
sed -i "s/^#\(ParallelDownloads\)/\1/" /mnt/etc/pacman.conf

cat > /mnt/etc/xdg/reflector/reflector.conf <<EOF
--country Russia
--delay 24
--score 10
--sort rate
--save /etc/pacman.d/mirrorlist
EOF

systemctl enable reflector.timer --root=/mnt > /dev/null

clear

echo "---"
echo "--- User Configuration ---"
echo "---"

while true; do
	read -r -p "Create user?: " create_user
	case $create_user in
		yes)
			read -p "Enter username to create/update: " username
			if ! arch-chroot /mnt id -u "$username" &>/dev/null; then
				arch-chroot /mnt useradd -m -s /bin/bash "$username"
				echo "$username ALL=(ALL:ALL) NOPASSWD: ALL" > /mnt/etc/sudoers.d/"$username"
				chmod 0440 /mnt/etc/sudoers.d/"$username"
			fi
			while true; do
				arch-chroot /mnt passwd "$username" && break
			done
			break
			;;
		*)
			break
			;;
	esac
done

echo "Setting root password:"
while ! arch-chroot /mnt passwd; do
    echo "Please try again" >&2
done

clear

echo "---"
echo "--- Finalizing Installation ---"
echo "---"

arch-chroot /mnt bootctl --path=/boot install > /dev/null

cat > /mnt/boot/loader/loader.conf <<EOF
default arch-$kernel_name
timeout 3
editor  no
EOF

cat > /mnt/boot/loader/entries/arch-$kernel_name.conf <<EOF
title   Arch Linux ($kernel_name Kernel)
linux   /vmlinuz-$kernel_name
initrd  /$microcode.img
initrd  /initramfs-$kernel_name.img
options root=UUID=$(blkid -s UUID -o value "$root_partition") rw
EOF

arch-chroot /mnt pacman -Syu --noconfirm > /dev/null
arch-chroot /mnt pacman -Scc --noconfirm > /dev/null

umount -R /mnt > /dev/null
swapoff -a

clear

echo "---"
echo "Installation complete!"
echo "You may now reboot your system."
echo "---"

exit 0
