# Unfold

An iPhone-Fold-style lid animation for the MacBook: the picture stays fixed in space (a virtual screen at angle β) while the physical lid sweeps through it. Each pixel row blurs in proportion to its distance from the image plane (R · s/H · sin(β − φ)), everything outside the virtual screen (as seen from the eye) turns black, and just before the lid closes the picture slips into black. The angle comes live from the hinge sensor.

## Installation
1. Open `dist/Unfold.dmg` and drag **Unfold** onto **Applications**.
2. Launch Unfold from Applications. It shows up in the Dock and in the menu bar, and registers itself as a login item on first launch.

## Usage
The settings window opens from the Dock icon or via **Settings…** in the menu bar menu.

- **Image plane β**: angle of the virtual screen; from here on everything is sharp
- **Black below**: below this angle the picture slips into black
- **Blur / Dimming at top**: strength at the top edge (always 0 at the hinge)
- **Top edge fade**: soft fade to black at the physical top edge; disappears at β
- **Perspective**: eye distance and height for the black edges, width of the soft edge
- **Also when closing**: the effect also plays in reverse, live, while closing the lid
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
