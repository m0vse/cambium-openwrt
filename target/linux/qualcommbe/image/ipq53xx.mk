define Device/cambiumnetworks_miami-recovery
	$(call Device/FitImageLzma)
	DEVICE_VENDOR := Cambium Networks
	DEVICE_MODEL := Miami family
	DEVICE_VARIANT := RAM recovery
	SOC := ipq5332
	DEVICE_DTS := ipq5332-x7-35x-recovery
	DEVICE_DTS_CONFIG := config@mi01.6-acadia
	# The OEM U-Boot 2016.01 boots an LZMA FIT by its OEM configuration name.
	KERNEL = kernel-bin | lzma | cambium-family-fit lzma
	CAMBIUM_FIT_BOARDS := mi01.6-acadia:mi01.6-acadia:ipq5332-x7-35x-recovery
	SUPPORTED_DEVICES := cambiumnetworks,x7-35x
	IMAGES :=
	DEVICE_PACKAGES := kmod-ath12k ath12k-firmware-qcn9274 kmod-qrtr-smd \
		ethtool ip-full cambium-miami-support \
		-e2fsprogs -kmod-fs-ext4 -losetup -kmod-usb3 -kmod-usb-dwc3 -kmod-usb-dwc3-qcom
endef
TARGET_DEVICES += cambiumnetworks_miami-recovery

define Device/cambiumnetworks_miami-persistent
	$(call Device/cambiumnetworks_miami-recovery)
	$(call Device/UbiFit)
	DEVICE_VARIANT := persistent
	DEVICE_DTS := ipq5332-x7-35x-persistent-slot0 ipq5332-x7-35x-persistent-slot1 \
		ipq5332-x7-35x-persistent-ab
	DEVICE_DTS_CONFIG := config@mi01.6-acadia-slot0
	# Per model: the bank 0 and bank 1 trees used beside the OEM firmware
	# (only that bank writable) and the Cambium A/B tree (both banks).
	CAMBIUM_FIT_BOARDS := mi01.6-acadia-slot0:mi01.6-acadia-slot0:ipq5332-x7-35x-persistent-slot0 \
		mi01.6-acadia-slot1:mi01.6-acadia-slot1:ipq5332-x7-35x-persistent-slot1 \
		mi01.6-acadia-ab:mi01.6-acadia-ab:ipq5332-x7-35x-persistent-ab
	BLOCKSIZE := 128k
	PAGESIZE := 2048
	NAND_SIZE := 256m
	IMAGE_SIZE := 98304k
	# A/B banks: kernel (0), rootfs (1), rootfs_data (2) and the per-bank
	# device-data vault (3), which holds the Q6 firmware and every regional
	# board file (72 LEBs).
	CAMBIUM_VAULT_SIZE := 9142272
	# cambium-install.sh writes kernel.itb and rootfs.squashfs into the
	# stock firmware's inactive bank volume by volume (as validated), so a
	# reinstall can keep the settings; factory.ubi is the same bank.
	IMAGES := kernel.itb rootfs.squashfs factory.ubi sysupgrade.bin
	IMAGE/kernel.itb := append-kernel
	IMAGE/rootfs.squashfs := append-rootfs
	IMAGE/factory.ubi := cambium-ab-ubi
	IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
	BOARD_NAME := cambiumnetworks_miami
	DEVICE_PACKAGES += uboot-envtools
endef
TARGET_DEVICES += cambiumnetworks_miami-persistent

define Build/fit-inline-rootfs
	rm -f $@.dtb $@.kernel
	cp $@ $@.kernel
	cp $(word 2,$(1)) $@.dtb
	cp $@.kernel $@
	$(call Build/fit-its,$(word 1,$(1)) $@.dtb with-rootfs)
	$(call Build/fit-image,$(word 1,$(1)) $@.dtb with-rootfs)
	kernel_size="$$(stat -c%s $@.kernel)"; \
	rootfs_offset="$$(grep -oba hsqs $@ | \
		awk -F: -v limit="$$kernel_size" '$$1 >= limit {print $$1; exit}')"; \
	[ -n "$$rootfs_offset" ] || { echo "Failed to locate SquashFS in $@"; exit 1; }; \
	pad="$$(( (4096 - ($$rootfs_offset % 4096)) % 4096 ))"; \
	cp $(word 2,$(1)) $@.dtb; \
	dd if=/dev/zero bs=1 count="$$pad" >> $@.dtb 2>/dev/null; \
	cp $@.kernel $@; \
	$(call Build/fit-its,$(word 1,$(1)) $@.dtb with-rootfs)
	$(call Build/fit-image,$(word 1,$(1)) $@.dtb with-rootfs)
	kernel_size="$$(stat -c%s $@.kernel)"; \
	rootfs_offset="$$(grep -oba hsqs $@ | \
		awk -F: -v limit="$$kernel_size" '$$1 >= limit {print $$1; exit}')"; \
	[ "$$(( $$rootfs_offset % 4096 ))" -eq 0 ] || { echo "SquashFS is misaligned in $@"; exit 1; }; \
	rm -f $@.dtb $@.kernel
endef
