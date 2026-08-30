#!/system/bin/sh
# Credit to ahmed-alnassif
MODPATH=${0%/*}

echo "rtw88: Loading modules..." > /dev/kmsg

if lsmod | grep -q mac80211; then
  rmmod mac80211 2> /dev/null
fi

ksud insmod $MODPATH/lkm/mac80211.ko 2> /dev/null

ksud insmod $MODPATH/lkm/rtw88_core.ko 2> /dev/null
ksud insmod $MODPATH/lkm/rtw88_usb.ko 2> /dev/null

ksud insmod $MODPATH/lkm/rtw88_88xxa.ko 2> /dev/null
ksud insmod $MODPATH/lkm/rtw88_8723x.ko 2> /dev/null

for mod in rtw88_8812a rtw88_8812au rtw88_8814a rtw88_8814au \
  rtw88_8821a rtw88_8821au rtw88_8821c rtw88_8821cu \
  rtw88_8822b rtw88_8822bu rtw88_8723d rtw88_8723du; do
  ksud insmod $MODPATH/lkm/$mod.ko 2> /dev/null
done

ksud insmod $MODPATH/lkm/r8188eu.ko 2> /dev/null

echo "rtw88 modules loaded" > /dev/kmsg
lsmod | grep -E "rtw|mac80211|cfg80211" > /dev/kmsg 2>&1
