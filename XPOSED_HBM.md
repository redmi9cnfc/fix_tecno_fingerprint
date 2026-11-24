# Подэкранный отпечаток (UDFPS) на TECNO Camon 30S / GSI

Рабочая схема из двух частей:

1. **Magisk-модуль `transsion_udfps`** — оживляет HAL, зажигает панель и снимает
   3-секундное ожидание uevent'а при каждой авторизации;
2. **Xposed-модуль `com.hbm.transsionudfps` (Vector/LSPosed)** — рисует значок
   отпечатка из настройки UDFPS внутри SystemUI, публикует состояние keyguard'а.

Системные APK не заменяются и не модифицируются.

## Почему не Magisk-модуль с заменой SystemUI

Замена `SystemUIGoogle.apk` на пересобранный **невозможна**:

* у пакета `sharedUserId="android.uid.systemui"` — PackageManager сверяет подпись с уже
  записанной в `/data/system/packages.xml`. Наш ключ (`CN=SystemUI Mod`) не совпадает
  с ключом сборщика GSI (`CN=Android`, SHA1 `B0:E2:7D:DB:...`) → пакет отбрасывается
  целиком, система висит на «Запуск устройства»;
* даже если обойти проверку, SystemUI просит **231** разрешение, из которых **94**
  выдаются только приложению с подписью платформы: `CONTROL_KEYGUARD`,
  `INTERNAL_SYSTEM_WINDOW`, `MANAGE_ACTIVITY_TASKS`, `ACCESS_SURFACE_FLINGER`,
  `STATUS_BAR_SERVICE`, `MONITOR_INPUT`, `MODIFY_TOUCH_MODE_STATE` … Без них SystemUI
  не работает в принципе;
* приватного ключа (`platform.pk8`) в прошивке нет — он есть только у сборщика GSI,
  а AOSP-testkeys не подходят (другой сертификат).

Поэтому правильный путь: **не трогать APK**, а добавить то же окно в рантайме.

---

## Часть 1. Magisk-модуль `transsion_udfps`

Файлы: `module.prop`, `service.sh`, `uevent_fp` в корне zip.

`service.sh` работает в цикле (200 мс) и решает три задачи.

### 1.1. Гейт «TP finger detect» в HAL

Silead-HAL игнорирует события драйвера тача:

```
[silead_cust]E[_cust_finger_detect_dispatch] not handle it
```

пока Transsion-фреймворк не пришлёт `sendCommand(10,1)`. GSI этого не делает
никогда → запись отпечатка уходит в таймаут, локскрин не реагирует.

Решение: держать включённым внутренний байт-гейт в `.bss` библиотеки
`/vendor/lib64/libsl_fp_impl.so` — **VA `0x6E4AC`** (смещение `0x674AC` от начала
r-xp-мэппинга). Пишется через `/proc/<pid>/mem`, проверяется каждые 2 с
(в т.ч. после рестарта HAL).

Параллельно `service.sh` пишет `1` в `/proc/fingerprint_status` — иначе драйвер
тача не генерирует FOD-ключ `EV_KEY 0x00c3`, и HAL не узнаёт о касании.

### 1.2. Подсветка зоны сенсора

Пока устройство заблокировано (или активен клиент отпечатка):

* яркость LED-подсветки → `max_brightness`;
* `echo 1 > /sys/devices/platform/soc/14013000.dsi/lcm_hbm_state` — настоящий HBM панели;
* `setprop sys.hbm.force 1` — Xposed-модуль рисует значок.

При снятии — всё возвращается. **Яркость `0` не восстанавливается никогда**: пока
панель погашена, `brightness` = 0, и запись этого значения после разблокировки давала
чёрный экран (выглядело как падение SystemUI). Если запомненной яркости нет,
восстановление просто пропускается.

### 1.3. uevent-фикс: почему отпечаток «не срабатывал»

Главная причина «медленного отпечатка (почти не определяется)».

HAL в `silfp_cust_wait_ui_ready()` ждёт до **3 секунд** kernel-uevent
`TRAN_FULL_HBM_EVENT=FULL_HBM_SET`:

