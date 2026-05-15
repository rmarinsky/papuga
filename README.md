# Papuga

Papuga - це менюбар-утиліта для macOS, яка рятує текст, набраний не тією розкладкою.
Виділив текст, дав команду, отримав нормальний результат. Без ритуалів, без копіпаст-акробатики.

## Що вміє зараз
- Перетворює вже набраний виділений текст між системними розкладками.
- Працює з будь-якими активними keyboard layouts macOS (мапи будуються динамічно з системних input sources).
- Два режими результату: `Копіювати` або `Копіювати і вставити`.
- Активація подвійним натисканням (`Opt+Shift`, `Cmd+Shift`, `Ctrl+Shift`).
- Активація кастомним хоткеєм через KeyboardShortcuts recorder.
- Зберігає історію буфера обміну з часом копіювання, групуванням (`Сьогодні/Вчора/Раніше`) та вибором retention-періоду.
- Показує аналітику економії часу (сьогодні + загалом).
- Анімована іконка в меню-барі після успішного перемикання.
- Онбординг із покроковою видачею дозволів.
- Підтримує автозапуск при вході в систему.

## Системні вимоги
- macOS 14.0+ (Sonoma або новіше)
- Дозвіл `Accessibility`
- Дозвіл `Input Monitoring`

Без цих дозволів гарячі клавіші й автоматичний copy/paste не працюватимуть стабільно.

## Як користуватися
1. Виділи текст у будь-якому застосунку.
2. Виклич перемикання: або подвійним натисканням налаштованої комбінації, або власним шорткатом.
3. Papuga скопіює виділене, конвертує, вставить (або залишить у буфері залежно від режиму), і переключить системну розкладку.

## Встановлення

### Через Homebrew tap
```bash
brew tap rmarinsky/tap
brew install --cask papuga
```

### Без tap (прямо з формули репо)
```bash
brew install --cask rmarinsky/tap/papuga
```

## Локальний запуск для розробки
```bash
xcodebuild -resolvePackageDependencies -project papuga.xcodeproj -scheme papuga
xcodebuild -project papuga.xcodeproj -scheme papuga -configuration Debug build
```

Або просто відкрий `papuga.xcodeproj` в Xcode і запускай схему `papuga`.

Для швидкого dev-інсталу в `/Applications` (окремий app bundle + зручне тестування TCC-дозволів):
```bash
./scripts/dev-install.sh
```

## Релізи та автооновлення

Автооновлення працює через Sparkle і читає appcast з `https://rmarinsky.github.io/papuga/appcast.xml`.

Реліз триггериться **label-driven** з PR:

1. Відкрий PR у `main`.
2. Додай рівно один лейбл: `release:patch`, `release:minor`, `release:major` або `release:skip`.
3. Змерджи PR.

Далі CI сам: `prepare-release.yml` рахує наступну версію з останнього тега, пушить `vX.Y.Z`, далі `release.yml` білдить + нотаризує + підписує, створює GitHub Release і оновлює `appcast.xml` на гілці `gh-pages`. Версія застосунку береться **з тега** — `MARKETING_VERSION` у проекті лише плейсхолдер.

Ніколи не пушити в `main` напряму, не створювати теги `v*` руками, не редагувати `MARKETING_VERSION` чи `appcast.xml` вручну.

Локальний `./release.sh` бере версію з `git describe --tags` або зі змінної `RELEASE_VERSION`; для appcast потрібні `SPARKLE_EDDSA_PRIVATE_KEY` і `SPARKLE_DOWNLOAD_URL`.

## Технічний стек
- Swift + SwiftUI
- Defaults
- KeyboardShortcuts
- LaunchAtLogin
- Sauce

## Коротко про філософію
Papuga не намагається бути "AI, що все зробить за вас".
Це маленький, швидкий інструмент, який закриває одну болючу задачу дуже добре.
