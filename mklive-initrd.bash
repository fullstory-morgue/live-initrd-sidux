#!/bin/bash

#####################################################################
# Copyright (C) 2006 Kel Modderman <kelmo@kanotixguide.org>
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# On Debian GNU/Linux systems, the text of the GPL license can be
# found in /usr/share/common-licenses/GPL.
#####################################################################
# Sanity checks

if [[ $UID != "0" ]]; then
	echo "Must be run by root user."
	exit 1
fi

# Source variables from distro-defaults
if [[ -s /etc/default/distro ]]; then
	source /etc/default/distro
else
	echo "This script requires \`distro-defaults'"
	exit 1
fi

#####################################################################
# Process arguments

while (($#)); do
	case $1 in
#		-k|--keep)
#			XXX: make 1:1 of working directory for investigation
#			;;
		-v|--version)
			shift
			KVERS=$1
			;;
		-d|--debug)
			VERBOSITY=1
			;;
		-o|--output)
			shift
			FINAL_INITRD=$1
			;;
		*)
			;;
	esac
	shift
done

#####################################################################
# Initialize variables

# Kernel version
[[ $KVERS ]] || KVERS=$(uname -r)

if ! modprobe --set-version=${KVERS} --ignore-install --list >/dev/null 2>&1; then
	echo "Invalid kernel version: ${KVERS}, aborting"
	exit 1
fi

# Working directories
TARGET_INITRD_NAME="miniroot"
TARGET_INITRD_TMPDIR=$(mktemp -d)
TARGET_INITRD="${TARGET_INITRD_TMPDIR}/${TARGET_INITRD_NAME}"
TARGET_INITRD_SIZE="10000"
TARGET_INITRD_DIR=$(mktemp -d)

FINAL_INITRD="/boot/live-miniroot-${KVERS}.gz"

# Static shell binary provided by busybox-sidux
BUSYBOX_BIN="/usr/lib/busybox-sidux/busybox.static"
BUSYBOX_LINKS="/usr/share/busybox-sidux/busybox.links"

# XXX: are all these files in /etc really required?
if [[ -d ${PWD}/templates ]]; then
	TEMPLATE_DIR="${PWD}/templates"
else
	TEMPLATE_DIR="/usr/share/live-initrd-sidux/templates"
fi

if [[ -x ${PWD}/linuxrc ]]; then
	LINUXRC="${PWD}/linuxrc"
else
	LINUXRC="/usr/share/live-initrd-sidux/linuxrc"
fi

SCSI_MODULES="
	aic7xxx
	BusLogic
	ncr53c8xx
	NCR53c406a
	initio
	advansys
	aha1740
	aha1542
	aha152x
	atp870u
	dtc
	eata
	fdomain
	gdth
	megaraid
	pas16
	pci2220i
	pci2000
	psi240i
	qlogicfas
	qlogicfc
	qlogicisp
	seagate
	t128
	tmscsim
	u14-34f
	ultrastor
	wd7000
	a100u2w
	3w-xxxx
	dc395x
	dpt_i2o
	iswraid
	sym53c8xx
	ohci1394
	sbp2
	ehci-hcd
	ohci-hcd
	usb-storage
"

MODULES="
	cloop
	loop
	ntfs
	squashfs
	unionfs
	ext2
	ext3
	reiserfs
	xfs
	jfs
	vfat
	isofs
"

#####################################################################
# Utility functions

# Bash's trap calls this on exit
#
make_miniroot_and_cleanup() {
	if grep -q ${TARGET_INITRD_DIR} /proc/mounts; then
		rm -rf ${TARGET_INITRD_DIR}/lost+found
		umount ${TARGET_INITRD_DIR}
	fi
	if [[ -f ${TARGET_INITRD} ]]; then
		gzip -9 -c ${TARGET_INITRD} > ${FINAL_INITRD}
	fi
	rm -rf ${TARGET_INITRD_DIR}
	rm -rf ${TARGET_INITRD_TMPDIR}
}