```
waiting ui ...                       ← ждём сигнал
(ровно 3.020 с таймаута)
[AUTH_TIME] delay_time = 20ms        ← и только теперь захват кадра
```

Шлёт его display-драйвер Transsion из своего HBM-нотификатора, которого на GSI нет.
Каждая авторизация висела 3 секунды, палец к моменту захвата уже убран — отсюда
«почти не работает».

Ключевое наблюдение: HAL принимает этот uevent через обычный
`AF_NETLINK`/`NETLINK_KOBJECT_UEVENT` сокет (группа 1) и делает `strstr()` по строке
`TRAN_FULL_HBM_EVENT=FULL_HBM_SET` — то есть **userspace может послать его сам**.
Проверено дизассемблером `_cust_icon_hbm_status` (`+0x4c268`): после `strstr()` идёт
вызов `pthread_cond_signal` (`+0x4c4b0`).

`uevent_fp` — статический aarch64 ELF на 304 байта без libc (syscalls
`socket`/`sendto`/`nanosleep`/`exit`). Он отправляет 12 сообщений с шагом 15 мс, чтобы
попасть в окно ожидания auth-потока.

Триггер — событие `00c3 DOWN` от тача (его читает `getevent`): в этот момент HAL уже
(или вот-вот) войдёт в ожидание.

Результат:

```
finger down          18:08:57.795
waiting ui ...       18:08:57.806
uevent → signal      18:08:57.815
delay_time = 80ms    18:08:57.895
```

Ожидание: **3020 мс → 28–30 мс**. Полный цикл от касания до `accept` ≈ **195 мс**
(в т.ч. на выключенном экране, с первого касания).

### 1.4. Пауза перед захватом кадра

После сигнала HAL спит `persist.log.tag.fp.delay.*` мс и только потом снимает кадр.
Штатные 20 мс давали снимок в момент, когда палец ещё не прижат: ~30 % промахов.
`service.sh` выставляет:

```
setprop persist.log.tag.fp.delay.screenon    80
setprop persist.log.tag.fp.delay.screenoff   80
setprop persist.log.tag.fp.delay.screenblind 80
```

80 мс — стабильный кадр (9 из 9 совпали) при общем времени ~195 мс.

### 1.5. Пробуждение экрана по касанию (экран выключен)

Когда панель **полностью погашена**, она не светит вообще: сколько ни выставляй
яркость/HBM заранее, кадр получается чёрным и авторизация отклоняется. На стоковой
прошивке дисплей по FOD-касанию будит `UdfpsController`, но на GSI этот путь мёртв.

`service.sh` на каждое `00c3 DOWN` при заблокированном keyguard'е отправляет
`input keyevent 224` (KEYCODE_WAKEUP, ~40–70 мс) и только затем, через 50 мс, —
uevent. К моменту захвата кадра (ещё +80 мс) панель уже горит.

Результат на выключенном экране: **3 из 3 успешно**, 220–330 мс от касания до
`accept` (при включённом экране ~200 мс).

Так как экран уже разбужен, HAL идёт по ветке «screen on» — то есть используется
`persist.log.tag.fp.delay.screenon`, а не `screenoff`/`screenblind`. `service.sh`
дополнительно один раз «прогревает» утилиту `input` при старте, чтобы первое касание
после загрузки не платило за запуск `app_process` и панель успевала разгореться.

---

## Часть 2. Xposed-модуль (Vector / LSPosed)

Пакет `com.hbm.transsionudfps`, APK `out\TranssionUdfpsHbm.apk`.

### 2.1. Значок отпечатка вместо белого круга

Хук `UdfpsController#showUdfpsOverlay(...)` → прозрачное окно
`TranshitHBMController` (type `0x7e8`, `FORMAT_TRANSLUCENT = -3`), внутри — только
**белый значок из настройки UDFPS** (`Settings.System "udfps_icon"`, пак
`org.evolution.udfps.icons`). Белой подложки-круга больше нет: светятся только
пиксели глифа, как на Pixel. `hideUdfpsOverlay()` убирает окно.

