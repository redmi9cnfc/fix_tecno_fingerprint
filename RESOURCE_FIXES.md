# Починка `apktool b SystemUI_src`

## 1. Ошибка smali

```
StatusBarFragmentModule_GetStatusBarLocationFactory$InstanceHolder.smali[1,0]
required (...)+ loop did not match anything at input '
```

Файл корректный (проверен отдельным ассемблером — `ASSEMBLED=true`). Ошибка возникала
из-за сбоя/гонки при параллельной сборке smali. После чистого прохода сборка
собирается и с `-j 1`, и с параметрами по умолчанию.

Если повторится:

```
java -jar apktool_3.0.3.jar b SystemUI_src -j 1 -o out\SystemUI.apk
```

Также помогает удалить `SystemUI_src\build` перед сборкой.

## 2. Приватные ресурсы framework (`resource android:... is private`)

aapt2 (Android 15+) запрещает ссылки на приватные ресурсы платформы. В AOSP это
делается так же — через namespace `androidprv` и «звёздочку» у пакета.

Правила замены:

| Было | Стало | Где |
|---|---|---|
| `@android:<type>/<name>` | `@*android:<type>/<name>` | `res/**/*.xml` + `AndroidManifest.xml` |
| `?android:^attr-private/<attr>` | `?androidprv:attr/<attr>` | `res/**/*.xml` (+ `xmlns:androidprv=...` в корне) |
| `<item name="android:<attr>">` для приватного attr | `<item name="androidprv:<attr>">` | `res/values*/styles.xml` |

`?androidprv:attr/...` и `@*android:...` дают **те же самые resource ID**, что были
в оригинальном APK (проверено дампом `aapt2 dump resources`).

Массовая замена сделана скриптом `fix_private_res.ps1` (лежит рядом):

* `346` замен `^attr-private` → `androidprv:attr`
* `2415` замен `@android:` → `@*android:`
* xmlns добавлен в 5 файлов

Ручные правки после скрипта:

* `res/values/styles.xml` — 8 записей `<item name="android:...">` с приватными attr:
  `floatingToolbarDividerColor` (2), `gestureOverlayViewStyle` (2),
  `tooltipVerticalPadding` (2), `monthTextAppearance`, `colorProgressBackgroundNormal`
* `AndroidManifest.xml` — 12 ссылок `@android:style/...` → `@*android:style/...`
* `res/layout/media_projection_app_selector.xml` — атрибуты были декодированы с
  неверными именами (см. п.3), исправлено на:
  `android:maxWidth`, `androidprv:maxCollapsedHeight="10000.0dp"`,
  `androidprv:maxCollapsedHeightSmall="56.0dp"`, `androidprv:layout_alwaysShow="true"`

## 3. ВАЖНО: framework не совпадает с APK

Установленный framework `C:\Users\vbmeta\AppData\Local\apktool\framework\1.apk` —
это **AOSP Android 16** (`versionCode=36`), а SystemUI.apk — **Android 15**
(`targetSdk=35`). Поэтому приватные attr'ы в декомпиле названы по чужой таблице и
часть имён «съехала»:

```
оригинал в APK:  prv:maxCollapsedHeight     = 0x011200d3
в framework 1.apk: maxCollapsedHeight       = 0x01120092
в декомпиле было: preferenceListStyle       (имя 0x011200d3 из таблицы Android 16)
```

Поскольку apktool и декодирует, и кодирует по одной и той же таблице, ID при
пересборке восстанавливаются такие же, как в оригинале. Но если планируется
ковырять ресурсы дальше — лучше поставить framework от целевого устройства:

```
apktool if framework-res.apk     # из /system/framework/ целевого девайса
# ids: в apktool.yml должен стать новый номер (не 1)
```

## 4. Сборка

```
cd C:\systemuiudps\apktool+3.0.3
java -jar apktool_3.0.3.jar b SystemUI_src -o out\SystemUI.apk
```

Результат: `out\SystemUI.apk` — 5 dex (`classes..classes5.dex`), `resources.arsc`
и dex лежат без сжатия (stored), как в оригинале. APK **не подписан** — подпись
нужно ставить отдельно (`apksigner`/MT Manager), как и раньше.

HBM-код (TranshitHBMController, `persist.sys.phh.transsion_udfps_hbm`) — в
`classes2.dex`.
