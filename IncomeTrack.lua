-- ============================================================
--  Income Tracker Pro
--  Author  : Faisal Hazary
--  GitHub  : https://github.com/faisalhazary/-HZG-IncomeTrackerPro
-- ============================================================
script_name("Income Tracker Pro")
script_author("Faisal Hazary")

require "lib.moonloader"
local imgui    = require "mimgui"
local new      = imgui.new
local encoding = require 'encoding'
local samp     = require 'lib.samp.events'
local json     = require 'dkjson'
local lfs      = require 'lfs'
local http     = require 'socket.http'
local ltn12    = require 'ltn12'
encoding.default = 'CP1251'
u8 = encoding.UTF8

-- ============================================================
--  VERSION — only edit this one line per release
-- ============================================================
local VERSION = "5.3"

-- ============================================================
--  GITHUB
-- ============================================================
local GH_USER   = "faisalhazary"
local GH_REPO   = "-HZG-IncomeTrackerPro"
local GH_BRANCH = "main"
local GH_SCRIPT = "IncomeTrack.lua"
local GH_RAW     = "https://raw.githubusercontent.com/"..GH_USER.."/"..GH_REPO.."/refs/heads/"..GH_BRANCH.."/"..GH_SCRIPT
local GH_COMMITS = "https://api.github.com/repos/"..GH_USER.."/"..GH_REPO.."/commits?per_page=5&sha="..GH_BRANCH

-- ============================================================
--  PATHS
-- ============================================================
local SCRIPT_PATH = thisScript().path
local DOC_PATH    = os.getenv("USERPROFILE") .. "\\Documents\\IncomeTrackerPro\\"
local FILES = {
    config  = DOC_PATH .. "config.json",
    data    = DOC_PATH .. "data.json",
    goals   = DOC_PATH .. "goals.json",
    history = DOC_PATH .. "history.json",
    session = DOC_PATH .. "session.json",
}

-- ============================================================
--  DEFAULTS
-- ============================================================
local cfg = {
    showHUD=true, fontSize=16, posX=10, posY=10, fontFlags=5,
    showBg=true, show_session=true, show_total=true, show_jobs=true,
    show_speed=true, show_goal=true, show_eta=true,
    show_payout_msg=false, auto_update=true,
}
local stats = {
    total_earned=0, total_jobs=0, fastest_interval=999999,
    all_avg_interval=0, interval_count=0, intervals={},
}
local activeGoal = { active=false, target=0, earned_at_start=0, start_time=0 }
local history = {}

-- ============================================================
--  RUNTIME
-- ============================================================
local sessionEarned  = 0
local sessionJobs    = 0
local lastPayoutTime = nil
local lastPayoutTs   = nil
local etaAvg         = "N/A"
local etaFast        = "N/A"
local myFont         = nil
local AFK_TIMEOUT    = 300
local SESSION_STALE  = 3600

-- ============================================================
--  UPDATE STATE
-- ============================================================
local upd = { status="", newVer=nil, changelog=nil }

-- ============================================================
--  GUI
-- ============================================================
local gui = {
    show=new.bool(false), goalAmt=new.int(1000000),
    posX=new.int(10), posY=new.int(10), fontSize=new.int(16),
}
local hdr = { stats=true, goal=true, hud=false, update=false, log=false, credits=false, reset=false }

-- ============================================================
--  COLOURS
-- ============================================================
local C = { INFO=0xFFAAAAAA, OK=0xFF00FF00, WARN=0xFFFFAA00, ERR=0xFFFF4444, GOLD=0xFFFFDD00, BLUE=0xFF44AAFF }
local function msg(t,c) sampAddChatMessage("[IT] "..t, c or C.INFO) end

-- ============================================================
--  FILE I/O
-- ============================================================
local function ensureDir()
    if lfs.attributes(DOC_PATH,"mode") ~= "directory" then lfs.mkdir(DOC_PATH) end
end
local function io_save(path,tbl)
    ensureDir()
    local f=io.open(path,"w"); if f then f:write(json.encode(tbl,{indent=true})); f:close() end
end
local function io_load(path,default)
    local f=io.open(path,"r"); if not f then return default end
    local d=json.decode(f:read("*a")); f:close()
    if not d then return default end
    for k,v in pairs(default) do if d[k]==nil then d[k]=v end end
    return d
end
local function saveAll()
    io_save(FILES.config,cfg); io_save(FILES.data,stats)
    io_save(FILES.goals,activeGoal); io_save(FILES.history,history)
