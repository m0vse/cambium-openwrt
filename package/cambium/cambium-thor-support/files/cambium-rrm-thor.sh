#!/bin/sh
# Cambium RRM module for the Thor family. See cambium-rrm.sh.
#
# The XV3-8 has a dedicated scanning radio: the QCA9887 on PCIe 1, driven by
# ath10k. The measurement agent may scan with it at any time without
# affecting clients on the three serving radios.

case " ${RRM_SCAN_RADIOS:-} " in
*" cambiumnetworks,xv3-8:ath10k_pci "*) ;;
*) RRM_SCAN_RADIOS="${RRM_SCAN_RADIOS:+$RRM_SCAN_RADIOS }cambiumnetworks,xv3-8:ath10k_pci" ;;
esac
