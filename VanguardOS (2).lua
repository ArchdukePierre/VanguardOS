-- Vanguard OS V11.3
-- Target: Minecraft 1.20.1+ | CC:Tweaked | Command Computer
--
-- Features:
--   * Touchscreen lock screen PIN (stored as salted hash on disk)
--   * Optional keyboard-only admin override unlock (no player identity exists in monitor_touch events)
--   * Multi-monitor split: roster left monitor, grid right monitor (if 2+ monitors exist)
--   * Vehicle-seat fallback: RootVehicle.Entity.Pos when player Pos freezes (passenger/gunner cases)
--   * Stale indicators: per-player age badges + offline handling
--   * task_complete shape-agnostic unpacking
--   * ASCII-only UI
--
-- Default PIN (first run only): 040400
-- You can change PIN in-file via admin menu (see notes).

------------------------------------------------------------
-- TERMINAL / MONITORS
------------------------------------------------------------
local nativeTerm = term.current()

local function listMonitors()
  local mons = {}
  for _, n in ipairs(peripheral.getNames()) do
    if peripheral.getType(n) == "monitor" then
      table.insert(mons, { side = n, mon = peripheral.wrap(n) })
    end
  end
  return mons
end

local MONS = listMonitors()
local MON_A = MONS[1] and MONS[1].mon or nil  -- roster monitor (or single)
local MON_B = MONS[2] and MONS[2].mon or nil  -- grid monitor (or same as A)
local SIDE_A = MONS[1] and MONS[1].side or nil
local SIDE_B = MONS[2] and MONS[2].side or nil

local function safeTextScale(mon, scale)
  if not mon then return end
  pcall(function() mon.setTextScale(scale) end)
end

safeTextScale(MON_A, 0.5)
safeTextScale(MON_B, 0.5)

local function withTerm(t, fn)
  local prev = term.current()
  term.redirect(t)
  local ok, err = pcall(fn)
  term.redirect(prev)
  if not ok then return false, err end
  return true
end

------------------------------------------------------------
-- VERSION / CONFIG
------------------------------------------------------------
local VERSION = "V11.3"

local CFG = {
  theme = {
    bg      = colors.black,
    header  = colors.blue,
    text    = colors.white,
    dim     = colors.lightGray,
    ghost   = colors.gray,
    warn    = colors.orange,
    err     = colors.red,
    accent  = colors.cyan,

    cardEdgeOn  = colors.lightBlue,
    cardFillOn  = colors.blue,
    cardEdgeOff = colors.gray,
    cardFillOff = colors.black,

    btnEdge   = colors.cyan,
    btnFill   = colors.black,
    btnText   = colors.cyan,

    selectEdge = colors.cyan
  },

  system = {
    refreshRate = 0.20,
    listRate    = 2.0,
    pollRate    = 0.25,
    pollPerTick = 4,
    maxTasks    = 180,
    taskTimeout = 9000,

    stateFile   = ".vanguard_data_v113",
    pinFile     = ".vanguard_pin_v113"
  },

  plausibility = {
    -- Swap Y/Z only when Y is extreme and Z is plausible.
    swapAbs = 1000
  },

  stale = {
    staleMs = 5000,      -- >5s without data => STALE
    hardStaleMs = 15000  -- >15s => HARD STALE
  },

  vehicle = {
    -- If player Pos XZ doesn't change for this long but vehicle does,
    -- we prefer vehicle coords for display.
    freezeMs = 2000,
    -- extra RootVehicle polls are expensive; only do them when needed.
    probeCooldownMs = 1200
  }
}

------------------------------------------------------------
-- TIME / UTILS
------------------------------------------------------------
local function nowMs() return os.epoch("utc") end
local function clamp(n, a, b) return math.max(a, math.min(b, n)) end

local function shallowCopy(t)
  local o = {}
  for k, v in pairs(t) do o[k] = v end
  return o
end

------------------------------------------------------------
-- PIN STORAGE (SALTED HASH)
-- "Encrypted PIN storage" in CC:Tweaked realistically means:
--   * no plaintext PIN on disk
--   * compare using salted hash
-- This stops casual snooping and copy/paste leakage.
-- It is not cryptographic-grade encryption.
------------------------------------------------------------
local function fnv1a32(s)
  -- FNV-1a 32-bit
  local hash = 2166136261
  for i = 1, #s do
    hash = bit32.bxor(hash, s:byte(i))
    hash = (hash * 16777619) % 4294967296
  end
  return hash
end

