#!/bin/bash

# Install XFCE GUI, VNC server, and other necessary packages

apt update && apt install -y ca-certificates curl openssl sudo xvfb x11vnc xfce4 xfce4-terminal faenza-icon-theme bash procps nano git ethtool

# Set VNC password: ("admin" but you can set it to whatever)

mkdir -p /root/.vnc && x11vnc -storepasswd admin /root/.vnc/passwd

# Start GUI and VNC server services

export DISPLAY=:99
export RESOLUTION=1920x1080x24

nohup /usr/bin/Xvfb :99 -screen 0 $RESOLUTION -ac +extension GLX +render -noreset > /dev/null 2>&1 &

nohup startxfce4 > /dev/null 2>&1 &

nohup x11vnc -xkb -noxrecord -noxfixes -noxdamage -display $DISPLAY -forever -bg -rfbauth /root/.vnc/passwd -users root -rfbport 5900 > /dev/null 2>&1 &

# Install KVM hypervisor

apt install -y qemu qemu-kvm libvirt-daemon libvirt-clients bridge-utils virt-manager
modprobe tun
modprobe br_netfilter
grep -q -E 'vmx' /proc/cpuinfo && modprobe kvm-intel
grep -q -E 'svm' /proc/cpuinfo && modprobe kvm-amd
service libvirtd start


# Install web-browser (Firefox works, Chromium seems to throw an I/O error and doesn't launch)

apt install -y firefox
xdg-settings set default-web-browser firefox.desktop

# Install NoVNC (VNC client over http)

