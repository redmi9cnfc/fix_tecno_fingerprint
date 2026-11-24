# Установка SystemUI в систему (Magisk-модуль и альтернативы)

## 0. Сначала про подпись — это главный блокер

Оригинальный `SystemUI.apk` подписан **ключом вендора**:

```
Owner: EMAILADDRESS=android@android.com, CN=Android, OU=Android, O=Android,
       L=Mountain View, ST=California, C=US
SHA1:  B0:E2:7D:DB:A9:33:07:6E:AC:E0:04:61:50:CA:8D:CD:03:81:94:FD
SHA256:44:0F:11:48:A9:6D:31:DC:35:74:3F:6E:4C:A5:D5:09:F6:12:4F:84:3D:5D:8F:C4:68:49:27:55:56:BB:F8:4B
Действителен: 27.08.2024 — 13.01.2052
```

Это **не** AOSP testkey, приватного ключа у нас нет. В манифесте
`android:sharedUserId="android.uid.systemui"`, поэтому PackageManager при загрузке
сверяет подпись нового APK с записью в `/data/system/packages.xml`. Чужая подпись =
SystemUI не сканется, в logcat:

```
Signature mismatch for shared user: android.uid.systemui
```

и на экране чёрный фон / «System UI isn't responding».

> **Текущий статус:** собранный `out\SystemUI_signed.apk` подписан **локальным**
> ключом `systemui.jks` (`CN=SystemUI Mod`,
> SHA-256 `07:9b:9c:59:97:12:8d:60:92:29:d5:70:12:c9:82:cb:f9:99:9b:ae:ac:73:c7:bb:ae:d6:10:3c:e4:33:41:23`),
> то есть с вендорским он **не совпадает**. На системе с работающей проверкой
> подписи такой APK не запустится — нужен один из вариантов ниже (ключ вендора,
> CorePatch или прошивка образа с wipe data).

Варианты решения (любой один):

| Вариант | Комментарий |
|---|---|
| Подписать **ключом платформы (вендора)** | Единственный «чистый» путь. Если ключ есть — просто `apksigner sign --key platform.pk8 --cert platform.x509.pem` |
| Отключить проверку подписи | LSPosed + CorePatch (или патч `services.jar`). Проверка живёт в `system_server`, стартует раньше SystemUI — работает |
| Прошить образ целиком со **сбросом data** | `packages.xml` создаётся заново → подойдёт любой ключ. Так делают при портировании ROM |
| Оставить оригинальную подпись | Невозможно: любой изменённый APK = новая подпись |

Если ничего из этого нет — не ставьте модуль на рабочую систему: SystemUI не
поднимется.

---

## 1. Подготовка APK (порядок важен!)

```
# 0) путь к build-tools (взят из Unity SDK)
$BT = "C:\Program Files\Unity\Hub\Editor\2021.3.45f2\Editor\Data\PlaybackEngines\AndroidPlayer\SDK\build-tools\34.0.0"

# 1) сборка
java -jar apktool_3.0.3.jar b SystemUI_src -o out\SystemUI.apk

# 2) выравнивание (аналог zipalign)
powershell -ExecutionPolicy Bypass -File .\zipalign_apk.ps1
#    -> out\SystemUI_aligned.apk   (.so -> 16384, resources.arsc -> 4096)

# 3) подпись (v2+v3)
& "$BT\apksigner.bat" sign --v1-signing-enabled false --v2-signing-enabled true --v3-signing-enabled true `
    --ks .\systemui.jks --ks-pass pass:systemui --key-pass pass:systemui `
    --out out\SystemUI_signed.apk out\SystemUI_aligned.apk

# 4) проверка
powershell -ExecutionPolicy Bypass -File .\check_apk.ps1 -Apk .\out\SystemUI_signed.apk

# 5) модуль
powershell -ExecutionPolicy Bypass -File .\make_module.ps1 -Apk .\out\SystemUI_signed.apk
#    -> out\systemui_transsion_hbm.zip
```

Ключ `systemui.jks`: alias `systemui`, пароли `systemui`. Для переподписи
вендорским ключом — заменить параметры `--ks/--ks-pass/--key-pass` на
`--key platform.pk8 --cert platform.x509.pem`.

**Почему шаг 2 обязателен:** в манифесте `android:extractNativeLibs="false"`, значит
`lib/arm64-v8a/libtensorflowlite_jni.so` грузится mmap'ом прямо из APK и должен быть
выровнен по странице. apktool выравнивание не делает (в оригинале было 4096).
Без этого — падение при загрузке нативной библиотеки.

