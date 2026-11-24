local VERSION = "V12.0"

local nativeTerm = term.current()
local floor, ceil, min, max = math.floor, math.ceil, math.min, math.max
local insert, remove, sort, concat = table.insert, table.remove, table.sort, table.concat
local rep = string.rep

local CFG = {
  theme = {
    bg = colors.black,
    header = colors.blue,
    headerText = colors.white,
    text = colors.white,
    dim = colors.lightGray,
    ghost = colors.gray,
    warn = colors.orange,
    err = colors.red,
    accent = colors.cyan,
    good = colors.lime,
    cardEdgeOn = colors.lightBlue,
    cardFillOn = colors.blue,
    cardEdgeOff = colors.gray,
    cardFillOff = colors.black,
    cardEdgeFocus = colors.yellow,
    btnEdge = colors.cyan,
    btnFill = colors.black,
    btnText = colors.cyan,
    btnActive = colors.lime,
    btnOff = colors.gray,
    keyFill = colors.gray,
    hpGood = colors.lime,
    hpMid = colors.yellow,
    hpLow = colors.red,
    barOff = colors.gray,
    chipText = colors.black
  },
  system = {
    textScale = 0.5,
    refreshRate = 0.2,
    listRate = 2.0,
    pollRate = 0.25,
    pollPerTick = 4,
    maxTasks = 120,
    taskTimeout = 9000,
    saveRate = 60,
    gcRate = 5,
    autoLockSec = 180,
    stateFile = ".vanguard_data_v12",
    legacyStateFile = ".vanguard_data_v113",
    pinFile = ".vanguard_pin_v12",
    crashFile = ".vanguard_crash.log"
  },
  pin = {
    minLen = 4,
    maxLen = 8,
    rounds = 128,
    freeAttempts = 3,
    lockBaseSec = 30,
    lockMaxSec = 900
  },
  poll = {
    focusMs = 250,
    baseMs = 1000,
    maxBackoff = 3,
    dimMs = 10000
  },
  stale = {
    staleMs = 5000,
    hardStaleMs = 15000
  },
  vehicle = {
    freezeMs = 2000,
    probeMs = 1200,
    maxBackoffMs = 15000,
    moveEps2 = 0.25,
    vehEps2 = 1.0
  },
  alert = {
    lowHealth = 6
  },
  log = {
    max = 60
  },
  crash = {
    maxRestarts = 5,
    windowSec = 120,
    delaySec = 3
  }
}

local GRAY = {
  bg = colors.black,
  header = colors.gray,
  headerText = colors.white,
  text = colors.white,
  dim = colors.lightGray,
  ghost = colors.gray,
  warn = colors.white,
  err = colors.white,
  accent = colors.white,
  good = colors.white,
  cardEdgeOn = colors.white,
  cardFillOn = colors.gray,
  cardEdgeOff = colors.gray,
  cardFillOff = colors.black,
  cardEdgeFocus = colors.white,
  btnEdge = colors.white,
  btnFill = colors.black,
  btnText = colors.white,
  btnActive = colors.white,
  btnOff = colors.gray,
  keyFill = colors.gray,
  hpGood = colors.white,
  hpMid = colors.lightGray,
  hpLow = colors.lightGray,
  barOff = colors.black,
  chipText = colors.black
}

local function nowMs() return os.epoch("utc") end
local function clamp(n, a, b) return max(a, min(b, n)) end

local function fit(s, n)
  s = tostring(s == nil and "" or s)
  if n <= 0 then return "" end
  if #s > n then return s:sub(1, n) end
  return s
end

