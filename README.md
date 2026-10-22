# AtlasCoop — split-screen co-op for Little Nightmares (2017)

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

- **Left stick can go wrong after a ladder.** After a player climbs a ladder, that player's
  left stick can move the character in a rotated direction (for example, "up" walks left).
  Movement is camera-relative and the game does not refresh the movement basis for the
  second player after the climb. Restarting the level clears it. Reported, not fixed yet.
- **Recolouring player 2's raincoat is not implemented.** The material has no colour
  parameter and a texture swap reads back but renders unchanged.
- **The game picks the pad for player 1.** If the two pads reconnect in the other order, the
  players swap pads. Relaunching the game is the current workaround.
- The mod is a prototype: co-op is only tested in windowed mode and on the builds listed
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

---

## По-русски

Кооператив на одном ПК для **Little Nightmares Enhanced Edition**: два игрока, разделённый
экран, два геймпада, без сети.

**Установка.** Поставьте UE4SS в `<игра>\Atlas\Binaries\Win64\ue4ss`, скопируйте папку
`AtlasCoop` в `...\ue4ss\Mods\` и добавьте строку `AtlasCoop : 1` в
`...\ue4ss\Mods\mods.txt`. Запустите игру: в главном меню появится строка
«Совместная игра: включена», кооп включён по умолчанию.

**Известные проблемы.** После подъёма по лестнице у поднявшегося игрока левый стик может
двигать персонажа не в ту сторону — помогает перезапуск уровня, причина пока не исправлена.
Перекраска плаща второго игрока не реализована. Если геймпады переподключить в другом
порядке, игроки могут поменяться местами — перезапустите игру.