# make_initrd_symlinks $link_target $link_name
#
# $link_name is relative to TARGET_INITRD_DIR
#
make_initrd_symlinks() {
	while (($#)); do
		[[ ${VERBOSITY} ]] && echo "Creating symlink: $2 -> $1"
		ln -s $1 ${TARGET_INITRD_DIR}/$2
		shift 2
	done
}

# make_initrd_dirs $dir_name
#
# $dir_name is relative to TARGET_INITRD_DIR
#
make_initrd_dirs() {
	for dir in $@; do
		[[ ${VERBOSITY} ]] && echo "Creating directory: ${dir}"
		mkdir -p ${TARGET_INITRD_DIR}/${dir}
	done
}

# install_kmod $module $dir
#
# resolves module dependencies for $module and copies deps to same $dir
# $dir is relative to TARGET_INITRD_DIR
#
install_kmod() {
	# XXX: we should use modprobe, and not use stupid module directories
	local KMOD
	local KMODS=$(modprobe --set-version=${KVERS} --ignore-install --show-depends $1 2>/dev/null)
	for kmod in ${KMODS}; do
		[[ -f ${kmod} ]] || continue
		unset KMOD
		KMOD=$(basename ${kmod})
		if [[ ! -f ${TARGET_INITRD_DIR}/$2/${KMOD} ]]; then
			cp ${kmod} ${TARGET_INITRD_DIR}/$2/
			[[ ${VERBOSITY} ]] && echo "Adding module: $2/${KMOD}"
		fi
	done
}

## XXX: this is _*UGLY*_ -> FIXME please
#create_scsi_parse_file() {
#	for s in $(find /lib/modules/${KVERS}/kernel/drivers/scsi -name *.ko); do 
#		DEP=$(modinfo $s|grep ^depends:|echo $(cut -d' ' -f2-))
#		[ -n "$DEP" ] && DEP=$DEP.ko
#		case $DEP in
#			*pcmcia*)
#				;;
#			*) 
#				modinfo $s|grep "^alias:"|grep pci|while read a; do
#					echo $a $DEP $(basename $s)|cut -f3- -d:
#				done
#				;;
#		esac
#	done|sort|uniq
#}

#####################################################################
# main()

trap "{ make_miniroot_and_cleanup; }" SIGINT SIGTERM EXIT

echo "Creating live initrd for ${FLL_DISTRO_NAME}"

# Initialise miniroot ramdisk
dd if=/dev/zero of=${TARGET_INITRD} bs=1k count=${TARGET_INITRD_SIZE} >/dev/null 2>&1
# Create ext2 filesystem on loopback file
mke2fs -L "${FLL_DISTRO_NAME} Live Initrd" \
	-b 1024 -N 32768 -O none -F -q -m 0 \
	${TARGET_INITRD}
# Loop-mount miniroot to staging directory
mount -o loop ${TARGET_INITRD} ${TARGET_INITRD_DIR}

echo "Creating initrd base layout."

# Create root directory tree
make_initrd_dirs \
	cdrom	 		\
	dev			\
	etc			\
	mnt			\
	modules/scsi		\
	proc			\
	static			\
	sys			\
	${FLL_IMAGE_DIR}

# Symlinks to live image mount point
make_initrd_symlinks \
	${FLL_MOUNTPOINT}/bin bin 			\
	${FLL_MOUNTPOINT}/boot boot			\
	${FLL_MOUNTPOINT}/lib lib			\
	${FLL_MOUNTPOINT}/opt opt			\
	${FLL_MOUNTPOINT}/usr usr			\
	static sbin					\
	/var/tmp tmp					\
	/sbin/MAKEDEV dev/MAKEDEV			\
	${FLL_MOUNTPOINT}/etc/ld.so.conf etc/ld.so.conf

# Architecture specific symlinks
case "$(uname -m)" in
	x86_64)
		make_initrd_symlinks \
			${FLL_MOUNTPOINT}/lib lib64	\
			${FLL_MOUNTPOINT}/emul emul
		;;
	*)
		;;
esac

# Install static busybox binary
install -m 0755 ${BUSYBOX_BIN} ${TARGET_INITRD_DIR}/static/busybox

# Create busybox softlinks
for bb in $(< ${BUSYBOX_LINKS}); do
	make_initrd_symlinks busybox static/${bb/*\//}
done

# Populate miniroot /etc
touch ${TARGET_INITRD_DIR}/etc/exports

# Copy /etc templates to staging area
#
# Substitute special @TAGS@ with correct names from distro-defaults
pushd ${TEMPLATE_DIR}/etc >/dev/null
	for tmpl in *; do
		[[ -f ${tmpl} ]] || continue
		# sed hack in distro-defaults support
		sed \
			-e "s/@FLL_LIVE_USER@/${FLL_LIVE_USER}/g" 	\
			-e "s/@FLL_DISTRO_NAME@/${FLL_DISTRO_NAME}/g"	\
			${tmpl} > ${TARGET_INITRD_DIR}/etc/${tmpl}
	done
popd >/dev/null

chmod 0644 ${TARGET_INITRD_DIR}/etc/*
chmod 0755 ${TARGET_INITRD_DIR}/etc/init

# Install linuxrc script
# XXX: apply same sed logic as above
install -m 0755 ${LINUXRC} ${TARGET_INITRD_DIR}/linuxrc

echo "Adding kernel modules..."

# Add other modules
for module in ${MODULES}; do
	install_kmod ${module} modules
done

# Add scsi modules
# XXX: create scsi parse txt file
for module in ${SCSI_MODULES}; do
	install_kmod ${module} modules/scsi
done

#create_scsi_parse_file > ${TARGET_INITRD_DIR}/modules/scsi/scsi-modules.txt

# Populate /dev with MAKEDEV
pushd ${TARGET_INITRD_DIR}/dev >/dev/null
	# XXX: pick correct device node groups for creation
	echo "Creating device nodes..."
	./MAKEDEV generic hd sd sr sg loop md input pty usb
popd >/dev/null

echo "Compressing ${FINAL_INITRD}"

exit 0

