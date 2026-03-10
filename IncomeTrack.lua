script_name("Income Tracker Pro V4")
script_author("Faisal Hazary")

require "lib.moonloader"
local imgui    = require "mimgui"
local new      = imgui.new
local encoding = require 'encoding'
local samp     = require 'lib.samp.events'
local json     = require 'dkjson'
local lfs      = require 'lfs'
encoding.default = 'CP1251'
u8 = encoding.UTF8

-- ============================================================
--  PATHS
-- ============================================================
local DOC_PATH = os.getenv("USERPROFILE") .. "\\Documents\\IncomeTrackerPro\\"
local FILES = {
    config  = DOC_PATH .. "config.json",
    data    = DOC_PATH .. "data.json",
    goals   = DOC_PATH .. "goals.json",
    history = DOC_PATH .. "history.json"
}

-- ============================================================
--  DATA DEFAULTS
-- ============================================================
local cfg = {
    showHUD   = true,
    fontSize  = 16,
    posX      = 10,
    posY      = 10,       -- safe top-left default
    fontFlags = 5,
    showBg    = true,
}

-- stats saved to disk — intervals grow permanently across sessions
local stats = {
    total_earned     = 0,
    total_jobs       = 0,
    fastest_interval = 999999,
    all_avg_interval = 0,       -- running average saved to disk
    interval_count   = 0,       -- how many intervals recorded ever
    intervals        = {},      -- last 500 raw intervals (for recalculation)
}

local activeGoal = {
    active          = false,
    target          = 0,
    earned_at_start = 0,
    start_time      = 0,
}
local history = {}

-- ============================================================
--  RUNTIME (not saved)
-- ============================================================
local sessionEarned  = 0
local sessionJobs    = 0
local lastPayoutTime = nil
local etaAvg         = "N/A"
local etaFast        = "N/A"
local myFont         = nil
local AFK_TIMEOUT    = 300   -- seconds; gaps longer than this are AFK, not counted

-- ============================================================
--  GUI
-- ============================================================
local gui = {
    show     = new.bool(false),
    goalAmt  = new.int(1000000),
    posX     = new.int(10),
    posY     = new.int(10),
    fontSize = new.int(16),
}

-- ============================================================
--  CHAT COLOURS
-- ============================================================
local C = {
    INFO = 0xFFAAAAAA,
    OK   = 0xFF00FF00,
    WARN = 0xFFFFAA00,
    ERR  = 0xFFFF4444,
    GOLD = 0xFFFFDD00,
    SAVE = 0xFFFF88FF,
}
local function msg(t, c) sampAddChatMessage("[IT] "..t, c or C.INFO) end

-- ============================================================
--  FILE I/O
-- ============================================================
local function ensureDir()
    if lfs.attributes(DOC_PATH, "mode") ~= "directory" then lfs.mkdir(DOC_PATH) end
end

local function io_save(path, tbl)
    ensureDir()
    local f = io.open(path, "w")
    if f then f:write(json.encode(tbl, {indent=true})); f:close() end
end

local function io_load(path, default)
    local f = io.open(path, "r")
    if f then
        local decoded = json.decode(f:read("*a"))
        f:close()
        if decoded then
            for k,v in pairs(default) do
                if decoded[k] == nil then decoded[k] = v end
            end
            return decoded
        end
    end
    return default
end

local function saveAll()
    io_save(FILES.config,  cfg)
    io_save(FILES.data,    stats)
    io_save(FILES.goals,   activeGoal)
    io_save(FILES.history, history)
end

local function loadAll()
    cfg        = io_load(FILES.config,  cfg)
    stats      = io_load(FILES.data,    stats)
    activeGoal = io_load(FILES.goals,   activeGoal)
    history    = io_load(FILES.history, history)
    if not stats.intervals       then stats.intervals       = {} end
    if not stats.fastest_interval then stats.fastest_interval = 999999 end
    if not stats.all_avg_interval then stats.all_avg_interval = 0 end
    if not stats.interval_count   then stats.interval_count   = 0 end
end