local function randomSalt(len)
  local chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
  local out = {}
  for i = 1, len do
    local idx = math.random(1, #chars)
    out[i] = chars:sub(idx, idx)
  end
  return table.concat(out)
end

local function writePinHash(pin)
  local salt = randomSalt(16)
  local h = fnv1a32(salt .. ":" .. pin)
  local f = fs.open(CFG.system.pinFile, "w")
  if f then
    f.write(textutils.serialize({ salt = salt, hash = h }))
    f.close()
  end
end

local function readPinHash()
  if not fs.exists(CFG.system.pinFile) then return nil end
  local f = fs.open(CFG.system.pinFile, "r")
  if not f then return nil end
  local data = textutils.unserialize(f.readAll())
  f.close()
  return data
end

local function pinMatches(pin)
  local data = readPinHash()
  if not data then return false end
  local h = fnv1a32(tostring(data.salt) .. ":" .. tostring(pin))
  return h == data.hash
end

local function ensurePinFile()
  if fs.exists(CFG.system.pinFile) then return end
  -- first run default
  writePinHash("040400")
end

------------------------------------------------------------
-- STATE
------------------------------------------------------------
local SYSTEM = {
  running = true,
  hasPerms = false,

  locked = true,
  pinBuf = "",
  pinMsg = "",
  pinMsgKind = "info",
  pinMsgUntil = 0,

  -- UI
  hitsA = {},  -- hitboxes for monitor A
  hitsB = {},  -- hitboxes for monitor B
  hitsSingle = {},

  onlinePage = 0,
  watchPage = 0,

  status = "Booting...",
  statusKind = "info",
  statusAt = 0,

  -- Data
  tasks = {},
  players = {},  -- name -> Player
  online = {},   -- name -> true
  watch = {},    -- name -> true
  focus = nil,

  pollQueue = {},
  pollIdx = 1,

  timers = {},
  dirtyA = true,
  dirtyB = true,
  dirtySingle = true
}

local function setStatus(msg, kind)
  SYSTEM.status = msg or ""
  SYSTEM.statusKind = kind or "info"
  SYSTEM.statusAt = nowMs()
  SYSTEM.dirtyA, SYSTEM.dirtyB, SYSTEM.dirtySingle = true, true, true
end

local function setPinMsg(msg, kind, ms)
  SYSTEM.pinMsg = msg or ""
  SYSTEM.pinMsgKind = kind or "info"
  SYSTEM.pinMsgUntil = nowMs() + (ms or 1500)
  SYSTEM.dirtyA, SYSTEM.dirtyB, SYSTEM.dirtySingle = true, true, true
end

------------------------------------------------------------
-- PLAYER MODEL
------------------------------------------------------------
local function newPlayer(name)
  return {
    name = name,

    health = nil,
    pos = nil,         -- {x,y,z}
    vehPos = nil,      -- RootVehicle.Entity.Pos parsed
    useVeh = false,    -- display vehicle coords if true

    lastSeen = 0,
    lastData = 0,
    lastVehData = 0,

    online = false,

    session = 0,       -- increments on join
    failStreak = 0,

    -- freeze detection
    lastPosSample = nil,
    lastPosSampleAt = 0,
    lastVehProbeAt = 0
  }
end

local function ensurePlayer(name)
  local p = SYSTEM.players[name]
  if not p then
    p = newPlayer(name)
    SYSTEM.players[name] = p
  end
  return p
end

local function rebuildPollQueue()
  local q = {}
  for name in pairs(SYSTEM.watch) do table.insert(q, name) end
  table.sort(q)
  SYSTEM.pollQueue = q
  SYSTEM.pollIdx = 1
end

------------------------------------------------------------
-- SAVE / LOAD
------------------------------------------------------------
local function saveState()
  local data = {
    focus = SYSTEM.focus,
    watch = SYSTEM.watch,
    players = {}
  }
  for name, p in pairs(SYSTEM.players) do
    data.players[name] = {
      health = p.health,
      pos = p.pos,
      vehPos = p.vehPos,
      useVeh = p.useVeh,
      lastSeen = p.lastSeen,
      lastData = p.lastData,
      lastVehData = p.lastVehData,
      online = p.online,
      session = p.session
    }
  end

  local f = fs.open(CFG.system.stateFile, "w")
  if f then
    f.write(textutils.serialize(data))
    f.close()
  end
end

local function loadState()
  if not fs.exists(CFG.system.stateFile) then return end
  local f = fs.open(CFG.system.stateFile, "r")
  if not f then return end
  local data = textutils.unserialize(f.readAll())
  f.close()
  if not data then return end

  SYSTEM.focus = data.focus
  SYSTEM.watch = data.watch or {}

  for name, pd in pairs(data.players or {}) do
    local p = ensurePlayer(name)
    p.health = pd.health
    p.pos = pd.pos
    p.vehPos = pd.vehPos
    p.useVeh = pd.useVeh or false
    p.lastSeen = pd.lastSeen or 0
    p.lastData = pd.lastData or 0
    p.lastVehData = pd.lastVehData or 0
    p.online = pd.online or false
    p.session = pd.session or 0
  end

  rebuildPollQueue()
end

------------------------------------------------------------
-- TASK ENGINE
------------------------------------------------------------
local function taskCount()
  local n = 0
  for _ in pairs(SYSTEM.tasks) do n = n + 1 end
  return n
end

local function query(cmdStr, kind, meta)
  if not SYSTEM.hasPerms then return end
  if taskCount() >= CFG.system.maxTasks then
    setStatus("Task queue saturated; throttling polls.", "warn")
    return
  end
  local ok, id = pcall(commands.execAsync, cmdStr)
  if ok then
    SYSTEM.tasks[id] = { type = kind, meta = meta, cmd = cmdStr, t = nowMs() }
  end
end

local function gcTasks()
  local t = nowMs()
  for id, task in pairs(SYSTEM.tasks) do
    if (t - task.t) > CFG.system.taskTimeout then
      SYSTEM.tasks[id] = nil
    end
  end
end

------------------------------------------------------------
-- OUTPUT NORMALIZATION + PARSERS
------------------------------------------------------------
local function normalizeTaskOutput(out)
  local typ = type(out)
  if typ == "table" then
    local ok, s = pcall(table.concat, out, " ")
    if ok then return s else return "" end
  elseif typ == "string" then
    return out
  elseif typ == "number" then
    return tostring(out)
  else
    return ""
  end
end

local function extractNumsPreferBracket(text, maxCount)
  if not text or text == "" then return {} end
  local src = text
  local br = text:match("%b[]")
  if br and #br >= 3 then src = br end

  local nums = {}
  for n in src:gmatch("[-%d%.]+") do
    nums[#nums+1] = tonumber(n)
    if maxCount and #nums >= maxCount then break end
  end
  return nums
end

local function parseLastNumber(text)
  local nums = extractNumsPreferBracket(text, nil)
  if #nums == 0 then return nil end
  return nums[#nums]
end

local function parsePosXYZ(text)
  local nums = extractNumsPreferBracket(text, 3)
  if #nums < 3 then return nil end
  local x, y, z = nums[1], nums[2], nums[3]
  if not x or not y or not z then return nil end

  local swapAbs = CFG.plausibility.swapAbs
  if math.abs(y) > swapAbs and math.abs(z) <= swapAbs then
    y, z = z, y
  end
  return x, y, z
end

local function parseListOutput(text)
  local namePart = nil
  local startIdx = text:match(".*:%s*()")
  if startIdx then
    namePart = text:sub(startIdx)
  else
    local lower = text:lower()
    if lower:find("online", 1, true) or lower:find("players", 1, true) then
      namePart = text
    else
      return nil
    end
  end

  local found = {}
  local ignore = {
    there=true, are=true, of=true, online=true, players=true, player=true, max=true,
    list=true, total=true, connected=true, server=true, joined=true, left=true
  }

  for word in namePart:gmatch("[^, ]+") do
    local clean = word:gsub("§.", ""):gsub("[^a-zA-Z0-9_]", "")
    if #clean >= 3 and #clean <= 16 and not ignore[clean:lower()] then
      found[clean] = true
    end
  end

  return found
end

------------------------------------------------------------
-- VEHICLE FREEZE DETECTION
------------------------------------------------------------
local function dist2(a, b)
  local dx = (a.x - b.x)
  local dz = (a.z - b.z)
  return dx*dx + dz*dz
end

local function updateFreezeTracking(p)
  if not p.pos then return end
  local t = nowMs()

  if not p.lastPosSample then
    p.lastPosSample = { x = p.pos.x, y = p.pos.y, z = p.pos.z }
    p.lastPosSampleAt = t
    return
  end

  -- If XZ hasn't moved much since last sample, track that duration
  local d2 = dist2(p.pos, p.lastPosSample)
  if d2 <= 0.25 then
    -- keep waiting; potential freeze accumulating
  else
    -- moved; reset sample baseline
    p.lastPosSample = { x = p.pos.x, y = p.pos.y, z = p.pos.z }
    p.lastPosSampleAt = t
    p.useVeh = false
  end
end

local function shouldProbeVehicle(p)
  if not p.online then return false end
  if not p.pos then return false end

  local t = nowMs()
  if (t - (p.lastVehProbeAt or 0)) < CFG.vehicle.probeCooldownMs then return false end
  if not p.lastPosSampleAt or (t - p.lastPosSampleAt) < CFG.vehicle.freezeMs then return false end

  -- We think player Pos is frozen. Ask RootVehicle.Pos.
  return true
end

------------------------------------------------------------
-- TASK HANDLER (SESSION TOKENS + VEH FALLBACK)
------------------------------------------------------------
local function handleTaskResolved(id, okTask, outOrErr)
  local task = SYSTEM.tasks[id]
  if not task then return end
  SYSTEM.tasks[id] = nil

  if not okTask then
    return
  end

  local now = nowMs()
  local typ = task.type

  if typ == "list" then
    local data = normalizeTaskOutput(outOrErr)
    if data == "" then return end
    local seen = parseListOutput(data)
    if not seen then return end

    SYSTEM.online = {}

    for name in pairs(seen) do
      SYSTEM.online[name] = true
      local p = ensurePlayer(name)
      p.lastSeen = now

      if not p.online then
        p.online = true
        p.session = (p.session or 0) + 1
        p.failStreak = 0

        -- snap-back behavior after rejoin
        p.lastPosSample = nil
        p.lastPosSampleAt = 0
        p.useVeh = false
      end
    end

    for name, p in pairs(SYSTEM.players) do
      if p.online and not SYSTEM.online[name] then
        p.online = false
        p.useVeh = false
      end
    end

    SYSTEM.dirtyA, SYSTEM.dirtyB, SYSTEM.dirtySingle = true, true, true
    return
  end

  -- health / pos / vehpos require meta
  local meta = task.meta
  if not meta or not meta.name then return end
  local p = ensurePlayer(meta.name)
  if meta.session ~= p.session then return end

  local data = normalizeTaskOutput(outOrErr)
  if data == "" then return end

  if typ == "health" then
    local hp = parseLastNumber(data)
    if hp then
      p.health = hp
      p.lastData = now
      p.failStreak = 0
      SYSTEM.dirtyA, SYSTEM.dirtyB, SYSTEM.dirtySingle = true, true, true
    else
      p.failStreak = (p.failStreak or 0) + 1
    end
    return
  end

  if typ == "pos" then
    local x, y, z = parsePosXYZ(data)
    if x then
      p.pos = { x = x, y = y, z = z }
      p.lastData = now
      p.failStreak = 0
      updateFreezeTracking(p)
      SYSTEM.dirtyA, SYSTEM.dirtyB, SYSTEM.dirtySingle = true, true, true
    else
      p.failStreak = (p.failStreak or 0) + 1
    end
    return
  end

  if typ == "vehpos" then
    local x, y, z = parsePosXYZ(data)
    p.lastVehProbeAt = now
    if x then
      p.vehPos = { x = x, y = y, z = z }
      p.lastVehData = now

      -- If vehicle moved while player pos was frozen, prefer vehicle coords
      if p.pos and p.lastPosSampleAt and (now - p.lastPosSampleAt) >= CFG.vehicle.freezeMs then
        local moved = dist2(p.vehPos, p.lastPosSample) > 1.0
        if moved then
          p.useVeh = true
        end
      end

      SYSTEM.dirtyA, SYSTEM.dirtyB, SYSTEM.dirtySingle = true, true, true
    end
    return
  end
end

------------------------------------------------------------
-- TASK COMPLETE UNPACKING (SHAPE-AGNOSTIC)
------------------------------------------------------------
local function onTaskComplete(e)
  -- Handles:
  --   task_complete, id, false, "err"
  --   task_complete, id, true, cmdOk, outLines, affected?
  --   task_complete, id, true, outLines, affected?
  local id = e[2]
  local okTask = e[3]
  if not okTask then
    handleTaskResolved(id, false, e[4])
    return
  end

  local a4, a5 = e[4], e[5]
  if type(a4) == "boolean" then
    local cmdOk = a4
    local outLines = a5
    if cmdOk then
      handleTaskResolved(id, true, outLines)
    else
      handleTaskResolved(id, false, normalizeTaskOutput(outLines))
    end
  else
    handleTaskResolved(id, true, a4)
  end
end

------------------------------------------------------------
-- TOUCH HITBOXES
------------------------------------------------------------
local function clearHits()
  SYSTEM.hitsA, SYSTEM.hitsB, SYSTEM.hitsSingle = {}, {}, {}
end

local function addHit(which, x1, y1, x2, y2, fn)
  local t = (which == "A" and SYSTEM.hitsA) or (which == "B" and SYSTEM.hitsB) or SYSTEM.hitsSingle
  table.insert(t, {x1=x1, y1=y1, x2=x2, y2=y2, fn=fn})
end

local function runHit(which, x, y)
  local t = (which == "A" and SYSTEM.hitsA) or (which == "B" and SYSTEM.hitsB) or SYSTEM.hitsSingle
  for _, hb in ipairs(t) do
    if x >= hb.x1 and x <= hb.x2 and y >= hb.y1 and y <= hb.y2 then
      hb.fn()
      return true
    end
  end
  return false
end

------------------------------------------------------------
-- UI PRIMITIVES
------------------------------------------------------------
local function fillRect(x, y, ww, hh, bg)
  term.setBackgroundColor(bg)
  for yy = y, y + hh - 1 do
    term.setCursorPos(x, yy)
    term.write(string.rep(" ", ww))
  end
end

local function writeAt(x, y, s, fg, bg)
  if bg then term.setBackgroundColor(bg) end
  if fg then term.setTextColor(fg) end
  term.setCursorPos(x, y)
  term.write(s)
end

local function drawBox(x, y, ww, hh, edgeBg, innerBg)
  fillRect(x, y, ww, hh, edgeBg)
  if ww >= 3 and hh >= 3 then
    fillRect(x+1, y+1, ww-2, hh-2, innerBg)
  end
end

local function drawButton(x, y, label, active)
  local ww = #label + 2
  local edge = active and CFG.theme.selectEdge or CFG.theme.btnEdge
  drawBox(x, y, ww, 3, edge, CFG.theme.btnFill)
  writeAt(x+1, y+1, label, CFG.theme.btnText, CFG.theme.btnFill)
  return ww
end

local function fmtAge(ms)
  if not ms or ms <= 0 then return "--" end
  local s = math.floor(ms / 1000)
  if s < 60 then return tostring(s) .. "s" end
  local m = math.floor(s / 60)
  if m < 60 then return tostring(m) .. "m" end
  local hr = math.floor(m / 60)
  return tostring(hr) .. "h"
end

------------------------------------------------------------
-- PIN UI / ADMIN OVERRIDE
------------------------------------------------------------
local function pinStars()
  -- ASCII-only
  local n = #SYSTEM.pinBuf
  local stars = string.rep("*", n)
  local blanks = string.rep("_", math.max(0, 6 - n))
  return stars .. blanks
end

local function lockResetPin()
  SYSTEM.pinBuf = ""
  SYSTEM.dirtyA, SYSTEM.dirtyB, SYSTEM.dirtySingle = true, true, true
end

local function lockAppendDigit(d)
  if #SYSTEM.pinBuf >= 6 then return end
  SYSTEM.pinBuf = SYSTEM.pinBuf .. tostring(d)
  SYSTEM.dirtyA, SYSTEM.dirtyB, SYSTEM.dirtySingle = true, true, true
end

local function lockBackspace()
  if #SYSTEM.pinBuf == 0 then return end
  SYSTEM.pinBuf = SYSTEM.pinBuf:sub(1, #SYSTEM.pinBuf - 1)
  SYSTEM.dirtyA, SYSTEM.dirtyB, SYSTEM.dirtySingle = true, true, true
end

local function lockTryEnter()
  if pinMatches(SYSTEM.pinBuf) then
    SYSTEM.locked = false
    lockResetPin()
    setStatus("Authorized.", "success")
    query("list", "list", nil)
    saveState()
  else
    setPinMsg("DENIED", "err", 1400)
    lockResetPin()
  end
end

-- Admin-only keyboard override:
-- monitor_touch does not tell us which Minecraft player touched it.
-- The only reliable "admin identity" in CC is physical access to the computer keyboard.
local function adminKeyboardUnlock()
  -- Draw prompt on the REAL computer terminal
  term.redirect(nativeTerm)
  term.setBackgroundColor(colors.black)
  term.setTextColor(colors.white)
  term.clear()
  term.setCursorPos(1,1)
  print("ADMIN OVERRIDE")
  print("Enter PIN (hidden). Press Enter to submit. Press Esc to cancel.")
  write("PIN: ")
  local buf = ""
  while true do
    local ev, p1 = os.pullEvent()
    if ev == "char" then
      if #buf < 6 and p1:match("%d") then
        buf = buf .. p1
        write("*")
      end
    elseif ev == "key" then
      if p1 == keys.backspace then
        if #buf > 0 then
          buf = buf:sub(1, #buf-1)
          -- crude backspace redraw
          term.setCursorPos(6, 3)
          write(string.rep("*", #buf) .. string.rep(" ", 6-#buf))
          term.setCursorPos(6 + #buf, 3)
        end
      elseif p1 == keys.enter then
        break
      elseif p1 == keys.escape then
        buf = ""
        break
      end
    end
  end

  term.redirect(monitor or nativeTerm)

  if buf ~= "" and pinMatches(buf) then
    SYSTEM.locked = false
    setStatus("Admin override authorized.", "success")
    query("list", "list", nil)
  else
    setStatus("Admin override denied.", "warn")
  end

  SYSTEM.dirtyA, SYSTEM.dirtyB, SYSTEM.dirtySingle = true, true, true
end

------------------------------------------------------------
-- DRAW LOCK SCREENS
------------------------------------------------------------
local function drawLockTo(which, t)
  withTerm(t, function()
    local w, h = term.getSize()
    term.setBackgroundColor(CFG.theme.bg)
    term.clear()

    term.setCursorPos(1,1)
    term.setBackgroundColor(CFG.theme.header)
    term.setTextColor(CFG.theme.text)
    term.clearLine()
    local head = " VANGUARD ACCESS  " .. VERSION .. " "
    if #head > w then head = head:sub(1, w) end
    term.write(head)

    local cx = math.floor(w/2)
    local topY = 3

    local title = "ENTER PASSCODE"
    writeAt(math.max(1, cx - math.floor(#title/2)), topY, title, CFG.theme.accent, CFG.theme.bg)
    local dots = pinStars()
    writeAt(math.max(1, cx - math.floor(#dots/2)), topY+2, dots, CFG.theme.text, CFG.theme.bg)

    if SYSTEM.pinMsg ~= "" and nowMs() <= SYSTEM.pinMsgUntil then
      local col = CFG.theme.text
      if SYSTEM.pinMsgKind == "err" then col = CFG.theme.err
      elseif SYSTEM.pinMsgKind == "warn" then col = CFG.theme.warn
      elseif SYSTEM.pinMsgKind == "success" then col = CFG.theme.accent end
      writeAt(math.max(1, cx - math.floor(#SYSTEM.pinMsg/2)), topY+4, SYSTEM.pinMsg, col, CFG.theme.bg)
    end

    local padW, padH = 9, 3
    local gapX, gapY = 2, 1
    local gridW = (padW*3) + (gapX*2)
    local gx = math.max(1, cx - math.floor(gridW/2))
    local gy = topY + 6

    local function key(x, y, label, onPress)
      drawBox(x, y, padW, padH, CFG.theme.btnEdge, CFG.theme.btnFill)
      writeAt(x + math.floor((padW-#label)/2), y+1, label, CFG.theme.btnText, CFG.theme.btnFill)
      addHit(which, x, y, x+padW-1, y+padH-1, onPress)
    end

    local d = 1
    for r=0,2 do
      for c=0,2 do
        local x = gx + c*(padW+gapX)
        local y = gy + r*(padH+gapY)
        local digit = tostring(d)
        key(x, y, digit, function() lockAppendDigit(digit) end)
        d = d + 1
      end
    end

    local y4 = gy + 3*(padH+gapY)
    key(gx, y4, "CLR", function() lockResetPin() end)
    key(gx + 1*(padW+gapX), y4, "0", function() lockAppendDigit("0") end)
    key(gx + 2*(padW+gapX), y4, "BK", function() lockBackspace() end)

    local enterW, enterH = gridW, 3
    local ex, ey = gx, y4 + padH + 2
    drawBox(ex, ey, enterW, enterH, CFG.theme.selectEdge, CFG.theme.btnFill)
    writeAt(ex + math.floor((enterW-5)/2), ey+1, "ENTER", CFG.theme.btnText, CFG.theme.btnFill)
    addHit(which, ex, ey, ex+enterW-1, ey+enterH-1, function() lockTryEnter() end)

    local hint = "Keyboard admin override: press U on the computer"
    if #hint > w-2 then hint = hint:sub(1, w-2) end
    writeAt(2, h, hint, CFG.theme.dim, CFG.theme.bg)
  end)
end

local function drawLocked()
  clearHits()
  if MON_A and MON_B then
    drawLockTo("A", MON_A)
    drawLockTo("B", MON_B)
  elseif MON_A then
    drawLockTo("S", MON_A)
  else
    -- no monitor: draw on native term
    drawLockTo("S", nativeTerm)
  end
end

------------------------------------------------------------
-- MAIN UI DRAW
------------------------------------------------------------
local function drawHeader(t, title)
  local w, _ = term.getSize()
  term.setCursorPos(1,1)
  term.setBackgroundColor(CFG.theme.header)
  term.setTextColor(CFG.theme.text)
  term.clearLine()
  if #title > w then title = title:sub(1, w) end
  term.write(title)
  term.setBackgroundColor(CFG.theme.bg)
end

local function staleBadge(p)
  if not p.online then return "OFF", CFG.theme.ghost end
  local age = nowMs() - (p.lastData or 0)
  if age >= CFG.stale.hardStaleMs then return "HARD", CFG.theme.err end
  if age >= CFG.stale.staleMs then return "STALE", CFG.theme.warn end
  return "FRESH", CFG.theme.accent
end

local function posToString(p)
  local pos = p.useVeh and p.vehPos or p.pos
  if not pos then return "--, --, --" end
  return string.format("%.0f, %.0f, %.0f", pos.x, pos.y, pos.z)
end

local function drawRoster(which, t)
  withTerm(t, function()
    clearHits()

    local w, h = term.getSize()
    term.setBackgroundColor(CFG.theme.bg)
    term.clear()

    local onlineCount = 0
    for _ in pairs(SYSTEM.online) do onlineCount = onlineCount + 1 end
    local watchCount = 0
    for _ in pairs(SYSTEM.watch) do watchCount = watchCount + 1 end

    drawHeader(t, string.format(" VANGUARD %s  ONLINE:%d  WATCH:%d ", VERSION, onlineCount, watchCount))

    writeAt(2, 3, "ONLINE (tap to watch/unwatch)", CFG.theme.accent, CFG.theme.bg)

    local names = {}
    for name in pairs(SYSTEM.online) do table.insert(names, name) end
    table.sort(names)

    local listTop = 5
    local listBottom = h - 4
    local listH = math.max(1, listBottom - listTop + 1)

    local perPage = listH
    local pages = math.max(1, math.ceil(#names / perPage))
    SYSTEM.onlinePage = clamp(SYSTEM.onlinePage, 0, pages - 1)

    local startIdx = SYSTEM.onlinePage * perPage + 1
    local endIdx = math.min(#names, startIdx + perPage - 1)

    local y = listTop
    for i = startIdx, endIdx do
      local name = names[i]
      local watched = SYSTEM.watch[name] == true
      local label = (watched and "+ " or "  ") .. name
      if #label > w-4 then label = label:sub(1, w-4) end
      writeAt(2, y, label .. string.rep(" ", math.max(0, w-3-#label)), watched and CFG.theme.accent or CFG.theme.text, CFG.theme.bg)

      addHit(which, 1, y, w, y, function()
        if SYSTEM.watch[name] then
          SYSTEM.watch[name] = nil
          if SYSTEM.focus == name then SYSTEM.focus = nil end
          rebuildPollQueue()
          saveState()
          setStatus("Unwatched: " .. name, "warn")
        else
          SYSTEM.watch[name] = true
          ensurePlayer(name)
          rebuildPollQueue()
          saveState()
          setStatus("Watching: " .. name, "success")
        end
      end)

      y = y + 1
    end

    local btnY = h - 2
    local px = 2
    local prevW = drawButton(px, btnY, "<", SYSTEM.onlinePage > 0)
    addHit(which, px, btnY, px+prevW-1, btnY+2, function()
      if SYSTEM.onlinePage > 0 then SYSTEM.onlinePage = SYSTEM.onlinePage - 1; setStatus("Roster page " .. tostring(SYSTEM.onlinePage+1), "info") end
    end)
    px = px + prevW + 2
    local nextW = drawButton(px, btnY, ">", SYSTEM.onlinePage < pages - 1)
    addHit(which, px, btnY, px+nextW-1, btnY+2, function()
      if SYSTEM.onlinePage < pages - 1 then SYSTEM.onlinePage = SYSTEM.onlinePage + 1; setStatus("Roster page " .. tostring(SYSTEM.onlinePage+1), "info") end
    end)

    local pageTxt = string.format("PAGE %d/%d", SYSTEM.onlinePage+1, pages)
    writeAt(w-#pageTxt-1, btnY+1, pageTxt, CFG.theme.dim, CFG.theme.bg)

    local lockLabel = "LOCK"
    local lw = #lockLabel + 2
    drawBox(w-lw-1, 1, lw, 1, CFG.theme.header, CFG.theme.header)
    writeAt(w-lw, 1, lockLabel, CFG.theme.warn, CFG.theme.header)
    addHit(which, w-lw-1, 1, w, 1, function()
      SYSTEM.locked = true
      SYSTEM.pinBuf = ""
      setPinMsg("", "info", 0)
      saveState()
    end)
  end)
end

local function drawGrid(which, t)
  withTerm(t, function()
    local w, h = term.getSize()
    term.setBackgroundColor(CFG.theme.bg)
    term.clear()

    local onlineCount = 0
    for _ in pairs(SYSTEM.online) do onlineCount = onlineCount + 1 end
    local watchCount = 0
    for _ in pairs(SYSTEM.watch) do watchCount = watchCount + 1 end

    drawHeader(t, string.format(" WATCH GRID  %s  ONLINE:%d WATCH:%d ", VERSION, onlineCount, watchCount))

    local lockLabel = "LOCK"
    local lw = #lockLabel + 2
    drawBox(w-lw-1, 1, lw, 1, CFG.theme.header, CFG.theme.header)
    writeAt(w-lw, 1, lockLabel, CFG.theme.warn, CFG.theme.header)
    addHit(which, w-lw-1, 1, w, 1, function()
      SYSTEM.locked = true
      SYSTEM.pinBuf = ""
      setPinMsg("", "info", 0)
      saveState()
    end)

    local topY = 3
    if SYSTEM.focus then
      local p = ensurePlayer(SYSTEM.focus)
      local badge, bcol = staleBadge(p)
      drawBox(2, topY, w-2, 5, CFG.theme.cardEdgeOn, CFG.theme.cardFillOn)
      writeAt(4, topY+1, "FOCUS: " .. SYSTEM.focus, CFG.theme.text, CFG.theme.cardFillOn)
      writeAt(w-12, topY+1, badge, bcol, CFG.theme.cardFillOn)
      writeAt(4, topY+2, "HP: " .. (p.health and string.format("%.1f", p.health) or "--"), CFG.theme.text, CFG.theme.cardFillOn)
      local ps = posToString(p)
      local mode = p.useVeh and " (VEH)" or ""
      writeAt(4, topY+3, "POS: " .. ps .. mode, CFG.theme.text, CFG.theme.cardFillOn)
      topY = topY + 6
    end

    writeAt(2, topY, "Tap cards: FOCUS / UNWATCH", CFG.theme.dim, CFG.theme.bg)
    topY = topY + 2

    local names = {}
    for nm in pairs(SYSTEM.watch) do table.insert(names, nm) end
    table.sort(names)

    local cardW, cardH = 30, 7
    local cols = math.max(1, math.floor((w-2) / (cardW + 1)))
    local rows = math.max(1, math.floor((h - topY - 5) / (cardH + 1)))
    local capacity = math.max(1, cols * rows)

    local pages = math.max(1, math.ceil(#names / capacity))
    SYSTEM.watchPage = clamp(SYSTEM.watchPage, 0, pages - 1)

    local startIdx = SYSTEM.watchPage * capacity + 1
    local endIdx = math.min(#names, startIdx + capacity - 1)

    local idx = 0
    for i = startIdx, endIdx do
      idx = idx + 1
      local nm = names[i]
      local p = ensurePlayer(nm)

      local r = math.floor((idx-1)/cols)
      local c = (idx-1) % cols
      local x = 2 + c*(cardW+1)
      local y = topY + r*(cardH+1)

      local on = p.online
      local edge = on and CFG.theme.cardEdgeOn or CFG.theme.cardEdgeOff
      local fill = on and CFG.theme.cardFillOn or CFG.theme.cardFillOff
      drawBox(x, y, cardW, cardH, edge, fill)

      local badge, bcol = staleBadge(p)

      local nameLine = nm
      if #nameLine > 18 then nameLine = nameLine:sub(1,18) end
      writeAt(x+2, y+1, nameLine, CFG.theme.text, fill)
      writeAt(x+cardW-6, y+1, badge, bcol, fill)

      writeAt(x+2, y+2, "HP: " .. (p.health and string.format("%.0f", p.health) or "--"), CFG.theme.text, fill)

      local ps = posToString(p)
      local mode = p.useVeh and " VEH" or ""
      writeAt(x+2, y+3, "POS: " .. ps, CFG.theme.text, fill)
      if mode ~= "" then
        writeAt(x+2, y+4, "SRC: VEHICLE", CFG.theme.accent, fill)
      else
        writeAt(x+2, y+4, "SRC: PLAYER", CFG.theme.dim, fill)
      end

      local age = nowMs() - (p.lastData or 0)
      writeAt(x+2, y+5, "AGE: " .. fmtAge(age), (age > CFG.stale.staleMs) and CFG.theme.warn or CFG.theme.dim, fill)

      local bx, by = x+2, y+cardH-2
      local fw = drawButton(bx, by, "FOCUS", SYSTEM.focus == nm)
      addHit(which, bx, by, bx+fw-1, by+2, function()
        SYSTEM.focus = nm
        saveState()
        setStatus("Focus set: " .. nm, "success")
      end)

      local ux = bx + fw + 2
      local uw = drawButton(ux, by, "UNWATCH", false)
      addHit(which, ux, by, ux+uw-1, by+2, function()
        SYSTEM.watch[nm] = nil
        if SYSTEM.focus == nm then SYSTEM.focus = nil end
        rebuildPollQueue()
        saveState()
        setStatus("Unwatched: " .. nm, "warn")
      end)
    end

    local btnY = h - 2
    local px = 2
    local prevW = drawButton(px, btnY, "<", SYSTEM.watchPage > 0)
    addHit(which, px, btnY, px+prevW-1, btnY+2, function()
      if SYSTEM.watchPage > 0 then SYSTEM.watchPage = SYSTEM.watchPage - 1; setStatus("Grid page " .. tostring(SYSTEM.watchPage+1), "info") end
    end)
    px = px + prevW + 2
    local nextW = drawButton(px, btnY, ">", SYSTEM.watchPage < pages - 1)
    addHit(which, px, btnY, px+nextW-1, btnY+2, function()
      if SYSTEM.watchPage < pages - 1 then SYSTEM.watchPage = SYSTEM.watchPage + 1; setStatus("Grid page " .. tostring(SYSTEM.watchPage+1), "info") end
    end)

    local pageTxt = string.format("PAGE %d/%d", SYSTEM.watchPage+1, pages)
    writeAt(w-#pageTxt-1, btnY+1, pageTxt, CFG.theme.dim, CFG.theme.bg)

    local sk = SYSTEM.statusKind
    local col = CFG.theme.text
    if sk == "warn" then col = CFG.theme.warn
    elseif sk == "err" then col = CFG.theme.err
    elseif sk == "success" then col = CFG.theme.accent end

    local s = SYSTEM.status or ""
    if #s > w-4 then s = s:sub(1, w-4) end
    writeAt(2, h-3, s .. string.rep(" ", math.max(0, w-2-#s)), col, CFG.theme.bg)
  end)
end

local function drawUnlocked()
  -- Two-monitor split:
  --   A = roster
  --   B = grid
  -- Single monitor:
  --   show grid + roster integrated behavior via taps and paging; we keep it grid-oriented.
  if MON_A and MON_B then
    drawRoster("A", MON_A)
    drawGrid("B", MON_B)
  elseif MON_A then
    -- single monitor: draw grid only; roster still accessible by "list" scanning + watch taps not available.
    -- practical compromise: show roster+grid in one view is heavy; for now draw grid and rely on watchlist already built.
    drawGrid("S", MON_A)
  else
    drawGrid("S", nativeTerm)
  end
end

------------------------------------------------------------
-- COMMANDS: LIST / POLLING (FOCUS-FIRST + VEH PROBE)
------------------------------------------------------------
local function pollPlayer(name)
  local p = ensurePlayer(name)
  if not p.online then return end
  local meta = { name = name, session = p.session }
  query("data get entity " .. name .. " Health", "health", meta)
  query("data get entity " .. name .. " Pos", "pos", meta)
end

local function pollVehicleIfNeeded(name)
  local p = ensurePlayer(name)
  if not p.online then return end
  if not shouldProbeVehicle(p) then return end
  p.lastVehProbeAt = nowMs()
  local meta = { name = name, session = p.session }
  -- RootVehicle path; will fail silently for non-riders, which is fine.
  query("data get entity " .. name .. " RootVehicle.Entity.Pos", "vehpos", meta)
end

local function pollWatched()
  -- Focus-first every cycle (feels like V7 again)
  if SYSTEM.focus then
    pollPlayer(SYSTEM.focus)
    pollVehicleIfNeeded(SYSTEM.focus)
  end

  if #SYSTEM.pollQueue == 0 then return end
  local count = math.min(CFG.system.pollPerTick, #SYSTEM.pollQueue)
  for _ = 1, count do
    if SYSTEM.pollIdx > #SYSTEM.pollQueue then SYSTEM.pollIdx = 1 end
    local name = SYSTEM.pollQueue[SYSTEM.pollIdx]
    SYSTEM.pollIdx = SYSTEM.pollIdx + 1

    pollPlayer(name)
    pollVehicleIfNeeded(name)
  end
end

------------------------------------------------------------
-- BOOT
------------------------------------------------------------
local function entry()
  ensurePinFile()

  if not commands or not commands.execAsync then
    SYSTEM.hasPerms = false
    setStatus("No Command API. Use a Command Computer.", "err")
  else
    SYSTEM.hasPerms = true
    loadState()
    rebuildPollQueue()
    setStatus("Locked. Enter PIN.", "warn")
    query("list", "list", nil)
  end

  SYSTEM.timers.refresh = os.startTimer(CFG.system.refreshRate)
  SYSTEM.timers.list    = os.startTimer(CFG.system.listRate)
  SYSTEM.timers.poll    = os.startTimer(CFG.system.pollRate)
  SYSTEM.timers.gc      = os.startTimer(5)

  while SYSTEM.running do
    if SYSTEM.locked then
      drawLocked()
    else
      drawUnlocked()
    end

    local e = { os.pullEventRaw() }
    local ev = e[1]

    if ev == "terminate" then
      SYSTEM.running = false
      saveState()

    elseif ev == "term_resize" then
      SYSTEM.dirtyA, SYSTEM.dirtyB, SYSTEM.dirtySingle = true, true, true

    elseif ev == "monitor_touch" then
      local side, x, y = e[2], e[3], e[4]
      if SYSTEM.locked then
        if SIDE_A and side == SIDE_A then runHit("A", x, y) end
        if SIDE_B and side == SIDE_B then runHit("B", x, y) end
        if (not SIDE_A) and (not SIDE_B) then runHit("S", x, y) end
      else
        if SIDE_A and side == SIDE_A then runHit("A", x, y) end
        if SIDE_B and side == SIDE_B then runHit("B", x, y) end
        if (not SIDE_A) and (not SIDE_B) then runHit("S", x, y) end
      end

    elseif ev == "mouse_click" then
      -- For single-monitor-on-terminal testing
      local _, x, y = e[2], e[3], e[4]
      runHit("S", x, y)

    elseif ev == "key" then
      local k = e[2]

      -- Keyboard admin override while locked:
      if SYSTEM.locked and k == keys.u then
        adminKeyboardUnlock()
      end

    elseif ev == "task_complete" then
      onTaskComplete(e)

    elseif ev == "timer" then
      if e[2] == SYSTEM.timers.refresh then
        SYSTEM.timers.refresh = os.startTimer(CFG.system.refreshRate)
        if SYSTEM.locked and SYSTEM.pinMsg ~= "" and nowMs() > SYSTEM.pinMsgUntil then
          SYSTEM.pinMsg = ""
        end

      elseif e[2] == SYSTEM.timers.list then
        query("list", "list", nil)
        SYSTEM.timers.list = os.startTimer(CFG.system.listRate)

      elseif e[2] == SYSTEM.timers.poll then
        if not SYSTEM.locked then pollWatched() end
        SYSTEM.timers.poll = os.startTimer(CFG.system.pollRate)

      elseif e[2] == SYSTEM.timers.gc then
        gcTasks()
        SYSTEM.timers.gc = os.startTimer(5)
      end
    end
  end

  saveState()
end

------------------------------------------------------------
-- CRASH SAFETY
------------------------------------------------------------
local ok, err = xpcall(entry, debug.traceback)
if not ok then
  term.redirect(nativeTerm)
  term.setBackgroundColor(colors.blue)
  term.setTextColor(colors.white)
  term.clear()
  term.setCursorPos(1,1)
  print("VANGUARD CRASHED")
  print(err)
  print("Press R to reboot")
  while true do
    local _, k = os.pullEvent("key")
    if k == keys.r then os.reboot() end
  end
end