Белый круг остаётся единственным fallback'ом и рисуется **только если пак
`org.evolution.udfps.icons` вообще не установлен** — иначе сенсор остался бы без
света. Если пак есть, но глиф не удалось загрузить (например, панель ещё не
готова сразу после старта), окно остаётся прозрачным, а вотчер повторяет попытку
каждые 300 мс — подложка не появляется.

`udfps_icon = 0` (`udfps_ic_none`, прозрачный глиф) — окно прозрачное, на экране
ничего не светится; это штатное поведение, а не сбой.

Параметры (system properties, читаются при каждом показе):

| property | по умолчанию | на устройстве |
|---|---|---|
| `persist.sys.phh.udfps.hbm_mode` | `band` | `circle` |
| `persist.sys.phh.udfps.hbm_x` | 540 | 540 |
| `persist.sys.phh.udfps.hbm_y` | 2179 | 2179 |
| `persist.sys.phh.udfps.hbm_radius` | 120 | 130 |

Итого окно 260×260 в (410, 2049) — центр (540, 2179); значок масштабируется под
`FIT_CENTER` на всю площадь окна.

Показывается, когда `sys.hbm.force` = 1 (это делает `service.sh`) либо SystemUI сам
запросил авторизацию. С v2.2 значок меняется **на лету**: вотчер сравнивает
`Settings.System "udfps_icon"` каждые 300 мс и перерисовывает глиф в уже
показанном окне (в лог: `udfps icon redraw -> N`), без переблокировки и без
перезапуска SystemUI. Проверено: `5 → 6` на заблокированном экране, скриншот
`ic5.png`/`ic6.png` — глиф без круга.

### 2.2. Состояние keyguard для `service.sh`

Модуль каждые ~250 мс публикует `1`/`0` в
`/data/user_de/0/com.android.systemui/files/keyguard` (device-protected storage,
читается и до разблокировки). Благодаря этому подсветка включена **до** того, как
панель проснётся, и первый же кадр после включения экрана уже освещён — иначе
требовалось второе касание.

Если файла ещё нет, `service.sh` падает на эвристику: касание `00c3` + `Fps state: 1`.

### 2.3. Значки UDFPS в Evolver

Evolver прячет пункты выбора значка, если не установлен пакет
`org.evolution.udfps.icons` (контракт: `string-array "udfps_icons"`, выбор хранится в
`Settings.System "udfps_icon"`). Пак установлен, поэтому настройка доступна и
сохраняется. Модуль читает её при каждом показе окна и рисует выбранный глиф
белым — без тонировки и без белого круга под ним.

---

## Установка

### 1. Zygisk

Magisk → **Настройки** → включить **Zygisk** → перезагрузка.
Если в сборке Magisk Zygisk нет — поставить NeoZygisk и включить его.

### 2. Xposed-фреймворк

**Vector** (наследник LSPosed, Android 8.1–17, классический Xposed API):

```
https://github.com/JingMatrix/Vector/releases/latest
```

Файл `Vector-v2.2-3080-Release.zip` установить в Magisk как модуль → перезагрузка.

### 3. Magisk-модуль

```
adb push udfps_module.zip /sdcard/
# Magisk → Модули → Установить из хранилища → udfps_module.zip → перезагрузка
```

Или вручную (без перезагрузки):

```
adb push uevent_fp service.sh module.prop /data/local/tmp/
adb shell su -c "M=/data/adb/modules/transsion_udfps; \
  rm -f \$M/service.sh \$M/module.prop \$M/uevent_fp; \
  cp /data/local/tmp/service.sh /data/local/tmp/module.prop /data/local/tmp/uevent_fp \$M/; \
  chmod 755 \$M/service.sh \$M/uevent_fp; sh \$M/service.sh &"
```

`cp` поверх существующего файла в `/data/adb/modules/...` даёт `Permission denied` —
поэтому сначала `rm -f`.