-- ============================================================
--  FORMAT HELPERS
-- ============================================================
local function fmtMoney(n)
    n = math.floor(n or 0)
    local s = tostring(n)
    local r, c = "", 0
    for i = #s, 1, -1 do
        c = c + 1; r = s:sub(i,i)..r
        if c%3 == 0 and i ~= 1 then r = ","..r end
    end
    return "$"..r
end

local function fmtTime(sec)
    if not sec or sec <= 0 then return "Done!" end
    if sec > 86400*30 then return ">1 month" end
    local h = math.floor(sec/3600)
    local m = math.floor((sec%3600)/60)
    local s = math.floor(sec%60)
    if h > 0  then return string.format("%dh %dm", h, m) end
    if m > 0  then return string.format("%dm %ds", m, s) end
    return string.format("%ds", s)
end

local function fmtSec(s)
    if not s or s >= 999999 then return "N/A" end
    if s >= 60 then return string.format("%.1fm", s/60) end
    return string.format("%.1fs", s)
end

-- ============================================================
--  INTERVAL ENGINE  (persistent across sessions)
-- ============================================================

-- Recompute all_avg_interval from the stored intervals list
local function recomputeAvg()
    local list = stats.intervals
    if #list == 0 then
        stats.all_avg_interval = 0
        stats.interval_count   = 0
        return
    end
    local total = 0
    for _, v in ipairs(list) do total = total + v end
    stats.all_avg_interval = total / #list
    stats.interval_count   = #list
end

-- Record a new payout interval
local function recordInterval(gap)
    -- AFK guard: skip gaps longer than AFK_TIMEOUT
    if gap > AFK_TIMEOUT then
        msg(string.format("AFK gap skipped (%.0fs)", gap), C.INFO)
        return
    end

    -- Add to persistent list (keep last 500)
    table.insert(stats.intervals, gap)
    while #stats.intervals > 500 do table.remove(stats.intervals, 1) end

    -- Update fastest ever
    if gap < stats.fastest_interval then
        stats.fastest_interval = gap
    end

    -- Recompute running average from full list
    recomputeAvg()
end

