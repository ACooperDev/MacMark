# MacMark

Your Mac's About window, drawn as a sigil from the Mac's real specs. Every mark is made of round dots. Each ring stands for one fact about the computer. You can knead the whole thing into a strip of rows and back, and it goes a different way each time: it bursts, weaves, reels, spins like a coin, rings out like a harp or breaks like a cue ball.

MacMark is a macOS port of [Machine Mark](https://github.com/erikrjohansson/omarchy-machine-mark), an About window for Omarchy (Linux).

## What it shows

The header gives the Mac's name, then its model ("MacBook Air (13-inch, M5)"), the macOS version and build, and the serial number. Hover the macOS line to see the Darwin kernel. Hover the serial to see the model number, model identifier and firmware.

- **Hardware** (blue):
  - **Chip:** the chip ("Apple M5"), with a short line of dots per CPU core.
  - **Cores:** the performance and efficiency cores ("4 Super + 6 Efficiency"). Each performance core is a long line, each efficiency core a short one.
  - **GPU:** one dot per GPU core. Hover it to see the GPU's current load.
  - **Memory:** used against total, as a row of large dots. It updates every 4 seconds.
  - **Storage:** used against total on the startup disk, counted the way Finder and About This Mac count it (decimal GB, purgeable space counted as free). Once measured, the ring is split into the categories Storage settings uses, in its colours: Applications, Documents, Developer, Photos, Music, Messages, iCloud Drive, macOS and System Data. Hover it for a legend with each category's size.
  - **Display:** one ring per display, with a pulse per 10 Hz. The built-in screen comes first.
  - **Thermal:** how hot macOS judges the Mac to be, in its own four steps: nominal, fair, serious and critical. The ring fills a quarter per step and turns red from serious on, when macOS slows the chip to cool it. It updates as soon as the state changes.
  - **Devices:** what is plugged in or paired: a short line per USB device (not hubs or the Mac's own built-in ones), a dot per Bluetooth device. Paired devices that aren't connected are faint. Hover it for their names. It updates every 12 seconds.
- **Software** (yellow):
  - **Apps:** a line per app in Applications, in the order they were added. Taller lines take more disk space. Homebrew packages are counted alongside.
  - **Installs:** everything macOS has installed (system updates, security responses, App Store apps, packages), as short runs of dots.
  - **Appearance:** light, dark or auto.
  - **Background:** a dot per launch agent or daemon that apps have added. Faint ones are switched off.
- **Age / Uptime** (pink):
  - **Mac age:** a dot per week since the Mac was set up. A dot is bigger in weeks when macOS installed more.
  - **Battery:** how full it is now, and its health (how much it holds now against how much it held new). The faint dots are what it holds, the bright ones the charge; an accent-coloured dot means it's on power. Hover it for the time left, the Wh and the charge cycles. The charge updates every 4 seconds, and at once when you plug in or unplug.
  - **Updated:** a one-week dial for the time since the last system update.
  - **Uptime:** a 24-hour dial.

The colours are macOS's own system blue, yellow and pink, plus your accent colour; press <kbd>C</kbd> for other schemes, all made of system colours. They follow light and dark mode as you switch. The shape of the sigil comes from a seed of the Mac's name and hardware, so every Mac gets its own.

## Build and run

It needs the Xcode command line tools (`xcode-select --install`) and macOS 13 or later.

```bash
./build.sh                 # builds MacMark.app here
open MacMark.app
```

Drag `MacMark.app` to Applications if you want to keep it. It is signed ad hoc, so the first time you open it after copying it to another Mac, right-click it and choose **Open**.

Other ways to run it:

```bash
MacMark.app/Contents/MacOS/MacMark --json     # print everything it reads, as JSON
MacMark.app/Contents/MacOS/MacMark --live     # memory, GPU load, uptime, battery charge, thermal state, devices
MacMark.app/Contents/MacOS/MacMark --shot out.png [--strip] [--hover N] [--mode loom]
                                              # draw the window off-screen to a PNG
```

To work on the page in a browser, run `MacMark --json > web/machine.json` and serve `web/` (for example, `python3 -m http.server -d web`).

## Storage categories and permissions

macOS works out its Storage categories privately, so MacMark measures the folders behind each one in the background, which takes about 10 seconds:

| Category | Folders |
|---|---|
| Applications | `/Applications`, `~/Applications` |
| Documents | `~/Documents`, `~/Desktop`, `~/Downloads`, `~/Movies` |
| Developer | `~/Library/Developer`, `/Library/Developer` (Xcode, simulators), Homebrew |
| Photos | `~/Pictures` |
| Music | `~/Music` |
| Messages | `~/Library/Messages` |
| iCloud Drive | `~/Library/Mobile Documents` (the copies on this Mac) |
| macOS | the sealed system volume |
| System Data | everything else in use: caches, app containers, swap, snapshots |

macOS's privacy protection guards some of these folders. The first time, it asks once each for Desktop, Documents, Downloads and iCloud Drive, and the legend says "Measuring…" until you answer. Messages, and parts of the Music and Photos libraries, can only be measured with **Full Disk Access** (System Settings › Privacy & Security). Without it, they are marked in the legend and their space is counted in System Data. Each rebuild with `./build.sh` is a new ad-hoc signature, so macOS may ask again.

`MacMark --storage` prints the measurement as JSON.

## Use

| | |
|---|---|
| Drag sideways, click, <kbd>Space</kbd> | knead between sigil and strip |
| <kbd>←</kbd> <kbd>→</kbd> | sigil / strip |
| <kbd>↑</kbd> <kbd>↓</kbd>, hover | pick a ring; the footer explains it |
| <kbd>1</kbd>–<kbd>6</kbd>, <kbd>0</kbd> | keep to one animation (burst, loom, spool, coin, harp, break shot); 0 picks one at random each time |
| **Copy**, <kbd>⌘</kbd> <kbd>C</kbd> | copy everything shown as plain text |
| <kbd>C</kbd> | next colour scheme (System, Ocean, Sunset, Garden, Berry, Accent, Mono, and Rainbow: every ring its own hue, slowly cycling); it's remembered the next time MacMark opens |
| <kbd>Esc</kbd>, <kbd>⌘</kbd> <kbd>W</kbd> | close |

## What it reads

MacMark only reads. It changes no settings, and nothing leaves the Mac.

- `sysctl`: chip, core counts and kinds, memory size, boot time, macOS build
- IOKit: serial number, battery capacity and cycles (`AppleSmartBattery`), battery charge (power sources), GPU load (`IOAccelerator`), USB devices (`IOUSBHostDevice`)
- `system_profiler SPBluetoothDataType`: Bluetooth devices, connected or paired (MacMark doesn't use Bluetooth itself, so it needs no Bluetooth permission)
- `system_profiler SPHardwareDataType SPDisplaysDataType`: model name and number, firmware, GPU core count
- NSScreen and CoreGraphics: each display's size, resolution and refresh rate
- the startup volume's capacity
- Spotlight metadata for the apps in `/Applications` and `~/Applications`: date added, size
- `/Library/Receipts/InstallHistory.plist`: installs and updates
- `/var/db/.AppleSetupDone`: when the Mac was set up
- `~/Library/LaunchAgents`, `/Library/LaunchAgents`, `/Library/LaunchDaemons` and `launchctl print-disabled`: background items
- Homebrew's `Cellar` and `Caskroom` folders
- the appearance and accent colour settings
- the thermal state (`ProcessInfo.thermalState`)

It reads everything when it opens, again when the appearance or the displays change, and while open: memory, GPU load, uptime, battery charge and thermal state every 4 seconds, devices every 12.

## Layout

- `Sources/Machine.swift`: reads the Mac
- `Sources/main.swift`: the window, the bridge to the page, the clipboard and the system colours
- `Icon/`: the app icon, a simplified sigil (`make-icon.swift` draws it; run `swift Icon/make-icon.swift` to redraw `MacMark.icns`).
- `web/`: the drawing. `Sigil.js` holds the rings, facts and marks; `modes/` holds the animations; `card.js` holds the window's logic.# MacMark
