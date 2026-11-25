# Revenge of the Mage · Кооператив

[English](README.md) · [Скачать 0.6.0](https://github.com/tornado909/RotM-Coop/releases/tag/v0.6.0)

Модификация добавляет сетевой кооператив в Revenge of the Mage: лобби Steam, приглашения друзей, индивидуальные способности и карты, общую паузу при выборе улучшений, переходы между аренами и воскрешение союзников. Подключение через Steam P2P, без проброса портов и VPN.

## Установка

1. Закройте игру. Требуется Windows x64 и Steam-версия игры **1.0.0.301**.
2. Скачайте и распакуйте `RotMCoop-Win64-0.6.0-test.zip` со страницы релиза.
3. Запустите `Install-RotMCoop.cmd` и выберите каталог игры, содержащий папку `RevengeOfTheMage`.
4. Установите одинаковую версию мода всем участникам и запустите игру через Steam.

Установщик проверяет версию EXE, сохраняет резервные копии заменяемых файлов и не удаляет другие моды UE4SS.

## Как играть

Хост: **Сетевая игра → Создать лобби → Пригласить друга → Начать игру**.

Гость: запустите игру, примите приглашение Steam или откройте **Сетевая игра → Найти лобби**, выберите комнату и дождитесь хоста. Приглашение может отображаться как Spacewar (тестовый Steam AppID 480).

Каждый маг выбирает свои карты. Забег продолжается после выбора всех участников. Для воскрешения союзника оставайтесь в зоне его смерти пять секунд; он восстановит половину здоровья.

## Ограничения

Экспериментальная сборка. Проверена игра вдвоём; четыре места в лобби предусмотрены, но полноценная игра вчетвером и все виды заклинаний ещё не проверены. Сохраняйте резервные копии сохранений.

Если возникают ошибки, укажите версию игры, версию мода, роль хоста или гостя и последовательность действий. Журнал находится в `RevengeOfTheMage/Binaries/Win64/ue4ss/UE4SS.log`. Перед публикацией журнала удалите личные идентификаторы.

Чтобы отключить мод, закройте игру и установите `RotMCoop : 0` в `ue4ss/Mods/mods.txt`.


## 0.6.0

## Changes

- Per-player animation montage and notify isolation for simultaneous attacks.
- Native authoritative automatic/manual reload and ammunition synchronization.
- Ally HUD, health, armor, spell charges and cooldowns.
- Improved aim and Niagara effects including LavaLeap targeting and landing.
- Localized multiplayer menus and combat transport v2.

## Installation

Extract the ZIP, run Install-RotMCoop.cmd, select the game directory and launch the game through Steam. Windows x64, Steam game build 1.0.0.301. All players must upgrade to this version; incompatible with 0.5.9 transport.

**Experimental pre-release.** Two-player Fire/Fire stress test and automated transport checks passed. All schools, dynamic effect overlap, damage attribution and full portal/run acceptance remain incomplete. Back up saves.
