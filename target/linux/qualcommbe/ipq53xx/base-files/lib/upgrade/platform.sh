# SPDX-License-Identifier: GPL-2.0-only

platform_check_image() {
	# Cambium A/B family images must never reach a generic NAND path; before
	# cambium-ab-convert (OEM firmware in the other bank) this refuses.
	if command -v ab_family >/dev/null && ab_family; then
		cambium_ab_check_image "$1"
		return
	fi
	return 1
}

platform_do_upgrade() {
	if command -v ab_family >/dev/null && ab_family; then
		cambium_ab_do_upgrade "$1"
		return
	fi
	echo "Sysupgrade is not supported on this board"
	return 1
}
