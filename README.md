# metal-isometric-xepa-ubuntu

ISO installation environment for Equinix Metal

![windows-isometric-meme](/images/windows-isometric-meme.png)

## Overview

This project makes it possible to install any ISO of your choice on Equinix Metal instances. Windows 10? TrueNAS? NSX Edge? All the ISOs!!!

While you will be able to install any ISO, it is not guaranteed to work due to several factors such as kernel or driver support for the hardware.

## How does it work?

TLDR: Custom iPXE + live Linux OS + KVM hypervisor + IOMMU / VFIO PCI Passthrough + GUI

Equinix Metal provides the option of deploying instances with the Custom iPXE Operating System which is effectively a bare metal node with empty local storage drives.

Once provisioned, we can log in to the in-memory live Linux environment.

Inside the live Linux environment, a set of packages are installed to provide a GUI interface with a web browser and KVM hypervisor.

A virtual machine is created that boots the ISO with the server local disk allocated to it along with the PCI device of your choice passed through in cases where you may need to install drivers.

Once the ISO installation is done, rebooting the machine will make it boot through the local disk which we wrote to via the VM earlier.

Profit???

## Guide

## Contents

- [Provision an Equinix Metal instance with Custom iPXE](#provision-an-equinix-metal-instance-with-custom-ipxe)
- [Log in to the instance](#log-in-to-the-instance)
- [Run the ISO installation environment setup script](#run-the-iso-installation-environment-setup-script)
- [Access the ISO installation environment](#access-the-iso-installation-environment)
- [Get the ISO](#get-the-iso)
  - [Download the ISO](#download-the-iso)
  - [Upload the ISO](#upload-the-iso)
- [Create the ISO installation Virtual Machine](#create-the-iso-installation-virtual-machine)
  - [Automated Instructions](#automated-instructions)
  - [Manual Instructions](#manual-instructions)
- [Set Virtual Machine boot firmware](#set-virtual-machine-boot-firmware)
- [Add serial consoles to the Virtual Machine](#add-serial-consoles-to-the-virtual-machine)
- [Add a TPM to the Virtual Machine](#add-a-tpm-to-the-virtual-machine)
- [Attach a PCI device to the Virtual Machine](#attach-a-pci-device-to-the-virtual-machine)
- [Install the Operating System](#install-the-operating-system)
- [Post installation configuration](#post-installation-configuration)
  - [Networking driver](#networking-driver)
  - [Serial console](#serial-console)
  - [Remote access](#remote-access)
- [Rebooting to the physical host](#rebooting-to-the-physical-host)
- [Troubleshooting](#troubleshooting)

### Provision an Equinix Metal instance with Custom iPXE

Login to the Equinix Metal [console](https://console.equinix.com/), then click the `New Server` button to provision an instance.

![new-server](/images/new-server.png)

Select your deployment type such as on-demand.

Select the metro location that you will be deploying in, then select the server type of your choice.

![metro-server-selection](/images/metro-server-selection.png)

Under the Operating Systems section, choose `Custom iPXE`. For the iPXE Script URL field, leave it empty as we will pass the iPXE script through User Data.

![custom-ipxe-selection](/images/custom-ipxe-selection.png)

At the Optional Settings section, there will be an option to add User Data. Enable the toggle and paste the following iPXE script in the User Data field.

```
#!ipxe
dhcp
imgfree

# pci=nocrs avoids BIOS tables and lets the kernel build its own which is needed for some m3.small.x86 systems based on Supermicro and ASRockRack Open19 with iGPU enabled and Intel E810 NIC. Otherwise the NIC will not work so DHCP fails and the boot fails. Other workarounds in BIOS are to enable MMIO over 4G or SR-IOV or disable the iGPU.

iseq ${product} SYS-510T-MR-EI018 && set kernel_opts pci=nocrs ||
iseq ${product} SYS-510T-MR1-EI018 && set kernel_opts pci=nocrs ||
iseq ${product} m3.small.x86 && set kernel_opts pci=nocrs ||

set base_url https://github.com/netbootxyz/ubuntu-squash/releases/download/22.04-0eccaa7c/
kernel ${base_url}vmlinuz initrd=initrd ip=dhcp boot=casper netboot=url url=${base_url}filesystem.squashfs intel_iommu=on iommu=pt console=tty0 console=ttyS1,115200 ${kernel_opts}
initrd ${base_url}initrd
boot
```

![ipxe-script-user-data](/images/ipxe-script-user-data.png)

There will also be an option to configure IPs. If you leave the toggle unchecked, the instance will be deployed with a /31 public IPv4 subnet, /31 private IPv4 subnet, and a /127 public IPv6 subnet.

**For many operating systems a /31 subnet size will work fine but there are cases where a /30 subnet is required at minimum such as for Microsoft Windows, VMware ESXi, TrueNAS, and pfSense. If that is the case, you will need to [request a /30 Elastic IP subnet](https://deploy.equinix.com/developers/docs/metal/networking/reserve-public-ipv4s/#requesting-public-ipv4-addresses) and then use that subnet as the [instance management subnet](https://deploy.equinix.com/developers/docs/metal/networking/reserve-public-ipv4s/#provisioning-with-a-reserved-public-ipv4-subnet).**

For this guide I will be installing Windows 10 so I will be using a /30 Elastic IP subnet for the instance management subnet. Here is what it would look like:

![configure-instance-ips](/images/configure-instance-ips.png)

Confirm your settings and click the `Deploy Now` button to start provisioning your server.

### Log in to the instance

Once the Equinix Metal instance has completed provisioning, click on it so that you can view the server's overview page. On this page you will be able to see additional information such as the management subnets. We need to log in to the [Out-of-Band console](https://deploy.equinix.com/developers/docs/metal/resilience-recovery/serial-over-ssh/) via SSH. You can get the Out-of-Band console SSH command through the button on the top of the instance overview page.

![out-of-band-console-button](/images/out-of-band-console-button.png)

Copy the command and run it on your local machine so that you can connect to the instance. Note that it is required to have a [public SSH key](https://deploy.equinix.com/developers/docs/metal/identity-access-management/ssh-keys/) added to your Equinix Metal account to be able to log in to the Out-of-Band console. Once you have logged in to the console, you should get a user login prompt similar to the following image. Type `ubuntu` and press `Enter` to log in to the shell.

![out-of-band-console](/images/out-of-band-console.png)

Once you are logged in to the shell as the `ubuntu` user, type the following and press enter to switch to the `root` user:

```
sudo su
```

### Run the ISO installation environment setup script

We need to install several packages to make the Rescue Mode environment ready for installing an ISO to the server. There are two options for this, automated (recommended) and manual.

#### Automated (recommended) (API key required)

The automated option provides the best experience as it eliminates a lot of steps and creates a Virtual Machine called XEPA that looks very similar to the physical host as it shares the same SMBIOS information and has the necessary PCI devices attached such as local storage and the management network interface (eth0). This means that the VM will be using the host's actual management Layer 3 Public IPv4 network for connectivity.

However, an API key is required which you can generate by following the instructions [here](https://deploy.equinix.com/developers/docs/metal/identity-access-management/api-keys/). Once you have your API key ready, you can run the following command to run the setup script:

```
sed -i "s/#DNS=/DNS=147.75.207.207 147.75.207.208/" /etc/systemd/resolved.conf ; systemctl restart systemd-resolved ; apt update && apt install -y jq curl ; wget -q -O setup-v2.sh https://raw.githubusercontent.com/enkelprifti98/metal-isometric-xepa-ubuntu/main/setup-v2.sh && chmod +x setup-v2.sh && clear && ./setup-v2.sh
```

#### Manual (no API key required)

The manual option does not require an API key and is useful for legacy systems that don't support IOMMU / PCI passthrough but it takes more steps. You can run the following command to run the setup script:

```
sed -i "s/#DNS=/DNS=147.75.207.207 147.75.207.208/" /etc/systemd/resolved.conf ; systemctl restart systemd-resolved ; apt update && apt install -y jq curl ; curl -s https://raw.githubusercontent.com/enkelprifti98/metal-isometric-xepa-ubuntu/main/setup.sh | bash
```

The script should only take less than a minute to complete depending on the speed of the system and package downloads. If it completed successfully, you should see the following output with the environment endpoints along with the boot mode the instance is running in, BIOS or UEFI.

![script-completed](/images/script-completed.png)

### Access the ISO installation environment

The simplest way to access the environment is by pointing your web browser to the public IPv4 address of the Equinix Metal instance which is found on the output of the setup script. The web browser should show this page:

![novnc](/images/novnc.png)

You can also use a VNC client of your choice and point it to the public IPv4 address of the Equinix Metal instance.

In both cases, you will be prompted to connect and enter a password which will be `admin`.

Once you have logged in, you will see the desktop UI. You may get a prompt about the Power Manager Plugin but you can just close the window by clicking the `X` button on the top right corner of the prompt. You might also see a notification about the Ethernet network being disconnected but you can ignore it.

![desktop](/images/desktop.png)

### Get the ISO

We need to get the ISO file first which will be Windows 10 for this guide. You have the option to either download the ISO from the web or you can upload your own files from your local machine.

#### Download the ISO

To download the ISO image, you can launch the Firefox web browser by clicking the browser icon on the dock at the bottom of the screen. It may take several seconds for the browser to open for the first launch.

![launch-web-browser](/images/launch-web-browser.png)

You should see the Firefox browser window open. At this point you can proceed with downloading the ISO of your choice.

![firefox](/images/firefox.png)

If you want to monitor the download you can click the downward facing arrow on the top right corner of the firefox window. To see where the ISO file was downloaded click the folder icon on the right side of the download. Downloads should be under the `/root/Downloads` folder by default.

![iso-download](/images/iso-download.png)

#### Upload the ISO

To upload the ISO image from your local machine, you can open another tab on your web browser and navigate to the File Transfer portal endpoint found at the output of the setup script. The File Transfer portal should look like the following image and you can log in with these credentials:

Username: `admin`

Password: `admin`

![file-transfer-portal-login-page](/images/file-transfer-portal-login-page.png)

Once you have logged in to the file transfer portal, you will have access to the entire root user directory. You can navigate to the folder of your choice where you want to upload the ISO such as the `Downloads` folder. To upload the ISO, click the up arrow icon on the top right corner of the portal, select the file option and choose your ISO in the local file browser prompt.

![file-transfer-portal-upload-file](/images/file-transfer-portal-upload-file.png)

### Create the ISO installation Virtual Machine

Once you have the ISO ready, you need to create a Virtual Machine so that you can install the Operating System to the local server storage.

Launch the Virtual Machine Manager by clicking the search icon on the dock at the bottom of the screen, then type `virtual machine manager` in the search field which should show the Virtual Machine Manager application as a search result. Double click on the application to start it.

![launch-virt-manager](/images/launch-virt-manager.png)

#### Automated Instructions

The Virtual Machine Manager application will look like the following image where you will notice there is a Virtual Machine called `xepa`. Open the xepa VM by double clicking on it, then click on the upper left `i` icon to show virtual hardware details.

![virt-manager-open-xepa-vm](/images/virt-manager-open-xepa-vm.png)

On the left sidebar of the virtual hardware details page click on `SATA CDROM 1`, then click `Browse` on the right side. On the new window click `Browse Local` to locate your ISO file.

![virt-manager-xepa-vm-add-iso](/images/virt-manager-xepa-vm-add-iso.png)

A new window will appear to locate the ISO file. Go to the Downloads folder or anywhere else that your ISO file might be located in and select it as the ISO media by double clicking the ISO file or click the `Open` button. Then click `Apply` to save the ISO media to the SATA CDROM.

![find-downloads-folder](/images/find-downloads-folder.png)

![select-iso-file](/images/select-iso-file.png)

Once your ISO is added to the VM SATA CDROM, you can start up the VM by clicking on the the left corner monitor icon to show the graphical video console and click on the play icon to power on the virtual machine. It may take a few seconds for the VM to power on.

![virt-manager-start-xepa-vm](/images/virt-manager-start-xepa-vm.png)

The VM should start booting from the ISO image and you can proceed with the rest of the [Operating System installation](#install-the-operating-system).

#### Manual Instructions

The Virtual Machine Manager application will look like the following image. Start the process of creating a Virtual Machine by clicking the monitor icon at the top left corner of the Virtual Machine Manager window.

![virt-manager](/images/virt-manager.png)

You will get a prompt asking how you would like to install the operating system. Choose the `Local install media (ISO image or CDROM)` option and click the `Forward` button.

![virt-manager-install-media](/images/virt-manager-install-media.png)

Then you will be asked to choose the ISO file. Click the `Browse...` button.

![virt-manager-browse-button](/images/virt-manager-browse-button.png)

A new window will appear to choose the storage volume, click the `Browse Local` button.

![virt-manager-browse-local-button](/images/virt-manager-browse-local-button.png)

A new window will appear to locate the ISO file. Go to the Downloads folder or anywhere else that your ISO file might be located in and select it as the ISO media.

![find-downloads-folder](/images/find-downloads-folder.png)

![select-iso-file](/images/select-iso-file.png)

Once you've selected your ISO file, at the bottom of the window there will be a field that automatically detects the Operating System.

In my case, Microsoft Windows 10 is detected successfully.

![virt-manager-windows-detected](/images/virt-manager-windows-detected.png)

However, for other ISO images the detection may not work. You need to uncheck the `Automatically detect from the installation media / source` box and search for `generic` in the operating system field. On the search results window, check the box for `Include end of life operating systems` and select the `Generic default (generic)` option. If your image is using a popular operating system under the hood such as Ubuntu or FreeBSD you could also choose those as the operating system profile instead of the generic option.

![virt-manager-generic-os](/images/virt-manager-generic-os.png)

After you have chosen your ISO file, click the `Forward` button. A prompt will appear saying that `The emulator may not have search permissions for the path to the ISO file` and asking you to correct it now, click the `Yes` button.

Then you need to allocate the RAM and CPU amount to the VM. I personally use 4096 MB (4 GB) and 4 CPUs but feel free to adjust those to your preference.

![virt-manager-ram-cpu-settings](/images/virt-manager-ram-cpu-settings.png)

Click the `Forward` button.

The next step is configuring storage for the VM. On the storage configuration window, choose the `Select or create custom storage` option. There is an empty field below the option where we have to set the local server storage disk device path.

![virt-manager-storage](/images/virt-manager-storage.png)

To look at the available local disks, open the terminal application at the dock on the bottom of the screen.

![launch-terminal](/images/launch-terminal.png)

Inside the terminal window, type `lsblk -p -e7` and press `Enter`. It will show the list of local storage drives along with their full device path (`/dev/sdX` or `/dev/nvmeXn1`) and size.

![list-storage](/images/list-storage.png)

**Depending on the server type you may see NVMe storage drives as well. You can only use them as the target for the bootable operating system if your instance is running in UEFI boot mode. NVMe drives cannot be used as bootable drives in BIOS boot mode.**

I recommend using the smallest available drive which in my case are `/dev/sdc` and `/dev/sdd`. For this guide I will be using `/dev/sdc`.

Type the `/dev/sdc` disk device path in the Virtual Machine Manager storage field and click the `Forward` button.

![virt-manager-storage-device-path](/images/virt-manager-storage-device-path.png)

On the last page, select the `Customize configuration before install` option and click the `Finish` button.

![virt-manager-customize-config-before-install](/images/virt-manager-customize-config-before-install.png)

A new overview window will appear where you can see the different hardware components of the virtual machine.

### Set Virtual Machine boot firmware

The boot firmware of the virtual machine should match with your instance. Your instance boot mode is provided at the output of the setup script. On the VM overview page, under the firmware option, select BIOS or UEFI depending on your instance.

![vm-boot-firmware](/images/vm-boot-firmware.png)

### Add serial consoles to the Virtual Machine

We need to add 2 serial console devices to the Virtual Machine so that we can enable it later after installing the Operating System. This is needed to make the Equinix Metal Out-of-Band console work.

Start adding the first serial console device by clicking the `+ Add Hardware` button on the bottom left corner of the window.

![virt-manager-add-hardware](/images/virt-manager-add-hardware.png)

On the left sidebar select the `Serial` category. On the right side leave everything as default and click the `Finish` button.

![virt-manager-add-serial-console-device](/images/virt-manager-add-serial-console-device.png)

Repeat this process once again to add the second serial console device.

You should see 2 serial devices on the VM overview sidebar once you have added them.

![virt-manager-add-serial-console-devices](/images/virt-manager-add-serial-console-devices.png)

### Add a TPM to the Virtual Machine

Some operating systems such as Microsoft's Windows 11 may require a Trusted Platform Module (TPM) chip to run. You can add an emulated TPM device to the virtual machine by clicking the `+ Add Hardware` button on the bottom left corner of the window.

![virt-manager-add-hardware](/images/virt-manager-add-hardware.png)

On the left sidebar select the `TPM` category. On the right side select the model as CRB, backend as Emulated device and Version as 2.0, then click the `Finish` button.

![tpm-hardware](/images/tpm-hardware.png)

### Attach a PCI device to the Virtual Machine

**Note: This step may not be possible on legacy server types that do not support IOMMU / VFIO PCI Passthrough properly such as the [c3.small.x86](https://github.com/dlotterman/metal_code_snippets/blob/main/metal_configurations/c3_small_x86/c3_small_x86.md). If the host does not support IOMMU or has not been configured properly, virt-manager will throw errors when starting the VM with PCI devices attached. Check with the Equinix Metal support team to verify that the server BIOS / UEFI settings for AMD-Vi / Intel VT-d / IOMMU have been enabled.**

The next step is to pass the physical networking PCIe card to the Virtual Machine which is done through IOMMU / VFIO PCI Passthrough. This is not required to proceed with the OS installation but it is helpful in cases where the original ISO image may not include the drivers needed for the network card so passing the physical device to the VM allows us to install the drivers through the internet provided to the virtual machine.

To do this, click the `+ Add Hardware` button on the bottom left corner of the window and a new one will appear.

![virt-manager-add-hardware](/images/virt-manager-add-pci-hardware.png)

On the left sidebar select the `PCI Host Device` category. On the right side you will see a large list of different PCI devices so you will need to find the networking card. Typically there will be `Ethernet controller` in the name of the PCI device so look for that.

```
domain number : bus number : device number : function number ... ... Ethernet Controller ... (interface ethX)
```

Once you have found it you will see 2 or 4 devices with the same name which represent each individual card. Equinix Metal instances typically come with 2 or 4 networking ports. If you scroll horizontally to the right side you will see `(interface eth0)` and `(interface eth1)`. This is also denoted by the PCI device function number at the beginning of the line so in my case it looks like the following:

```
0000:41:00:0 ... Ethernet Controller ... (interface eth0)
0000:41:00:1 ... Ethernet Controller ... (interface eth1)
```

**You cannot use the first device / interface eth0 as that is being used by the live linux environment for internet access. Therefore you need to choose any other interface so I will be using the second PCI device network card or interface eth1.**

![virt-manager-pci-device](/images/virt-manager-pci-device.png)

Once you have selected the networking PCI device, click the `Finish` button.

### Install the Operating System

On the VM overview window click the `Begin Installation` button on the top left corner of the window to start the virtual machine.

![virt-manager-begin-installation](/images/virt-manager-begin-installation.png)

A new window will appear with a video console of the Virtual Machine which should show the ISO image installer. You can maximize the window by clicking the square button on the top right corner of the window.

![virt-manager-maximize-window](/images/virt-manager-maximize-window.png)

At this point you can proceed with the installation process and you will notice that the local server disk we allocated earlier will appear as an installation target option.

![windows-installation-storage-selection](/images/windows-installation-storage-selection.png)

Once the installation has completed the VM will reboot into the operating system that was written to the local server disk.

![windows-desktop](/images/windows-desktop.png)

### Post installation configuration

After the operating system has been installed there are a few things to keep in mind before rebooting over to the physical host that will be running the operating system.

#### Networking driver

We need to make sure that the operating system has a working driver for the networking card so the server can get internet access and be managed remotely.

In many cases the operating system will already include a working driver as part of the vanilla ISO image installation.

If the OS does not contain the driver as part of the ISO image, it may be able to install the driver automatically through the internet. If not, you will need to download the driver manually through the networking card vendor driver download web pages as long as they support your operating system. To get internet access inside the virtual machine, you will need to add a virtual network adapter connected to the default NAT network and reboot the VM.

In the case of Microsoft Windows 10, the ISO image does not include drivers for my servers' networking card so I will be installing the driver through Windows Update via the internet. Looking at Device Manager, you will see the `Ethernet Controller` device that has no driver installed. That is the physical server PCI networking card that we passed to the VM.

![windows-device-manager-missing-nic-driver](/images/windows-device-manager-missing-nic-driver.png)

When we check windows update, there is an optional driver ready to be downloaded over the internet for our Intel Ethernet network card.

![windows-update-nic-driver-download](/images/windows-update-nic-driver-download.png)

Once the driver has been downloaded and installed, you will now notice in Device Manager that the physical networking card adapter is ready. The other Intel Gigabit network adapter is a virtual network adapter emulated by the virtual machine hypervisor that provides internet access to the VM.

![windows-device-manager-nic-ready](/images/windows-device-manager-nic-ready.png)

#### Serial console

The Equinix Metal Out-of-Band console is helpful in situations where the instance does not have internet access so it's a good idea to enable your operating system for serial console output.

More specifically, the Out-of-Band console uses the `COM2` serial port (I/O port `0x2F8`, IRQ 3) with a baud rate of `115200`, 8 data bits, no parity, and 1 stop bit.

In some cases, the operating system may have an option to enable the serial console through the GUI. If not, you may be able to do it through the following methods or other ways. Depending on how the OS starts the serial port numbering, you may need to set it as port 1 or port 2 if they start from 0 or not.

The standard edition of Windows does not support serial console output but if you're running Windows Server edition, we can enable Emergency Management Services (EMS) redirection with the following commands ran in Command Prompt as an Administrator:

```
bcdedit /bootems {default} ON
bcdedit /ems {current} ON
bcdedit /emssettings EMSPORT:2 EMSBAUDRATE:115200
```

![windows-enable-ems-serial-console](/images/windows-enable-ems-serial-console.png)

For Linux based operating systems, you can typically enable serial console output through the GRUB bootloader options found in `/etc/default/grub`. There you can add the following:

```
#GRUB_TIMEOUT_STYLE=hidden
GRUB_TIMEOUT_STYLE=menu
GRUB_TIMEOUT=3
GRUB_CMDLINE_LINUX="console=tty0 console=ttyS1,115200n8"
GRUB_TERMINAL="serial console"
GRUB_SERIAL_COMMAND="serial --unit=1 --speed=115200 --word=8 --parity=no --stop=1"
```

Once you've edited the GRUB config file, you may be able to apply the change with one of these GRUB commands depending on your distribution: `update-grub` / `update-grub2` / `grub-mkconfig -o /path/to/configfile` / `grub2-mkconfig -o /path/to/configfile`.

For BSD based operating systems you should be able to add serial console support by editing the `/boot/loader.conf` bootloader configuration file. Add the following to the config file:

```
boot_multicons="YES"
boot_serial="YES"
comconsole_speed="115200"
console="comconsole,vidconsole"
comconsole_port=0x2F8
```

In some cases the settings you set in `/boot/loader.conf` file can get changed/overwritten by the OS so it might be better to use `/boot/loader.conf.local` instead. The file might not exist by default so you can just create it.

Restart the virtual machine after you have configured the serial console settings inside the operating system for them to take effect.

To confirm that you have configured serial console output properly inside the operating system, you can open the terminal shell and run the following command if you followed the automated instructions:

```
virsh console xepa serial1
```

where `xepa` is the name of the xepa virtual machine. If you created the vm by following the manual instructions, you can run the following command instead:

```
virsh console win10 serial1
```

where `win10` is the name of my virtual machine. In your case the name of the VM may be different so replace it with your VM's name. You can see the VM name at the top of the running VM window.

![virt-manager-vm-name](/images/virt-manager-vm-name.png)

Note that `serial1` is the alias name of the second serial device (`Serial 2`) we added to the VM which corresponds to `COM2`. If you need to double check the alias name you can do so by viewing the XML settings of the serial device and look for `<alias name="serial1"/>`. The `Serial 2` device should also be using port 1 in `<target type="isa-serial" port="1">`.

On the other hand, the `Serial 1` device has alias name of `<alias name="serial0"/>` and is using port 0 in `<target type="isa-serial" port="0">` which corresponds to `COM1` or `0x3F8`. We need to be using the second serial device/port instead since that is what Equinix Metal uses for the Out-of-Band console.

You should be able to see output and also send keyboard input to the VM through the serial console. If you're not able to see any output you need to go back and adjust the operating system configuration.

#### Remote access

After we reboot over to the physical host booting from the local disk that has our installed operating system, we need to be able to access it remotely through its IP address. Remote access will depend on the operating system but typically it will either be RDP for Windows and SSH for almost everything else.

In windows, we can enable RDP in the settings app:

![windows-enable-remote-desktop](/images/windows-enable-remote-desktop.png)

For other operating systems, you need to install or enable the SSH server.

### Rebooting to the physical host

Once we have completed the post installation steps, we can prepare to reboot over to the physical host.

First shut down the virtual machine either through an option in the Operating System or use the `Shut Down` button of virtual machine manager. If the shutdown option doesn't work, use the `Force Off` option under the downard pointing arrow icon.

Then close all running applications. Disconnect from the VNC console or close the web browser window.

You can now reboot to the host by going to the server's Out-of-Band console and type `reboot`, then press `Enter`.

NOTE: Do not use the reboot function on the Equinix Metal portal as it sends a hard reset instead of a graceful shutfown signal so the automated cleanup process that runs during Rescue OS shutdown will not work.

<!---
Rebooting via the portal sends a hard reset instead of a graceful shutfown signal so the automated cleanup process will not work.

Go to the Equinix Metal console server overview page, click the `Server Actions` button and select the `Reboot` action.

![post-install-reboot-server](/images/post-install-reboot-server.png)

While the server is rebooting, you can monitor its progress through the [Out-of-Band console](https://metal.equinix.com/developers/docs/resilience-recovery/serial-over-ssh/#using-sos).
-->

You will notice the server will be trying to PXE boot over the network initially and loop through each network interface but it should eventually get to the OS boot drive. You can usually press `Escape` on your keyboard to cancel the PXE boot process. If it doesn't find the OS boot drive, it means that either the VM firmware did not match with the server (BIOS vs UEFI) or the OS was installed on an NVMe drive in a BIOS server which do not support booting an OS from NVMe drives, only UEFI servers can support NVMe drives as boot targets.

If there are any kernel panics during the OS boot process, it may potentially mean that your hardware is not supported by the kernel.

If you see any storage drive missing or filesystem mounting related errors during the OS boot process, it could potentially mean that the Operating System does not support or detect the underlying storage drives / controller. It could also mean that the OS boot configuration is set up by using disk or filesystem UUIDs which will differ when passing the server drives as virtual storage. Try installing the OS in a different drive type under a different HBA / storage controller. You can also [attach the PCI storage controller](#attach-a-pci-device-to-the-virtual-machine) to the VM inside the ISO installation environment to install the OS directly through the storage controller and verify if the OS can detect the drives or not.

While the server is booting into the OS, you should see logs appearing in the Out-of-Band console if the OS supports serial console output and was configured properly as shown [here](#serial-console).

Once the server has rebooted succesfully, you should be able to access it via RDP / SSH through its IP address or the Out-of-Band console.

![windows-rdp-session](/images/windows-rdp-session.png)

NOTE:

In many cases the operating system will automatically configure the network through DHCP for the first network interface only. It's recommended to configure a link aggregation group (LAG) with LACP (802.3ad) bonding for the server's network interfaces to achieve network redundancy if the operating system supports it. Otherwise you will experience downtime during network maintenance events performed by Equinix.

These are the recommended LAG LACP settings:

```
Mode:  Active - Active
Timeout:  Fast
Hash policy:  Layer 3+4
```

If you need to configure the network interfaces statically, the management subnet information can be found in the Equinix Metal portal instance overview page and for DNS servers you can use the following provided by Equinix Metal or any others that you may prefer:

```
Primary   DNS Server:  147.75.207.207
Secondary DNS Server:  147.75.207.208
```

At this point you're all set!

### Troubleshooting

In the case that you reboot over to the physical host and things such as the Out-of-Band console or remote access over the internet are not working, you can go back to the VM environment to troubleshoot.

To do so, set the instance to always PXE boot by going to the "Server Actions" button on the top right and click "Set to always pxe boot". Click Server Actions again and click Reboot.

![always-pxe-boot](/images/always-pxe-boot.png)

After the instance reboots, log in to the [Out-of-Band console](#log-in-to-the-instance). Then [run the ISO installation environment setup script](#run-the-iso-installation-environment-setup-script) and [access the ISO installation environment](#access-the-iso-installation-environment) through your web browser or VNC client.

Once you're back in the GUI environment, launch the Virtual Machine Manager by clicking the search icon on the dock at the bottom of the screen, then type `virtual machine manager` in the search field which should show the Virtual Machine Manager application as a search result. Double click on the application to start it.

![launch-virt-manager](/images/launch-virt-manager.png)

If you followed the automated intrusctions, you can just open the xepa virtual machine and power it on by clicking on the play icon.

If you followed the manual instructions, you can start the process of creating a Virtual Machine by clicking the monitor icon at the top left corner of the Virtual Machine Manager window.

![virt-manager](/images/virt-manager.png)

You will get a prompt asking how you would like to install the operating system. This time we will choose the `Import existing disk image` option and click the `Forward` button.

![virt-manager-import-disk-image](/images/virt-manager-import-disk-image.png)

Then you need to provide the local storage device path where the operating system was installed. This should be the same one that we used earlier which in my case was `/dev/sdc` but you can double check in the terminal with `lsblk -p -e7` or `fdisk -l` which will show several partitions under one of the storage drives.

![check-os-drive](/images/check-os-drive.png)

Search for your operating system or `generic` in the operating system field. On the search results window, check the box for `Include end of life operating systems` and select your specific OS or the `Generic default (generic)` option if nothing matches your OS. If your image is using a popular operating system under the hood such as Debian or Redhat, you can also choose those as the operating system instead of the generic option.

You can proceed with the rest of the VM hardware configuration settings and select the `Customize configuration before install` option and click the `Finish` button.

A new overview window will appear where you can see the different hardware components of the virtual machine. Add the [serial consoles](#add-serial-consoles-to-the-virtual-machine) and the [PCI networking card](#attach-a-pci-device-to-the-virtual-machine) to the virtual machine.

Once you have configured the VM settings you can click the `Begin Installation` button to start the VM. You can refer to the following sections of the guide to troubleshoot:

- [Post installation configuration](#post-installation-configuration)
  - [Networking driver](#networking-driver)
  - [Serial console](#serial-console)
  - [Remote access](#remote-access)

After you're done troubleshooting, go to the Equinix Metal portal instance overview page. Click the "Server Actions" button on the top right and click "Disable always PXE boot". Then you can [reboot back to the physical host](#rebooting-to-the-physical-host).
