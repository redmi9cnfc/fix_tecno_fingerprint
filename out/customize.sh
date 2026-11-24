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

# ---- 1. проверка подписи APK (v2+) ----
# неподписанный/подписанный только v1 APK = SystemUI не запустится -> бутлуп
if ! grep -q "APK Sig Block 42" "$APK_IN_MODULE"; then
  abort "! APK не подписан схемой v2+. Переподпиши out/SystemUI.apk и собери модуль заново."
fi

# ---- 2. найти реальный путь SystemUI в системе ----
TARGET_PART=""
TARGET_NAME=""
for PART in system_ext system product; do
  DIR="/$PART/priv-app/SystemUI"
  if [ -d "$DIR" ]; then
    SRC=$(ls "$DIR"/*.apk 2>/dev/null | head -n 1)
    if [ -n "$SRC" ]; then
      TARGET_PART="$PART"
      TARGET_NAME=$(basename "$SRC")
      break
    fi
  fi
done

[ -n "$TARGET_PART" ] || abort "! Не найден каталог SystemUI (/system_ext|/system|/product/priv-app/SystemUI)"

ui_print "- цель: /$TARGET_PART/priv-app/SystemUI/$TARGET_NAME"

# ---- 3. разложить по структуре модуля ----
mkdir -p "$MODPATH/$TARGET_PART/priv-app/SystemUI"
mv -f "$APK_IN_MODULE" "$MODPATH/$TARGET_PART/priv-app/SystemUI/$TARGET_NAME"

# ---- 4. права ----
find "$MODPATH" -type d -exec chmod 0755 {} +
find "$MODPATH" -type f -exec chmod 0644 {} +

# ---- 5. подсказки ----
if [ -f "/$TARGET_PART/priv-app/SystemUI/oat/arm64/${TARGET_NAME%.apk}.odex" ] || \
   [ -f "/$TARGET_PART/priv-app/SystemUI/oat/arm/${TARGET_NAME%.apk}.odex" ]; then
  ui_print "- в системе есть preopt (.odex): ART пересоберёт кеш сам"
fi

ui_print "- установлено. Перезагрузись."
ui_print "- HBM включается: resetprop -n persist.sys.phh.transsion_udfps_hbm true"
ui_print "- откат: удалить /data/adb/modules/systemui_transsion_hbm"
