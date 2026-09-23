#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
	echo "Usage: $0 thor-xv3-8.itb" >&2
	exit 2
fi
fit=$1
selector=$(dirname "$0")/select-fit-config.sh
flavor=${THOR_FLAVOR:-recovery}

case "$flavor" in
	recovery) expected_configs='config@hk02
config@hk01.c6' ;;
	persistent) expected_configs='config@hk02' ;;
	*) echo "Unknown Thor FIT flavor: $flavor" >&2; exit 2 ;;
esac
test "$(fdtget -l "$fit" /configurations)" = "$expected_configs"
test "$(fdtget -t s "$fit" /configurations default)" = 'config@hk02'
test "$(THOR_FLAVOR="$flavor" sh "$selector" "$fit" 19)" = 'config@hk02'
if [ "$flavor" = recovery ]; then
	test "$(THOR_FLAVOR=recovery sh "$selector" "$fit" 30)" = 'config@hk01.c6'
else
	if THOR_FLAVOR=persistent sh "$selector" "$fit" 30 >/dev/null 2>&1; then
		echo 'Persistent selector accepted unvalidated XE5-8 SKU 30' >&2
		exit 1
	fi
fi
if sh "$selector" "$fit" 99 >/dev/null 2>&1; then
	echo 'Selector accepted unknown SKU 99' >&2
	exit 1
fi

kernel=$(fdtget -t s "$fit" /configurations/config@hk02 kernel)
test "$(fdtget -t s "$fit" "/images/$kernel" compression)" = none
test "$(fdtget -t x "$fit" "/images/$kernel" load)" = 41000000
test "$(fdtget -t x "$fit" "/images/$kernel" entry)" = 41000000

printf 'Thor FIT contains the explicit hardware-validated XV3-8/SKU-19 mapping only.\n'
