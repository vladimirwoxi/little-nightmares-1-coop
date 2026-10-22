# Little Nightmares Coop — split-screen co-op for Little Nightmares (2017)

Same-PC couch co-op for **Little Nightmares Enhanced Edition**: two local players, split
screen, two gamepads, no networking involved.

> Status: playable prototype. The main story path has been played with two players; see
> [Known issues](#known-issues) before you start.

## What it does

- Adds a second local player at the main menu and keeps both players through level loads.
- Splits the screen for exactly two players. Each half keeps a true 16:9 frame, so the
  composition the game was designed for is preserved (black side bars inside each half).
- Each gamepad drives its own character; both walk, run, jump, climb and interact.
- Makes the game's single-player machinery cope with two players: enemies target whichever
  player is closest, and doors that close behind player 1 do not strand player 2.
- Co-op is on by default at launch. A row in the main menu turns it off and on
  («Совместная игра: включена / отключена», or `Coop Game: On/Off` if the game UI is not
  Russian).

## Requirements

- **Little Nightmares (2017) Enhanced Edition**, Unreal Engine 4.27.2. The tested build is a
  non-Steam Enhanced Edition release whose `Atlas-Win64-Shipping.exe` has SHA-256
  `F7E42C865253A277FE754EF3646AE134CC367728F38BAAC42987E605514E3397`. The regular edition is
  not tested.
- **UE4SS experimental build.** Stable UE4SS 3.0.1 does not load this mod correctly. The
  tested build is `v3.0.1-1181-g83330635`.
- **Two XInput gamepads** (tested: 8BitDo Ultimate 2 and 8BitDo Ultimate 2C).
- Windowed mode is what has been tested (1280×720 client).

## Install

1. Install UE4SS into the game, for Little Nightmares that is
   `<game>\Atlas\Binaries\Win64\ue4ss` (UE4SS' own instructions: copy `dwmapi.dll`,
   `UE4SS.dll` and the `ue4ss` folder next to `Atlas-Win64-Shipping.exe`).
2. Copy the `AtlasCoop` folder from this repo into `<game>\Atlas\Binaries\Win64\ue4ss\Mods\`.
3. Open `<game>\Atlas\Binaries\Win64\ue4ss\Mods\mods.txt` and add this line:

   ```
   AtlasCoop : 1
   ```

4. Launch the game. The main menu gets an extra row: «Совместная игра: включена».
   Co-op is created while the menu is up, so both characters spawn when the level starts.

To uninstall, set the mods.txt line to `AtlasCoop : 0` (or delete the folder).

## How it works (short version)

The mod is a UE4SS Lua script. It creates a second `ULocalPlayer` with
`UGameplayStatics::CreatePlayer` while the front end is up, enables `bUseSplitscreen`, gives
player 2 the other gamepad id, forces `bConstrainAspectRatio` + `AspectRatio = 16:9` on every
camera component (the only framing lever this game does not overwrite), and each tick it
retargets enemies, holds doors open for the second player, and re-creates player 2 if a level
load drops it.

Player 1 keeps the controller id the game gave it; only player 2's id is written. Writing
player 1's id is reverted by the game within about two seconds, and fighting it makes the
pads swap characters every two seconds.

## Known issues

Reported by players, roughly in the order they are hit:

1. **Running on diagonal ladders breaks the left stick.** Sprinting up a diagonal ladder can
   leave that player's movement rotated (for example, the stick pushed right walks up).
   Walking the same ladder is fine. Restarting the level clears it. Not fixed yet.
2. **Crash when both players grab the same hook.** In the hook sequences (the Chef escape)
   the game can crash when both players hook onto the same object. Workaround: each player
   takes a different hook, the sequence can then be finished.
3. **A door blocks the view of the first lever.** In the opening area with the lever and the
   grate, the door in front of the lever hides it on one of the screens; the lever can still
   be flipped blind.
4. **Closing doors and lifts can leave player 2 behind.** Both players have to go through at
   the same time, otherwise the second character stays outside.
5. **Turning co-op off leaves player 2 in the level.** The view goes back to a single window,
   but the second character is still there.
6. **Recolouring player 2's raincoat is not implemented.** The material has no colour
   parameter and a texture swap reads back but renders unchanged.
7. **The game picks the pad for player 1.** If the two pads reconnect in the other order, the
   players swap pads. Relaunching the game is the current workaround.
8. The mod is a prototype: co-op is only tested in windowed mode and on the builds listed
   above.

## Tested on

| | |
|---|---|
| Game | Little Nightmares Enhanced Edition (2017), Unreal Engine 4.27.2 |
| Executable | `Atlas-Win64-Shipping.exe`, SHA-256 `F7E42C865253A277FE754EF3646AE134CC367728F38BAAC42987E605514E3397` |
| UE4SS | experimental-latest `v3.0.1-1181-g83330635` |
| OS / video | Windows, windowed 1280×720 client |
| Gamepads | 8BitDo Ultimate 2 (player 1), 8BitDo Ultimate 2C (player 2) |

## Development helpers

The mod reads one-line commands from `Mods/AtlasCoop/test.cmd` (for example `lpinfo`,
`unpause`, `movwatch 30`). They are diagnostics used while building the mod; they are not
needed to play and are documented in the script itself.

## Credits and legal

- Built with [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS).
- No game files, assets or code are included or redistributed. The mod only calls the game's
  own Blueprint/native API at runtime, so you need your own copy of the game.
- This is a single-player game; the mod does not touch any online service or anti-cheat.
- License: see [LICENSE](LICENSE).

## Support the mod

If you like the mod and want to say thanks:
**[donationalerts.com/r/woxi](https://www.donationalerts.com/r/woxi)**

---

## По-русски

Кооператив на одном ПК для **Little Nightmares Enhanced Edition**: два игрока, разделённый
экран, два геймпада, без сети.

**Установка.** Поставьте UE4SS в `<игра>\Atlas\Binaries\Win64\ue4ss`, скопируйте папку
`AtlasCoop` в `...\ue4ss\Mods\` и добавьте строку `AtlasCoop : 1` в
`...\ue4ss\Mods\mods.txt`. Запустите игру: в главном меню появится строка
«Совместная игра: включена», кооп включён по умолчанию.

**Известные проблемы.**

1. Бег по диагональным лестницам ломает левый стик: направление движения поворачивается
   (стик вправо — персонаж идёт вверх). Пешком по той же лестнице всё нормально; помогает
   перезапуск уровня. Не исправлено.
2. Краш, если оба игрока цепляются за один и тот же крюк (погоня от Поваров). Обходится так:
   каждый цепляется за свой крюк, и момент проходится.
3. В начале, у рубильника за решёткой, дверь закрывает обзор на одном из экранов; рубильник
   можно включить вслепую.
4. Закрывающиеся двери и лифты: заходите одновременно, иначе второй игрок остаётся снаружи.
5. Если выключить совместную игру, остаётся одно окно, но второй персонаж в уровне остаётся.
6. Перекраска плаща второго игрока не реализована.
7. Геймпад для первого игрока выбирает игра: если переподключить геймпады в другом порядке,
   игроки меняются местами — перезапустите игру.

**Поддержать мод.** Если хочется отблагодарить:
[donationalerts.com/r/woxi](https://www.donationalerts.com/r/woxi)
