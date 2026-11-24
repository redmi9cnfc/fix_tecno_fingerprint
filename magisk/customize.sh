#!/system/bin/sh

# ---- helpers (работают и в Magisk, и в KernelSU/APatch) ----
command -v ui_print >/dev/null 2>&1 || ui_print() { echo "$1"; }
command -v abort    >/dev/null 2>&1 || abort()    { echo "$1"; exit 1; }

SKIPUNZIP=0

ui_print "*******************************"
ui_print " SystemUI Transsion HBM (UDFPS)"
ui_print "*******************************"

APK_IN_MODULE="$MODPATH/SystemUI.apk"
[ -f "$APK_IN_MODULE" ] || abort "! SystemUI.apk отсутствует в архиве модуля"

# ---- 1. проверка подписи APK (v2/v3) ----
# без подписи SystemUI не запустится -> чёрный экран
if ! grep -q "APK Sig Block 42" "$APK_IN_MODULE"; then
  abort "! APK не подписан схемой v2+. Переподпиши out/SystemUI_signed.apk и собери модуль заново."
fi

# ---- 2. найти реальный APK SystemUI ----
# первый в списке - целевое устройство: nubia/Pixel-style ROM
CANDIDATES="/system/system_ext/priv-app/SystemUIGoogle
/system/system_ext/priv-app/SystemUI
/system_ext/priv-app/SystemUIGoogle
/system_ext/priv-app/SystemUI
/system/priv-app/SystemUIGoogle
/system/priv-app/SystemUI
/product/priv-app/SystemUIGoogle
/product/priv-app/SystemUI
/system/product/priv-app/SystemUIGoogle
/system/product/priv-app/SystemUI"

TARGET=""
for DIR in $CANDIDATES; do
  FOUND=$(ls "$DIR"/*.apk 2>/dev/null | head -n 1)
  if [ -n "$FOUND" ]; then
    TARGET="$FOUND"
    break
  fi
done

[ -n "$TARGET" ] || abort "! Не найден APK SystemUI ни по одному известному пути"

REL="${TARGET#/}"          # system/system_ext/priv-app/SystemUIGoogle/SystemUIGoogle.apk
REL_DIR=$(dirname "$REL")  # system/system_ext/priv-app/SystemUIGoogle

ui_print "- цель: /$REL"

# ---- 3. разложить по структуре модуля (зеркало реального пути) ----
mkdir -p "$MODPATH/$REL_DIR"
mv -f "$APK_IN_MODULE" "$MODPATH/$REL"

# ---- 4. права ----
find "$MODPATH" -type d -exec chmod 0755 {} +
find "$MODPATH" -type f -exec chmod 0644 {} +

# ---- 5. подсказки ----
ui_print "- установлено. Перезагрузись."
ui_print "- HBM включён по умолчанию (system.prop)"
ui_print "- откат: удалить /data/adb/modules/systemui_transsion_hbm"