Порядок «выровнять → подписать» тоже важен: `apksigner`/MT Manager подпись
**добавляют** signing block, не сдвигая данные, поэтому выравнивание сохраняется.
Если инструмент пересобирает zip — выравнивание потеряется.

---

## 2. Magisk / KernelSU / APatch модуль (systemless)

```
out\systemui_hbm_SystemUIGoogle.zip
 ├── module.prop
 ├── customize.sh      # сам находит путь SystemUI и проверяет подпись
 ├── system.prop       # HBM включён по умолчанию
 └── SystemUI.apk
```

`customize.sh` ищет APK по списку путей (сначала твой вариант):

```
/system/system_ext/priv-app/SystemUIGoogle   <- твоё устройство
/system/system_ext/priv-app/SystemUI
/system_ext/priv-app/SystemUIGoogle
/system_ext/priv-app/SystemUI
/system/priv-app/SystemUIGoogle
/system/priv-app/SystemUI
/product/priv-app/...
```

и раскладывает файл **зеркалом реального пути**, сохраняя имя
(для тебя: `$MODPATH/system/system_ext/priv-app/SystemUIGoogle/SystemUIGoogle.apk`).

Установка:

1. Magisk → **Модули** → «Установить из хранилища» → выбрать zip.
2. Перезагрузка.
3. `customize.sh` сам определяет раздел (`/system_ext`, `/system`, `/product`),
   имя файла (`SystemUI.apk` и т.п.) и раскладывает APK по нужному пути.
   Если APK не подписан v2+ — установка прервётся (защита от бутлупа).

Проверка после загрузки:

```
adb shell pm path com.android.systemui
adb shell dumpsys package com.android.systemui | findstr versionName
```

Откат:

* **Magisk Safe Mode**: зажать Vol Down при появлении анимации загрузки — модули
  отключаются, система грузится штатно.
* TWRP / root: удалить каталог `/data/adb/modules/systemui_transsion_hbm` и ребут.
* `magisk --remove-modules` (если есть adb).

### Включение/выключение HBM

В текущем модуле HBM **включён по умолчанию**: в `magisk\system.prop` раскомментирована
строка `persist.sys.phh.transsion_udfps_hbm=true`, Magisk применяет её при каждой
загрузке.

Выключить: закомментировать строку в `magisk\system.prop`, пересобрать модуль и
переустановить; либо разово:

```
adb shell su -c "resetprop -n persist.sys.phh.transsion_udfps_hbm false"
```

Проверка:

```
adb shell getprop persist.sys.phh.transsion_udfps_hbm
adb logcat | findstr /i "TranshitHBM UdfpsController"
```

---

## 3. Другие способы

### 3.1. Вшить в образ ROM (если портируешь)

Положить подписанный APK в образ по тому же пути
(`system_ext/priv-app/SystemUI/SystemUI.apk`), прошить ROM **с wipe data** —
запись о подписи создаётся заново, конфликта нет. Это самый надёжный путь для
порта, если ключа вендора нет.

### 3.2. Прямая замена в /system

Только если есть RW-доступ (Android 10+ `/system` обычно read-only + dm-verity):

```
mount -o rw,remount /
cp SystemUI.apk /system_ext/priv-app/SystemUI/SystemUI.apk
chmod 644 /system_ext/priv-app/SystemUI/SystemUI.apk
chown root:root /system_ext/priv-app/SystemUI/SystemUI.apk
restorecon -v /system_ext/priv-app/SystemUI/SystemUI.apk
```
плюс `rm -rf /data/dalvik-cache/*SystemUI*` и перезагрузка.
Минус — откат сложнее, чем у Magisk-модуля.

### 3.3. ADB (только userdebug/eng прошивки)

```
adb root
adb remount
adb push SystemUI.apk /system_ext/priv-app/SystemUI/SystemUI.apk
adb shell stop && adb shell start
```

---

## 4. Если SystemUI не поднялся

1. Подключить adb (если успевает) и смотреть:
   ```
   adb logcat -b all | findstr /i "systemui signature PackageManager"
   ```
2. Типовые причины:
   * `Signature mismatch for shared user` → подпись (см. п.0);
   * `Failed to extract native libraries` / `dlopen failed` → не сделан шаг 2
     (выравнивание);
   * `Resources$NotFoundException` / странный вид UI → пересобранные ресурсы не
     совпали с framework (см. `RESOURCE_FIXES.md`, п.3 про Android 16 vs 15).
3. Быстрый откат — Safe Mode или удаление каталога модуля из TWRP.