end
local function loadAll()
    cfg=io_load(FILES.config,cfg); stats=io_load(FILES.data,stats)
    activeGoal=io_load(FILES.goals,activeGoal); history=io_load(FILES.history,history)
    if not stats.intervals        then stats.intervals={}         end
    if not stats.fastest_interval then stats.fastest_interval=999999 end
    if not stats.all_avg_interval then stats.all_avg_interval=0   end
    if not stats.interval_count   then stats.interval_count=0     end
end

-- ============================================================
--  SESSION
-- ============================================================
local function saveSession()
    io_save(FILES.session,{earned=sessionEarned,jobs=sessionJobs,last_payout=lastPayoutTs})
end
local function clearSession() os.remove(FILES.session) end
local function loadSession()
    local f=io.open(FILES.session,"r"); if not f then return false end
    local d=json.decode(f:read("*a")); f:close(); if not d then return false end
    if d.last_payout then
        local age=os.time()-d.last_payout
        if age>SESSION_STALE then clearSession(); return false end
        if age<AFK_TIMEOUT then lastPayoutTime=os.clock()-age end
        lastPayoutTs=d.last_payout
    end
    sessionEarned=d.earned or 0; sessionJobs=d.jobs or 0
    return true
end

-- ============================================================
--  FORMAT HELPERS  (pure, never yield)
-- ============================================================
local function fmtMoney(n)
    n=math.floor(n or 0)
    local s=tostring(n); local r,c="",0
    for i=#s,1,-1 do
        c=c+1; r=s:sub(i,i)..r
        if c%3==0 and i~=1 then r=","..r end
    end
    return "$"..r
end
local function fmtTime(sec)
    if not sec or sec<=0 then return "Done!" end
    if sec>86400*30 then return ">1month" end
    local h=math.floor(sec/3600); local m=math.floor((sec%3600)/60); local s=math.floor(sec%60)
    if h>0 then return h.."h "..m.."m" end
    if m>0 then return m.."m "..s.."s" end
    return s.."s"
end
local function fmtSec(s)
    if not s or s>=999999 then return "N/A" end
    if s>=60 then return string.format("%.1fm",s/60) end
    return string.format("%.1fs",s)
end

-- ============================================================
--  HUD LINE CACHE
--  hudLines is a plain table of {text,col} pairs.
--  Built here, read by drawHUD. Zero computation in draw path.
-- ============================================================
local hudLines = {}
local hud = {
    session="$0", total="$0", jobs="0/0",
    has_speed=false, avg_gap="N/A", fastest="N/A", samples="0",
    has_goal=false, goal_pct="0%", goal_tgt="$0", remain="$0",
    eta_avg="N/A", eta_fast="N/A",
}

-- forward declared so rebuildHUD can call it
local rebuildHudLines