### 4. Наш Xposed-модуль

```
adb install -r out\TranssionUdfpsHbm.apk
```

Vector → **Modules** → **Transsion UDFPS HBM** → включить; в Scope должен быть
**System UI** (`com.android.systemui`) → перезагрузка (или
`adb shell su -c "killall com.android.systemui"`).

### 5. Значки (опционально)

Пак `org.evolution.udfps.icons` уже установлен. Пункт выбора появляется в Evolver →
Buttons/Other → UDFPS icons.

---

## Проверка

```
adb logcat -s TranshitHBM
```

Ожидаемо:

```
hooks installed on com.android.systemui ctx=true
keyguard 1
HBM window added (force, circle) 260x260 at 410,2049
HBM window removed
```

Состояние сервиса:

```
adb shell su -c "cat /data/local/tmp/udfps_fix.log"
```

```
--- start 2026-10-25_18:14:43 ---
2026-10-25_18:14:43 fod mode on
2026-10-25_18:14:43 fp ui on (prev_bl=128 bl=255 age=... fps=0 kg=1)
2026-10-25_18:14:51 gate pid=3462 addr=472083547308
2026-10-25_18:15:02 uevent fired rc=0
```

Замер задержки (коснуться сенсора во время записи):

```
adb shell su -c "logcat -T 100 -v threadtime -s fingerprint" | grep -E "waiting ui|delay_time|_stats_auth"
```

Правильная картина: между `waiting ui ...` и `delay_time = 80ms` **десятки мс**, а не
3020 мс; далее `[_stats_auth_dump] ... match`.

Полное время от `finger down` до `match`:

* экран включён — ~200 мс;
* экран выключен (перед этим — пробуждение панели) — 220–330 мс.

Визуально: при касании на локскрине — только выбранный значок (белый глиф), яркая
белая подсветка панели, без подложки-круга.

---

## Выключить / откатить

* Выключить подсветку, оставив модули:
  `adb shell su -c "resetprop -n persist.sys.phh.transsion_udfps_hbm false"`
  (обратно `true`).
* Вернуть полосу вместо круга:
  `adb shell su -c "resetprop -n persist.sys.phh.udfps.hbm_mode band"`
  (обратно `circle`).
* Отключить uevent-фикс (вернётся ожидание 3 с):
  `adb shell su -c "rm -f /data/adb/modules/transsion_udfps/uevent_fp"`
  и перезапустить сервис. Штатные задержки:
  `resetprop -n persist.log.tag.fp.delay.screenon 20` (аналогично screenoff/screenblind).
* Убрать Xposed-модуль: Vector → выключить → перезагрузка;
  либо `adb uninstall com.hbm.transsionudfps`.
* Убрать Magisk-модуль: `adb shell su -c "touch /data/adb/modules/transsion_udfps/remove"`
  → перезагрузка.

Никакие системные файлы не изменяются — откат всегда безопасен.

---

## Сборка

Xposed-модуль (v1.9, versionCode 10):

```
powershell -ExecutionPolicy Bypass -File .\build_xposed.ps1
```

Исходники: `xmod\src\com\hbm\transsionudfps\HbmModule.java`, заглушки Xposed API —
`xmod\stubs` (в APK **не** попадают). Ключ подписи: `hbm.jks` (alias `hbm`,
пароли `hbmpass`).

Магиск-модуль: файлы из `mod\` (`module.prop`, `service.sh`) + `uevent_fp` в корень
zip. Zip не сохраняет права, поэтому `service.sh` сам делает `chmod 755 uevent_fp`.
`service.sh` должен быть с LF, без BOM.

Генератор `uevent_fp`: `mkuevent.ps1` (PowerShell, собирает ELF побайтово).

---

## Что удалить, чтобы не путаться

* `out\systemui_hbm_SystemUIGoogle.zip` — старый Magisk-модуль с заменой APK (не работает);
* `out\systemui_transsion_hbm.zip` — то же, ещё более старый;
* `SystemUI_patched.apk` в корне проекта — неподписанный/невыровненный.
