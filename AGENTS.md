# Stock OpenWrt / OpenWiFi boundary

This repository builds stock Cambium OpenWrt. OpenWiFi-specific code belongs
in the OpenWiFi firmware repositories (`wlan-ap` / `wlan-ap-legacy-targets`),
not here, even if it is optional or dormant on stock images.

Do not add uCentral identity, discovery, certificate-store layouts, onboarding,
controller protocol, or OpenWiFi-renderer naming assumptions to stock packages.
Shared fixes may live here only when they independently benefit stock OpenWrt:
hardware support, generic A/B safety, configurable networking, and diagnostics.
Keep shared implementations controller-neutral and test stock behaviour.
Generic family tasks should continue committing appropriate stock OpenWrt
improvements here. Contribution origin does not decide placement; behaviour
and usefulness to stock OpenWrt do.

Before committing, inspect the whole change (including family modules, tests,
package installation rules and build profiles) for this boundary. Preserve
OpenWiFi-specific changes in their own repositories; do not silently remove
them from existing OpenWiFi firmware or change deployed APs during cleanup.

Use commit identity Phil Taylor <phil@m0vse.uk>.