export NOVNC_TAG=$(curl -s https://api.github.com/repos/novnc/noVNC/releases/latest | jq -r .tag_name)

export WEBSOCKIFY_TAG=$(curl -s https://api.github.com/repos/novnc/websockify/releases/latest | jq -r .tag_name)

git clone --depth 1 https://github.com/novnc/noVNC --branch ${NOVNC_TAG} /root/noVNC

git clone --depth 1 https://github.com/novnc/websockify --branch ${WEBSOCKIFY_TAG} /root/noVNC/utils/websockify

cp /root/noVNC/vnc.html /root/noVNC/index.html

sed -i "s/UI.initSetting('resize', 'off');/UI.initSetting('resize', 'scale');/" /root/noVNC/app/ui.js

nohup /root/noVNC/utils/novnc_proxy --vnc localhost:5900 --listen 80 > /dev/null 2>&1 &

# Install File Browser (https://filebrowser.org/)
# Default login is:
# Username: admin
# Password: admin

curl -fsSL https://raw.githubusercontent.com/filebrowser/get/master/get.sh | bash

PUBLIC_IP=$(curl -s https://metadata.platformequinix.com/metadata | jq -r ".network.addresses[] | select(.public == true) | select(.address_family == 4) | .address")

nohup filebrowser -r /root -a $PUBLIC_IP -p 8080 > /dev/null 2>&1 &

clear

# Network Interface PCI information

#IFS=$'\n'
METADATA=$(curl -s metadata.packet.net/metadata)
INTERFACES_COUNT=$(echo $METADATA | jq '.network.interfaces | length')
echo
echo "Network interfaces:"
echo

for i in $(seq 1 $INTERFACES_COUNT)
do

METADATA_MAC=$(echo $METADATA | jq -r .network.interfaces[$i-1].mac)
METADATA_IF_NAME=$(echo $METADATA | jq -r .network.interfaces[$i-1].name)

for LINE in $(ls -d /sys/class/net/*/ | cut -d '/' -f5)
do

#LOCAL_MAC=$(cat /sys/class/net/$LINE/address)
# /sys/class/net/$LINE/address returns the same MAC for any interface part of a bonded interfaces so it's not reliable
# ethtool permanent address option returns the real MAC of the interface regardless if it's part of a bond
LOCAL_MAC=$(ethtool -P $LINE | cut -d ' ' -f3)

# some interfaces like bonds will have the same MAC address as the primary interface but they won't have a uevent file so we're ignoring it
if [ "$METADATA_MAC" == "$LOCAL_MAC" ] && [ -f "/sys/class/net/$LINE/device/uevent" ]; then

    PCI_ID=$(grep PCI_SLOT_NAME /sys/class/net/$LINE/device/uevent | cut -d "=" -f2)

# only add API Interface name if OS name is different

    if [ "$METADATA_IF_NAME" == "$LINE" ]; then
        lspci -D | grep $PCI_ID | sed 's#^#PCI BDF #' | sed "s/$/ ($LINE)/"
    else
        lspci -D | grep $PCI_ID | sed 's#^#PCI BDF #' | sed "s/$/ ($LINE)/" | sed "s/$/ ($METADATA_IF_NAME)/"
    fi

    echo
    break
fi
done
done


# Storage drive information and PCI mapping

IFS=$'\n'
echo
echo "Local storage drives:"
echo

#SATA drives
for LINE in $(ls -l /sys/block/ | grep "sd" | awk '{print $9, $10, $11}')
do

# Get the amount of words separated by a backslash
# Then run a a while loop starting from word count and reducing by one so we go in the left direction and stop when you find the first word that matches the format of a PCI address
# Some servers have their storage controllers connected to host or PCI bridges which have their own PCI addresses so that's why we need to start from the right end and go towards the left
WORD_COUNT=$(echo $LINE | grep -o "/" | wc -l)
WORD_COUNT=$(( WORD_COUNT + 1 ))
PCI_ID_FOUND=false
while [ $WORD_COUNT -gt 1 ] && [ $PCI_ID_FOUND == "false" ]; do
    if [ $(echo $LINE | cut -d "/" -f$WORD_COUNT | grep -Eo "....:..:..\..") ]; then
        PCI_ID_FOUND=true
        PCI_ID=$(echo $LINE | cut -d "/" -f$WORD_COUNT)
    else
        WORD_COUNT=$(( WORD_COUNT - 1 ))
    fi
done

lspci -D | grep $PCI_ID | sed 's#^#PCI BDF #'
DEVICE_PATH=$(echo $LINE | awk '{print $1}' | sed 's#^#/dev/#')
lsblk -p -o NAME,TYPE,SIZE,MODEL,TRAN,ROTA,HCTL,MOUNTPOINT $DEVICE_PATH | sed 's#NAME#PATH#' | sed 's#ROTA#DRIVE-TYPE#' | sed 's# 0 #SSD      #' | sed 's# 1 #HDD      #'
echo

done

#NVMe drives
for LINE in $(ls -l /sys/block/ | grep "nvme" | awk '{print $9, $10, $11}')
do

# Get the amount of words separated by a backslash
# Then run a a while loop starting from word count and reducing by one so we go in the left direction and stop when you find the first word that matches the format of a PCI address
# Some servers have their storage controllers connected to host or PCI bridges which have their own PCI addresses so that's why we need to start from the right end and go towards the left
WORD_COUNT=$(echo $LINE | grep -o "/" | wc -l)
WORD_COUNT=$(( WORD_COUNT + 1 ))
PCI_ID_FOUND=false
while [ $WORD_COUNT -gt 1 ] && [ $PCI_ID_FOUND == "false" ]; do
    if [ $(echo $LINE | cut -d "/" -f$WORD_COUNT | grep -Eo "....:..:..\..") ]; then
        PCI_ID_FOUND=true
        PCI_ID=$(echo $LINE | cut -d "/" -f$WORD_COUNT)
    else
        WORD_COUNT=$(( WORD_COUNT - 1 ))
    fi
done

lspci -D | grep $PCI_ID | sed 's#^#PCI BDF #'
DEVICE_PATH=$(echo $LINE | awk '{print $1}' | sed 's#^#/dev/#')
lsblk -p -o NAME,TYPE,SIZE,MODEL,TRAN,ROTA,HCTL,MOUNTPOINT $DEVICE_PATH | sed 's#NAME#PATH#' | sed 's#ROTA#DRIVE-TYPE#' | sed 's# 0 #SSD      #' | sed 's# 1 #HDD      #'
echo

done

printf "\n\n"
echo "The ISO installation environment is available at:"
printf "\n"
echo "http://$PUBLIC_IP/"
printf "\n"
echo "The File Transfer portal is available at:"
printf "\n"
echo "http://$PUBLIC_IP:8080/"
printf "\n"
echo "The instance is running in $([ -d /sys/firmware/efi ] && echo UEFI || echo BIOS) boot mode."
printf "\n\n"