local function pad(s, n)
  s = fit(s, n)
  return s .. rep(" ", n - #s)
end

local function padLeft(s, n)
  s = fit(s, n)
  return rep(" ", n - #s) .. s
end

local function count(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  return n
end

local function validName(n)
  return type(n) == "string" and #n >= 1 and #n <= 16 and n:match("^[%w_]+$") ~= nil
end

local function ival(n)
  local v = floor(n)
  if v == 0 then return "0" end
  return string.format("%.0f", v)
end

local function fmtHp(hp)
  local s = string.format("%.1f", hp)
  return (s:gsub("%.0$", ""))
end

local function clockText()
  local ok, s = pcall(os.date, "%H:%M:%S")
  if ok and type(s) == "string" then return s end
  return ""
end

local function readFile(path)
  for _, candidate in ipairs({ path, path .. ".tmp" }) do
    if fs.exists(candidate) then
      local f = fs.open(candidate, "r")
      if f then
        local s = f.readAll()
        f.close()
        return s or ""
      end
    end
  end
  return nil
end

local function writeFile(path, text)
  local tmp = path .. ".tmp"
  local f = fs.open(tmp, "w")
  if not f then return false end
  local ok = pcall(f.write, text)
  f.close()
  if not ok then
    pcall(fs.delete, tmp)
    return false
  end
  if fs.exists(path) then fs.delete(path) end
  return (pcall(fs.move, tmp, path))
end

local function writeCrashLog(text)
  local path = CFG.system.crashFile
  pcall(function()
    if fs.exists(path) and fs.getSize(path) > 16384 then fs.delete(path) end
    local f = fs.open(path, "a")
    if f then
      f.writeLine("[" .. tostring(os.date("%Y-%m-%d %H:%M:%S")) .. "] " .. tostring(text))
      f.close()
    end
  end)
end

local bxor, band, bnot, rrot, rshift = bit32.bxor, bit32.band, bit32.bnot, bit32.rrotate, bit32.rshift
local MOD = 4294967296

local K = {
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
}

local function be32(n)
  return string.char(floor(n / 16777216) % 256, floor(n / 65536) % 256, floor(n / 256) % 256, n % 256)
end

local HEX = "0123456789abcdef"

local function hex32(n)
  local t = {}
  for i = 8, 1, -1 do
    local d = n % 16
    t[i] = HEX:sub(d + 1, d + 1)
    n = (n - d) / 16
  end
  return concat(t)
end

local function sha256(msg)
  local len = #msg
  msg = msg .. "\128" .. rep("\0", (55 - len) % 64) .. be32(floor(len * 8 / MOD)) .. be32((len * 8) % MOD)
  local h0, h1, h2, h3 = 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a
  local h4, h5, h6, h7 = 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
  local w = {}
  for chunk = 1, #msg, 64 do
    for i = 1, 16 do
      local at = chunk + (i - 1) * 4
      local b1, b2, b3, b4 = msg:byte(at, at + 3)
      w[i] = b1 * 16777216 + b2 * 65536 + b3 * 256 + b4
    end
    for i = 17, 64 do
      local x, y = w[i - 15], w[i - 2]
      local s0 = bxor(bxor(rrot(x, 7), rrot(x, 18)), rshift(x, 3))
      local s1 = bxor(bxor(rrot(y, 17), rrot(y, 19)), rshift(y, 10))
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) % MOD
    end
    local a, b, c, d, e, f, g, h = h0, h1, h2, h3, h4, h5, h6, h7
    for i = 1, 64 do
      local S1 = bxor(bxor(rrot(e, 6), rrot(e, 11)), rrot(e, 25))
      local ch = bxor(band(e, f), band(bnot(e), g))
      local t1 = (h + S1 + ch + K[i] + w[i]) % MOD
      local S0 = bxor(bxor(rrot(a, 2), rrot(a, 13)), rrot(a, 22))
      local maj = bxor(bxor(band(a, b), band(a, c)), band(b, c))
      local t2 = (S0 + maj) % MOD
      h, g, f, e, d, c, b, a = g, f, e, (d + t1) % MOD, c, b, a, (t1 + t2) % MOD
    end
    h0, h1, h2, h3 = (h0 + a) % MOD, (h1 + b) % MOD, (h2 + c) % MOD, (h3 + d) % MOD
    h4, h5, h6, h7 = (h4 + e) % MOD, (h5 + f) % MOD, (h6 + g) % MOD, (h7 + h) % MOD
  end
  return hex32(h0) .. hex32(h1) .. hex32(h2) .. hex32(h3) .. hex32(h4) .. hex32(h5) .. hex32(h6) .. hex32(h7)
end

local function randomSalt(len)
  local chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
  local out = {}
  for i = 1, len do
    local k = math.random(1, #chars)
    out[i] = chars:sub(k, k)
  end
  return concat(out)
end

local function hashPin(pin, salt, rounds)
  local h = sha256(salt .. ":" .. pin)
  for _ = 2, rounds do h = sha256(h .. salt) end
  return h
end

local PIN = { salt = nil, hash = nil, rounds = nil }

local function loadPin()
  PIN.salt, PIN.hash, PIN.rounds = nil, nil, nil
  local raw = readFile(CFG.system.pinFile)
  if not raw then return false end
  local ok, data = pcall(textutils.unserialize, raw)
  if not ok or type(data) ~= "table" then return false end
  if data.v ~= 2 or type(data.salt) ~= "string" or type(data.hash) ~= "string" then return false end
  if type(data.rounds) ~= "number" or data.rounds < 1 or data.rounds > 5000 then return false end
  if #data.hash ~= 64 then return false end
  PIN.salt, PIN.hash, PIN.rounds = data.salt, data.hash, floor(data.rounds)
  return true
end

local function savePin(pin)
  local salt = randomSalt(16)
  local rounds = CFG.pin.rounds
  local data = { v = 2, salt = salt, rounds = rounds, hash = hashPin(pin, salt, rounds) }
  if not writeFile(CFG.system.pinFile, textutils.serialize(data)) then return false end
  PIN.salt, PIN.hash, PIN.rounds = data.salt, data.hash, data.rounds
  return true
end

local function pinMatches(pin)
  if not PIN.hash then return false end
  return hashPin(pin, PIN.salt, PIN.rounds) == PIN.hash
end

local function newSystem()
  return {
    running = true,
    hasPerms = false,
    locked = true,
    pinBuf = "",
    pinMsg = "",
    pinMsgKind = "info",
    pinMsgUntil = 0,
    failCount = 0,
    lockUntil = 0,
    view = "roster",
    rosterPage = 0,
    gridPage = 0,
    status = "",
    statusKind = "info",
    statusUntil = 0,
    players = {},
    online = {},
    watch = {},
    focus = nil,
    tasks = {},
    taskCount = 0,
    listBusy = false,
    timers = {},
    dirty = true,
    lastDraw = 0,
    lastActivity = 0,
    listSeen = false,
    log = {},
    prompt = nil,
    lastError = nil,
    errStamps = {},
    throttleNote = 0,
    saveWarned = false
  }
end

local SYS = newSystem()
local DISPLAYS = { list = {}, byName = {}, mode = "terminal" }

local function markDirty() SYS.dirty = true end

local function setStatus(msg, kind, ms)
  SYS.status = msg or ""
  SYS.statusKind = kind or "info"
  if msg and msg ~= "" then
    SYS.statusUntil = nowMs() + (ms or 6000)
  else
    SYS.statusUntil = 0
  end
  markDirty()
end

local function setPinMsg(msg, kind, ms)
  SYS.pinMsg = msg or ""
  SYS.pinMsgKind = kind or "info"
  SYS.pinMsgUntil = nowMs() + (ms or 1500)
  markDirty()
end

local function noteError(err)
  local now = nowMs()
  SYS.lastError = tostring(err)
  local stamps = SYS.errStamps
  stamps[#stamps + 1] = now
  while #stamps > 0 and now - stamps[1] > 10000 do remove(stamps, 1) end
  writeCrashLog("event error: " .. SYS.lastError)
  if #stamps > 15 then error(SYS.lastError, 0) end
end

local function newPlayer(name)
  return {
    name = name,
    online = false,
    session = 0,
    health = nil,
    pos = nil,
    dim = nil,
    vehPos = nil,
    useVeh = false,
    lastSeen = 0,
    lastData = 0,
    lastVehData = 0,
    failStreak = 0,
    nextPoll = 0,
    nextDim = 0,
    sample = nil,
    sampleAt = 0,
    vehFail = 0,
    vehNext = 0
  }
end

local function ensurePlayer(name)
  local p = SYS.players[name]
  if not p then
    p = newPlayer(name)
    SYS.players[name] = p
  end
  return p
end

local function logEvent(kind, text)
  insert(SYS.log, { time = clockText(), kind = kind, text = text })
  while #SYS.log > CFG.log.max do remove(SYS.log, 1) end
  markDirty()
end

local function numOrNil(v)
  if type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge then return v end
  return nil
end

local function vecOrNil(v)
  if type(v) ~= "table" then return nil end
  local x, y, z = numOrNil(v.x), numOrNil(v.y), numOrNil(v.z)
  if x and y and z then return { x = x, y = y, z = z } end
  return nil
end

local function saveState()
  local data = { v = 12, focus = SYS.focus, watch = {}, players = {} }
  for name in pairs(SYS.watch) do
    data.watch[name] = true
    local p = SYS.players[name]
    if p then
      data.players[name] = {
        health = p.health,
        pos = p.pos,
        dim = p.dim,
        vehPos = p.vehPos,
        useVeh = p.useVeh,
        lastData = p.lastData,
        lastVehData = p.lastVehData,
        session = p.session
      }
    end
  end
  local ok, text = pcall(textutils.serialize, data)
  if ok and writeFile(CFG.system.stateFile, text) then
    SYS.saveWarned = false
    return true
  end
  if not SYS.saveWarned then
    SYS.saveWarned = true
    setStatus("Could not save state to disk.", "warn", 10000)
  end
  return false
end

local function loadState()
  local raw = readFile(CFG.system.stateFile) or readFile(CFG.system.legacyStateFile)
  if not raw then return end
  local ok, data = pcall(textutils.unserialize, raw)
  if not ok or type(data) ~= "table" then return end
  if type(data.watch) == "table" then
    for name, flag in pairs(data.watch) do
      if flag and validName(name) then
        SYS.watch[name] = true
        ensurePlayer(name)
      end
    end
  end
  if validName(data.focus) and SYS.watch[data.focus] then SYS.focus = data.focus end
  if type(data.players) == "table" then
    for name, pd in pairs(data.players) do
      if SYS.watch[name] and type(pd) == "table" then
        local p = ensurePlayer(name)
        p.health = numOrNil(pd.health)
        p.pos = vecOrNil(pd.pos)
        p.vehPos = vecOrNil(pd.vehPos)
        p.useVeh = pd.useVeh == true and p.vehPos ~= nil
        if type(pd.dim) == "string" then p.dim = fit(pd.dim, 64) end
        p.lastData = numOrNil(pd.lastData) or 0
        p.lastVehData = numOrNil(pd.lastVehData) or 0
        p.session = floor(numOrNil(pd.session) or 0)
      end
    end
  end
end

local function submit(cmd, kind, meta)
  if not SYS.hasPerms then return false end
  if kind == "list" and SYS.listBusy then return false end
  if SYS.taskCount >= CFG.system.maxTasks then
    local now = nowMs()
    if now - SYS.throttleNote > 5000 then
      SYS.throttleNote = now
      setStatus("Command queue is full. Polls are slowing down.", "warn")
    end
    return false
  end
  local ok, id = pcall(commands.execAsync, cmd)
  if not ok or type(id) ~= "number" then
    local now = nowMs()
    if now - SYS.throttleNote > 5000 then
      SYS.throttleNote = now
      setStatus("Command failed: " .. fit(tostring(id), 60), "err")
    end
    return false
  end
  SYS.tasks[id] = { kind = kind, meta = meta, t = nowMs() }
  SYS.taskCount = SYS.taskCount + 1
  if kind == "list" then SYS.listBusy = true end
  return true
end

local function dropTask(id)
  local task = SYS.tasks[id]
  if not task then return nil end
  SYS.tasks[id] = nil
  SYS.taskCount = SYS.taskCount - 1
  if task.kind == "list" then SYS.listBusy = false end
  return task
end

local function toNumber(tok)
  if type(tok) ~= "string" then return nil end
  tok = tok:gsub("%s+", "")
  tok = tok:gsub("[dDfFbBsSlL]$", "")
  local n = tonumber(tok)
  if n and n == n and n ~= math.huge and n ~= -math.huge then return n end
  return nil
end

local function stripFormat(s)
  s = s:gsub("\194?\167.", "")
  return s
end

local function parseList(text)
  text = stripFormat(text)
  local lower = text:lower()
  if not (lower:find("online", 1, true) or lower:find("player", 1, true)) then return nil end
  local found = {}
  local colon = text:find(":", 1, true)
  if not colon then return found end
  local body = text:sub(colon + 1)
  body = body:gsub("%b[]", " ")
  body = body:gsub("%b()", " ")
  for name, tail in body:gmatch("([%w_]+)(:?)") do
    if tail ~= ":" and validName(name) then found[name] = true end
  end
  return found
end

local function parsePosList(text)
  local inner = text:match("%[([^%]]*)%]")
  if not inner then return nil end
  local nums = {}
  for tok in inner:gmatch("[^,]+") do
    local n = toNumber(tok)
    if not n then return nil end
    nums[#nums + 1] = n
  end
  if #nums ~= 3 then return nil end
  return nums[1], nums[2], nums[3]
end

local function parseHealth(text)
  local payload = text:match("data:%s*(.*)$") or text
  local tok = payload:match("^%s*([%+%-]?%d[%d%.]*[eE]?[%+%-]?%d*)")
  local n = toNumber(tok)
  if n and n >= 0 and n < 100000 then return n end
  return nil
end

local function parseDimension(text)
  local dim = text:match('"([%w_%-%./]+:[%w_%-%./]+)"') or text:match('"([%w_%-%./]+)"')
  if dim then return fit(dim, 64) end
  return nil
end

local function dist2(a, b)
  local dx, dz = a.x - b.x, a.z - b.z
  return dx * dx + dz * dz
end

local function trackFreeze(p, now)
  local pos = p.pos
  if not pos then return end
  local s = p.sample
  if not s then
    p.sample = { x = pos.x, y = pos.y, z = pos.z }
    p.sampleAt = now
    return
  end
  if dist2(pos, s) > CFG.vehicle.moveEps2 then
    p.sample = { x = pos.x, y = pos.y, z = pos.z }
    p.sampleAt = now
    p.useVeh = false
    p.vehFail = 0
    p.vehNext = 0
  end
end

local function shouldProbeVehicle(p, now)
  if not p.online or not p.sample then return false end
  if now - p.sampleAt < CFG.vehicle.freezeMs then return false end
  return now >= p.vehNext
end

local function pollBase(p)
  if p.name == SYS.focus then return CFG.poll.focusMs end
  return CFG.poll.baseMs
end

local function applyList(text, now)
  local seen = parseList(text)
  if not seen then return end
  local first = not SYS.listSeen
  SYS.listSeen = true
  SYS.online = {}
  for name in pairs(seen) do
    SYS.online[name] = true
    local p = ensurePlayer(name)
    p.lastSeen = now
    if not p.online then
      p.online = true
      p.session = p.session + 1
      p.failStreak = 0
      p.sample = nil
      p.sampleAt = 0
      p.useVeh = false
      p.vehFail = 0
      p.vehNext = 0
      p.nextPoll = 0
      p.nextDim = 0
      if not first then logEvent("join", name .. " joined") end
    end
  end
  for name, p in pairs(SYS.players) do
    if p.online and not seen[name] then
      p.online = false
      p.useVeh = false
      if not first then logEvent("leave", name .. " left") end
    end
  end
  markDirty()
end

local function applyResult(kind, p, text, now)
  if kind == "health" then
    local hp = parseHealth(text)
    if not hp then return false end
    local prev = p.health
    p.health = hp
    p.lastData = now
    local low = CFG.alert.lowHealth
    if SYS.watch[p.name] and hp <= low and (prev == nil or prev > low) then
      if hp <= 0 then
        logEvent("err", p.name .. " is down")
      else
        logEvent("warn", p.name .. " low health " .. fmtHp(hp))
      end
    end
    markDirty()
    return true
  end
  if kind == "pos" then
    local x, y, z = parsePosList(text)
    if not x then return false end
    p.pos = { x = x, y = y, z = z }
    p.lastData = now
    trackFreeze(p, now)
    markDirty()
    return true
  end
  if kind == "dim" then
    local dim = parseDimension(text)
    if dim then
      p.dim = dim
      p.nextDim = now + CFG.poll.dimMs
      markDirty()
      return true
    end
    p.nextDim = now + 30000
    return false
  end
  if kind == "vehpos" then
    local x, y, z = parsePosList(text)
    if x then
      p.vehPos = { x = x, y = y, z = z }
      p.lastVehData = now
      p.vehFail = 0
      p.vehNext = now + CFG.vehicle.probeMs
      if p.sample then p.useVeh = dist2(p.vehPos, p.sample) > CFG.vehicle.vehEps2 end
      markDirty()
      return true
    end
    p.vehFail = p.vehFail + 1
    p.vehNext = now + min(CFG.vehicle.maxBackoffMs, CFG.vehicle.probeMs * 2 ^ p.vehFail)
    if p.vehFail >= 2 then p.useVeh = false end
    return false
  end
  return false
end

local function resolveTask(id, ok, text)
  local task = dropTask(id)
  if not task then return end
  local now = nowMs()
  if task.kind == "list" then
    if ok and text ~= "" then applyList(text, now) end
    return
  end
  local meta = task.meta
  local p = meta and SYS.players[meta.name]
  if not p or meta.session ~= p.session then return end
  local good = false
  if ok and text ~= "" then good = applyResult(task.kind, p, text, now) end
  if task.kind == "health" or task.kind == "pos" then
    if good then
      p.failStreak = 0
      local soon = now + pollBase(p)
      if p.nextPoll > soon then p.nextPoll = soon end
    else
      p.failStreak = p.failStreak + 1
    end
  end
end

local function gcTasks()
  local now = nowMs()
  for id, task in pairs(SYS.tasks) do
    if now - task.t > CFG.system.taskTimeout then
      dropTask(id)
      local meta = task.meta
      local p = meta and SYS.players[meta.name]
      if p and meta.session == p.session and (task.kind == "health" or task.kind == "pos") then
        p.failStreak = p.failStreak + 1
      end
    end
  end
end

local function normalizeOutput(out)
  local typ = type(out)
  local s = ""
  if typ == "string" then
    s = out
  elseif typ == "number" then
    s = tostring(out)
  elseif typ == "table" then
    local parts = {}
    for i = 1, #out do
      local v = out[i]
      if type(v) == "string" or type(v) == "number" then parts[#parts + 1] = tostring(v) end
    end
    s = concat(parts, " ")
  end
  if #s > 6000 then s = s:sub(1, 6000) end
  return s
end

local function onTaskComplete(e)
  local id, okTask = e[2], e[3]
  if not okTask then
    resolveTask(id, false, normalizeOutput(e[4]))
    return
  end
  local out = e[4]
  if type(out) == "boolean" then out = e[5] end
  resolveTask(id, true, normalizeOutput(out))
end

local function pollPlayer(p, now)
  if not validName(p.name) then return false end
  local interval = pollBase(p) * 2 ^ min(p.failStreak, CFG.poll.maxBackoff)
  local meta = { name = p.name, session = p.session }
  local prefix = "data get entity " .. p.name .. " "
  if not submit(prefix .. "Health", "health", meta) then return false end
  submit(prefix .. "Pos", "pos", meta)
  p.nextPoll = now + interval
  if now >= p.nextDim then
    p.nextDim = now + CFG.poll.dimMs
    submit(prefix .. "Dimension", "dim", meta)
  end
  if shouldProbeVehicle(p, now) then
    p.vehNext = now + CFG.vehicle.probeMs
    submit(prefix .. "RootVehicle.Entity.Pos", "vehpos", meta)
  end
  return true
end

local function pollWatched()
  local now = nowMs()
  local due = {}
  for name in pairs(SYS.watch) do
    local p = SYS.players[name]
    if p and p.online and now >= p.nextPoll then due[#due + 1] = p end
  end
  if #due == 0 then return end
  sort(due, function(a, b)
    local fa, fb = a.name == SYS.focus, b.name == SYS.focus
    if fa ~= fb then return fa end
    if a.nextPoll ~= b.nextPoll then return a.nextPoll < b.nextPoll end
    return a.name < b.name
  end)
  for i = 1, min(#due, CFG.system.pollPerTick) do
    if not pollPlayer(due[i], now) then break end
  end
end

local function lockNow(msg)
  SYS.locked = true
  SYS.pinBuf = ""
  SYS.pinMsg = ""
  SYS.pinMsgUntil = 0
  if type(msg) == "string" then setStatus(msg, "info") end
  saveState()
  markDirty()
end

local function unlock(msg)
  SYS.locked = false
  SYS.pinBuf = ""
  SYS.failCount = 0
  SYS.lockUntil = 0
  SYS.lastActivity = nowMs()
  setStatus(msg, "success")
  submit("list", "list", nil)
  markDirty()
end

local function toggleWatch(name)
  if SYS.watch[name] then
    SYS.watch[name] = nil
    if SYS.focus == name then SYS.focus = nil end
    local p = SYS.players[name]
    if p and not p.online then SYS.players[name] = nil end
    setStatus("Unwatched: " .. name, "warn")
  else
    SYS.watch[name] = true
    ensurePlayer(name)
    setStatus("Watching: " .. name, "success")
  end
  saveState()
  markDirty()
end

local function toggleFocus(name)
  if SYS.focus == name then
    SYS.focus = nil
    setStatus("Focus cleared", "info")
  else
    SYS.focus = name
    setStatus("Focus set: " .. name, "success")
  end
  saveState()
  markDirty()
end

local function pinDigit(c)
  if #SYS.pinBuf < CFG.pin.maxLen then SYS.pinBuf = SYS.pinBuf .. c end
  markDirty()
end

local function pinClear()
  SYS.pinBuf = ""
  markDirty()
end

local function pinBack()
  SYS.pinBuf = SYS.pinBuf:sub(1, -2)
  markDirty()
end

local function pinEnter()
  local now = nowMs()
  if now < SYS.lockUntil then return end
  if #SYS.pinBuf < CFG.pin.minLen then
    setPinMsg("TOO SHORT", "warn", 1200)
    return
  end
  local entered = SYS.pinBuf
  SYS.pinBuf = ""
  if pinMatches(entered) then
    unlock("Authorized.")
    return
  end
  SYS.failCount = SYS.failCount + 1
  if SYS.failCount % CFG.pin.freeAttempts == 0 then
    local step = floor(SYS.failCount / CFG.pin.freeAttempts) - 1
    local secs = min(CFG.pin.lockMaxSec, CFG.pin.lockBaseSec * 2 ^ step)
    SYS.lockUntil = now + secs * 1000
  end
  setPinMsg("DENIED", "err", 1400)
end

local PROMPT_TITLES = {
  setup = { "Set a new PIN", "Confirm the new PIN" },
  unlock = { "Enter the PIN to unlock" },
  change = { "Enter the current PIN", "Enter the new PIN", "Confirm the new PIN" }
}

local function startPrompt(kind)
  SYS.prompt = { kind = kind, stage = 1, buf = "", first = "", note = "" }
  markDirty()
end

local function promptSubmit()
  local pr = SYS.prompt
  local v = pr.buf
  pr.buf = ""
  pr.note = ""
  if #v < CFG.pin.minLen then
    pr.note = "A PIN needs " .. CFG.pin.minLen .. " to " .. CFG.pin.maxLen .. " digits."
    markDirty()
    return
  end
  if pr.kind == "unlock" then
    if pinMatches(v) then
      SYS.prompt = nil
      unlock("Admin override authorized.")
    else
      pr.note = "Wrong PIN."
    end
  elseif pr.kind == "setup" then
    if pr.stage == 1 then
      pr.first, pr.stage = v, 2
    elseif v == pr.first then
      if savePin(v) then
        SYS.prompt = nil
        setStatus("PIN saved. Enter it to unlock.", "success", 10000)
      else
        pr.stage, pr.first, pr.note = 1, "", "Could not write the PIN file."
      end
    else
      pr.stage, pr.first, pr.note = 1, "", "The PINs did not match. Start again."
    end
  elseif pr.kind == "change" then
    if pr.stage == 1 then
      if pinMatches(v) then pr.stage = 2 else pr.note = "Wrong PIN." end
    elseif pr.stage == 2 then
      pr.first, pr.stage = v, 3
    elseif v == pr.first then
      if savePin(v) then
        SYS.prompt = nil
        setStatus("PIN changed.", "success")
      else
        pr.stage, pr.first, pr.note = 2, "", "Could not write the PIN file."
      end
    else
      pr.stage, pr.first, pr.note = 2, "", "The PINs did not match."
    end
  end
  markDirty()
end

local function put(d, x, y, s, fg, bg)
  if y < 1 or y > d.h or x > d.w then return end
  if x < 1 then
    s = s:sub(2 - x)
    x = 1
  end
  local room = d.w - x + 1
  if #s > room then s = s:sub(1, room) end
  if s == "" then return end
  if bg then term.setBackgroundColor(bg) end
  if fg then term.setTextColor(fg) end
  term.setCursorPos(x, y)
  term.write(s)
end

local function fill(d, x, y, w, h, bg)
  if w <= 0 or h <= 0 then return end
  local x1, y1 = max(1, x), max(1, y)
  local x2, y2 = min(d.w, x + w - 1), min(d.h, y + h - 1)
  if x2 < x1 or y2 < y1 then return end
  term.setBackgroundColor(bg)
  local line = rep(" ", x2 - x1 + 1)
  for yy = y1, y2 do
    term.setCursorPos(x1, yy)
    term.write(line)
  end
end

local function box(d, x, y, w, h, edge, inner)
  fill(d, x, y, w, h, edge)
  if w >= 3 and h >= 3 then fill(d, x + 1, y + 1, w - 2, h - 2, inner) end
end

local function hit(d, x1, y1, x2, y2, fn)
  d.hits[#d.hits + 1] = { x1 = x1, y1 = y1, x2 = x2, y2 = y2, fn = fn }
end

local function runHit(d, x, y)
  local hits = d.hits
  for i = #hits, 1, -1 do
    local hb = hits[i]
    if x >= hb.x1 and x <= hb.x2 and y >= hb.y1 and y <= hb.y2 then
      hb.fn()
      return true
    end
  end
  return false
end

local function button(d, x, y, w, h, label, kind, fn)
  local T = d.theme
  local edge, text = T.btnEdge, T.btnText
  if kind == "active" then
    edge, text = T.btnActive, T.btnActive
  elseif kind == "off" then
    edge, text = T.btnOff, T.btnOff
  elseif kind == "warn" then
    edge, text = T.warn, T.warn
  end
  local base = T.btnFill
  if h >= 3 then
    box(d, x, y, w, h, edge, base)
  else
    base = T.keyFill
    fill(d, x, y, w, h, base)
    if kind ~= "off" then text = T.text end
  end
  label = fit(label, max(0, w - 2))
  put(d, x + floor((w - #label) / 2), y + floor((h - 1) / 2), label, text, base)
  if fn and kind ~= "off" then hit(d, x, y, x + w - 1, y + h - 1, fn) end
end

local function header(d, titles, buttons)
  local T = d.theme
  fill(d, 1, 1, d.w, 3, T.header)
  local x = d.w + 1
  if buttons then
    for i = #buttons, 1, -1 do
      local b = buttons[i]
      local bw = #b[1] + 4
      if x - bw - 1 < 1 then break end
      x = x - bw - 1
      button(d, x, 1, bw, 3, b[1], b[2], b[3])
    end
  end
  local room = max(0, x - 3)
  local title
  for _, t in ipairs(titles) do
    if #t <= room then
      title = t
      break
    end
  end
  put(d, 2, 2, title or fit(titles[#titles], room), T.headerText, T.header)
end

local function headerButtons()
  local list = {}
  if DISPLAYS.mode ~= "dual" then
    list[#list + 1] = { "ROSTER", SYS.view == "roster" and "active" or "normal", function() SYS.view = "roster"; markDirty() end }
    list[#list + 1] = { "GRID", SYS.view == "grid" and "active" or "normal", function() SYS.view = "grid"; markDirty() end }
  end
  list[#list + 1] = { "LOCK", "warn", function() lockNow("Locked.") end }
  return list
end

local function ageOf(p, now)
  if not p.lastData or p.lastData <= 0 then return nil end
  return max(0, now - p.lastData)
end

local function fmtAge(ms)
  if not ms then return "n/a" end
  local s = floor(ms / 1000)
  if s < 60 then return s .. "s" end
  local m = floor(s / 60)
  if m < 60 then return m .. "m" end
  return floor(m / 60) .. "h"
end

local function staleBadge(p, T, now)
  if not p.online then return "OFF", T.ghost end
  local age = ageOf(p, now)
  if not age then return "WAIT", T.dim end
  if age >= CFG.stale.hardStaleMs then return "HARD", T.err end
  if age >= CFG.stale.staleMs then return "STALE", T.warn end
  return "FRESH", T.good
end

local DIMS = {
  ["minecraft:overworld"] = "OVERWORLD",
  ["minecraft:the_nether"] = "NETHER",
  ["minecraft:the_end"] = "END"
}

local function dimLabel(dim)
  if not dim then return "n/a" end
  if DIMS[dim] then return DIMS[dim] end
  local short = (dim:match(":(.+)$") or dim):gsub("[^%w]+", " ")
  return short:upper()
end

local function hpColor(T, hp)
  if not hp then return T.dim end
  if hp >= 14 then return T.hpGood end
  if hp > CFG.alert.lowHealth then return T.hpMid end
  return T.hpLow
end

local function posText(p)
  local pos = p.useVeh and p.vehPos or p.pos
  if not pos then return "n/a" end
  return ival(pos.x) .. ", " .. ival(pos.y) .. ", " .. ival(pos.z)
end

local function sortedWatch()
  local names = {}
  for name in pairs(SYS.watch) do names[#names + 1] = name end
  sort(names, function(a, b)
    local fa, fb = a == SYS.focus, b == SYS.focus
    if fa ~= fb then return fa end
    local la, lb = a:lower(), b:lower()
    if la ~= lb then return la < lb end
    return a < b
  end)
  return names
end

local function rosterNames()
  local names = {}
  for name, p in pairs(SYS.players) do
    if p.online or SYS.watch[name] then names[#names + 1] = name end
  end
  sort(names, function(a, b)
    local pa, pb = SYS.players[a], SYS.players[b]
    if pa.online ~= pb.online then return pa.online end
    local la, lb = a:lower(), b:lower()
    if la ~= lb then return la < lb end
    return a < b
  end)
  return names
end

local function drawStatus(d)
  local T = d.theme
  local now = nowMs()
  local s, col = "", T.dim
  if SYS.status ~= "" and now < SYS.statusUntil then
    s = SYS.status
    local k = SYS.statusKind
    if k == "warn" then
      col = T.warn
    elseif k == "err" then
      col = T.err
    elseif k == "success" then
      col = T.accent
    else
      col = T.text
    end
  elseif not SYS.hasPerms then
    s, col = "NO COMMAND API: use a Command Computer", T.err
  else
    s = "CMD " .. SYS.taskCount .. "/" .. CFG.system.maxTasks
  end
  put(d, 2, d.h - 3, fit(s, d.w - 2), col, T.bg)
end

local function drawPager(d, page, pages, setPage)
  local T = d.theme
  local y = d.h - 2
  button(d, 2, y, 5, 3, "<", page > 0 and "normal" or "off", function() setPage(page - 1) end)
  button(d, 8, y, 5, 3, ">", page < pages - 1 and "normal" or "off", function() setPage(page + 1) end)
  local txt = "PAGE " .. (page + 1) .. "/" .. pages
  put(d, d.w - #txt - 1, y + 1, txt, T.dim, T.bg)
end

local function drawLock(d)
  local T = d.theme
  local w, h = d.w, d.h
  local now = nowMs()
  fill(d, 1, 1, w, h, T.bg)
  header(d, { " VANGUARD ACCESS  " .. VERSION, " VANGUARD ACCESS", " ACCESS" }, nil)

  local function center(row, s, fg)
    put(d, floor((w - #s) / 2) + 1, row, s, fg, T.bg)
  end

  if not PIN.hash then
    center(5, "SETUP REQUIRED", T.warn)
    center(7, "Open the computer terminal", T.text)
    center(8, "and set a PIN to begin.", T.text)
    if not SYS.hasPerms then center(h - 2, "NO COMMAND API: USE A COMMAND COMPUTER", T.err) end
    return
  end

  center(5, "ENTER PASSCODE", T.accent)
  local slots = {}
  for i = 1, CFG.pin.maxLen do slots[i] = (i <= #SYS.pinBuf) and "*" or "_" end
  center(7, concat(slots, " "), T.text)

  local lockedOut = now < SYS.lockUntil
  if lockedOut then
    center(9, "LOCKED OUT " .. ceil((SYS.lockUntil - now) / 1000) .. "s", T.err)
  elseif SYS.pinMsg ~= "" and now <= SYS.pinMsgUntil then
    local col = T.text
    if SYS.pinMsgKind == "err" then
      col = T.err
    elseif SYS.pinMsgKind == "warn" then
      col = T.warn
    elseif SYS.pinMsgKind == "success" then
      col = T.accent
    end
    center(9, SYS.pinMsg, col)
  end

  local top = 11
  local avail = h - top - 1
  local padH, gapY = 3, 1
  if avail < 19 then padH, gapY = 2, 0 end
  if avail < 10 then padH, gapY = 1, 0 end
  local gapX = (w >= 40) and 2 or 1
  local padW = clamp(floor((w - 2 - 2 * gapX) / 3), 5, 11)
  local gridW = padW * 3 + gapX * 2
  local gx = floor((w - gridW) / 2) + 1
  local kind = lockedOut and "off" or "normal"

  local labels = { "1", "2", "3", "4", "5", "6", "7", "8", "9", "CLR", "0", "BK" }
  for i, label in ipairs(labels) do
    local r = floor((i - 1) / 3)
    local c = (i - 1) % 3
    local fn
    if label == "CLR" then
      fn = pinClear
    elseif label == "BK" then
      fn = pinBack
    else
      fn = function() pinDigit(label) end
    end
    button(d, gx + c * (padW + gapX), top + r * (padH + gapY), padW, padH, label, kind, fn)
  end
  button(d, gx, top + 4 * (padH + gapY), gridW, padH, "ENTER", lockedOut and "off" or "active", pinEnter)

  put(d, 2, h, fit("Admin override: press U on the computer terminal", w - 2), T.dim, T.bg)
  if not SYS.hasPerms then center(h - 1, "NO COMMAND API: USE A COMMAND COMPUTER", T.err) end
end

local function drawLog(d, top, rows)
  local T = d.theme
  put(d, 2, top, "EVENTS", T.accent, T.bg)
  local n = #SYS.log
  for i = 1, rows - 1 do
    local e = SYS.log[n - i + 1]
    if not e then break end
    local col = T.dim
    if e.kind == "join" then
      col = T.good
    elseif e.kind == "warn" then
      col = T.warn
    elseif e.kind == "err" then
      col = T.err
    end
    put(d, 2, top + i, fit(e.time .. "  " .. e.text, d.w - 2), col, T.bg)
  end
end

local function drawRoster(d)
  local T = d.theme
  local w, h = d.w, d.h
  fill(d, 1, 1, w, h, T.bg)
  local on, wa = count(SYS.online), count(SYS.watch)
  header(d, {
    string.format(" VANGUARD %s  ONLINE %d  WATCH %d", VERSION, on, wa),
    string.format(" ONLINE %d  WATCH %d", on, wa),
    string.format(" ON %d  WA %d", on, wa),
    " VANGUARD"
  }, headerButtons())
  put(d, 2, 5, "ONLINE PLAYERS  (tap a name to watch or unwatch)", T.accent, T.bg)

  local names = rosterNames()
  local rowH = (h >= 30) and 2 or 1
  local logH = (h >= 38) and 11 or 0
  local logTop = h - 4 - logH + 1
  local listTop = 7
  local listBottom = (logH > 0) and (logTop - 2) or (h - 5)
  local perPage = max(1, floor((listBottom - listTop + 1) / rowH))
  local pages = max(1, ceil(#names / perPage))
  SYS.rosterPage = clamp(SYS.rosterPage, 0, pages - 1)
  local first = SYS.rosterPage * perPage + 1
  local last = min(#names, first + perPage - 1)

  local y = listTop
  for i = first, last do
    local name = names[i]
    local p = SYS.players[name]
    local watched = SYS.watch[name] == true
    local col = watched and T.accent or T.text
    if not p.online then col = T.ghost end
    local line = (watched and "[+] " or "[ ] ") .. pad(name, 16)
    if w >= 46 then
      local hp = p.health and fmtHp(p.health) or "?"
      line = line .. "  HP " .. padLeft(hp, 4) .. "  " .. pad(p.online and dimLabel(p.dim) or "OFFLINE", 10)
      if p.useVeh then line = line .. " VEH" end
    end
    put(d, 2, y, fit(line, w - 2), col, T.bg)
    hit(d, 1, y, w, y + rowH - 1, function() toggleWatch(name) end)
    y = y + rowH
  end
  if #names == 0 then put(d, 3, listTop, "No players online.", T.dim, T.bg) end

  if logH > 0 then drawLog(d, logTop, logH) end
  drawStatus(d)
  drawPager(d, SYS.rosterPage, pages, function(n) SYS.rosterPage = n; markDirty() end)
end

local function drawCard(d, p, x, y, cw, ch, now)
  local T = d.theme
  local focused = SYS.focus == p.name
  local edge = focused and T.cardEdgeFocus or (p.online and T.cardEdgeOn or T.cardEdgeOff)
  local fillc = p.online and T.cardFillOn or T.cardFillOff
  box(d, x, y, cw, ch, edge, fillc)
  local ix, iw = x + 2, cw - 4

  local badge, chip = staleBadge(p, T, now)
  local label = " " .. badge .. " "
  put(d, ix, y + 1, fit(p.name, max(1, iw - #label - 2)), T.text, fillc)
  put(d, x + cw - 2 - #label, y + 1, label, T.chipText, chip)

  local hp = p.health
  put(d, ix, y + 2, "HP " .. pad(hp and fmtHp(hp) or "n/a", 5), T.text, fillc)
  local bw = min(12, iw - 9)
  if bw >= 4 then
    local filled = 0
    if hp and hp > 0 then filled = clamp(ceil(hp / 20 * bw), 1, bw) end
    if filled > 0 then fill(d, ix + 9, y + 2, filled, 1, hpColor(T, hp)) end
    if filled < bw then fill(d, ix + 9 + filled, y + 2, bw - filled, 1, T.barOff) end
  end

  put(d, ix, y + 3, fit("POS " .. posText(p), iw), T.text, fillc)

  local src = p.useVeh and "VEHICLE" or "PLAYER"
  put(d, ix, y + 4, fit("DIM " .. dimLabel(p.dim), iw - #src - 1), T.text, fillc)
  put(d, ix + iw - #src, y + 4, src, p.useVeh and T.cardEdgeFocus or T.dim, fillc)

  local age = ageOf(p, now)
  put(d, ix, y + 5, "AGE " .. fmtAge(age), (age and age > CFG.stale.staleMs) and T.warn or T.text, fillc)
  if p.online and hp and hp <= CFG.alert.lowHealth then
    local msg = (hp <= 0) and " DOWN " or " LOW HP "
    put(d, ix + iw - #msg, y + 5, msg, T.text, T.err)
  end

  local name = p.name
  button(d, ix, y + 6, 9, 3, "FOCUS", focused and "active" or "normal", function() toggleFocus(name) end)
  button(d, ix + 10, y + 6, 11, 3, "UNWATCH", "normal", function() toggleWatch(name) end)
end

local function drawGrid(d)
  local T = d.theme
  local w, h = d.w, d.h
  local now = nowMs()
  fill(d, 1, 1, w, h, T.bg)
  local on, wa = count(SYS.online), count(SYS.watch)
  header(d, {
    string.format(" WATCH GRID  %s  ONLINE %d  WATCH %d", VERSION, on, wa),
    string.format(" GRID  ONLINE %d  WATCH %d", on, wa),
    string.format(" ON %d  WA %d", on, wa),
    " GRID"
  }, headerButtons())

  local names = sortedWatch()
  local cardH = 10
  local cols = max(1, floor((w - 2) / 29))
  local cardW = clamp(floor((w - 2 - (cols - 1)) / cols), 20, 44)
  local top = 5
  local bottom = h - 5
  local rows = max(1, floor((bottom - top + 2) / (cardH + 1)))
  local capacity = cols * rows
  local pages = max(1, ceil(#names / capacity))
  SYS.gridPage = clamp(SYS.gridPage, 0, pages - 1)
  local first = SYS.gridPage * capacity + 1
  local last = min(#names, first + capacity - 1)

  local slot = 0
  for i = first, last do
    local p = ensurePlayer(names[i])
    local r = floor(slot / cols)
    local c = slot % cols
    drawCard(d, p, 2 + c * (cardW + 1), top + r * (cardH + 1), cardW, cardH, now)
    slot = slot + 1
  end
  if #names == 0 then
    put(d, 3, top, "No players are being watched.", T.dim, T.bg)
    local hint = (DISPLAYS.mode == "dual") and "Tap a name on the roster monitor." or "Open the ROSTER tab and tap a name."
    put(d, 3, top + 1, hint, T.dim, T.bg)
  end

  drawStatus(d)
  drawPager(d, SYS.gridPage, pages, function(n) SYS.gridPage = n; markDirty() end)
end

local function drawConsole(d)
  local T = d.theme
  local w, h = d.w, d.h
  fill(d, 1, 1, w, h, T.bg)
  fill(d, 1, 1, w, 1, T.header)
  put(d, 2, 1, fit("VANGUARD OS " .. VERSION, w - 2), T.headerText, T.header)

  local function row(y, label, value, col)
    put(d, 1, y, pad(label, 9), T.dim, T.bg)
    put(d, 10, y, fit(value, w - 9), col or T.text, T.bg)
  end

  local state = "UNLOCKED"
  local scol = T.good
  if not PIN.hash then
    state, scol = "SETUP REQUIRED", T.warn
  elseif SYS.locked then
    state, scol = "LOCKED", T.warn
  end
  row(3, "STATE", state, scol)
  row(4, "PLAYERS", "online " .. count(SYS.online) .. "  watching " .. count(SYS.watch))
  local names = {}
  for _, dd in ipairs(DISPLAYS.list) do
    if not dd.native then names[#names + 1] = dd.name end
  end
  row(5, "DISPLAY", DISPLAYS.mode .. (#names > 0 and (": " .. concat(names, " ")) or ""))
  if SYS.hasPerms then
    row(6, "COMMANDS", SYS.taskCount .. "/" .. CFG.system.maxTasks .. " pending")
  else
    row(6, "COMMANDS", "no command API", T.err)
  end
  if SYS.status ~= "" and nowMs() < SYS.statusUntil then row(7, "STATUS", SYS.status, T.text) end
  if SYS.lastError then row(8, "ERROR", SYS.lastError:gsub("%s+", " "), T.err) end

  local keysHelp = "Ctrl+T quit"
  if not PIN.hash then
    keysHelp = "Set a PIN to begin.  " .. keysHelp
  elseif SYS.locked then
    keysHelp = "U unlock  " .. keysHelp
  else
    keysHelp = "P change PIN  L lock  " .. keysHelp
  end
  put(d, 1, h, fit(keysHelp, w), T.dim, T.bg)
end

local function drawPrompt(d)
  local T = d.theme
  local pr = SYS.prompt
  fill(d, 1, 1, d.w, d.h, T.bg)
  fill(d, 1, 1, d.w, 1, T.header)
  put(d, 2, 1, fit("VANGUARD OS " .. VERSION .. "  ADMIN", d.w - 2), T.headerText, T.header)
  put(d, 2, 3, fit(PROMPT_TITLES[pr.kind][pr.stage], d.w - 2), T.text, T.bg)
  put(d, 2, 4, fit("Digits only, " .. CFG.pin.minLen .. " to " .. CFG.pin.maxLen .. " long.", d.w - 2), T.dim, T.bg)
  put(d, 2, 6, fit("PIN: " .. rep("*", #pr.buf), d.w - 2), T.accent, T.bg)
  if pr.note ~= "" then put(d, 2, 8, fit(pr.note, d.w - 2), T.warn, T.bg) end
  local help = (pr.kind == "setup") and "Enter = continue" or "Enter = continue   Esc = cancel"
  put(d, 2, 10, fit(help, d.w - 2), T.dim, T.bg)
end

local function drawDisplay(d)
  d.hits = {}
  if d.w < 16 or d.h < 8 then
    fill(d, 1, 1, d.w, d.h, d.theme.bg)
    put(d, 1, 1, fit("Monitor too small", d.w), d.theme.warn, d.theme.bg)
    return
  end
  if d.native and SYS.prompt then
    drawPrompt(d)
  elseif d.role == "console" then
    drawConsole(d)
  elseif SYS.locked then
    drawLock(d)
  elseif d.role == "roster" then
    drawRoster(d)
  elseif d.role == "grid" then
    drawGrid(d)
  elseif SYS.view == "grid" then
    drawGrid(d)
  else
    drawRoster(d)
  end
end

local function render()
  for _, d in ipairs(DISPLAYS.list) do
    local prev = term.redirect(d.win)
    local ok, err = pcall(drawDisplay, d)
    term.redirect(prev)
    pcall(d.win.setVisible, true)
    pcall(d.win.setVisible, false)
    if not ok then noteError("draw " .. d.name .. ": " .. tostring(err)) end
  end
  SYS.dirty = false
  SYS.lastDraw = nowMs()
end

local function makeDisplay(name, dev, native, role)
  local d = { name = name, dev = dev, native = native, role = role, hits = {} }
  local okc, color = pcall(dev.isColor)
  d.color = okc and color == true
  d.theme = d.color and CFG.theme or GRAY
  if not native then
    local oks, cur = pcall(dev.getTextScale)
    if not oks or cur ~= CFG.system.textScale then pcall(dev.setTextScale, CFG.system.textScale) end
  end
  d.w, d.h = dev.getSize()
  d.win = window.create(dev, 1, 1, d.w, d.h, false)
  d.win.setCursorBlink(false)
  return d
end

local function scanDisplays()
  local names = {}
  for _, n in ipairs(peripheral.getNames()) do
    local ok, t = pcall(peripheral.getType, n)
    if ok and t == "monitor" then names[#names + 1] = n end
  end
  sort(names)
  local mons = {}
  for _, n in ipairs(names) do
    if #mons < 2 then
      local okw, dev = pcall(peripheral.wrap, n)
      if okw and dev then
        local okd, d = pcall(makeDisplay, n, dev, false, "single")
        if okd and d then mons[#mons + 1] = d end
      end
    end
  end
  local mode = "terminal"
  if #mons >= 2 then
    mons[1].role, mons[2].role = "roster", "grid"
    mode = "dual"
  elseif #mons == 1 then
    mode = "single"
  end
  local list, by = {}, {}
  for _, d in ipairs(mons) do
    list[#list + 1] = d
    by[d.name] = d
  end
  pcall(nativeTerm.setCursorBlink, false)
  local nd = makeDisplay("@native", nativeTerm, true, (#mons == 0) and "single" or "console")
  list[#list + 1] = nd
  by["@native"] = nd
  DISPLAYS.list, DISPLAYS.byName, DISPLAYS.mode = list, by, mode
  markDirty()
end

local function touch() SYS.lastActivity = nowMs() end

local function onTouch(side, x, y)
  local d = DISPLAYS.byName[side]
  if not d or d.native or type(x) ~= "number" or type(y) ~= "number" then return end
  touch()
  runHit(d, x, y)
end

local function onMouse(x, y)
  local d = DISPLAYS.byName["@native"]
  if not d or d.role ~= "single" or type(x) ~= "number" or type(y) ~= "number" then return end
  touch()
  runHit(d, x, y)
end

local function onKey(k)
  touch()
  local pr = SYS.prompt
  if pr then
    if k == keys.backspace then
      pr.buf = pr.buf:sub(1, -2)
    elseif k == keys.enter or k == keys.numPadEnter then
      promptSubmit()
    elseif k == keys.escape and pr.kind ~= "setup" then
      SYS.prompt = nil
    end
    markDirty()
    return
  end
  if SYS.locked then
    if k == keys.u then startPrompt(PIN.hash and "unlock" or "setup") end
  elseif k == keys.p then
    startPrompt("change")
  elseif k == keys.l then
    lockNow("Locked.")
  end
end

local function onChar(c)
  local pr = SYS.prompt
  if not pr or type(c) ~= "string" or not c:match("^%d$") then return end
  touch()
  if #pr.buf < CFG.pin.maxLen then pr.buf = pr.buf .. c end
  markDirty()
end

local function arm(name, secs)
  SYS.timers[os.startTimer(secs)] = name
end

local TIMERS = {}

TIMERS.frame = function()
  local now = nowMs()
  if SYS.pinMsg ~= "" and now > SYS.pinMsgUntil then
    SYS.pinMsg = ""
    markDirty()
  end
  if SYS.statusUntil > 0 and now > SYS.statusUntil then
    SYS.status = ""
    SYS.statusUntil = 0
    markDirty()
  end
  local idle = CFG.system.autoLockSec
  if not SYS.locked and not SYS.prompt and idle > 0 and now - SYS.lastActivity > idle * 1000 then
    lockNow("Auto-locked after inactivity.")
  end
  if now - SYS.lastDraw >= 1000 then markDirty() end
  if SYS.dirty then render() end
  arm("frame", CFG.system.refreshRate)
end

TIMERS.list = function()
  submit("list", "list", nil)
  arm("list", CFG.system.listRate)
end

TIMERS.poll = function()
  if not SYS.locked then pollWatched() end
  arm("poll", CFG.system.pollRate)
end

TIMERS.gc = function()
  gcTasks()
  arm("gc", CFG.system.gcRate)
end

TIMERS.save = function()
  if next(SYS.watch) ~= nil then saveState() end
  arm("save", CFG.system.saveRate)
end

local function handleEvent(e)
  local ev = e[1]
  if ev == "timer" then
    local name = SYS.timers[e[2]]
    if name then
      SYS.timers[e[2]] = nil
      TIMERS[name]()
    end
  elseif ev == "task_complete" then
    onTaskComplete(e)
  elseif ev == "monitor_touch" then
    onTouch(e[2], e[3], e[4])
  elseif ev == "mouse_click" then
    onMouse(e[3], e[4])
  elseif ev == "key" then
    onKey(e[2])
  elseif ev == "char" then
    onChar(e[2])
  elseif ev == "monitor_resize" or ev == "term_resize" or ev == "peripheral" or ev == "peripheral_detach" then
    scanDisplays()
  elseif ev == "terminate" then
    SYS.running = false
  end
  if SYS.dirty and (ev == "key" or ev == "char" or ev == "monitor_touch" or ev == "mouse_click") then render() end
end

local function shutdown()
  saveState()
  for _, d in ipairs(DISPLAYS.list) do
    if not d.native then
      pcall(function()
        d.dev.setBackgroundColor(colors.black)
        d.dev.setTextColor(colors.white)
        d.dev.clear()
        d.dev.setCursorPos(1, 1)
        d.dev.write("Vanguard OS stopped")
      end)
    end
  end
  pcall(function()
    term.redirect(nativeTerm)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
    term.setCursorBlink(true)
  end)
end

local function entry()
  SYS = newSystem()
  math.randomseed(nowMs() % 2147483647 + floor(os.clock() * 1000))
  SYS.hasPerms = type(commands) == "table" and type(commands.execAsync) == "function"
  loadPin()
  loadState()
  scanDisplays()
  if SYS.hasPerms then
    setStatus("Locked. Enter the PIN.", "warn", 8000)
  else
    setStatus("No Command API. Use a Command Computer.", "err", 3600000)
  end
  if not PIN.hash then startPrompt("setup") end
  SYS.lastActivity = nowMs()
  arm("frame", CFG.system.refreshRate)
  arm("list", CFG.system.listRate)
  arm("poll", CFG.system.pollRate)
  arm("gc", CFG.system.gcRate)
  arm("save", CFG.system.saveRate)
  submit("list", "list", nil)
  render()
  while SYS.running do
    local e = { os.pullEventRaw() }
    local ok, err = pcall(handleEvent, e)
    if not ok then noteError(err) end
  end
  shutdown()
end

local traceback = (debug and debug.traceback) or function(m) return m end

local function showScreen(lines, bg)
  pcall(function()
    term.redirect(nativeTerm)
    term.setBackgroundColor(bg)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorBlink(false)
    local w = nativeTerm.getSize()
    for i, line in ipairs(lines) do
      term.setCursorPos(1, i)
      term.write(fit(line, w))
    end
  end)
end

local function supervise()
  local stamps = {}
  while true do
    local ok, err = xpcall(entry, traceback)
    if ok then return end
    writeCrashLog(err)
    local now = nowMs()
    local kept = {}
    for _, t in ipairs(stamps) do
      if now - t < CFG.crash.windowSec * 1000 then kept[#kept + 1] = t end
    end
    kept[#kept + 1] = now
    stamps = kept
    local lines = { "VANGUARD OS " .. VERSION .. " ERROR", "" }
    for line in tostring(err):gmatch("[^\n]+") do
      if #lines < 15 then lines[#lines + 1] = line end
    end
    if #stamps > CFG.crash.maxRestarts then
      lines[#lines + 1] = ""
      lines[#lines + 1] = "Too many crashes. Details: " .. CFG.system.crashFile
      lines[#lines + 1] = "Press R to reboot."
      showScreen(lines, colors.blue)
      while true do
        local ev, k = os.pullEventRaw("key")
        if ev == "terminate" then return end
        if k == keys.r then os.reboot() end
      end
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Restarting in " .. CFG.crash.delaySec .. "s. Ctrl+T quits."
    showScreen(lines, colors.blue)
    sleep(CFG.crash.delaySec)
  end
end

supervise()
