# Jaguar 6 GHz stock port: pending validation and push

Recorded 5 October 2026. Stock commit `649ac585ee` ports the tested ath11k
6 GHz LPI AP TPC fix to backports 7.2 and bumps mac80211's package release.
It is committed locally but has not been pushed, compiled into a stock
firmware image, or tested on physical hardware with the stock kernel.

The source archive hash and stock patch stack through ath11k were checked;
the patch applies with zero fuzz. All 192 actual TPC predicate combinations,
channel-context/LPI/station-mode invariants, and eight existing OEM API-2
loader tests passed. These checks do not establish hardware acceptance.

Retain the existing own-OEM XE3-4 board-data loader and the unit's calibration.
The September 2026 qca-wireless XE3-4 board file is byte-identical to the older
generic entry. The newer package date does not establish generic 6 GHz
support. OEM binaries are not included in this commit or redistributed.

Hardware may not be available imminently. Field testing may provide the
initial stock hardware validation. Record the exact image/source revision,
model, kernel, driver and board-data selection with any field result. Test
normal/cold boot, explicitly configured regulatory-compliant LPI operation,
6 GHz discovery and HE160 client association with bidirectional traffic,
scanning and configuration reapplication without loss of power or SSIDs,
and 2.4/5 GHz and DFS regressions. Power readbacks are not calibrated RF
measurements; extended stability and A/B confirmation should also be recorded.

The driver adaptation is from an unmerged upstream proposal. It preserves
firmware/service/subtype/band guards and station power modes; it does not
implement VLP or standard-power AP operation or override regulatory limits.
Earlier OpenWiFi hardware results support the approach, but do not qualify
the stock build or every Jaguar model.

Follow-up: build and validate the stock image when hardware or field testers
are available, record results and outstanding limitations, and push the port
and this note at the appropriate release step. If published for field testing
before acceptance, identify it as a test candidate with validation pending.