-- Average payout amount from recent history
local function avgPayoutAmount()
    if #history == 0 then return nil end
    local total = 0
    local count = math.min(#history, 100)
    for i = #history, math.max(1, #history - count + 1), -1 do
        total = total + (history[i].amount or 0)
    end
    return total / count
end

-- ETA given remaining money and an interval (seconds per payout)
local function calcETA(remaining, interval)
    if not interval or interval <= 0 or interval >= 999999 then return nil end
    local avg = avgPayoutAmount()
    if not avg or avg <= 0 then return nil end
    local moneyPerSec = avg / interval
    if moneyPerSec <= 0 then return nil end
    return remaining / moneyPerSec
end

local function updateETAs()
    if not activeGoal.active then
        etaAvg  = "No active goal"
        etaFast = "No active goal"
        return
    end
    local progress  = stats.total_earned - activeGoal.earned_at_start
    local remaining = math.max(0, activeGoal.target - progress)
    if remaining <= 0 then
        etaAvg  = "Goal complete!"
        etaFast = "Goal complete!"
        return
    end
    if stats.interval_count < 2 then
        etaAvg  = "Need 2+ payouts"
        etaFast = "Need 2+ payouts"
        return
    end

    local avgSec  = calcETA(remaining, stats.all_avg_interval)
    local fastSec = calcETA(remaining, stats.fastest_interval)

    etaAvg  = avgSec  and fmtTime(avgSec)  or "Calculating..."
    etaFast = fastSec and fmtTime(fastSec) or "Calculating..."
end

-- ============================================================
--  PAYOUT HANDLER
-- ============================================================
local function onJobComplete(amount)
    local now = os.clock()

    if lastPayoutTime ~= nil then
        local gap = now - lastPayoutTime
        recordInterval(gap)
        saveAll()
    end
    lastPayoutTime = now

    sessionEarned      = sessionEarned + amount
    sessionJobs        = sessionJobs + 1
    stats.total_earned = stats.total_earned + amount
    stats.total_jobs   = stats.total_jobs + 1

    table.insert(history, {
        time   = os.date("%H:%M:%S"),
        date   = os.date("%Y-%m-%d"),
        amount = amount
    })
    while #history > 300 do table.remove(history, 1) end

    updateETAs()
    saveAll()

    -- Chat feedback line
    local gapStr = ""
    if stats.interval_count >= 2 then
        gapStr = string.format("  avg gap: %s  fastest: %s",
            fmtSec(stats.all_avg_interval),
            fmtSec(stats.fastest_interval))
    end
    msg(string.format("+%s  session: %s  jobs: %d%s",
        fmtMoney(amount), fmtMoney(sessionEarned), sessionJobs, gapStr), C.OK)

    -- Milestones
    for _, ms in ipairs({100000,250000,500000,750000,1000000,2000000,5000000}) do
        if stats.total_earned >= ms and (stats.total_earned - amount) < ms then
            msg("*** MILESTONE: "..fmtMoney(ms).." ***", C.GOLD)
        end
    end
end

local function onTransfer(amount, recipient)
    stats.total_earned = math.max(0, stats.total_earned - amount)
    updateETAs()
    saveAll()
    msg("Deducted "..fmtMoney(amount).." (transfer to "..recipient..")", C.WARN)
end

-- ============================================================
--  TEXTDRAW / HUD
-- ============================================================
local function rebuildFont()
    myFont = renderCreateFont("Arial", math.max(6, cfg.fontSize), cfg.fontFlags or 5)
end

local function drawHUD()
    if not cfg.showHUD or not myFont then return end

    local sw, sh = getScreenResolution()
    -- Clamp position so it never goes off screen
    local x = math.max(0, math.min(cfg.posX, sw - 10))
    local y = math.max(0, math.min(cfg.posY, sh - 10))
    local lh = cfg.fontSize + 4

    -- Build lines (NO emoji, NO special unicode box chars)
    local lines = {}

    local function add(text, col)
        table.insert(lines, {text=text, col=col or 0xFFFFFFFF})
    end

    add("[ Income Tracker Pro ]",       0xFF44AAFF)
    add("Session : "..fmtMoney(sessionEarned),         0xFF88FF88)
    add("Total   : "..fmtMoney(stats.total_earned),    0xFFFFDD44)
    add("Jobs    : "..sessionJobs.." session / "..stats.total_jobs.." total", 0xFFCCCCCC)
    add("----------------------------",                 0xFF334455)

    -- Speed block
    if stats.interval_count >= 2 then
        add("Avg gap : "..fmtSec(stats.all_avg_interval)..
            "  ("..stats.interval_count.." samples)",  0xFF88DDFF)
        add("Fastest : "..fmtSec(stats.fastest_interval), 0xFF88FFAA)
    else
        add("Speed   : Need 2+ payouts",               0xFF888888)
    end

    add("----------------------------",                 0xFF334455)

    -- Goal block
    if activeGoal.active then
        local progress  = stats.total_earned - activeGoal.earned_at_start
        local remaining = math.max(0, activeGoal.target - progress)
        local pct       = math.min(100, math.floor(progress / math.max(1, activeGoal.target) * 100))
        add("Goal    : "..fmtMoney(activeGoal.target).."  ("..pct.."%)", 0xFFFFBB44)
        add("Remain  : "..fmtMoney(remaining),         0xFFFF7777)
        add("ETA avg : "..etaAvg,                      0xFFAADDFF)
        add("ETA fast: "..etaFast,                     0xFF88FF88)
    else
        add("Goal    : Not set  (/goalhud)",            0xFF888888)
    end

    -- Dark background box
    if cfg.showBg then
        local maxW = 0
        for _, l in ipairs(lines) do
            -- rough width estimate
            local w = #l.text * (cfg.fontSize * 0.56)
            if w > maxW then maxW = w end
        end
        renderDrawBox(x - 3, y - 3, maxW + 6, #lines * lh + 6, 0xBB000000)
    end

    for i, l in ipairs(lines) do
        renderFontDrawText(myFont, l.text, x, y + (i-1)*lh, l.col)
    end
end

-- ============================================================
--  MIMGUI STYLE  (FarmingFuzz palette)
-- ============================================================
imgui.OnInitialize(function()
    imgui.GetIO().IniFilename = nil
    local style  = imgui.GetStyle()
    local colors = style.Colors
    local clr    = imgui.Col
    local V4     = imgui.ImVec4
    local V2     = imgui.ImVec2

    pcall(function()
        local gr = imgui.GetIO().Fonts:GetGlyphRangesCyrillic()
        imgui.GetIO().Fonts:AddFontFromFileTTF("Arial.ttf", 14.0, nil, gr)
    end)

    style.WindowPadding     = V2(14, 14)
    style.WindowRounding    = 10.0
    style.FramePadding      = V2(6, 5)
    style.ItemSpacing       = V2(10, 8)
    style.ItemInnerSpacing  = V2(7, 5)
    style.FrameRounding     = 6.0
    style.GrabRounding      = 5.0
    style.ScrollbarRounding = 8.0
    style.WindowTitleAlign  = V2(0.5, 0.5)
    style.ButtonTextAlign   = V2(0.5, 0.5)

    colors[clr.WindowBg]         = V4(0.08,0.08,0.18,0.97)
    colors[clr.TitleBg]          = V4(0.06,0.06,0.14,1.00)
    colors[clr.TitleBgActive]    = V4(0.14,0.14,0.40,1.00)
    colors[clr.FrameBg]          = V4(0.14,0.14,0.30,0.80)
    colors[clr.FrameBgHovered]   = V4(0.20,0.20,0.45,0.80)
    colors[clr.FrameBgActive]    = V4(0.10,0.10,0.25,1.00)
    colors[clr.Button]           = V4(0.16,0.28,0.72,0.85)
    colors[clr.ButtonHovered]    = V4(0.28,0.45,0.95,1.00)
    colors[clr.ButtonActive]     = V4(0.10,0.20,0.60,1.00)
    colors[clr.Header]           = V4(0.16,0.28,0.72,0.75)
    colors[clr.HeaderHovered]    = V4(0.28,0.45,0.95,0.85)
    colors[clr.HeaderActive]     = V4(0.20,0.35,0.80,1.00)
    colors[clr.SliderGrab]       = V4(0.50,0.70,1.00,1.00)
    colors[clr.SliderGrabActive] = V4(0.30,0.55,0.95,1.00)
    colors[clr.CheckMark]        = V4(0.40,0.80,1.00,1.00)
    colors[clr.Separator]        = V4(0.30,0.30,0.55,0.60)
    colors[clr.Text]             = V4(0.92,0.93,1.00,1.00)
    colors[clr.TextDisabled]     = V4(0.45,0.47,0.60,1.00)
    colors[clr.Border]           = V4(0.30,0.30,0.60,0.50)
end)

-- ============================================================
--  MAIN GUI WINDOW
-- ============================================================
imgui.OnFrame(
    function() return gui.show[0] end,
    function()
        local sw, sh = getScreenResolution()
        imgui.SetNextWindowPos(imgui.ImVec2(sw/2, sh/2),
            imgui.Cond.FirstUseEver, imgui.ImVec2(0.5,0.5))
        imgui.SetNextWindowSize(imgui.ImVec2(370,0), imgui.Cond.FirstUseEver)

        imgui.Begin("Income Tracker Pro V4  |  Faisal Hazary", gui.show,
            imgui.WindowFlags.NoResize +
            imgui.WindowFlags.NoCollapse +
            imgui.WindowFlags.AlwaysAutoResize)

        -- LIVE STATS
        imgui.TextColored(imgui.ImVec4(0.4,0.9,1,1), "Live Stats")
        imgui.Separator()
        imgui.TextDisabled("Session : "); imgui.SameLine()
        imgui.TextColored(imgui.ImVec4(0.3,1,0.5,1), fmtMoney(sessionEarned))
        imgui.TextDisabled("Total   : "); imgui.SameLine()
        imgui.TextColored(imgui.ImVec4(1,0.9,0.2,1), fmtMoney(stats.total_earned))
        imgui.TextDisabled("Jobs    : "); imgui.SameLine()
        imgui.TextColored(imgui.ImVec4(0.7,0.7,1,1),
            sessionJobs.." session  /  "..stats.total_jobs.." all-time")

        imgui.Spacing()

        -- SPEED PANEL
        imgui.TextColored(imgui.ImVec4(0.4,0.9,1,1), "Payout Speed  (persistent, all sessions)")
        imgui.Separator()

        if stats.interval_count >= 2 then
            imgui.TextDisabled("Avg gap  : "); imgui.SameLine()
            imgui.TextColored(imgui.ImVec4(0.8,0.8,1,1),
                string.format("%s  (%d samples total)", fmtSec(stats.all_avg_interval), stats.interval_count))

            imgui.TextDisabled("Fastest  : "); imgui.SameLine()
            imgui.TextColored(imgui.ImVec4(0.4,1,0.6,1), fmtSec(stats.fastest_interval))

            -- Money per hour estimate
            local mph = avgPayoutAmount()
            if mph then
                local perHour = mph / stats.all_avg_interval * 3600
                imgui.TextDisabled("Avg $/hr : "); imgui.SameLine()
                imgui.TextColored(imgui.ImVec4(1,0.9,0.3,1), fmtMoney(perHour))

                local fastPerHour = mph / stats.fastest_interval * 3600
                imgui.TextDisabled("Max $/hr : "); imgui.SameLine()
                imgui.TextColored(imgui.ImVec4(0.4,1,0.5,1), fmtMoney(fastPerHour))
            end
        else
            imgui.TextColored(imgui.ImVec4(0.6,0.6,0.6,1),
                "Need 2+ payouts to calculate speed")
        end

        imgui.TextDisabled("AFK cutoff: "..AFK_TIMEOUT.."s  (gaps longer = ignored)")

        imgui.Spacing()

        -- GOAL
        imgui.TextColored(imgui.ImVec4(0.4,0.9,1,1), "Goal")
        imgui.Separator()

        if not activeGoal.active then
            imgui.SetNextItemWidth(210)
            imgui.InputInt("##g", gui.goalAmt)
            imgui.SameLine()
            imgui.PushStyleColor(imgui.Col.Button,        imgui.ImVec4(0.10,0.55,0.20,0.90))
            imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.15,0.75,0.30,1.00))
            imgui.PushStyleColor(imgui.Col.ButtonActive,  imgui.ImVec4(0.08,0.40,0.15,1.00))
            if imgui.Button("Start Goal", imgui.ImVec2(118,26)) then
                activeGoal = {
                    active=true, target=gui.goalAmt[0],
                    earned_at_start=stats.total_earned, start_time=os.time()
                }
                updateETAs(); saveAll()
                msg("Goal: "..fmtMoney(gui.goalAmt[0]), C.OK)
            end
            imgui.PopStyleColor(3)
        else
            local progress  = stats.total_earned - activeGoal.earned_at_start
            local remaining = math.max(0, activeGoal.target - progress)
            local pct       = math.min(1.0, progress / math.max(1, activeGoal.target))

            imgui.ProgressBar(pct, imgui.ImVec2(340,22),
                string.format("%s / %s  (%.1f%%)",
                    fmtMoney(progress), fmtMoney(activeGoal.target), pct*100))

            imgui.Spacing()
            imgui.TextDisabled("Remaining: "); imgui.SameLine()
            imgui.TextColored(imgui.ImVec4(1,0.4,0.4,1), fmtMoney(remaining))

            -- ETA box
            imgui.Spacing()
            imgui.PushStyleColor(imgui.Col.ChildBg, imgui.ImVec4(0.10,0.10,0.22,1.00))
            imgui.BeginChild("##eta", imgui.ImVec2(340,52), true)
            imgui.TextDisabled("  ETA at avg speed  : "); imgui.SameLine()
            imgui.TextColored(imgui.ImVec4(0.5,0.8,1.0,1), etaAvg)
            imgui.TextDisabled("  ETA at fastest    : "); imgui.SameLine()
            imgui.TextColored(imgui.ImVec4(0.3,1.0,0.5,1), etaFast)
            imgui.EndChild()
            imgui.PopStyleColor()

            imgui.Spacing()
            imgui.PushStyleColor(imgui.Col.Button,        imgui.ImVec4(0.55,0.12,0.12,0.90))
            imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.80,0.18,0.18,1.00))
            imgui.PushStyleColor(imgui.Col.ButtonActive,  imgui.ImVec4(0.40,0.08,0.08,1.00))
            if imgui.Button("Cancel Goal", imgui.ImVec2(340,26)) then
                activeGoal.active=false; updateETAs(); saveAll()
                msg("Goal cancelled.", C.WARN)
            end
            imgui.PopStyleColor(3)
        end

        imgui.Spacing()

        -- HUD SETTINGS
        if imgui.CollapsingHeader("HUD / Textdraw Settings") then
            imgui.Spacing()

            local hudLabel = cfg.showHUD and "Textdraw  ON" or "Textdraw  OFF"
            local hudCol   = cfg.showHUD
                and imgui.ImVec4(0.10,0.55,0.20,0.90)
                or  imgui.ImVec4(0.55,0.12,0.12,0.90)
            imgui.PushStyleColor(imgui.Col.Button,        hudCol)
            imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.20,0.70,0.35,1.00))
            imgui.PushStyleColor(imgui.Col.ButtonActive,  hudCol)
            if imgui.Button(hudLabel, imgui.ImVec2(340,30)) then
                cfg.showHUD = not cfg.showHUD; saveAll()
            end
            imgui.PopStyleColor(3)

            imgui.Spacing(); imgui.Separator(); imgui.Spacing()

            -- Font size
            imgui.TextColored(imgui.ImVec4(0.7,0.9,1,1), "Text Size (px)")
            imgui.SetNextItemWidth(280)
            if imgui.SliderInt("##fs", gui.fontSize, 6, 48) then
                cfg.fontSize = gui.fontSize[0]; rebuildFont(); saveAll()
            end
            imgui.SameLine()
            imgui.TextColored(imgui.ImVec4(0.5,1,0.5,1), cfg.fontSize.."px")

            imgui.Spacing()

            -- BG box toggle
            local bgLbl = cfg.showBg and "Dark BG Box  ON" or "Dark BG Box  OFF"
            if imgui.Button(bgLbl, imgui.ImVec2(340,26)) then
                cfg.showBg = not cfg.showBg; saveAll()
            end

            imgui.Spacing(); imgui.Separator()

            -- Position
            -- X slider
            imgui.TextColored(imgui.ImVec4(0.7,0.9,1,1), "HUD Position")
            local sw2, sh2 = getScreenResolution()
            imgui.TextDisabled(string.format("Screen: %dx%d", sw2, sh2))

            imgui.Text("X"); imgui.SameLine(); imgui.SetNextItemWidth(290)
            if imgui.SliderInt("##px", gui.posX, 0, sw2 - 10) then
                cfg.posX = gui.posX[0]; saveAll()
            end

            -- Y slider: range is 0 to sh2. LOW number = TOP of screen.
            imgui.Text("Y"); imgui.SameLine(); imgui.SetNextItemWidth(290)
            if imgui.SliderInt("##py", gui.posY, 0, sh2 - 10) then
                cfg.posY = gui.posY[0]; saveAll()
            end

            imgui.TextColored(imgui.ImVec4(0.6,0.6,0.6,1),
                "Y=0 is TOP of screen. Drag left to move up.")

            -- Quick snap buttons
            imgui.Spacing()
            if imgui.Button("Top-Left", imgui.ImVec2(80,22)) then
                cfg.posX=10; cfg.posY=10
                gui.posX[0]=10; gui.posY[0]=10; saveAll()
            end
            imgui.SameLine()
            if imgui.Button("Top-Right", imgui.ImVec2(80,22)) then
                local sw3,_ = getScreenResolution()
                cfg.posX=sw3-220; cfg.posY=10
                gui.posX[0]=cfg.posX; gui.posY[0]=10; saveAll()
            end
            imgui.SameLine()
            if imgui.Button("Bot-Left", imgui.ImVec2(80,22)) then
                local _,sh3 = getScreenResolution()
                cfg.posX=10; cfg.posY=sh3-220
                gui.posX[0]=10; gui.posY[0]=cfg.posY; saveAll()
            end
        end

        -- RECENT LOG
        if imgui.CollapsingHeader("Recent Earnings (last 15)") then
            local s = math.max(1, #history-14)
            for i = #history, s, -1 do
                local e = history[i]
                imgui.TextDisabled(e.time.."  ")
                imgui.SameLine()
                imgui.TextColored(imgui.ImVec4(0.3,1,0.5,1), fmtMoney(e.amount))
            end
        end

        -- RESET
        if imgui.CollapsingHeader("Reset") then
            imgui.Spacing()
            imgui.PushStyleColor(imgui.Col.Button,        imgui.ImVec4(0.55,0.12,0.12,0.90))
            imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.80,0.18,0.18,1.00))
            imgui.PushStyleColor(imgui.Col.ButtonActive,  imgui.ImVec4(0.40,0.08,0.08,1.00))
            if imgui.Button("Reset Session", imgui.ImVec2(162,28)) then
                sessionEarned=0; sessionJobs=0; lastPayoutTime=nil
                updateETAs()
                msg("Session reset.", C.WARN)
            end
            imgui.SameLine()
            if imgui.Button("Reset ALL Data", imgui.ImVec2(162,28)) then
                stats       = {total_earned=0,total_jobs=0,fastest_interval=999999,
                               all_avg_interval=0,interval_count=0,intervals={}}
                history     = {}
                activeGoal  = {active=false,target=0,earned_at_start=0,start_time=0}
                sessionEarned=0; sessionJobs=0; lastPayoutTime=nil
                etaAvg="N/A"; etaFast="N/A"
                saveAll()
                msg("All data wiped.", C.WARN)
            end
            imgui.PopStyleColor(3)
        end

        imgui.Separator()
        imgui.TextDisabled("F8 / /goalhud to toggle  |  /hudsize <n>  /itinfo")
        imgui.End()
    end
)

