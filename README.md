# Unfold

An iPhone-Fold-style lid animation for the MacBook: the picture stays fixed in space (a virtual screen at angle β) while the physical lid sweeps through it. Each pixel row blurs in proportion to its distance from the image plane (R · s/H · sin(β − φ)), everything outside the virtual screen (as seen from the eye) turns black, and just before the lid closes the picture slips into black. The angle comes live from the hinge sensor.

## Installation
1. Open `dist/Unfold.dmg` and drag **Unfold** onto **Applications**.
2. Launch Unfold from Applications. It lives in the menu bar (no Dock icon) and registers itself as a login item on first launch.

## Usage
The settings window opens via **Settings…** in the menu bar menu, or by launching Unfold again while it's running.

- **Image plane β**: angle of the virtual screen; from here on everything is sharp
- **Black below**: below this angle the picture slips into black
- **Blur / Dimming at top**: strength at the top edge (always 0 at the hinge)
- **Top edge fade**: soft fade to black at the physical top edge; disappears at β
- **Perspective**: eye distance and height for the black edges, width of the soft edge
- **Also when closing**: the effect also plays in reverse, live, while closing the lid
- **Follow the resting lid** (after 0.5 s by default): wherever the lid rests, below or above β, the virtual screen swings over to it in 0.7 s on a cubic Bézier ease (0.4, 0, 0.2, 1): the black wedges retreat into the corners and the blur recedes, so moving the lid from any angle starts the effect right away. Opening further, the lid pushes the virtual screen along, always slightly behind it so nothing flickers; sleep resets it to β, so opening from closed plays the configured animation all the way up to β (while opening from closed, stillness below 10° is ignored and a pause only counts as rest after 1.5 s; 2° hysteresis, so sensor jitter doesn't count as movement)
- **Show on lock screen**: draws the effect above the lock screen after waking
- **Play Preview**: plays the animation without moving the lid
- **Log**: opens `~/Library/Logs/Unfold.log` (sleep/wake events and the angle trace after waking)

## How it works
- `LidSensor.swift`: reads the HID hinge sensor (Apple 0x05AC/0x8104); no permissions required
- `Engine.swift`: puts the overlay up in its "closed" state (black, fully frosted) before the Mac sleeps, so the first frame after waking already shows the effect; after that, a critically damped spring follows the lid angle
- `Geometry.swift`: casts the line of sight from the eye through every point on the lid and intersects it with the plane at β; outside the virtual rectangle → black
- `Overlay.swift`: click-through full-screen window on the built-in display: backdrop layer with `variableBlur` (linear ramp as mask), dimming ramp, perspective mask, fade to black

## Building
```
./build.sh            # → dist/Unfold.dmg (universal, ad-hoc signed)
```
