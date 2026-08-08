# Zombie Survival on a Tang Nano 4K

A side-view survival shooter written in Verilog. It runs on a Sipeed Tang Nano 4K
(Gowin GW1NSR-4C) and draws straight out to HDMI at 640x480.

We built it as **Team 7A** at the **TSIC x Synopsys summer camp**, and it took
**3rd prize** in the closing hackathon.

You're a survivor defending a bunker. Zombies come in from the right, you shoot
them without having to press anything, and the run ends the moment one of them
touches you or slips past you to the bunker. **How long you last is your score.**

## Playing

Five buttons. WASD to move, one more for your skill, and the reset button that's
already on the board to start over. Wiring is in [The hardware](#the-hardware)
further down.

There's no fire button. You shoot on your own, constantly, always to the right.
Nothing moves until you press something, so the title screen just waits.

Kill 20 zombies and the counter in the top right turns green. That's your skill
charged. Press the skill button and you fire three times as fast for ten seconds,
and your streak drops back to zero. Worth saving for the mini boss, which is what
it's really there for.

## The enemies

| Enemy | Size | Speed | Bullets to kill | Shows up |
|---|---|---|---|---|
| normal | 32x32 | 2 px/frame | 1 | always |
| fast (red tint) | 32x32 | 3 px/frame | 1 | level 2+ |
| tanky (blue tint) | 32x32 | 1 px/frame | 3 | level 3+ |
| mini boss | 96x96 | 0.5 px/frame | 13 | 40 s+ |

Difficulty steps up every 10 seconds and tops out at level 7 after a minute, by
which point zombies are turning up twice a second. The mini boss is deliberately
rare, around 3% of spawns to begin with, climbing to 8% at 100 seconds and 12% at
120. Only one can be alive at a time, because it gets its own reserved slot in
the zombie array.

## The hardware

![The controller, five buttons on a breadboard next to the Tang Nano 4K](images/controller.jpg)

Everything runs off the one board. The Tang Nano handles video by itself, so the
only thing we actually had to build was a controller, and that's five buttons on
a breadboard.

| Button | Tang Nano pin | Does |
|---|---|---|
| W | 16 | move up |
| A | 20 | move left |
| S | 13 | move down |
| D | 17 | move right |
| skill | 18 | fast shooting for 10 seconds |

Each button is one leg to its pin and one leg to the ground rail. That's the
whole circuit.

You'll notice there isn't a single resistor anywhere on that breadboard. The FPGA
has pull-ups built into its pins and `src/hdmi_coin.cst` switches them on with
`PULL_MODE=UP`, so a pin sits high on its own and only reads low while you're
holding the button down. It's also why `debounce.v` inverts its input and treats
low as pressed, which looks backwards until you know that.

![The five buttons, each with one jumper to a pin and one to the ground rail](images/buttons.jpg)

One thing to watch. Those five pins sit in a 1.8 V bank. Shorting them to ground
is exactly what they're for, but don't wire them to 3.3 V or anything else that
drives a voltage into them.

Restarting after a game over uses the Tang Nano's own reset button, so there's
nothing to wire for that.

![Close-up of the Tang Nano 4K, HDMI on one end and USB-C on the other](images/tang-nano.jpg)

HDMI goes to a monitor, USB-C goes to your computer. The USB-C carries power and
the bitstream both, so you don't need a separate supply.

<!-- TODO: add a photo of the game running on a screen, e.g. images/gameplay.jpg -->

## What you need to install

Only the first one is genuinely required. The rest just make the code nicer to
work on.

### Required

**Gowin EDA, Education edition.** This is what turns the Verilog into a bitstream
and pushes it onto the board. Grab it from
[Gowin's developer site](https://www.gowinsemi.com/en/support/home/). We were on
`Gowin_V1.9.11.03_Education_x64` and it worked straight out of the installer with
no licence to request. Any recent version should be fine.

The build script expects to find it at `C:\Gowin\Gowin_V1.9.11.03_Education_x64`.
If yours lives somewhere else, set `GOWIN_HOME` once and every task will pick it
up from there:

```powershell
setx GOWIN_HOME "C:\Gowin\YourGowinFolder"
```

**Windows.** The build and asset scripts are PowerShell, and `png2mem` leans on
.NET's `System.Drawing` to read the PNGs, so it wants Windows PowerShell rather
than a POSIX shell. The Verilog itself would port fine. Nobody's tried.

If you only want to build it and play, you're done. Stop here.

### Recommended for editing the code

**VS Code**, plus the **Verilog-HDL/SystemVerilog** extension
(`mshr-h.veriloghdl`). VS Code offers it the moment you open the folder, since
it's listed in `.vscode/extensions.json`. You get syntax highlighting, and it
drives the linter below.

**Icarus Verilog** is the bit that actually catches your mistakes. The extension
only calls it. Install the extension on its own and all you get is nice colours,
which is a frustrating way to lose an afternoon. Windows builds live at
[bleyer.org/icarus](https://bleyer.org/icarus/), and `iverilog` needs to end up
on your PATH.

`.vscode/settings.json` already knows where this project keeps its headers and
its modules, so includes and cross-module references resolve as soon as
`iverilog` exists. Catching a typo as a red squiggle beats catching it five
minutes into a synthesis run.

Icarus only tells you the Verilog is valid. Whether it fits on the chip is
between you and Gowin.

## Building

Open the folder in VS Code, then Ctrl+Shift+P and Run Task:

- **run** synthesises, places, routes, and uploads to the board
- **png2mem** and **bitmap2mem** rebuild the assets
- **monitor** opens the camera app so you can watch the HDMI output
- **zip** packages the project for hand-in

Keep an eye on the resource table Gowin prints at the end of every build. We're
close to full at roughly 84% logic, 92% CLS and 9 of 10 BSRAM. If a change stops
fitting, drop `MAX_ZOMBIE` or `MAX_BULLET` in `src/game/game_core.v` before you
start rewriting anything clever.

If the upload dies instantly with exit code 50, that's the USB connection rather
than your code. Unplug the board, plug it back in, run it again.

## How the pixels get out

```text
top
  -> reset_sync, ff_sync, debounce      clean up the buttons
  -> game_core
       -> game_ctrl                     all the game rules
       -> bg_layer                      map and bunker
       -> obj_layer                     zombies, bullets, player
       -> ui_layer                      timer, LEVEL, kill streak
       -> res_overlay                   game over panel
  -> svo_hdmi -> svo_enc -> svo_tmds -> HDMI
```

Each layer takes the pixel stream in and hands it back out with its own drawing
on top, so whatever comes last wins. Any layer that reads a ROM also holds the
stream back by a clock, because the ROM's output is registered.

`tuser[0]` marks the first pixel of a frame, and `game_ctrl` uses that as its
only clock. One game step per frame, 60 a second.

## Where to change things

| To change | Edit |
|---|---|
| screen layout, sprite sizes, ground line, bunker | `src/game/game_defs.vh` |
| game rules like speeds, spawn rates, difficulty and the skill | `src/game/game_ctrl.v` |
| how many zombies and bullets can exist at once | `src/game/game_core.v` |
| button pins | `src/hdmi_coin.cst` |
| the map colours and the bunker | `src/overlay/bg_layer.v` |
| timer, LEVEL and streak display | `src/overlay/ui_layer.v` |

## Assets

The art lives in `png/` and the letters in `bitmap/`. The FPGA can't read either
of them, so both get converted into `.mem` files in `src/assets/` and baked into
the bitstream's block RAM.

- **png2mem** turns `png/*.png` into `src/assets/*.mem`. The zombie and the boss
  share a single `obj_atlas.mem`, so between them they cost one block of RAM
  instead of two. Block RAM is the tightest thing on this chip and we're using 9
  of the 10.
- **bitmap2mem** turns the hand-drawn 6x12 letters in `bitmap/*.txt` into
  `res_font.mem`. Glyph order is **append-only**. `ui_layer` and `res_overlay`
  hard-code the index of every letter, so reordering `bitmap/` will quietly break
  every word on screen.

Re-run the matching task whenever you touch the art.

## The team

Team 7A, TSIC x Synopsys summer camp:

- **Huy Hoang Le** (team leader)
- **Lucas Chang**
- **Alison Chen**
- **Amber Lin**
- **Raphaelt Seng**

## Credits

Huge thanks to **Bryant Chen**, our mentor at TSIC, who wrote the `hdmi_coin`
coin-catcher demo this project grew out of. It handed us a working HDMI pipeline
and a project skeleton on day one, which is the only reason we got to spend the
camp building a game instead of losing it to TMDS timing. The original is at
[czl0706/tsic-proj2-coin](https://github.com/czl0706/tsic-proj2-coin).

Everything game-shaped on top of that is ours. The rules, the drawing layers, the
sprites, and the tooling in `src/game/`, `src/overlay/`, `src/common/`, `png/`,
`bitmap/` and `.vscode/`.

Two folders aren't, and are used exactly as they came:

- `src/hdmi/` is the [SVO](https://github.com/cliffordwolf/svo) Simple Video Out
  core by Clifford Wolf, under the ISC licence. See `LICENSE`.
- `src/ip/` is PLL and clock-divider blocks that the Gowin IDE generated.