-- ============================================================
--  SAMP HOOK
-- ============================================================
function samp.onServerMessage(color, text)
    local clean = text:gsub("{%x%x%x%x%x%x}", "")

    local amount = clean:match("You received %$(%d+) for delivering the harvest")
    if amount then onJobComplete(tonumber(amount)); return end

    local rawAmt, recipient = clean:match("You have transferred %$([%d,]+) to (.+)'s account")
    if rawAmt then onTransfer(tonumber(rawAmt:gsub(",","")), recipient) end
end

-- ============================================================
--  MAIN
-- ============================================================
function main()
    while not isSampAvailable() do wait(100) end

    loadAll()
    recomputeAvg()   -- rebuild avg from loaded intervals list

    -- Sync GUI sliders
    gui.posX[0]     = cfg.posX
    gui.posY[0]     = cfg.posY
    gui.fontSize[0] = cfg.fontSize

    updateETAs()
    rebuildFont()

    sampRegisterChatCommand("goalhud", function()
        gui.show[0] = not gui.show[0]
    end)

    sampRegisterChatCommand("hudsize", function(args)
        local v = tonumber(args)
        if v and v >= 6 and v <= 48 then
            cfg.fontSize=v; gui.fontSize[0]=v; rebuildFont(); saveAll()
            msg("Text size: "..v.."px", C.OK)
        else
            msg("Usage: /hudsize <6-48>", C.WARN)
        end
    end)

    sampRegisterChatCommand("itinfo", function()
        msg(string.format("Session: %s  Jobs: %d  Avg gap: %s  Fastest: %s",
            fmtMoney(sessionEarned), sessionJobs,
            fmtSec(stats.all_avg_interval),
            fmtSec(stats.fastest_interval)), C.INFO)
        msg("ETA avg: "..etaAvg.."  |  ETA fast: "..etaFast, C.GOLD)
    end)

    lua_thread.create(function()
        while true do wait(15000); updateETAs() end
    end)

    msg("Income Tracker Pro V4 loaded!", C.OK)
    msg("/goalhud  /hudsize <n>  /itinfo", C.INFO)

    while true do
        wait(0)
        if wasKeyPressed(0x77) then gui.show[0] = not gui.show[0] end
        drawHUD()
    end
end