function rebuildHudLines()
    local lines={}
    local function add(t,col) lines[#lines+1]={text=t,col=col or 0xFFFFFFFF} end
    add("[ Income Tracker Pro v"..VERSION.." ]",     0xFF44AAFF)
    if cfg.show_session then add("Session : "..hud.session,              0xFF88FF88) end
    if cfg.show_total   then add("Total   : "..hud.total,                0xFFFFDD44) end
    if cfg.show_jobs    then add("Jobs    : "..hud.jobs,                 0xFFCCCCCC) end
    if cfg.show_speed   then
        add("----------------------------",                               0xFF334455)
        if hud.has_speed then
            add("Avg gap : "..hud.avg_gap.."  ("..hud.samples.."s)",     0xFF88DDFF)
            add("Fastest : "..hud.fastest,                               0xFF88FFAA)
        else
            add("Speed   : Need 2+ payouts",                             0xFF888888)
        end
    end
    if cfg.show_goal or cfg.show_eta then
        add("----------------------------",                               0xFF334455)
        if hud.has_goal then
            if cfg.show_goal then
                add("Goal    : "..hud.goal_tgt.." ("..hud.goal_pct..")", 0xFFFFBB44)
                add("Remain  : "..hud.remain,                            0xFFFF7777)
            end
            if cfg.show_eta then
                add("ETA avg : "..hud.eta_avg,                           0xFFAADDFF)
                add("ETA fast: "..hud.eta_fast,                          0xFF88FF88)
            end
        else
            add("Goal    : Not set  (/it)",                               0xFF888888)
        end
    end
    hudLines=lines
end

local function rebuildHUD()
    hud.session  = fmtMoney(sessionEarned)
    hud.total    = fmtMoney(stats.total_earned)
    hud.jobs     = sessionJobs.."/"..stats.total_jobs
    hud.has_speed= stats.interval_count>=2
    if hud.has_speed then
        hud.avg_gap=fmtSec(stats.all_avg_interval)
        hud.fastest=fmtSec(stats.fastest_interval)
        hud.samples=tostring(stats.interval_count)
    end
    hud.has_goal=activeGoal.active
    if hud.has_goal then
        local prog=stats.total_earned-activeGoal.earned_at_start
        local rem=math.max(0,activeGoal.target-prog)
        local pct=math.min(100,math.floor(prog/math.max(1,activeGoal.target)*100))
        hud.goal_pct=pct.."%"
        hud.goal_tgt=fmtMoney(activeGoal.target)
        hud.remain  =fmtMoney(rem)
        hud.eta_avg =etaAvg
        hud.eta_fast=etaFast
    end
    rebuildHudLines()
end

-- ============================================================
--  INTERVALS / ETA
-- ============================================================
local function recomputeAvg()
    local list=stats.intervals
    if #list==0 then stats.all_avg_interval=0;stats.interval_count=0;return end
    local t=0; for _,v in ipairs(list) do t=t+v end
    stats.all_avg_interval=t/#list; stats.interval_count=#list
end
local function recordInterval(gap)
    if gap>AFK_TIMEOUT then return end
    table.insert(stats.intervals,gap)
    while #stats.intervals>500 do table.remove(stats.intervals,1) end
    if gap<stats.fastest_interval then stats.fastest_interval=gap end
    recomputeAvg()
end
local function avgPayoutAmount()
    if #history==0 then return nil end
    local t,c=0,math.min(#history,100)
    for i=#history,math.max(1,#history-c+1),-1 do t=t+(history[i].amount or 0) end
    return t/c
end
local function calcETA(remaining,interval)
    if not interval or interval<=0 or interval>=999999 then return nil end
    local avg=avgPayoutAmount(); if not avg or avg<=0 then return nil end
    return remaining/(avg/interval)
end
local function updateETAs()
    if not activeGoal.active then etaAvg="No goal";etaFast="No goal";return end
    local prog=stats.total_earned-activeGoal.earned_at_start
    local rem=math.max(0,activeGoal.target-prog)
    if rem<=0 then etaAvg="Done!";etaFast="Done!";return end
    if stats.interval_count<2 then etaAvg="Need 2+ payouts";etaFast="Need 2+ payouts";return end
    etaAvg =fmtTime(calcETA(rem,stats.all_avg_interval)) or "..."
    etaFast=fmtTime(calcETA(rem,stats.fastest_interval)) or "..."
end

-- ============================================================
--  PAYOUT
-- ============================================================
local function onJobComplete(amount)
    local now=os.clock()
    if lastPayoutTime~=nil then recordInterval(now-lastPayoutTime) end
    lastPayoutTime=now; lastPayoutTs=os.time()
    sessionEarned=sessionEarned+amount; sessionJobs=sessionJobs+1
    stats.total_earned=stats.total_earned+amount; stats.total_jobs=stats.total_jobs+1
    table.insert(history,{time=os.date("%H:%M:%S"),date=os.date("%Y-%m-%d"),amount=amount})
    while #history>300 do table.remove(history,1) end
    updateETAs(); saveAll(); saveSession(); rebuildHUD()
    if cfg.show_payout_msg then
        local g=hud.has_speed and ("  avg:"..hud.avg_gap.." best:"..hud.fastest) or ""
        msg("+"..fmtMoney(amount).."  s:"..hud.session..g, C.OK)
    end
    for _,ms in ipairs({100000,250000,500000,750000,1000000,2000000,5000000}) do
        if stats.total_earned>=ms and (stats.total_earned-amount)<ms then
            msg("*** MILESTONE: "..fmtMoney(ms).." ***", C.GOLD)
        end
    end
end
local function onTransfer(amount,recipient)
    stats.total_earned=math.max(0,stats.total_earned-amount)
    updateETAs(); saveAll(); rebuildHUD()
    msg("Deducted "..fmtMoney(amount).." -> "..recipient, C.WARN)
end

-- ============================================================
--  HTTP  (blocking — only call from lua_thread)
-- ============================================================
local function httpGet(url)
    local resp={}
    local ok,code=http.request{
        url=url, sink=ltn12.sink.table(resp),
        headers={["User-Agent"]="IncomeTrackerPro/"..VERSION,["Accept"]="application/json"}
    }
    if ok and (code==200 or code=="200") then return table.concat(resp) end
    return nil
end

-- ============================================================
--  AUTO UPDATE
-- ============================================================
local function checkForUpdate(silent)
    lua_thread.create(function()
        upd.status="Checking..."
        local src=httpGet(GH_RAW)
        if not src then upd.status="Check failed (no internet?)"; return end
        local remoteVer=src:match('local%s+VERSION%s*=%s*"([%d%.]+)"')
        if not remoteVer then upd.status="Check failed (parse error)"; return end
        local function newer(a,b)
            local function pts(v) local t={} for n in v:gmatch("%d+") do t[#t+1]=tonumber(n) end return t end
            local pa,pb=pts(a),pts(b)
            for i=1,math.max(#pa,#pb) do
                local ai=pa[i] or 0; local bi=pb[i] or 0
                if bi>ai then return true end; if bi<ai then return false end
            end
            return false
        end
        if not newer(VERSION,remoteVer) then
            upd.status="Up to date (v"..VERSION..")"
            if not silent then msg("Up to date.",C.OK) end
            return
        end
        upd.newVer=remoteVer
        local apiBody=httpGet(GH_COMMITS)
        local changelog=""
        if apiBody then
            local commits=json.decode(apiBody)
            if commits and type(commits)=="table" then
                local lines={}
                for i,commit in ipairs(commits) do
                    if i>5 then break end
                    local cmsg=commit.commit and commit.commit.message or ""
                    local fl=cmsg:match("^([^\n]+)")
                    if fl and fl~="" then table.insert(lines,"* "..fl) end
                end
                changelog=table.concat(lines,"\n")
            end
        end
        upd.changelog=changelog~="" and changelog or "See GitHub for details."
        if cfg.auto_update then
            upd.status="Downloading v"..remoteVer.."..."
            local f=io.open(SCRIPT_PATH,"w")
            if not f then upd.status="Write failed. Run as admin?"; return end
            f:write(src); f:close()
            upd.status="Updated to v"..remoteVer.."! Reloading..."
            msg("Auto-updated to v"..remoteVer.."!", C.GOLD)
            wait(1500); thisScript():reload()
        else
            upd.status="v"..remoteVer.." available! Open /it"
            msg("New version v"..remoteVer.." available! /it -> Update", C.GOLD)
        end
    end)
end

-- ============================================================
--  FONT
-- ============================================================
local function rebuildFont()
    myFont=renderCreateFont("Arial",math.max(6,cfg.fontSize),cfg.fontFlags or 5)
end

-- ============================================================
--  DRAW HUD
--  Registered with imgui.OnFrame — runs in mimgui's D3D hook,
--  completely outside Lua coroutine scheduling.
--  Only reads hudLines (pre-built strings). Zero yield risk.
-- ============================================================
local function drawHUD()
    if not cfg.showHUD or not myFont or #hudLines==0 then return end
    local sw,sh=getScreenResolution()
    local x=math.max(0,math.min(cfg.posX,sw-10))
    local y=math.max(0,math.min(cfg.posY,sh-10))
    local lh=cfg.fontSize+4
    if cfg.showBg then
        local maxW=0
        for _,l in ipairs(hudLines) do
            local w=#l.text*(cfg.fontSize*0.56); if w>maxW then maxW=w end
        end
        renderDrawBox(x-3,y-3,maxW+6,#hudLines*lh+6,0xBB000000)
    end
    for i,l in ipairs(hudLines) do
        renderFontDrawText(myFont,l.text,x,y+(i-1)*lh,l.col)
    end
end

imgui.OnFrame(function() return cfg.showHUD and myFont~=nil end, function() drawHUD() end)

-- ============================================================
--  MIMGUI STYLE
-- ============================================================
imgui.OnInitialize(function()
    imgui.GetIO().IniFilename=nil
    local style=imgui.GetStyle(); local colors=style.Colors
    local clr=imgui.Col; local V4=imgui.ImVec4; local V2=imgui.ImVec2
    pcall(function()
        local gr=imgui.GetIO().Fonts:GetGlyphRangesCyrillic()
        imgui.GetIO().Fonts:AddFontFromFileTTF("Arial.ttf",13.0,nil,gr)
    end)
    style.WindowPadding=V2(10,10); style.WindowRounding=8.0
    style.FramePadding=V2(5,4);    style.ItemSpacing=V2(8,5)
    style.FrameRounding=5.0;       style.GrabRounding=4.0
    style.WindowTitleAlign=V2(0.5,0.5); style.ButtonTextAlign=V2(0.5,0.5)
    colors[clr.WindowBg]         =V4(0.08,0.08,0.18,0.97)
    colors[clr.TitleBg]          =V4(0.06,0.06,0.14,1.00)
    colors[clr.TitleBgActive]    =V4(0.12,0.12,0.35,1.00)
    colors[clr.FrameBg]          =V4(0.12,0.12,0.28,0.80)
    colors[clr.FrameBgHovered]   =V4(0.18,0.18,0.40,0.80)
    colors[clr.FrameBgActive]    =V4(0.10,0.10,0.25,1.00)
    colors[clr.Button]           =V4(0.14,0.25,0.65,0.85)
    colors[clr.ButtonHovered]    =V4(0.25,0.42,0.92,1.00)
    colors[clr.ButtonActive]     =V4(0.09,0.18,0.55,1.00)
    colors[clr.Header]           =V4(0.14,0.25,0.65,0.75)
    colors[clr.HeaderHovered]    =V4(0.25,0.42,0.92,0.85)
    colors[clr.HeaderActive]     =V4(0.18,0.32,0.75,1.00)
    colors[clr.SliderGrab]       =V4(0.45,0.65,1.00,1.00)
    colors[clr.SliderGrabActive] =V4(0.28,0.52,0.92,1.00)
    colors[clr.CheckMark]        =V4(0.35,0.75,1.00,1.00)
    colors[clr.Separator]        =V4(0.25,0.25,0.50,0.50)
    colors[clr.Text]             =V4(0.90,0.91,1.00,1.00)
    colors[clr.TextDisabled]     =V4(0.42,0.44,0.58,1.00)
    colors[clr.Border]           =V4(0.25,0.25,0.55,0.45)
    colors[clr.PopupBg]          =V4(0.08,0.08,0.18,0.98)
end)

-- ============================================================
--  GUI HELPERS
-- ============================================================
local function tbtn(label,state,w,h)
    w=w or 160; h=h or 22
    local on=imgui.ImVec4(0.09,0.50,0.18,0.90); local off=imgui.ImVec4(0.40,0.09,0.09,0.90)
    local hov=state and imgui.ImVec4(0.14,0.68,0.26,1) or imgui.ImVec4(0.58,0.13,0.13,1)
    imgui.PushStyleColor(imgui.Col.Button,state and on or off)
    imgui.PushStyleColor(imgui.Col.ButtonHovered,hov)
    imgui.PushStyleColor(imgui.Col.ButtonActive,state and on or off)
    local c=imgui.Button(label,imgui.ImVec2(w,h))
    imgui.PopStyleColor(3); return c
end
local function row(lbl,val,lw)
    lw=lw or 82
    imgui.TextDisabled(lbl); imgui.SameLine(lw); imgui.Text(val)
end
local function link(text,url,tip)
    imgui.TextColored(imgui.ImVec4(0.35,0.65,1,1),text)
    if imgui.IsItemHovered() then
        imgui.SetTooltip(tip or "Click to open")
        if imgui.IsItemClicked() then os.execute('start "" "'..url..'"') end
    end
end

-- ============================================================
--  MAIN GUI
-- ============================================================
imgui.OnFrame(
    function() return gui.show[0] end,
    function()
        local sw,sh=getScreenResolution()
        imgui.SetNextWindowPos(imgui.ImVec2(sw/2,sh/2),imgui.Cond.FirstUseEver,imgui.ImVec2(0.5,0.5))
        imgui.SetNextWindowSize(imgui.ImVec2(320,0),imgui.Cond.FirstUseEver)
        imgui.Begin("Income Tracker Pro v"..VERSION,gui.show,
            imgui.WindowFlags.NoResize+imgui.WindowFlags.NoCollapse+imgui.WindowFlags.AlwaysAutoResize)

        -- STATS
        if imgui.CollapsingHeader("Stats##hdr",hdr.stats and imgui.TreeNodeFlags.DefaultOpen or 0) then
            hdr.stats=true
            row("Session :",hud.session)
            row("Total   :",hud.total)
            row("Jobs    :",hud.jobs)
            if hud.has_speed then
                row("Avg gap :",hud.avg_gap.."  ("..hud.samples.." samples)")
                row("Fastest :",hud.fastest)
                local mph=avgPayoutAmount()
                if mph and stats.all_avg_interval>0 then
                    row("Avg $/hr:",fmtMoney(mph/stats.all_avg_interval*3600))
                    row("Max $/hr:",fmtMoney(mph/stats.fastest_interval*3600))
                end
            else imgui.TextDisabled("  Speed: need 2+ payouts") end
        else hdr.stats=false end

        -- GOAL
        if imgui.CollapsingHeader("Goal##hdr",hdr.goal and imgui.TreeNodeFlags.DefaultOpen or 0) then
            hdr.goal=true
            if not activeGoal.active then
                imgui.SetNextItemWidth(170); imgui.InputInt("##g",gui.goalAmt); imgui.SameLine()
                imgui.PushStyleColor(imgui.Col.Button,       imgui.ImVec4(0.09,0.50,0.18,0.90))
                imgui.PushStyleColor(imgui.Col.ButtonHovered,imgui.ImVec4(0.14,0.68,0.26,1.00))
                imgui.PushStyleColor(imgui.Col.ButtonActive, imgui.ImVec4(0.07,0.38,0.14,1.00))
                if imgui.Button("Set##goal",imgui.ImVec2(90,22)) then
                    activeGoal={active=true,target=gui.goalAmt[0],
                        earned_at_start=stats.total_earned,start_time=os.time()}
                    updateETAs(); saveAll(); rebuildHUD()
                    msg("Goal: "..fmtMoney(gui.goalAmt[0]),C.OK)
                end
                imgui.PopStyleColor(3)
            else
                local prog=stats.total_earned-activeGoal.earned_at_start
                local pct=math.min(1.0,prog/math.max(1,activeGoal.target))
                imgui.ProgressBar(pct,imgui.ImVec2(295,16),
                    string.format("%.1f%%  %s / %s",pct*100,fmtMoney(prog),fmtMoney(activeGoal.target)))
                row("Remain  :",hud.remain)
                row("ETA avg :",hud.eta_avg)
                row("ETA fast:",hud.eta_fast)
                imgui.Spacing()
                imgui.PushStyleColor(imgui.Col.Button,       imgui.ImVec4(0.40,0.09,0.09,0.90))
                imgui.PushStyleColor(imgui.Col.ButtonHovered,imgui.ImVec4(0.58,0.13,0.13,1.00))
                imgui.PushStyleColor(imgui.Col.ButtonActive, imgui.ImVec4(0.30,0.07,0.07,1.00))
                if imgui.Button("Cancel Goal",imgui.ImVec2(295,22)) then
                    activeGoal.active=false; updateETAs(); saveAll(); rebuildHUD()
                end
                imgui.PopStyleColor(3)
            end
        else hdr.goal=false end

        -- HUD SETTINGS
        if imgui.CollapsingHeader("HUD##hdr",hdr.hud and imgui.TreeNodeFlags.DefaultOpen or 0) then
            hdr.hud=true
            if tbtn(cfg.showHUD and "HUD  ON" or "HUD  OFF",cfg.showHUD,295,24) then
                cfg.showHUD=not cfg.showHUD; saveAll()
            end
            imgui.Spacing()
            local function tog2(l1,k1,l2,k2)
                if tbtn(l1..(cfg[k1] and " ON" or " OFF"),cfg[k1],143) then
                    cfg[k1]=not cfg[k1]; saveAll(); rebuildHudLines()
                end
                imgui.SameLine()
                if tbtn(l2..(cfg[k2] and " ON" or " OFF"),cfg[k2],143) then
                    cfg[k2]=not cfg[k2]; saveAll(); rebuildHudLines()
                end
            end
            tog2("Session","show_session","Total","show_total")
            tog2("Jobs","show_jobs","Speed","show_speed")
            tog2("Goal","show_goal","ETA","show_eta")
            if tbtn("Payout Chat Msg"..(cfg.show_payout_msg and " ON" or " OFF"),cfg.show_payout_msg,295) then
                cfg.show_payout_msg=not cfg.show_payout_msg; saveAll()
            end
            imgui.Spacing()
            imgui.Text("Size:"); imgui.SameLine(); imgui.SetNextItemWidth(215)
            if imgui.SliderInt("##fs",gui.fontSize,6,48) then
                cfg.fontSize=gui.fontSize[0]; rebuildFont(); saveAll()
            end
            imgui.SameLine(); imgui.TextDisabled(cfg.fontSize.."px")
            if tbtn(cfg.showBg and "BG Box ON" or "BG Box OFF",cfg.showBg,295) then
                cfg.showBg=not cfg.showBg; saveAll()
            end
            imgui.Spacing()
            local sw2,sh2=getScreenResolution()
            imgui.Text("X:"); imgui.SameLine(); imgui.SetNextItemWidth(255)
            if imgui.SliderInt("##px",gui.posX,0,sw2-10) then cfg.posX=gui.posX[0]; saveAll() end
            imgui.Text("Y:"); imgui.SameLine(); imgui.SetNextItemWidth(255)
            if imgui.SliderInt("##py",gui.posY,0,sh2-10) then cfg.posY=gui.posY[0]; saveAll() end
            imgui.TextDisabled("Y=0 is TOP.")
            imgui.Spacing()
            if imgui.Button("TL",imgui.ImVec2(44,20)) then
                cfg.posX=10;cfg.posY=10;gui.posX[0]=10;gui.posY[0]=10;saveAll() end
            imgui.SameLine()
            if imgui.Button("TR",imgui.ImVec2(44,20)) then
                cfg.posX=sw2-220;cfg.posY=10;gui.posX[0]=cfg.posX;gui.posY[0]=10;saveAll() end
            imgui.SameLine()
            if imgui.Button("BL",imgui.ImVec2(44,20)) then
                cfg.posX=10;cfg.posY=sh2-200;gui.posX[0]=10;gui.posY[0]=cfg.posY;saveAll() end
            imgui.SameLine()
            if imgui.Button("BR",imgui.ImVec2(44,20)) then
                cfg.posX=sw2-220;cfg.posY=sh2-200;gui.posX[0]=cfg.posX;gui.posY[0]=cfg.posY;saveAll() end
        else hdr.hud=false end

        -- UPDATE
        if imgui.CollapsingHeader("Update##hdr",hdr.update and imgui.TreeNodeFlags.DefaultOpen or 0) then
            hdr.update=true
            if upd.status~="" then
                local uc=upd.status:find("available") and imgui.ImVec4(1,0.85,0.2,1)
                       or upd.status:find("fail")     and imgui.ImVec4(1,0.4,0.4,1)
                       or imgui.ImVec4(0.4,0.9,0.4,1)
                imgui.TextColored(uc,upd.status)
            end
            if tbtn("Auto Update"..(cfg.auto_update and "  ON" or "  OFF"),cfg.auto_update,295,24) then
                cfg.auto_update=not cfg.auto_update; saveAll()
            end
            imgui.Spacing()
            if imgui.Button("Check Now",imgui.ImVec2(140,22)) then checkForUpdate(false) end
            imgui.SameLine(); imgui.TextDisabled("Current: v"..VERSION)
            if upd.newVer and not cfg.auto_update then
                imgui.Spacing()
                imgui.TextColored(imgui.ImVec4(1,0.85,0.2,1),"v"..upd.newVer.." is available!")
                imgui.TextColored(imgui.ImVec4(0.7,0.9,1,1),"Recent changes:")
                imgui.TextWrapped(upd.changelog or "")
                imgui.Spacing()
                imgui.PushStyleColor(imgui.Col.Button,       imgui.ImVec4(0.09,0.50,0.18,0.90))
                imgui.PushStyleColor(imgui.Col.ButtonHovered,imgui.ImVec4(0.14,0.68,0.26,1.00))
                imgui.PushStyleColor(imgui.Col.ButtonActive, imgui.ImVec4(0.07,0.38,0.14,1.00))
                if imgui.Button("Install v"..upd.newVer,imgui.ImVec2(295,24)) then
                    cfg.auto_update=true; saveAll(); checkForUpdate(true)
                end
                imgui.PopStyleColor(3)
            end
        else hdr.update=false end

        -- LOG
        if imgui.CollapsingHeader("Recent Earnings##hdr",hdr.log and imgui.TreeNodeFlags.DefaultOpen or 0) then
            hdr.log=true
            local s=math.max(1,#history-14)
            for i=#history,s,-1 do
                local e=history[i]
                imgui.TextDisabled(e.time.."  "); imgui.SameLine()
                imgui.TextColored(imgui.ImVec4(0.3,1,0.5,1),fmtMoney(e.amount))
            end
        else hdr.log=false end

        -- CREDITS
        if imgui.CollapsingHeader("Credits##hdr",hdr.credits and imgui.TreeNodeFlags.DefaultOpen or 0) then
            hdr.credits=true
            imgui.Spacing()
            imgui.TextColored(imgui.ImVec4(1,0.85,0.2,1),"Income Tracker Pro v"..VERSION)
            imgui.TextDisabled("Developed by Faisal Hazary")
            imgui.Spacing()
            imgui.TextDisabled("Support / Donate:")
            link("supportkori.com/dashboard/faisalhazary",
                "https://www.supportkori.com/dashboard/faisalhazary","Click to open support page")
            imgui.Spacing()
            imgui.TextDisabled("Bug Reports / Suggestions:")
            link("Discord: Faisal Hazary",
                "https://discord.com/users/757094020374593546","Click to open Discord profile")
            imgui.Spacing()
            imgui.TextDisabled("Source Code:")
            link("GitHub Repository",
                "https://github.com/faisalhazary/-HZG-IncomeTrackerPro","Click to open GitHub")
            imgui.Spacing()
        else hdr.credits=false end

        -- RESET
        if imgui.CollapsingHeader("Reset##hdr",hdr.reset and imgui.TreeNodeFlags.DefaultOpen or 0) then
            hdr.reset=true
            imgui.Spacing()
            imgui.PushStyleColor(imgui.Col.Button,       imgui.ImVec4(0.40,0.09,0.09,0.90))
            imgui.PushStyleColor(imgui.Col.ButtonHovered,imgui.ImVec4(0.58,0.13,0.13,1.00))
            imgui.PushStyleColor(imgui.Col.ButtonActive, imgui.ImVec4(0.30,0.07,0.07,1.00))
            if imgui.Button("Reset Session",imgui.ImVec2(143,22)) then
                sessionEarned=0;sessionJobs=0;lastPayoutTime=nil;lastPayoutTs=nil
                clearSession();updateETAs();rebuildHUD()
                msg("Session reset.",C.WARN)
            end
            imgui.SameLine()
            if imgui.Button("Reset ALL Data",imgui.ImVec2(143,22)) then
                stats={total_earned=0,total_jobs=0,fastest_interval=999999,
                    all_avg_interval=0,interval_count=0,intervals={}}
                history={};activeGoal={active=false,target=0,earned_at_start=0,start_time=0}
                sessionEarned=0;sessionJobs=0;lastPayoutTime=nil;lastPayoutTs=nil
                etaAvg="N/A";etaFast="N/A";clearSession();saveAll();rebuildHUD()
                msg("All data wiped.",C.WARN)
            end
            imgui.PopStyleColor(3)
        else hdr.reset=false end

        imgui.Spacing()
        imgui.TextDisabled("F8 / /it   |   /hudsize <n>   |   /itinfo")
        imgui.End()
    end
)

-- ============================================================
--  SAMP HOOKS
-- ============================================================
function samp.onServerMessage(color,text)
    local clean=text:gsub("{%x%x%x%x%x%x}","")
    local amount=clean:match("You received %$(%d+) for delivering the harvest")
    if amount then onJobComplete(tonumber(amount)); return end
    local rawAmt,recipient=clean:match("You have transferred %$([%d,]+) to (.+)'s account")
    if rawAmt then onTransfer(tonumber(rawAmt:gsub(",","")),recipient) end
end
function samp.onConnectionClose() clearSession() end
function script_exit()
    if not isSampAvailable or not isSampAvailable() then clearSession() end
end

-- ============================================================
--  MAIN
-- ============================================================
function main()
    while not isSampAvailable() do wait(100) end

    loadAll(); recomputeAvg()
    local restored=loadSession()
    if not restored then
        sessionEarned=0;sessionJobs=0;lastPayoutTime=nil;lastPayoutTs=nil;saveSession()
    end

    gui.posX[0]=cfg.posX; gui.posY[0]=cfg.posY; gui.fontSize[0]=cfg.fontSize
    updateETAs(); rebuildHUD(); rebuildFont()

    sampRegisterChatCommand("it",      function() gui.show[0]=not gui.show[0] end)
    sampRegisterChatCommand("goalhud", function() gui.show[0]=not gui.show[0] end)
    sampRegisterChatCommand("hudsize", function(args)
        local v=tonumber(args)
        if v and v>=6 and v<=48 then
            cfg.fontSize=v;gui.fontSize[0]=v;rebuildFont();saveAll()
            msg("Text size: "..v.."px",C.OK)
        else msg("Usage: /hudsize <6-48>",C.WARN) end
    end)
    sampRegisterChatCommand("itinfo", function()
        msg(string.format("Session:%s  Jobs:%d  Avg:%s  Best:%s",
            fmtMoney(sessionEarned),sessionJobs,
            fmtSec(stats.all_avg_interval),fmtSec(stats.fastest_interval)),C.INFO)
        msg("ETA avg:"..etaAvg.."  ETA fast:"..etaFast,C.GOLD)
    end)

    -- ETA refresh every 15s (inside its own thread, safe)
    lua_thread.create(function()
        while true do wait(15000); updateETAs(); rebuildHUD() end
    end)

    msg("Income Tracker v"..VERSION.." loaded. By Faisal Hazary",C.GOLD)
    msg("Type /it to open menu",C.BLUE)
    if restored then msg("Session restored: "..fmtMoney(sessionEarned).."  jobs:"..sessionJobs,C.OK) end

    lua_thread.create(function()
        wait(3000)
        if cfg.auto_update then checkForUpdate(true) end
    end)

    -- Main loop: only key input. HUD drawn by imgui.OnFrame above.
    while true do
        wait(0)
        if wasKeyPressed(0x77) then gui.show[0]=not gui.show[0] end
    end
end