# Vanguard OS V11.3


Vanguard OS is an advanced player tracking and monitoring operating system built for Minecraft Command Computers via the **CC:Tweaked** mod. It provides real-time, on-screen tracking of players' health, coordinates, and vehicle usage, wrapped in an interactive ASCII graphical user interface.

##  Key Features

*   **Touchscreen Lock Screen:** Secure access to the system using a touchscreen keypad. The PIN is stored on-disk as a salted FNV-1a hash to prevent casual snooping.
*   **Dual-Monitor Support:** Automatically detects up to two connected monitors, splitting the UI into a **Roster View** (Monitor A) and a **Watch Grid** (Monitor B). Single monitor setups are also seamlessly supported.
*   **Advanced Player Polling:** Asynchronously queries player Health and XYZ Position using command queues (`commands.execAsync`).
*   **Vehicle-Seat Fallback:** Automatically detects when a player is "frozen" (e.g., sitting in a vehicle, minecart, or passenger seat) and queries `RootVehicle.Entity.Pos` to display accurate coordinates.
*   **Target Prioritization:** Features a "Focus" mode to prioritize polling rates for a specific tracked target.
*   **Stale Indicators:** Real-time data age badges (`FRESH`, `STALE`, `HARD STALE`) and offline handling to immediately show when data is out of date.
*   **Admin Override:** Keyboard-only "Admin Override" accessible via the physical computer terminal (prevents lock-outs).
*   **Crash Safety:** Built-in error trapping that presents a safe reboot screen rather than dropping to the shell.

---

##  Requirements

1.  **Minecraft Version:** 1.20.1 or higher.
2.  **Mod:** CC:Tweaked (or an equivalent ComputerCraft fork).
3.  **Hardware:**
    *   **1x Command Computer** (Standard computers will *not* work as they lack the `commands` API).
    *   **1x or 2x Advanced Monitors** (For color GUI and multi-screen support).

---

##  Installation & Setup

1. Place down a Command Computer.
2. Attach 1 or 2 Advanced Monitors to the computer (adjacent sides or via modded networking).
3. Download/Paste the Vanguard OS Lua script into a file on the computer (e.g., `startup.lua` to run on boot).
4. Run the script.

---

##  User Guide

### 1. First Run & Authentication
Upon first boot, the system will generate a secure PIN file (`.vanguard_pin_v113`) and lock the screen.
*   **Default PIN:** `040400`
*   Enter the PIN using the touchscreen monitors to unlock the system.

### 2. Admin Keyboard Override
If you forget the PIN or want to bypass the monitor touchscreen:
*   Right-click the physical Command Computer block to open the native terminal.
*   Press the `U` key.
*   Enter the PIN on your keyboard. *(This is an anti-spoofing feature, as monitor touches don't carry player identity data, but terminal access implies physical block access).*

### 3. Using the UI
*   **Roster List (Monitor A):** Displays all players currently online. Tap a player's name to add them to your Watchlist. 
*   **Watch Grid (Monitor B):** Displays detailed cards for all tracked players.
    *   **HP:** Shows the player's current health.
    *   **POS:** Real-time X, Y, Z coordinates.
    *   **FOCUS:** Tap the "Focus" button on a card to prioritize that player, increasing their polling rate.
    *   **UNWATCH:** Removes the player from the active tracking grid.
*   **Locking:** Tap the `LOCK` button in the top right of either screen to secure the console when walking away.

---

##  Technical Details & Configuration

The script contains a top-level `CFG` table that advanced users can modify:

*   **System Files:** State and PIN are saved locally in `.vanguard_data_v113` and `.vanguard_pin_v113`. 
*   **Polling Limits:** `pollPerTick` and `maxTasks` (default: 180) prevent the script from saturating the server's command queue and causing tick lag.
*   **Stale Thresholds:** Data is marked `STALE` after 5 seconds without an update, and `HARD` (Hard Stale) after 15 seconds.
*   **Plausibility Checking:** Built-in heuristics swap Y and Z coordinates if the output parsers misalign due to extreme height maps vs distance limits (`CFG.plausibility.swapAbs = 1000`).

---

*Note: You can reset the PIN by either deleting the `.vanguard_pin_v113` file via the CraftOS shell or editing the default value in the script.*
