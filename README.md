# Резерв для iPhone

Приложение считает запас энергии на день (0–100) по данным Apple Health: сон и его стадии, пульс, HRV, стресс, шаги и тренировки. Плюс экраны «Сон», «Пульс», «Тренировки» (темп, отрезки, зоны) и «VO2max» с прогнозом на дистанциях. Светлая и тёмная тема.

Формулы те же, что в веб-демо. Это собственная приближённая модель, не алгоритм Garmin.

## Как поставить на iPhone с Windows (бесплатно)

Сборку делает GitHub: после каждого изменения кода в разделе **Releases** появляется свежий `Rezerv.ipa`.

1. На компьютере с Windows установите **iTunes** (с сайта apple.com, не из Microsoft Store) и **Sideloadly** (sideloadly.io).
2. Скачайте `Rezerv.ipa` из последнего релиза репозитория.
3. Подключите iPhone кабелем, на телефоне нажмите «Доверять этому компьютеру».
4. Откройте Sideloadly, перетащите туда `Rezerv.ipa`, введите свой Apple ID и нажмите **Start**. Пароль уходит только в Apple.
5. На iPhone: **Настройки → Основные → VPN и управление устройством** → ваш Apple ID → **Доверять**.
6. На iPhone 15 Pro Max (iOS 16+) включите **Настройки → Конфиденциальность и безопасность → Режим разработчика** и перезагрузите телефон.
7. Откройте «Резерв», нажмите «Подключить Здоровье» и разрешите все пункты.

Бесплатная подпись действует **7 дней**. Раз в неделю подключите телефон и снова нажмите Start в Sideloadly (данные не пропадут). В Sideloadly можно включить автоматическое обновление подписи по Wi‑Fi, когда компьютер и телефон в одной сети.

Если Sideloadly пишет об ошибке прав (entitlements), установите `Rezerv-basic.ipa`: в нём нет фоновой синхронизации, данные обновляются при открытии приложения.

## TestFlight (платный аккаунт Apple Developer, Mac не нужен)

Один раз, всё в браузере:

1. Оформите [Apple Developer Program](https://developer.apple.com/programs/enroll/) (99 $ в год) и дождитесь письма об активации.
2. **Team ID:** developer.apple.com → Account → Membership details → Team ID.
3. **App ID с HealthKit:** developer.apple.com → Certificates, IDs & Profiles → Identifiers → «+» → App IDs → App. Description: `Rezerv`, Bundle ID (Explicit): например `com.hasan.rezerv`. В списке Capabilities отметьте **HealthKit** → Continue → Register.
4. **Приложение в App Store Connect:** [appstoreconnect.apple.com](https://appstoreconnect.apple.com) → Приложения → «+» → Новое приложение: iOS, название `Резерв` (если занято, любое другое), язык Русский, Bundle ID из шага 3, SKU `rezerv`, доступ Полный.
5. **Ключ API:** App Store Connect → Пользователи и доступ → Интеграции → App Store Connect API → «+». Имя `GitHub`, доступ **Admin**. Скачайте файл `AuthKey_XXXX.p8` (скачать можно только один раз). Запишите **Key ID** и **Issuer ID** со страницы.
6. **Секреты в GitHub:** репозиторий → Settings → Secrets and variables → Actions → New repository secret. Пять секретов:
   - `APPLE_TEAM_ID` — из шага 2
   - `BUNDLE_ID` — из шага 3
   - `ASC_KEY_ID` — Key ID
   - `ASC_ISSUER_ID` — Issuer ID
   - `ASC_KEY_P8` — откройте `.p8` в Блокноте и вставьте весь текст, включая строки BEGIN и END
7. Запустите сборку: вкладка Actions → TestFlight → Run workflow. Через 15–30 минут сборка появится в App Store Connect → TestFlight.
8. В App Store Connect → TestFlight → Внутреннее тестирование добавьте себя тестировщиком. На iPhone поставьте приложение **TestFlight** из App Store и установите «Резерв» оттуда.

Дальше каждое изменение кода само уходит в TestFlight. Сборка в TestFlight живёт 90 дней, новые приходят автоматически.

## Сборка на Mac (если появится)

```
brew install xcodegen
xcodegen generate
open Rezerv.xcodeproj
```

В Xcode выберите свою команду (Personal Team) в Signing & Capabilities и запустите на телефоне.

## Устройство кода

- `Rezerv/Engine` — расчёт резерва, оценки сна, анализ тренировок, VO2max (перенос `engine.js`).
- `Rezerv/Health` — чтение HealthKit, раскладка по 5-минутным слотам, фоновая доставка.
- `Rezerv/Views` — экраны SwiftUI + Swift Charts.
