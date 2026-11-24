# Vanguard OS V12.0


Vanguard OS is an advanced player tracking and monitoring operating system built for Minecraft Command Computers via the **CC:Tweaked** mod. It provides real-time, on-screen tracking of players' health, coordinates, dimension and vehicle usage, wrapped in an interactive touchscreen interface.

The current version is `VanguardOS_V12.lua`. The older V11.3 file (`VanguardOS (2).lua`) is kept in the repository for reference.

##  Key Features

*   **Touchscreen Lock Screen:** Secure access with a PIN you choose on first run. The PIN is stored on disk as a salted, iterated SHA-256 hash. After 3 wrong attempts the keypad locks out for 30 seconds, and the delay doubles with every further 3 failures (up to 15 minutes). The system also locks itself after 3 minutes without input.
*   **Flexible Displays:** With two monitors, Monitor A shows the **Roster** and Monitor B shows the **Watch Grid**. With one monitor, a **ROSTER** and **GRID** tab switch between the two views. With no monitor, everything runs on the computer terminal. Layouts adapt to the monitor size, and monitors can be attached or removed while the system runs.
*   **Efficient Player Polling:** Queries Health, XYZ Position and Dimension asynchronously with `commands.execAsync`. The focused player is polled four times a second, other watched players once a second, and players that stop answering back off automatically so the server is not flooded.
*   **Vehicle-Seat Fallback:** Detects when a player's position is frozen (passenger or gunner seats in modded vehicles) and reads `RootVehicle.Entity.Pos` instead. Players who are not in a vehicle are probed less and less often.
*   **Player Cards:** Each card shows a health bar, a LOW HP flag, the dimension, the position source, the data age, and a status chip (`FRESH`, `STALE`, `HARD`, `WAIT` or `OFF`).
*   **Event Log:** Joins, leaves and low health alerts appear in an EVENTS panel on the roster screen (needs a tall monitor).
*   **Focus Mode:** Pin one player to the top of the grid with a yellow card edge and a faster polling rate.
*   **Admin Keyboard Controls:** Unlock, change the PIN or lock from the physical computer terminal. These work even during a keypad lockout.
*   **Crash Safety:** Errors are logged to `.vanguard_crash.log` and the system restarts itself. If it crashes more than 5 times within 2 minutes it shows a crash screen and waits for you to press `R` to reboot.

---

##  Requirements

1.  **Minecraft Version:** 1.20.1 or higher.
2.  **Mod:** CC:Tweaked (or an equivalent ComputerCraft fork).
3.  **Hardware:**
    *   **1x Command Computer** (Standard computers will *not* work as they lack the `commands` API).
    *   **Ideally 6 wide by 4 tall Advanced Monitors** (For color GUI, touch input and multi-screen support). Basic monitors are drawn in grayscale but cannot be touched.

##  User Guide

### 1. First Run & Setting a PIN
There is no default PIN. On first boot the computer terminal asks you to set one.
*   Right-click the physical Command Computer block to open the terminal.
*   Type a PIN of 4 to 8 digits and press Enter, then type it again to confirm.
*   The monitors then show the lock screen. Enter the PIN on the touchscreen keypad and tap `ENTER`.

### 2. Admin Keyboard Controls
These are used on the physical computer terminal (monitor touches carry no player identity, but terminal access implies physical access to the block).
*   `U` while locked: enter the PIN on your keyboard to unlock. This is also the way in during a keypad lockout.
*   `P` while unlocked: change the PIN (current PIN, then new PIN twice).
*   `L` while unlocked: lock the system.
*   `Ctrl+T`: quit to the shell. Monitors show a stopped notice.

### 3. Using the UI
*   **Roster (Monitor A):** Lists online players with their HP and dimension. Tap a name to add or remove it from your Watchlist. Watched players who are offline stay listed so they can be unwatched.
*   **Watch Grid (Monitor B):** Displays detailed cards for all watched players.
    *   **HP:** Current health with a color bar.
    *   **POS:** Real-time X, Y, Z block coordinates.
    *   **DIM:** The dimension the player is in.
    *   **SRC:** Whether the coordinates come from the player or from a vehicle.
    *   **AGE:** How long ago the data was last updated.
    *   **FOCUS:** Tap to prioritize that player. Tap again to clear the focus.
    *   **UNWATCH:** Removes the player from the grid.
*   **Single monitor:** Use the `ROSTER` and `GRID` buttons in the header to switch views.
*   **Paging:** Use `<` and `>` at the bottom of the screen when there are more players than fit.
*   **Locking:** Tap the `LOCK` button in the top right of the screen when walking away.

---

##  Technical Details & Configuration

The script contains a top-level `CFG` table that advanced users can modify:

*   **System Files:** State and PIN are saved in `.vanguard_data_v12` and `.vanguard_pin_v12`. Files are written to a temporary copy first, so a crash cannot leave a half-written file.
*   **Polling Limits:** `pollPerTick` (default 4 players per tick) and `maxTasks` (default 120) prevent the script from saturating the server's command queue and causing tick lag. `CFG.poll` sets the refresh interval for focused and normal players.
*   **Stale Thresholds:** Data is marked `STALE` after 5 seconds without an update, and `HARD` (Hard Stale) after 15 seconds.
*   **PIN Rules:** `CFG.pin` sets the PIN length, hashing rounds and lockout timing. `CFG.system.autoLockSec` sets the idle auto-lock (0 turns it off).
*   **Display:** `CFG.system.textScale` (default 0.5) is applied to every attached monitor.

### Upgrading from V11.3
*   V12 uses new file names, so V11.3 files are not overwritten.
*   The old PIN is not carried over. You set a new one on first run.
*   Your watchlist and focus are imported automatically from `.vanguard_data_v113` the first time V12 runs.

*Note: You can reset the PIN by deleting the `.vanguard_pin_v12` file via the CraftOS shell (press `Ctrl+T` to leave the program). The next start will ask for a new PIN.*
