-- AtlasCoop v0.7 - same-PC split-screen co-op for Little Nightmares Enhanced Edition
--
-- How it is used:
--   * main menu gets an extra row, "Совместная игра: включена / отключена"
--   * clicking it enables co-op: split screen + a second local player, created while still in
--     the menu. The engine then carries both players into the level and spawns both pawns.
--   * clicking it again turns co-op off.
--
-- Why the menu and not the level: creating the second player in a gameplay level is unreliable
-- (CreatePlayer returns nil depending on game state); creating it in the menu works every time
-- and both players spawn normally when the level starts.
--
-- Tested shape: Little Nightmares EE (repack), UE 4.27.2, UE4SS experimental-latest.

local UEHelpers = require("UEHelpers")
local GetGameplayStatics = UEHelpers.GetGameplayStatics
local GetGameMapsSettings = UEHelpers.GetGameMapsSettings

local TAG = "[AtlasCoop]"

local CONFIG = {
    -- the row follows the game's own UI language, see rowText() below
    rowTextOffRu = "Совместная игра: отключена",
    rowTextOnRu = "Совместная игра: включена",
    rowTextOffEn = "Coop Game: Off",
    rowTextOnEn = "Coop Game: On",
    snapDistance = 1500,
    fallDrop = 2000,
    fallGraceTicks = 2,
    heartbeat = 30,
    -- enemies keep a single "the player" pointer; hand it to whoever is closest. Switch only
    -- when the other player is closer by this many units, so the target does not flicker.
    aiSwitchMargin = 250,
    aiInterval = 0.4,
    -- the eye scanner's beam sweeps fast, its cone has to be sampled quicker than the AI
    eyeInterval = 0.25,
    -- doors that close themselves behind the first player strand the second one
    doorInterval = 1,
    doorHoldRadius = 1500,
}

local function log(fmt, ...)
    local ok, s = pcall(string.format, fmt, ...)
    print(TAG .. " " .. (ok and s or fmt) .. "\n")
end

local function isLive(o)
    if not o then return false end
    local ok, v = pcall(function() return o:IsValid() end)
    return ok and v
end

local function fullName(o)
    local ok, n = pcall(function() return o and o:GetFullName() end)
    return ok and n or "<nil>"
end

local function shortName(o)
    local n = fullName(o)
    return n:match("([^%.]+)$") or n or "?"
end

local function locOf(actor)
    local ok, v = pcall(function() return actor:K2_GetActorLocation() end)
    if ok and v then return v end
    return nil
end

local function shortLevel(n)
    local s = n and n:match("PLVL_[%w_]+")
    return s or (n or "?")
end

local function localPlayerArray(anyPc)
    local world, gi, lps = nil, nil, nil
    if not isLive(anyPc) then return nil end
    pcall(function() world = anyPc:GetWorld() end)
    if isLive(world) then pcall(function() gi = world.OwningGameInstance end) end
    if isLive(gi) then pcall(function() lps = gi.LocalPlayers end) end
    return lps
end

local function getPlayers()
    local list = {}
    local t = FindAllOf("PlayerController")
    if not t then return list end
    -- which slot of the local player list a controller sits in is the stable identity (slot 1 is
    -- the game own player, slot 2 the one the mod created); the controller id changes with the
    -- level, so sorting by it would swap the two players around
    local lps = nil
    for _, pc in pairs(t) do
        if isLive(pc) then lps = localPlayerArray(pc); break end
    end
    local slotOf = {}
    if lps then
        for i = 1, #lps do
            local lp, opc = nil, nil
            pcall(function() lp = lps[i] end)
            pcall(function() opc = lp.PlayerController end)
            if isLive(opc) then slotOf[fullName(opc)] = i end
        end
    end
    for _, pc in pairs(t) do
        if isLive(pc) then
            local id, pawn = -1, nil
            pcall(function() id = pc.Player.ControllerId end)
            pcall(function() pawn = pc.Pawn end)
            list[#list + 1] = { pc = pc, id = id, pawn = pawn, slot = slotOf[fullName(pc)] or 99 }
        end
    end
    table.sort(list, function(a, b)
        if a.slot ~= b.slot then return a.slot < b.slot end
        return a.id < b.id
    end)
    return list
end
local function isRealPawn(pawn)
    if not isLive(pawn) then return false end
    return not fullName(pawn):find("DefaultPawn")
end

-- menu language --------------------------------------------------------------------
-- The game's own menu labels are localized, so one of them tells us the UI language.

local uiIsRussian = nil

local function hasCyrillic(s)
    if type(s) ~= "string" or #s == 0 then return false end
    -- UTF-8 Cyrillic is a D0/D1 lead byte plus one continuation byte
    local _, n = s:gsub("[\208\209][\128-\191]", "")
    return n > 0
end

local function widgetText(w)
    if not isLive(w) then return nil end
    local s = nil
    pcall(function() s = w:GetText():ToString() end)
    if type(s) == "string" and #s > 0 then return s end
    return nil
end

-- Russian text is only used when the game itself is Russian: Cyrillic in a font without
-- those glyphs, or in a string that lost its encoding, shows up as garbage in the menu.
local function learnLanguage(w)
    if uiIsRussian ~= nil then return end
    local s = widgetText(w)
    if not s or #s < 2 then return end
    uiIsRussian = hasCyrillic(s)
    log("game UI language: %s (menu label '%s')", uiIsRussian and "ru" or "not ru", s)
end

local function rowText(on)
    if uiIsRussian == true then
        return on and CONFIG.rowTextOnRu or CONFIG.rowTextOffRu
    end
    return on and CONFIG.rowTextOnEn or CONFIG.rowTextOffEn
end

-- co-op state ----------------------------------------------------------------------

local coopEnabled = false
local rowButton, rowTextBlock = nil, nil
local rowForMenu = nil
local rowWasPressed = false
local rowArmAfterUnhover = false
local lastRowToggle = 0
local lastRowAttempt = 0
local lastCreate = 0
local adoptionChecked = false
local rowLabelSample = nil
local autoStartDone = false
local inMenuLevel = false
local lastWorld = ""
local levelSince = 0
local fallTicks = 0
local lastBeat = 0

local function setRowText()
    if not isLive(rowTextBlock) then return end
    local txt = rowText(coopEnabled)
    local ok, err = pcall(function() rowTextBlock:SetText(FText(txt)) end)
    if not ok then log("set row text failed: %s", tostring(err)) end
end

local function countPlayers()
    return #getPlayers()
end

-- number of local players the game instance holds; each one owns a gamepad and a viewport, and
-- the mod must never add more than the second one
local function localPlayerCount(players)
    local pc = players[1] and players[1].pc
    if not isLive(pc) then return 0 end
    local world, gi, lps, n = nil, nil, nil, 0
    pcall(function() world = pc:GetWorld() end)
    if isLive(world) then pcall(function() gi = world.OwningGameInstance end) end
    if not isLive(gi) then return 0 end
    pcall(function() lps = gi.LocalPlayers end)
    pcall(function() n = #lps end)
    return n
end

local function addSecondPlayer(reason, menuMode)
    local list = getPlayers()
    local pc1 = list[1] and list[1].pc
    if not pc1 then log("no player controller to create player 2 from"); return false end
    local have = localPlayerCount(list)
    if have >= 2 then
        -- a second local player already exists (its controller may just not be spawned yet):
        -- adding another one gives it a gamepad id nobody owns and a third viewport
        log("create skipped (%s): %d local player(s) already", reason, have)
        return false
    end
    local gms = GetGameMapsSettings()
    if not isLive(gms) then return false end
    lastCreate = os.time()
    gms.bUseSplitscreen = true
    gms.bOffsetPlayerGamepadIds = false
    -- controller id 1 is not always free (the engine can already hold a local player at that
    -- index, and CreatePlayer then returns nil), so walk a few slots until one takes
    local created = nil
    local gs = GetGameplayStatics()
    local before = localPlayerCount(list)
    log("addSecondPlayer (%s): %d local player(s) before", reason, before)
    for _, cid in ipairs({ 1, 2, 3 }) do
        local ok, res = pcall(function() return gs:CreatePlayer(pc1, cid, true) end)
        local after = localPlayerCount(list)
        log("CreatePlayer (%s id=%d) -> %s (local players %d -> %d)", reason, cid,
            ok and (isLive(res) and fullName(res) or "<nil>") or ("error " .. tostring(res)),
            before, after)
        if ok and isLive(res) then created = res; break end
        if after > before then
            -- the engine did create the local player, it just had no controller to hand back yet;
            -- trying the next id here is what used to leave a second ghost local player behind
            log("CreatePlayer (%s id=%d): local player created, controller not ready yet", reason, cid)
            break
        end
    end
    -- while the front-end is up keep a single view: otherwise the menu is split in half and
    -- the bottom half (player 2's world view) makes the white menu text unreadable
    if menuMode then gms.bUseSplitscreen = false end
    return isLive(created)
end

-- UGameplayStatics::RemovePlayer kills this build (the engine dies with a fatal error a moment
-- after it returns true, with or without bDestroyPawn and one player at a time), so turning co-op
-- off parks player 2 instead: the pawn is hidden and stops taking input, and the split view is
-- switched off. Turning co-op back on just reverses that.
local p2Parked = false

local function parkSecondPlayer(park)
    local list = getPlayers()
    for i = 2, #list do
        local p = list[i]
        if isLive(p.pawn) then
            pcall(function() p.pawn:SetActorHiddenInGame(park) end)
            pcall(function() p.pawn:SetActorEnableCollision(not park) end)
        end
        pcall(function() p.pc:SetIgnoreMoveInput(park) end)
        pcall(function() p.pc:SetIgnoreLookInput(park) end)
    end
    p2Parked = park
    log("second player %s (%d player(s) in the level)", park and "parked" or "reactivated", #list)
end

-- the local player list is what decides which gamepad drives which character, so it has to be
-- inspected at runtime: a local player left over from a failed creation keeps that pad slot
local function lpInfo(players)
    local pc = players[1] and players[1].pc
    if not isLive(pc) then log("lpinfo: no player controller"); return end
    local world, gi = nil, nil
    pcall(function() world = pc:GetWorld() end)
    if isLive(world) then pcall(function() gi = world.OwningGameInstance end) end
    log("lpinfo: world=%s gi=%s", isLive(world) and shortName(world) or "-", isLive(gi) and shortName(gi) or "-")
    if not isLive(gi) then return end
    local lps, n = nil, 0
    pcall(function() lps = gi.LocalPlayers end)
    pcall(function() n = #lps end)
    log("lpinfo: %d local player(s), %d controller(s) in the level", n, #players)
    for i = 1, math.min(n, 6) do
        local lp, cid, opc, pawn, loc = nil, -1, nil, nil, nil
        pcall(function() lp = lps[i] end)
        pcall(function() cid = lp.ControllerId end)
        pcall(function() opc = lp.PlayerController end)
        pcall(function() pawn = opc.Pawn end)
        pcall(function() loc = locOf(pawn) end)
        log("lpinfo: lp[%d] cid=%s pc=%s pawn=%s at %s", i, tostring(cid),
            isLive(opc) and shortName(opc) or "-",
            isLive(pawn) and shortName(pawn) or "-",
            loc and string.format("%.0f,%.0f,%.0f", loc.X, loc.Y, loc.Z) or "-")
    end
    for _, p in ipairs(players) do
        local cid, ignored, loc = -1, false, nil
        pcall(function() cid = p.pc.Player.ControllerId end)
        pcall(function() ignored = p.pc:IsMoveInputIgnored() end)
        pcall(function() loc = locOf(p.pawn) end)
        log("lpinfo: pc %s cid=%s pawn=%s moveIgnored=%s at %s", shortName(p.pc), tostring(cid),
            isLive(p.pawn) and shortName(p.pawn) or "-", tostring(ignored),
            loc and string.format("%.0f,%.0f,%.0f", loc.X, loc.Y, loc.Z) or "-")
    end
end

-- Diagnostics: walk player 2's controller id over 0..3 while the owner holds a direction on its
-- gamepad. The id under which the character starts moving is the one the game binds that pad to.
local cidTrial = nil

local function startCidTrial(players)
    local p2 = players[2]
    if not (p2 and isLive(p2.pc)) then log("cidcycle: no player 2 to test"); return end
    cidTrial = { pc = p2.pc, index = 0, nextAt = 0, lastLog = 0, base = nil, cid = nil }
    log("cidcycle: started, hold a direction on player 2's gamepad")
end

local function pumpCidTrial(now)
    if not cidTrial then return end
    if not isLive(cidTrial.pc) then log("cidcycle: controller gone"); cidTrial = nil; return end
    local loc = nil
    pcall(function() loc = locOf(cidTrial.pc.Pawn) end)
    if now >= cidTrial.nextAt then
        local cid = cidTrial.index % 4
        cidTrial.index = cidTrial.index + 1
        cidTrial.nextAt = now + 5
        cidTrial.cid = cid
        cidTrial.base = loc
        local pc = cidTrial.pc
        ExecuteInGameThread(function()
            local lp, ok = nil, false
            pcall(function() lp = pc.Player end)
            if isLive(lp) then
                ok = pcall(function() lp.ControllerId = cid end)
                local readback = nil
                pcall(function() readback = lp.ControllerId end)
                log("cidcycle: trial cid=%d writeOk=%s readback=%s", cid, tostring(ok), tostring(readback))
            else
                log("cidcycle: trial cid=%d has no local player", cid)
            end
        end)
    end
    if loc and cidTrial.base then
        local d = (loc.X - cidTrial.base.X) ^ 2 + (loc.Y - cidTrial.base.Y) ^ 2
        if d > 25 then
            log("cidcycle: MOVED with cid=%s (p2 at %.0f,%.0f)", tostring(cidTrial.cid), loc.X, loc.Y)
            local lp = nil
            pcall(function() lp = cidTrial.pc.Player end)
            if isLive(lp) then
                local keep = cidTrial.cid
                pcall(function() lp.ControllerId = keep end)
                log("cidcycle: kept cid=%s", tostring(keep))
            end
            cidTrial = nil
            return
        end
    end
    if now - cidTrial.lastLog >= 1.0 then
        cidTrial.lastLog = now
        log("cidcycle: cid=%s pos p2=%s", tostring(cidTrial.cid),
            loc and string.format("%.0f,%.0f", loc.X, loc.Y) or "-")
    end
end

-- Diagnostics: report which player controller actually receives a given key/gamepad button. The
-- engine routes every input event to the local player whose ControllerId matches the device, so
-- this tells us which device drives which character without needing anybody to watch the screen.
local keyProbe = nil
local PROBE_KEYS = { "W", "A", "S", "D", "SpaceBar",
    "Gamepad_FaceButton_Bottom", "Gamepad_FaceButton_Right",
    "Gamepad_LeftTrigger", "Gamepad_RightTrigger", "Gamepad_LeftStick_Up" }

local function makeKey(name)
    -- UE4SS exposes the engine key list as the global Key table; FKey() cannot be built by hand
    local ok, k = pcall(function() return Key[name] end)
    if ok and k ~= nil then return k, "Key[]" end
    local ok2, k2 = pcall(function() return FKey(name) end)
    if ok2 and k2 ~= nil then return k2, "FKey(str)" end
    local ok3, k3, err3 = pcall(function()
        local key = FKey()
        key.KeyName = FName(name)
        return key
    end)
    if ok3 and k3 ~= nil then return k3, "FKey+FName" end
    return nil, tostring(err3)
end

local function startKeyProbe()
    if keyProbe then
        keyProbe = nil
        log("keylog: stopped")
        return
    end
    keyProbe = { keys = {}, last = 0, state = {} }
    for _, name in ipairs(PROBE_KEYS) do
        local k, how = makeKey(name)
        log("keylog: key %s via %s -> %s", name, tostring(how), tostring(k ~= nil))
        if k ~= nil then keyProbe.keys[#keyProbe.keys + 1] = { name = name, key = k } end
    end
    log("keylog: started, %d key(s)", #keyProbe.keys)
end
local function pumpKeyProbe(now, players)
    if not keyProbe then return end
    if now - keyProbe.last < 0.25 then return end
    keyProbe.last = now
    for i, p in ipairs(players) do
        local parts = {}
        for _, kk in ipairs(keyProbe.keys) do
            local down = false
            pcall(function() down = p.pc:IsInputKeyDown(kk.key) end)
            parts[#parts + 1] = kk.name .. "=" .. (down and "1" or "0")
        end
        local line = table.concat(parts, " ")
        if keyProbe.state[i] ~= line then
            keyProbe.state[i] = line
            log("keylog: p%d %s", i, line)
        end
    end
end

-- The local player's ControllerId is the pad the engine feeds it: pad n reaches the local player
-- whose ControllerId is n (the engine looks the player up per input event). The game gives its own
-- player an id of its own choosing (0 in the menu, 1 after a level load) and re-applies it, so the
-- mod does not fight it: player 1 keeps the id the game gave it and player 2 takes the other one of
-- {0, 1}. The engine re-creates the local players on every level load, so this is re-checked.
local lastIdCheck = 0

local function ensureControllerIds(players)
    local now = os.clock()
    if now - lastIdCheck < 2 then return end
    lastIdCheck = now
    if #players < 2 then return end
    local lps = {}
    for _, p in ipairs(players) do
        local lp = nil
        pcall(function() lp = p.pc.Player end)
        if isLive(lp) then lps[#lps + 1] = lp end
    end
    if #lps < 2 then return end
    local p1cid, p2cid = nil, nil
    pcall(function() p1cid = lps[1].ControllerId end)
    pcall(function() p2cid = lps[2].ControllerId end)
    local want = (p1cid == 0) and 1 or 0
    if p2cid == want then return end
    local ok = pcall(function() lps[2].ControllerId = want end)
    local readback = nil
    pcall(function() readback = lps[2].ControllerId end)
    log("controller ids: p1=%s p2=%s -> %d (writeOk=%s readback=%s)",
        tostring(p1cid), tostring(p2cid), want, tostring(ok), tostring(readback))
end
-- set later, where the split-screen aspect code lives: puts the cameras back to the game's own
-- 16:9 framing when the second viewport goes away
local restoreAspect = nil

local function setCoop(on, reason)
    if on == coopEnabled then
        log("co-op already %s (%s)", tostring(on), reason)
        return
    end
    ExecuteInGameThread(function()
        local gms = GetGameMapsSettings()
        if on then
            if countPlayers() < 2 then addSecondPlayer(reason, inMenuLevel) end
            if isLive(gms) and not inMenuLevel then gms.bUseSplitscreen = true end
            if p2Parked then parkSecondPlayer(false) end
        else
            parkSecondPlayer(true)
            if isLive(gms) then gms.bUseSplitscreen = false end
            if restoreAspect then pcall(restoreAspect) end
        end
        coopEnabled = on
        setRowText()
    end)
    coopEnabled = on
    adoptionChecked = true
    log("co-op %s (%s)", on and "ON" or "OFF", reason)
end

-- main menu row --------------------------------------------------------------------

local function findMainMenu()
    local main = nil
    pcall(function() main = FindFirstOf("WID_BP_AtlasMainMenu_C") end)
    return isLive(main) and main or nil
end

local function findButtonsBox(main)
    local box = nil
    pcall(function() box = main.ButtonsVBox end)
    if isLive(box) then return box end
    -- fallback: first VerticalBox child of the menu canvas
    local root = nil
    pcall(function() root = main.WidgetTree.RootWidget end)
    if isLive(root) then
        local n = 0
        pcall(function() n = root:GetChildrenCount() end)
        for i = 0, (tonumber(n) or 0) - 1 do
            local child = nil
            pcall(function() child = root:GetChildAt(i) end)
            local cls = ""
            pcall(function() cls = child:GetClass():GetFName():ToString() end)
            if cls:find("VerticalBox") then return child end
        end
    end
    return nil
end

local function ensureMenuRow()
    local main = findMainMenu()
    if not main then return end
    -- UE4SS hands out a fresh wrapper for the same UObject, so compare by full name
    local mainKey = fullName(main)
    if rowForMenu == mainKey then
        if isLive(rowButton) then return end
        rowForMenu = nil   -- rows were destroyed with the menu; allow one rebuild
    end
    if os.time() - lastRowAttempt < 1 then return end

    local box = findButtonsBox(main)
    if not isLive(box) then return end

    -- classes taken from live widgets so we never guess a path; the button must be the plain
    -- UMG UButton - constructing the game's AtlasMenuButton natively crashes the renderer
    local sampleText, sampleMenuButton = nil, nil
    pcall(function() sampleText = FindFirstOf("TextBlock") end)
    pcall(function() sampleMenuButton = FindFirstOf("AtlasMenuButton") end)
    if not isLive(sampleText) then
        log("cannot resolve widget classes yet")
        return
    end

    local tbClass, btnClass = nil, nil
    pcall(function() tbClass = sampleText:GetClass() end)
    pcall(function() btnClass = StaticFindObject("/Script/UMG.Button") end)
    if not (isLive(tbClass) and isLive(btnClass)) then
        log("button class not resolved (got %s)", fullName(btnClass))
        return
    end
    lastRowAttempt = os.time()

    -- typography reference: a real menu label (the menu uses a custom font with wide spacing)
    local labelSample = nil
    pcall(function() labelSample = main.StartGameText end)
    if not isLive(labelSample) then
        pcall(function() labelSample = main.ResumeButtonText end)
    end
    if not isLive(labelSample) then
        local n = 0
        pcall(function() n = box:GetChildrenCount() end)
        for i = 0, (tonumber(n) or 0) - 1 do
            local child = nil
            pcall(function() child = box:GetChildAt(i) end)
            if isLive(child) then
                local cn = 0
                pcall(function() cn = child:GetChildrenCount() end)
                for j = 0, (tonumber(cn) or 0) - 1 do
                    local leaf = nil
                    pcall(function() leaf = child:GetChildAt(j) end)
                    local f = nil
                    pcall(function() f = leaf:GetFont() end)
                    if f then labelSample = leaf break end
                end
            end
            if isLive(labelSample) then break end
        end
    end
    if isLive(labelSample) then
        log("styling row from label %s", fullName(labelSample))
        local lf, lfErr = nil, nil
        local okFont = pcall(function() lf = labelSample.Font end)
        if not (okFont and lf) then
            pcall(function() lf = labelSample:GetFont() end)
        end
        if lf then
            local fo, tf, sz, ls = nil, nil, nil, nil
            pcall(function() fo = lf.FontObject end)
            pcall(function() tf = lf.TypefaceFontName end)
            pcall(function() sz = lf.Size end)
            pcall(function() ls = lf.LetterSpacing end)
            log("label font: object=%s typeface=%s size=%s spacing=%s",
                fullName(fo), tostring(tf), tostring(sz), tostring(ls))
        else
            log("label has no readable font")
        end
    else
        log("no menu label to copy the font from")
    end

    -- the row's language: read a game label before the text is built
    if isLive(labelSample) then learnLanguage(labelSample) end
    if uiIsRussian == nil then pcall(function() learnLanguage(main.StartGameText) end) end
    if uiIsRussian == nil then pcall(function() learnLanguage(main.ResumeButtonText) end) end
    if uiIsRussian == nil then learnLanguage(sampleText) end
    if uiIsRussian == nil then log("game UI language: unknown, keeping the English row") end

    ExecuteInGameThread(function()
        local ok, err = pcall(function()
            local btn = StaticConstructObject(btnClass, main, FName("AtlasCoopButton"), 0, nil)
            local tb = StaticConstructObject(tbClass, btn, FName("AtlasCoopButtonText"), 0, nil)
            if not isLive(btn) or not isLive(tb) then error("construct returned nil") end
            tb:SetText(FText(rowText(coopEnabled)))

            -- copy the menu's typography, colour, shadow and justification
            if isLive(labelSample) then
                local lf = nil
                pcall(function() lf = labelSample.Font end)
                if not lf then pcall(function() lf = labelSample:GetFont() end) end
                if lf then
                    local okSet, setErr = pcall(function() tb:SetFont(lf) end)
                    if not okSet then
                        pcall(function() tb.Font = lf end)
                    end
                    pcall(function() tb:SetColorAndOpacity(labelSample:GetColorAndOpacity()) end)
                    pcall(function() tb:SetShadowOffset(labelSample:GetShadowOffset()) end)
                    pcall(function() tb:SetShadowColorAndOpacity(labelSample:GetShadowColorAndOpacity()) end)
                    pcall(function() tb:SetJustification(labelSample:GetJustification()) end)
                    local rf = nil
                    pcall(function() rf = tb.Font end)
                    if rf then
                        local fo2, tf2, sz2, ls2 = nil, nil, nil, nil
                        pcall(function() fo2 = rf.FontObject end)
                        pcall(function() tf2 = rf.TypefaceFontName end)
                        pcall(function() sz2 = rf.Size end)
                        pcall(function() ls2 = rf.LetterSpacing end)
                        log("row font after copy (ok=%s err=%s): object=%s typeface=%s size=%s spacing=%s",
                            tostring(okSet), tostring(setErr), fullName(fo2), tostring(tf2), tostring(sz2), tostring(ls2))
                    end
                end
            end

            local contentOk, contentErr = pcall(function() btn:SetContent(tb) end)
            if not contentOk then
                local addOk, addErr = pcall(function() btn:AddChild(tb) end)
                if not addOk then
                    error("attach failed: " .. tostring(contentErr) .. " / " .. tostring(addErr))
                end
            end
            -- borrow the look of a real menu button when the style struct is assignable
            if isLive(sampleMenuButton) then
                pcall(function() btn.WidgetStyle = sampleMenuButton.WidgetStyle end)
            end
            -- put the row right after "Продолжить" so it sits in the dark part of the layout
            local placed = false
            pcall(function()
                box:InsertChildAt(1, btn)
                placed = true
            end)
            if not placed then
                local slot, slotOk = nil, pcall(function() slot = box:AddChildToVerticalBox(btn) end)
                if not slotOk or not slot then box:AddChild(btn) end
                if isLive(slot) then
                    pcall(function() slot:SetPadding(FMargin(0, 6, 0, 6)) end)
                    pcall(function() slot:SetHorizontalAlignment(1) end)
                end
            end
            rowButton, rowTextBlock = btn, tb
            rowLabelSample = labelSample
            rowForMenu = mainKey
            rowWasPressed = false
            rowArmAfterUnhover = true
            log("menu row added (inserted=%s)", tostring(placed))
        end)
        if not ok then log("menu row failed: %s", tostring(err)) end
    end)
end

local debugPolls = 0

local function pollMenuRow()
    if not isLive(rowButton) then return end
    local pressed, hovered = false, false
    pcall(function() pressed = rowButton:IsPressed() end)
    pcall(function() hovered = rowButton:IsHovered() end)
    -- IsPressed alone reported phantom presses in this build, so a click counts only while the
    -- pointer actually sits on the row, once, and not again until the pointer leaves it.
    local click = (pressed == true) and (hovered == true)
    if debugPolls < 8 then
        debugPolls = debugPolls + 1
        log("row state: pressed=%s hovered=%s click=%s", tostring(pressed), tostring(hovered), tostring(click))
    end
    if click and not rowWasPressed and not rowArmAfterUnhover
        and (os.clock() - lastRowToggle) > 1.5 then
        lastRowToggle = os.clock()
        rowArmAfterUnhover = true
        log("row clicked")
        setCoop(not coopEnabled, "menu row")
    end
    rowWasPressed = click
    if not hovered then rowArmAfterUnhover = false end
end

-- gameplay upkeep ------------------------------------------------------------------

local function teleportToP1(p2pawn)
    local list = getPlayers()
    local p1 = list[1]
    if not (p1 and isRealPawn(p1.pawn)) then return end
    local l1 = locOf(p1.pawn)
    if not l1 then return end
    pcall(function() p2pawn:K2_SetActorLocationAndRotation(l1, p1.pawn:K2_GetActorRotation(), false, {}, false) end)
    log("player 2 moved to player 1")
end

-- co-op gameplay: enemies and doors -------------------------------------------------
--
-- The game's enemies are driven by AAtlasAICharacter (Janitor, Chef), AAtlasGuestAI and
-- AAtlasLeechAI. Each of them keeps ONE player pointer (Player / AtlasPlayerPawn) that is
-- filled in when the player spawns - player 2 never reaches it, so enemies ignore him.
-- Every few hundred milliseconds we point that field at whichever player is closest.

local lastAiTick = 0
local lastDoorTick = 0
local lastEyeTick = 0
local aiLogCount = 0

-- defined at the bottom of the file, needed here (Lua locals must be declared before use)
local pollTestCmd, watchDamage, holdParked
local lastCmdPoll = 0
local parked = nil

local function isRealObject(o)
    if not o then return false end
    if tostring(o):find("TrivialObject") then return false end
    return isLive(o)
end

local function distTo(actor, other)
    local a, b = locOf(actor), locOf(other)
    if not (a and b) then return nil end
    local dx, dy, dz = a.X - b.X, a.Y - b.Y, a.Z - b.Z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- which UPROPERTY of this actor points at the player? (reading a missing property returns a
-- TrivialObject placeholder instead of nil in this UE4SS build)
local function aiPlayerProp(ai)
    local p = nil
    pcall(function() p = ai.Player end)
    if isRealObject(p) then return "Player" end
    pcall(function() p = ai.AtlasPlayerPawn end)
    if isRealObject(p) then return "AtlasPlayerPawn" end
    -- property exists but is still null: decide by class name
    local cn = ""
    pcall(function() cn = ai:GetClass():GetFName():ToString() end)
    if cn:find("Leech") then return "AtlasPlayerPawn" end
    local hasField = false
    pcall(function() hasField = type(ai.DistanceToPlayer) == "number" end)
    if hasField or cn:find("Janitor") or cn:find("Chef") or cn:find("Guest") then return "Player" end
    return nil
end

local function retargetEnemies(players)
    local list = {}
    for _, a in pairs(FindAllOf("Pawn") or {}) do
        if isLive(a) then
            local isPlayer = false
            for _, p in ipairs(players) do
                if fullName(p.pawn) == fullName(a) then isPlayer = true break end
            end
            if not isPlayer then
                local prop = aiPlayerProp(a)
                if prop then list[#list + 1] = { ai = a, prop = prop } end
            end
        end
    end

    for _, entry in ipairs(list) do
        local ai, prop = entry.ai, entry.prop
        local pos = locOf(ai)
        if pos then
            local best, bestD = nil, math.huge
            for _, p in ipairs(players) do
                local d = distTo(ai, p.pawn)
                if d and d < bestD then best, bestD = p.pawn, d end
            end
            if best then
                local current = nil
                pcall(function() current = ai[prop] end)
                -- Only retarget an enemy the game has already initialised (it has a player).
                -- Writing the pointer into an AI that never received OnPlayerSpawn crashes the
                -- game a few seconds later (seen with a test-spawned Janitor).
                if isRealObject(current) then
                    local same = fullName(current) == fullName(best)
                    if not same then
                        local curD = distTo(ai, current)
                        -- keep the current target unless the other player is clearly closer
                        if curD and bestD + CONFIG.aiSwitchMargin < curD then
                            local ok = pcall(function() ai[prop] = best end)
                            if ok and aiLogCount < 60 then
                                aiLogCount = aiLogCount + 1
                                log("enemy %s now tracks %s (%.0f units, was %s)",
                                    fullName(ai):match("([^%.]+)$"), fullName(best):match("([^%.]+)$"),
                                    bestD, fullName(current):match("([^%.]+)$"))
                            end
                        end
                    end
                end
            end
        end
    end
end

-- The eye scanner (BP_EyeScanner_C, the "stand in the light and you turn to stone" trap).
--
-- The game's own detection only ever considers player 1. Measured: player 2 pinned dead centre
-- in the beam (0.8 deg off the axis, 11 m away) with eye.AtlasPlayerReference pointed straight
-- at him still gave ActorInSight=false and VisibleActors=0, so both of the eye's player
-- pointers are useless for us -- it never looks at anybody but the first player. The
-- petrification is therefore driven from here: every awake eye petrifies every player standing
-- inside its light cone, exactly the way the game does it for player 1 (the same
-- DamageComponent:SetPetrified call the eye makes), and a player whose meter fills dies with
-- the game's own petrification death type.
-- Measured: the eye's SpotLightEyeCone component has OuterConeAngle 25.5 / InnerConeAngle 24.5 and
-- BP_EyeScanner.SpotlightAngle is 25, i.e. the same number. Both are half angles in Unreal terms
-- (a hard edged +/-25 deg cone), so SpotlightAngle is used as is.
-- The beam is a cone *volume*, not an infinite cone: the BP stretches SM_HollowPointyCylinder from
-- the eye to the point it is looking at, so the light ends at the base plane. Players past that
-- plane stand in the dark and must not petrify (observed: p2 turned to stone at 12 deg / 1791 u
-- while the beam only reached the floor ~1236 u away).
local EYE_CONE_DEFAULT = 25.0
local EYE_CONE_SLACK = 4.0     -- hysteresis, the beam sweeps past a player in a few frames
local EYE_BEAM_SLACK = 120.0   -- the beam mesh ends at its target point, allow a little overshoot
local EYE_MAX_DIST = 2500.0
local EYE_DEATH_PETRIFICATION = 7
-- keyed by eye|player: { armed = saw the meter below full while in the beam }
local petrifiedByUs = {}

local function isPlayerPawn(a)
    if not isRealObject(a) then return false end
    local n = fullName(a)
    return n:find("BP_Player_C", 1, true) ~= nil or n:find("AtlasPlayer", 1, true) ~= nil
end

local function baseName(o)
    return (fullName(o):match("([^%.%/:]+)$")) or "?"
end

local function vsub(a, b)
    return { X = a.X - b.X, Y = a.Y - b.Y, Z = a.Z - b.Z }
end

local function vlen(v)
    return math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z)
end

local function vnorm(v)
    local l = vlen(v)
    if l < 0.0001 then return nil end
    return { X = v.X / l, Y = v.Y / l, Z = v.Z / l }
end

-- returns angle (degrees) between the beam axis and the eye->point vector, and the distance
local function beamAngle(origin, axis, point)
    local v = vsub(point, origin)
    local d = vlen(v)
    local u = vnorm(v)
    if not u then return -1, 0 end
    local c = axis.X * u.X + axis.Y * u.Y + axis.Z * u.Z
    if c > 1 then c = 1 elseif c < -1 then c = -1 end
    return math.deg(math.acos(c)), d
end

-- The visible beam is the SM_HollowPointyCylinder mesh (the SpotLightEyeCone light has Intensity 0, it
-- is only a marker). The mesh is attached to that light component and stretched from the eye to the
-- point the eye looks at, so the light component gives us both the instantaneous aim (no smoothing
-- lag) and the cone angle (OuterConeAngle == SpotlightAngle + 0.5).
local eyeLampByName = {}

local function eyeLamp(eye)
    local en = fullName(eye)
    local l = eyeLampByName[en]
    if l == nil then
        eyeLampByName[en] = false
        local tag = en:match("([^%.]+)$")
        for _, c in pairs(FindAllOf("SpotLightComponent") or {}) do
            local nm = nil
            pcall(function() nm = c:GetFullName() end)
            if nm and nm:find(tag, 1, true) then
                local ic = nil
                pcall(function() ic = tonumber(c.InnerConeAngle) end)
                if ic and ic > 0 then
                    eyeLampByName[en] = c
                    break
                end
            end
        end
        l = eyeLampByName[en]
    end
    if l and isLive(l) then return l end
    return nil
end

-- returns axis, origin, beam length, cone half angle (degrees)
local function eyeBeam(eye)
    local el = locOf(eye)
    if not el then return nil, nil, 0, 0 end
    local axis, origin, beamLen, outer = nil, el, 0, 0
    local lamp = eyeLamp(eye)
    if lamp then
        local lc = nil
        pcall(function() lc = lamp:K2_GetComponentLocation() end)
        if lc and lc.X then origin = lc end
        local f = nil
        pcall(function() f = lamp:GetForwardVector() end)
        if f and f.X then axis = vnorm(f) end
        local o = nil
        pcall(function() o = tonumber(lamp.OuterConeAngle) end)
        if o and o > 0 then outer = o end
    end
    local p = nil
    pcall(function() p = eye.CurrentTargetPositionSmoothed end)
    if p and p.X then
        local d = vlen(vsub(p, origin))
        if d > 50 then beamLen = d end
    end
    if not axis then
        local cur = nil
        pcall(function() cur = eye.CurrentTarget end)
        if isLive(cur) then
            local tl = locOf(cur)
            if tl then axis = vnorm(vsub(tl, origin)) end
        end
    end
    return axis, origin, beamLen, outer
end

local function petrifyEyes(players)
    for _, eye in pairs(FindAllOf("BP_EyeScanner_C") or {}) do
        if isLive(eye) then
            local en = fullName(eye)
            local state = nil
            pcall(function() state = eye.EyeState end)
            local axis, el, beamLen, lampOuter = nil, nil, 0, 0
            if state == 1 or state == 2 then axis, el, beamLen, lampOuter = eyeBeam(eye) end
            local gain, coneDeg = 0.3, EYE_CONE_DEFAULT
            local g, sa = nil, nil
            pcall(function() g = eye.PetrificationGainRate end)
            if tonumber(g) and tonumber(g) > 0 then gain = tonumber(g) end
            pcall(function() sa = eye.SpotlightAngle end)
            sa = tonumber(sa)
            if lampOuter > 0 then coneDeg = lampOuter
            elseif sa and sa > 0 then coneDeg = sa end
            local gameTarget = nil
            pcall(function() gameTarget = eye.AtlasPlayerReference end)
            local gameTargetName = isLive(gameTarget) and fullName(gameTarget) or nil
            for i = 1, #players do
                local pawn = players[i].pawn
                local key = en .. "|" .. fullName(pawn)
                local dmg = nil
                pcall(function() dmg = pawn.DamageComponent end)
                if isLive(dmg) and gameTargetName ~= fullName(pawn) then
                    local inBeam, ang, d, t = false, -1, 0, 0
                    local pl = locOf(pawn)
                    if axis and el and pl then
                        ang, d = beamAngle(el, axis, pl)
                        local limit = petrifiedByUs[key] and (coneDeg + EYE_CONE_SLACK) or coneDeg
                        -- distance measured along the beam axis: the cone stops at its base plane
                        t = d * math.cos(math.rad(math.max(ang, 0)))
                        inBeam = ang >= 0 and ang <= limit and d <= EYE_MAX_DIST
                            and t <= beamLen + EYE_BEAM_SLACK
                    end
                    if inBeam then
                        local amount = 0
                        pcall(function() amount = dmg:GetPetrificationAmount() end)
                        amount = tonumber(amount) or 0
                        local mark = petrifiedByUs[key]
                        if not mark then
                            mark = { armed = amount < 0.9 }
                            petrifiedByUs[key] = mark
                            log("eye %s petrifies p%d (ang=%.1f dist=%.0f t=%.0f beam=%.0f gain=%.2f)",
                                baseName(eye), i, ang, d, t, beamLen, gain)
                        elseif amount < 0.9 then
                            mark.armed = true
                        end
                        if amount >= 0.99 and mark.armed then
                            -- the eye kills player 1 itself once the meter is full, nobody kills
                            -- player 2: use the game's own petrification death
                            local dir = vnorm(vsub(el, pl)) or { X = 0, Y = 0, Z = 0 }
                            local okKill = pcall(function() dmg:Kill(EYE_DEATH_PETRIFICATION, dir) end)
                            if not mark.killed then
                                mark.killed = true
                                log("eye %s turned p%d to stone (kill ok=%s, ang=%.1f)", baseName(eye), i, tostring(okKill), ang)
                            end
                        else
                            pcall(function() dmg:SetPetrified(gain) end)
                        end
                    elseif petrifiedByUs[key] then
                        petrifiedByUs[key] = nil
                        pcall(function() dmg:ClearPetrified() end)
                        log("eye %s released p%d (left the beam)", baseName(eye), i)
                    end
                end
            end
        end
    end
end

-- Doors close themselves when a player has walked through them (bCloseWhenOpenTowards /
-- bCloseWhenOpenAway). With two players that slams the door in front of the second one, so
-- the automatic closing is switched off and the doors stay where the players leave them.
--
-- The plain wooden door (BP_PlainWoodDoor) is a physics door on a hinge: its angle is changed
-- by simulated physics, not by SetDoorAngle, and it locks itself once it has swung shut
-- (`LockDoor` in the log, then IsDoorSimulatingPhysics() == false). The flags alone do not
-- keep it open, so a door that is open while a player is anywhere near it is frozen in place
-- with SetDoorSimulatePhysics(false); physics comes back once both players have walked away.
local doorsHeld = {}
-- angle each door rests at while nobody is near it, used as its "closed" position
local doorRest = {}
local lastDoorError = nil
local lastDoorCount = -1

local function doorNear(d, players)
    local owner = nil
    pcall(function() owner = d:GetOwner() end)
    if not isLive(owner) then return false end
    for _, p in ipairs(players) do
        local dd = distTo(owner, p.pawn)
        if dd and dd < CONFIG.doorHoldRadius then return true end
    end
    return false
end

local function tuneDoors(players)
    local n = 0
    for _, d in pairs(FindAllOf("AtlasDoor") or {}) do
        if isLive(d) then
            n = n + 1
            local key = fullName(d)
            pcall(function() d.bCloseWhenOpenTowards = false end)
            pcall(function() d.bCloseWhenOpenAway = false end)

            local angle, locked, sim = 0, false, false
            pcall(function() angle = d:GetDoorAngle() end)
            pcall(function() locked = d:IsDoorLocked() end)
            pcall(function() sim = d:IsDoorSimulatingPhysics() end)
            angle = tonumber(angle) or 0
            local near = doorNear(d, players)

            -- ClosedAngle/FullyOpenAngle cannot be trusted here: most doors report 0.5/1.0, so
            -- snapping to "fully open" would close them. The resting angle is learned instead, and
            -- a door counts as open once it has swung well away from it. The old test (absolute
            -- angle > 8 degrees) treated a door that rests slightly ajar - 12 degrees - as open and
            -- froze it before the players could push it, which is why doors stopped opening.
            local rest = doorRest[key]
            if rest == nil then
                rest = angle
                doorRest[key] = rest
            elseif not near and not doorsHeld[key] and math.abs(angle - rest) < 20 then
                rest = angle
                doorRest[key] = rest
            end
            local open = math.abs(angle - rest) >= 65

            if open and near and not locked then
                if not doorsHeld[key] then
                    log("door held open: %s at %.0f degrees", shortName(d), angle)
                end
                if sim then pcall(function() d:SetDoorSimulatePhysics(false) end) end
                doorsHeld[key] = true
            elseif doorsHeld[key] then
                pcall(function() d:SetDoorSimulatePhysics(true) end)
                doorsHeld[key] = nil
                log("door released: %s", shortName(d))
            end
        end
    end
    if n ~= lastDoorCount then
        lastDoorCount = n
        log("doors: %d (automatic closing off)", n)
    end
end

-- Diagnostic: everything the door state machine keeps about the doors around the players. Doors are
-- components (UAtlasDoor) on the door actor, so the owner is what has the location.
local function doorInfo(players, all)
    local n = 0
    for _, d in pairs(FindAllOf("AtlasDoor") or {}) do
        if isLive(d) then
            local owner = nil
            pcall(function() owner = d:GetOwner() end)
            if isLive(owner) then
                local d1 = distTo(owner, players[1] and players[1].pawn)
                local d2 = distTo(owner, players[2] and players[2].pawn)
                if all or (d1 and d1 < 1600) or (d2 and d2 < 1600) then
                    n = n + 1
                    local angle, closed, full, locked, sim, auto, push, closeT, closeA = nil, nil, nil, nil, nil, nil, nil, nil, nil
                    pcall(function() angle = d:GetDoorAngle() end)
                    pcall(function() closed = d.ClosedAngle end)
                    pcall(function() full = d.FullyOpenAngle end)
                    pcall(function() locked = d:IsDoorLocked() end)
                    pcall(function() sim = d:IsDoorSimulatingPhysics() end)
                    pcall(function() auto = d.bEnableAutomaticState end)
                    pcall(function() push = d.bAllowAutomaticPushing end)
                    pcall(function() closeT = d.bCloseWhenOpenTowards end)
                    pcall(function() closeA = d.bCloseWhenOpenAway end)
                    local loc = locOf(owner)
                    log("door %d: %s at %s d1=%s d2=%s angle=%s closed=%s full=%s locked=%s sim=%s auto=%s push=%s closeT=%s closeA=%s",
                        n, shortName(owner),
                        loc and string.format("%.0f,%.0f,%.0f", loc.X, loc.Y, loc.Z) or "?",
                        d1 and string.format("%.0f", d1) or "?", d2 and string.format("%.0f", d2) or "?",
                        tostring(angle), tostring(closed), tostring(full), tostring(locked), tostring(sim),
                        tostring(auto), tostring(push), tostring(closeT), tostring(closeA))
                end
            end
        end
    end
    log("doorinfo: %d door(s) within reach", n)
end

-- split-screen aspect ---------------------------------------------------------------
-- The game pins its cameras to a wide cinematic frame. A split-screen half is 1280x360
-- (3.556:1), so an unconstrained camera stretches that frame over the half and cuts the
-- bottom of the picture - and the player character walks in the lower part of the frame,
-- so a player regularly loses their own feet. Forcing every camera component to a 16:9
-- constrained aspect makes the engine letterbox each half into a true 16:9 picture with
-- side bars: exactly the composition the game was designed for, whole character on screen.
-- This is the only framing lever the game does not overwrite: FOVAngle, POV.FOV,
-- DefaultFOV, ViewTargetOffset, OffCenterProjectionOffset, camera transforms,
-- SetCameraZoomModifier and SetExternal were all tested and are ignored by the game's own
-- camera manager (see games/little-nightmares/NOTES.md).
local SPLIT_VIEW_ASPECT = 16.0 / 9.0

local lastAspectTick = 0
local aspectLogAt = 0

-- put every camera back to the framing the game ships with: no forced ratio
restoreAspect = function()
    for _, cc in pairs(FindAllOf("CameraComponent") or {}) do
        if isLive(cc) then
            pcall(function() cc.bConstrainAspectRatio = false end)
        end
    end
end

local function fixSplitAspect(players)
    local total, retuned = 0, 0
    for _, cc in pairs(FindAllOf("CameraComponent") or {}) do
        if isLive(cc) then
            total = total + 1
            local constrained, ratio = nil, nil
            pcall(function() constrained = cc.bConstrainAspectRatio end)
            pcall(function() ratio = cc.AspectRatio end)
            if constrained ~= true or type(ratio) ~= "number"
                or math.abs(ratio - SPLIT_VIEW_ASPECT) > 0.01 then
                local okRatio = pcall(function() cc.AspectRatio = SPLIT_VIEW_ASPECT end)
                local okConstrain = pcall(function() cc.bConstrainAspectRatio = true end)
                if okRatio and okConstrain then retuned = retuned + 1 end
            end
        end
    end
    if retuned > 0 and os.clock() - aspectLogAt > 5 then
        aspectLogAt = os.clock()
        log("aspect: retuned %d of %d camera components to the 16:9 half window",
            retuned, total)
    end
end

local function tickGameplay(players, wname)
    if not coopEnabled then
        -- a live reload of this mod starts with co-op "off"; if player 2 is already in the
        -- world, adopt that session instead of silently dropping every co-op fix. Only once per
        -- load, otherwise switching co-op off in the menu is undone on the next tick.
        if not adoptionChecked then
            adoptionChecked = true
            if #players >= 2 then
                coopEnabled = true
                log("co-op session adopted (player 2 already in the level)")
            else
                return
            end
        else
            return
        end
    end
    if #players < 2 then
        -- the engine re-spawns the player controllers of the existing local players when a level
        -- is loaded; creating another local player at that moment is what left a third player in
        -- the game, which took player 2's gamepad and split the view three ways
        if localPlayerCount(players) >= 2 then return end
        -- the engine dropped player 2 (level change, respawn): create again
        if os.time() - lastCreate < 3 then return end
        lastCreate = os.time()
        ExecuteInGameThread(function() addSecondPlayer("gameplay fallback", false) end)
        return
    end
    -- a failed creation attempt can leave an extra local player behind (the engine does not
    -- always free the slot), and RemovePlayer on it does not take, so the list is filtered by
    -- players that actually own a live pawn instead of being pruned mid-level
    local real = {}
    for _, pl in ipairs(players) do
        if isRealPawn(pl.pawn) then real[#real + 1] = pl end
    end
    if #real >= 2 then players = real end
    local p1, p2 = players[1], players[2]
    if not (isRealPawn(p1.pawn) and isRealPawn(p2.pawn)) then return end
    ensureControllerIds(players)
    if parked then holdParked(p1) end
    watchDamage(players)
    local l1, l2 = locOf(p1.pawn), locOf(p2.pawn)
    if not (l1 and l2) then return end

    local now = os.clock()
    if now - lastAspectTick >= 0.5 then
        lastAspectTick = now
        local okAsp, errAsp = pcall(fixSplitAspect, players)
        if not okAsp then log("aspect fix failed: %s", tostring(errAsp)) end
    end
    -- let a freshly loaded level settle before touching its enemies: the game initialises the
    -- AI player pointers during BeginPlay and streaming
    if now - lastAiTick >= CONFIG.aiInterval and (now - levelSince) > 5 then
        lastAiTick = now
        local ok, err = pcall(retargetEnemies, players)
        if not ok then log("enemy retarget failed: %s", tostring(err)) end
    end
    if now - lastEyeTick >= CONFIG.eyeInterval and (now - levelSince) > 3 then
        lastEyeTick = now
        local ok2, err2 = pcall(petrifyEyes, players)
        if not ok2 then log("eye petrify failed: %s", tostring(err2)) end
    end
    if now - lastDoorTick >= CONFIG.doorInterval then
        lastDoorTick = now
        local ok, err = pcall(tuneDoors, players)
        if not ok then
            local msg = tostring(err)
            if msg ~= lastDoorError then
                lastDoorError = msg
                log("doors: error %s", msg)
            end
        end
    end

    -- player 2 fell out of the level (skip while player 1 is parked far above)
    if not parked and l2.Z < l1.Z - CONFIG.fallDrop then
        fallTicks = fallTicks + 1
        if fallTicks >= CONFIG.fallGraceTicks then
            log("player 2 is %.0f units below player 1; rescuing", l1.Z - l2.Z)
            teleportToP1(p2.pawn)
            fallTicks = 0
        end
    else
        fallTicks = 0
    end

    if os.time() - lastBeat >= CONFIG.heartbeat then
        lastBeat = os.time()
        local dx, dy, dz = l1.X - l2.X, l1.Y - l2.Y, l1.Z - l2.Z
        log("alive: %s  p1=(%.0f,%.0f,%.0f) p2=(%.0f,%.0f,%.0f) dist=%.0f", shortLevel(wname),
            l1.X, l1.Y, l1.Z, l2.X, l2.Y, l2.Z, math.sqrt(dx * dx + dy * dy + dz * dz))
    end
end

-- test helpers (player 1 out of the way, damage watch) -------------------------------
--
-- Controlled through a one line file next to the mod: write "park", "unpark" or "dump"
-- into <mods>/AtlasCoop/test.cmd and the mod consumes (and deletes) it on the next tick.
-- No hotkeys: RegisterKeyBind repeats the key state in this build.
-- The paths are derived from where this script was loaded from, so the mod works wherever it
-- is installed; they are development helpers only and are not needed to play.
local function modDirectory()
    local ok, info = pcall(debug.getinfo, 1, "S")
    local src = (ok and info and info.source) or ""
    local path = (src:gsub("^@", "")):gsub("\\", "/")
    return path:match("^(.*)/Scripts/[^/]+$") or "Mods/AtlasCoop"
end
local MOD_DIR = modDirectory()
local TEST_CMD = MOD_DIR .. "/test.cmd"
-- presence of this file keeps the launch from creating player 2, so creation can be driven by
-- hand from test.cmd while the local player list is being measured
local NO_AUTO = MOD_DIR .. "/noauto.txt"

local function autoCreateSuppressed()
    local f = io.open(NO_AUTO, "r")
    if f then f:close(); return true end
    return false
end

local DEATH_NAMES = {
    [0] = "None", [1] = "Default", [2] = "Fall", [3] = "Pit", [4] = "GrabChef",
    [5] = "GrabJanitor", [6] = "GrabGuest", [7] = "Petrification", [8] = "Leech",
    [9] = "ElectricGrab", [10] = "ElectricFloor", [11] = "ShoeMonster", [12] = "DrownInSea",
    [13] = "TelepathicRaise", [14] = "Steam", [15] = "Hunger", [16] = "Crushed",
    [17] = "ElectricWater", [18] = "GrabGranny", [19] = "GrabShadows",
}

local lastDam = {}

local function damageState(pawn)
    local dmg = nil
    pcall(function() dmg = pawn.DamageComponent end)
    if not isLive(dmg) then return nil end
    local st = {}
    pcall(function() st.dead = (dmg:IsDead(false) and true) or false end)
    pcall(function() st.dtype = tonumber(dmg:GetDeathType()) end)
    pcall(function() st.petr = tonumber(dmg:GetPetrificationAmount()) end)
    pcall(function() st.hunger = tonumber(dmg:GetHungerLevel()) end)
    pcall(function() st.hypno = (dmg:IsHypnotized() and true) or false end)
    pcall(function()
        local out = {}
        dmg:GetAttachedLeeches(out)
        st.leeches = #out
    end)
    return st
end

watchDamage = function(players)
    for i = 1, #players do
        local st = damageState(players[i].pawn)
        if st then
            local dtype = st.dtype or -1
            local petr = (st.petr and string.format("%.2f", st.petr)) or "?"
            local key = tostring(st.dead) .. "|" .. tostring(dtype) .. "|" .. petr .. "|" ..
                tostring(st.hunger or "?") .. "|" .. tostring(st.hypno) .. "|" .. tostring(st.leeches or "?")
            if lastDam[i] ~= key then
                lastDam[i] = key
                log("watch p%d dead=%s death=%s(%d) petr=%s hunger=%s hypno=%s leeches=%s",
                    i, tostring(st.dead), DEATH_NAMES[dtype] or "?", dtype,
                    petr, tostring(st.hunger or "?"), tostring(st.hypno), tostring(st.leeches or "?"))
            end
        end
    end
end

local function setP1Hidden(pawn, on)
    pcall(function() pawn:SetActorHiddenInGame(on) end)
    pcall(function() pawn:SetActorEnableCollision(not on) end)
end

local function parkP1(players, on)
    local p1 = players[1]
    if not (p1 and isRealPawn(p1.pawn)) then
        log("test: no player 1 to park")
        return
    end
    if on then
        if parked then log("test: p1 is already parked"); return end
        local l = locOf(p1.pawn)
        if not l then return end
        parked = { X = l.X, Y = l.Y, Z = l.Z, spot = { X = l.X, Y = l.Y, Z = l.Z + 4000 } }
        setP1Hidden(p1.pawn, true)
        pcall(function() p1.pawn:K2_SetActorLocation(parked.spot, false, {}, true) end)
        log("test: p1 parked 4000 u up at %.0f,%.0f,%.0f (hidden, no collision)", parked.spot.X, parked.spot.Y, parked.spot.Z)
    else
        if not parked then log("test: p1 is not parked"); return end
        local l = parked
        parked = nil
        pcall(function() p1.pawn:K2_SetActorLocation({ X = l.X, Y = l.Y, Z = l.Z }, false, {}, true) end)
        setP1Hidden(p1.pawn, false)
        log("test: p1 restored at %.0f,%.0f,%.0f", l.X, l.Y, l.Z)
    end
end

holdParked = function(p1)
    if not (parked and isLive(p1.pawn)) then return end
    pcall(function() p1.pawn:K2_SetActorLocation(parked.spot, false, {}, true) end)
end

-- coat recolour (experiment) ---------------------------------------------------------
local COAT_CANDIDATES = {
    "Color", "Tint", "BaseColor", "Base_Color", "CoatColor", "Coat_Color", "PlayerColor",
    "TintColor", "RaincoatColor", "ClothColor", "MainColor", "Diffuse", "Albedo", "ColorTint",
    "Raincoat", "Raincoat_Tint", "Coat_Tint", "CoatTint", "DressColor", "MaterialColor",
    "CoatBaseColor", "Color_1", "Colour", "OverlayColor", "StainColor", "DirtColor",
}

local function makeMID(mesh, slot, mat)
    local mid = nil
    local ok, err = pcall(function() mid = mesh:CreateDynamicMaterialInstance(slot, mat, "") end)
    if ok and isLive(mid) then return mid, "mesh" end
    return nil, tostring(ok and mid or err)
end

local function tintPlayerCoat(players, idx, color)
    local p = players[idx]
    if not (p and isRealPawn(p.pawn)) then log("tint: no player %d", idx); return end
    -- UMaterialInstanceDynamic::Create through UE4SS' own object creation crashes the game,
    -- so let the engine build the dynamic instances: SetVectorParameterValueOnMaterials does
    -- exactly that (CreateAndSetMaterialInstanceDynamic) for every slot.
    ExecuteInGameThread(function()
        local mesh = nil
        pcall(function() mesh = p.pawn.Mesh end)
        if not isLive(mesh) then log("tint: player %d has no mesh", idx); return end
        -- a plain Lua string handed to an FName parameter crashes this UE4SS build,
        -- so build a real FName userdata first
        local probe = FName("AtlasCoopProbe")
        local ok0, err0 = pcall(function()
            mesh:SetVectorParameterValueOnMaterials(probe, { X = 1.0, Y = 1.0, Z = 1.0 })
        end)
        log("tint: probe call ok=%s err=%s", tostring(ok0), tostring(err0))
        local n = 0
        pcall(function() n = mesh:GetNumMaterials() end)
        log("tint: p%d slots=%d", idx, n)
        for s = 0, n - 1 do
            local mat = nil
            pcall(function() mat = mesh:GetMaterial(s) end)
            local parentName = "-"
            pcall(function() parentName = fullName(mat.Parent) end)
            log("tint: slot %d = %s parent=%s", s, mat and shortName(mat) or "-", parentName)
            -- the engine just swapped every slot to a MaterialInstanceDynamic, so the coat is
            -- recognised by its parent material now, not by the instance name
            local isCoat = s == 1 or s == 2 or parentName:find("Coat") ~= nil
            if isLive(mat) and isCoat then
                for _, cand in ipairs(COAT_CANDIDATES) do
                    local fn = FName(cand)
                    pcall(function() mat:SetVectorParameterValue(fn, color) end)
                end
                log("tint: candidates set on slot %d (%d names)", s, #COAT_CANDIDATES)
            end
        end
    end)
end

-- the master material has no colour parameter (only Fresnel/Pattern scalars and texture slots),
-- so the coat colour lives in the Diffuse texture: import a solid orange png and push it into
-- the two coat slots' Diffuse parameter (experimental, not part of the release)
local COAT_TEX_FILE = MOD_DIR .. "/coat_orange.png"

local function callImportTexture(ctx, path)
    local tries = {
        function() return UKismetRenderingLibrary.ImportFileAsTexture2D(ctx, path) end,
        function()
            local lib = StaticFindObject("/Script/Engine.Default__KismetRenderingLibrary")
            return lib:ImportFileAsTexture2D(ctx, path)
        end,
        function()
            local lib = FindFirstOf("KismetRenderingLibrary")
            return lib:ImportFileAsTexture2D(ctx, path)
        end,
    }
    for i, fn in ipairs(tries) do
        local ok, res = pcall(fn)
        if ok and isLive(res) then return res, i end
        log("coattex: import try %d failed: %s", i, tostring(res))
    end
    return nil
end

local COAT_TEX_PROBES = { "Diffuse", "Normal", "Roughness", "Fresnel Masking", "DynTexParam",
    "PatternTexture", "Pattern", "Mask", "BaseColor", "Albedo", "Texture", "CoatTexture" }

-- only MaterialInstanceDynamic accepts parameter setters; calling one on a plain Material
-- (the hair slot) crashes the process, so every write goes through this guard
local function isMID(mat)
    if not isLive(mat) then return false end
    local cls = ""
    pcall(function() cls = mat:GetClass():GetFName():ToString() end)
    return cls:find("MaterialInstanceDynamic") ~= nil
end

local function coatSlots(mesh)
    local out = {}
    local n = 0
    pcall(function() n = mesh:GetNumMaterials() end)
    for s = 0, n - 1 do
        local mat = nil
        pcall(function() mat = mesh:GetMaterial(s) end)
        local parent = "-"
        pcall(function() parent = fullName(mat.Parent) end)
        if isMID(mat) and (parent:find("MAT_Player_Coat") or s == 1 or s == 2) then
            out[#out + 1] = { slot = s, mat = mat }
        end
    end
    return out
end

local function setCoatDiffuse(players, idx, texPath)
    local p = players[idx]
    if not (p and isRealPawn(p.pawn)) then log("coatdiffuse: no player %d", idx); return end
    ExecuteInGameThread(function()
        local mesh = nil
        pcall(function() mesh = p.pawn.Mesh end)
        if not isLive(mesh) then log("coatdiffuse: no mesh"); return end
        local probe = FName("AtlasCoopProbe")
        pcall(function() mesh:SetVectorParameterValueOnMaterials(probe, { X = 1.0, Y = 1.0, Z = 1.0 }) end)
        local tex = nil
        if texPath then
            local ok = pcall(function() tex = StaticFindObject(texPath) end)
            log("coatdiffuse: load %s ok=%s -> %s", texPath, tostring(ok), isLive(tex) and fullName(tex) or "<nil>")
        else
            tex = callImportTexture(p.pawn, COAT_TEX_FILE)
            log("coatdiffuse: import -> %s", isLive(tex) and fullName(tex) or "<nil>")
        end
        if not isLive(tex) then return end
        for _, c in ipairs(coatSlots(mesh)) do
            local ok = pcall(function() c.mat:SetTextureParameterValue(FName("Diffuse"), tex) end)
            log("coatdiffuse: slot %d set ok=%s", c.slot, tostring(ok))
        end
        log("coatdiffuse: done")
    end)
end

local function setCoatTextureAll(players, idx)
    local p = players[idx]
    if not (p and isRealPawn(p.pawn)) then log("coatall: no player %d", idx); return end
    ExecuteInGameThread(function()
        local mesh = nil
        pcall(function() mesh = p.pawn.Mesh end)
        local probe = FName("AtlasCoopProbe")
        pcall(function() mesh:SetVectorParameterValueOnMaterials(probe, { X = 1.0, Y = 1.0, Z = 1.0 }) end)
        local tex = callImportTexture(p.pawn, COAT_TEX_FILE)
        if not isLive(tex) then log("coatall: import failed"); return end
        local n = 0
        pcall(function() n = mesh:GetNumMaterials() end)
        for s = 0, n - 1 do
            local mat = nil
            pcall(function() mat = mesh:GetMaterial(s) end)
            if isMID(mat) then
                for _, nm in ipairs({ "Diffuse", "Pattern", "DynTexParam" }) do
                    local ok = pcall(function() mat:SetTextureParameterValue(FName(nm), tex) end)
                    log("coatall: slot %d %s ok=%s", s, nm, tostring(ok))
                end
            end
        end
        -- list every skeletal mesh component of the pawn so we can see whether the visible coat
        -- belongs to the main mesh or to a second component
        local comps = nil
        pcall(function() comps = p.pawn:K2_GetComponentsByClass(USkeletalMeshComponent) end)
        local nc = 0
        pcall(function() nc = #comps end)
        log("coatall: %d skeletal mesh components", nc)
        for i = 1, math.min(nc, 8) do
            local c = comps[i]
            local cn, sn, nmats = "?", "-", -1
            pcall(function() cn = shortName(c) end)
            pcall(function() sn = c.SkeletalMesh and shortName(c.SkeletalMesh) or "-" end)
            pcall(function() nmats = c:GetNumMaterials() end)
            log("coatall: comp %d %s mesh=%s mats=%d", i, tostring(cn), tostring(sn), nmats)
        end
    end)
end

local function probeCoatTextures(players, idx)
    local p = players[idx]
    if not (p and isRealPawn(p.pawn)) then log("coattexprobe: no player %d", idx); return end
    ExecuteInGameThread(function()
        local mesh = nil
        pcall(function() mesh = p.pawn.Mesh end)
        local probe = FName("AtlasCoopProbe")
        pcall(function() mesh:SetVectorParameterValueOnMaterials(probe, { X = 1.0, Y = 1.0, Z = 1.0 }) end)
        local n = 0
        pcall(function() n = mesh:GetNumMaterials() end)
        for s = 1, math.min(n - 1, 2) do
            local mat = nil
            pcall(function() mat = mesh:GetMaterial(s) end)
            log("coattexprobe: slot %d mat=%s", s, mat and shortName(mat) or "-")
            for _, cand in ipairs(COAT_TEX_PROBES) do
                local ok, tex = pcall(function() return mat:K2_GetTextureParameterValue(FName(cand)) end)
                log("coattexprobe:   %s -> %s", cand,
                    ok and (isLive(tex) and fullName(tex) or "<nil>") or ("error " .. tostring(tex)))
            end
        end
        log("coattexprobe: done")
    end)
end

local function tintCoatTexture(players, idx)
    local p = players[idx]
    if not (p and isRealPawn(p.pawn)) then log("coattex: no player %d", idx); return end
    ExecuteInGameThread(function()
        local mesh = nil
        pcall(function() mesh = p.pawn.Mesh end)
        if not isLive(mesh) then log("coattex: no mesh"); return end
        local probe = FName("AtlasCoopProbe")
        pcall(function() mesh:SetVectorParameterValueOnMaterials(probe, { X = 1.0, Y = 1.0, Z = 1.0 }) end)
        local tex, which = callImportTexture(p.pawn, COAT_TEX_FILE)
        log("coattex: import -> %s (try %s)", isLive(tex) and fullName(tex) or "<nil>", tostring(which))
        if not isLive(tex) then return end
        local n = 0
        pcall(function() n = mesh:GetNumMaterials() end)
        for s = 0, n - 1 do
            if s == 1 or s == 2 then
                local mat = nil
                pcall(function() mat = mesh:GetMaterial(s) end)
                local okS, errS = pcall(function() mat:SetTextureParameterValue(FName("Diffuse"), tex) end)
                log("coattex: slot %d Diffuse ok=%s err=%s mat=%s", s, tostring(okS), tostring(errS),
                    mat and shortName(mat) or "-")
            end
        end
        log("coattex: done")
    end)
end

-- reading a cooked master's vector parameter names is impossible (UE4SS collapses the fixed
-- FMaterialCachedParameterEntry[5] array), but K2_GetVectorParameterValue returns a parameter's
-- value for a known name and a zero colour for an unknown one, so a name whose readback matches
-- the value stored in the material's cached data is a real parameter name
local COAT_NAME_PROBES = {
    "Color", "Colour", "Tint", "TintColor", "BaseColor", "BaseColorTint", "DiffuseColor",
    "CoatColor", "CoatColour", "CoatTint", "RaincoatColor", "PatternColor", "PatternColour",
    "PatternTint", "MaskColor", "FresnelColor", "FresnelColour", "RimColor", "EmissiveColor",
    "OverlayColor", "DetailColor", "DetailTint", "DirtColor", "MudColor", "StainColor",
    "WetColor", "WaterColor", "BloodColor", "TopColor", "BottomColor", "MainColor",
    "PrimaryColor", "SecondaryColor", "ClothColor", "ClothesColor", "FabricColor",
    "TextureTint", "TexTint", "DiffuseTint", "AlbedoTint", "AlbedoColor", "ColorMultiplier",
    "Color1", "Color2", "ColorA", "ColorB", "TintA", "TintB", "PaintColor", "VertexColor",
    "VertexColorTint", "OverlayTint", "PatternScaleColor", "LineColor", "TrimColor",
    "StripeColor", "AccentColor", "HoodColor", "SleeveColor", "BodyTint", "MudTint",
}

local function findVectorParams(players, idx)
    local p = players[idx]
    log("findvec: start idx=%d players=%d p=%s", idx, #players, p and "yes" or "no")
    if not (p and isRealPawn(p.pawn)) then log("findvec: no player %d", idx); return end
    ExecuteInGameThread(function()
        log("findvec: game thread started")
        local mesh = nil
        pcall(function() mesh = p.pawn.Mesh end)
        if not isLive(mesh) then log("findvec: no mesh"); return end
        -- make sure the slots are dynamic instances (the probe creates them engine-side)
        local probe = FName("AtlasCoopProbe")
        pcall(function() mesh:SetVectorParameterValueOnMaterials(probe, { X = 1.0, Y = 1.0, Z = 1.0 }) end)
        local mat = nil
        pcall(function() mat = mesh:GetMaterial(1) end)
        if not isLive(mat) then log("findvec: no slot 1 material"); return end
        -- walk up to the base Material to read the cached vector values
        local cur, master = mat, nil
        for _ = 1, 4 do
            local nx = nil
            pcall(function() nx = cur.Parent end)
            if not isLive(nx) then break end
            cur = nx
            local cls = ""
            pcall(function() cls = cur:GetClass():GetFName():ToString() end)
            if cls == "Material" then master = cur; break end
        end
        if isLive(master) then
            local ced, params, vals = nil, nil, nil
            pcall(function() ced = master.CachedExpressionData end)
            pcall(function() params = ced.Parameters end)
            pcall(function() vals = params.VectorValues end)
            local n = 0
            pcall(function() n = #vals end)
            log("findvec: master %s has %d vector values", shortName(master), n)
            for i = 1, math.min(n, 6) do
                local c = vals[i]
                local r, g, b, a = -9.0, -9.0, -9.0, -9.0
                pcall(function() r = c.R; g = c.G; b = c.B; a = c.A end)
                log("findvec: cached vector %d = %.3f,%.3f,%.3f,%.3f", i, r, g, b, a)
            end
        else
            log("findvec: base Material not found, readback only")
        end
        local hits = 0
        for _, cand in ipairs(COAT_NAME_PROBES) do
            local ok, v = pcall(function() return mat:K2_GetVectorParameterValue(FName(cand)) end)
            if ok and v then
                local s = string.format("%.3f,%.3f,%.3f,%.3f", v.R, v.G, v.B, v.A)
                if s ~= "0.000,0.000,0.000,0.000" then
                    hits = hits + 1
                    log("findvec: HIT %s = %s", cand, s)
                end
            end
        end
        log("findvec: %d of %d probe names exist on %s", hits, #COAT_NAME_PROBES, shortName(mat))
        log("findvec: done")
    end)
end

-- the game paints the coat with vertex colours (mud, blood, water) through
-- UAtlasPlayerMaterialOverrideComponent::ColorizeVertecesInRadius; reuse it for a flat tint
local function paintCoat(players, idx)    local p = players[idx]
    if not (p and isRealPawn(p.pawn)) then log("paint: no player %d", idx); return end
    ExecuteInGameThread(function()
        local comp = nil
        pcall(function() comp = p.pawn.MaterialOverrideComponent end)
        if not isLive(comp) then log("paint: player %d has no MaterialOverrideComponent", idx); return end
        local loc = nil
        pcall(function() loc = p.pawn:K2_GetActorLocation() end)
        local vec = { X = 0, Y = 0, Z = 0 }
        if loc then pcall(function() vec.X = loc.X; vec.Y = loc.Y; vec.Z = loc.Z end) end
        log("paint: comp=%s loc=%.0f,%.0f,%.0f", shortName(comp), vec.X, vec.Y, vec.Z)
        local ok1, e1 = pcall(function() comp:SetMaterialOverride(1, 3600.0) end)
        log("paint: SetMaterialOverride(Coat1) ok=%s err=%s", tostring(ok1), tostring(e1))
        local ok2, e2 = pcall(function()
            comp:ColorizeVertecesInRadius({ R = 255, G = 79, B = 0, A = 255 }, vec, 10000.0, false, 2, 3600.0)
        end)
        log("paint: Colorize ok=%s err=%s", tostring(ok2), tostring(e2))
    end)
end

local function dumpMatParams(tag, mat)
    local ok, arr = pcall(function() return mat.VectorParameterValues end)
    if not ok or arr == nil then
        log("%s vector params: <unavailable>", tag)
        return
    end
    local n = nil
    pcall(function() n = #arr end)
    if not n then pcall(function() n = arr:GetArrayNum() end) end
    log("%s vector params: n=%s", tag, tostring(n))
    if type(n) ~= "number" or n <= 0 then return end
    for i = 1, math.min(n, 12) do
        local name, col, text = nil, nil, "?"
        pcall(function() name = arr[i].ParameterInfo.Name:ToString() end)
        pcall(function() col = arr[i].ParameterValue end)
        if col then
            pcall(function() text = string.format("%.3f,%.3f,%.3f,%.3f", col.R, col.G, col.B, col.A) end)
        end
        log("%s  [%d] %s = %s", tag, i, tostring(name), text)
    end
end

local function dumpScalarParams(tag, mat)
    local ok, arr = pcall(function() return mat.ScalarParameterValues end)
    if not ok or arr == nil then
        log("%s scalar params: <unavailable>", tag)
        return
    end
    local n = nil
    pcall(function() n = #arr end)
    log("%s scalar params: n=%s", tag, tostring(n))
    if type(n) ~= "number" or n <= 0 then return end
    for i = 1, math.min(n, 12) do
        local name, val = nil, nil
        pcall(function() name = arr[i].ParameterInfo.Name:ToString() end)
        pcall(function() val = arr[i].ParameterValue end)
        log("%s  [%d] %s = %s", tag, i, tostring(name), tostring(val))
    end
end

local function dumpTextureParams(tag, mat)
    local ok, arr = pcall(function() return mat.TextureParameterValues end)
    if not ok or arr == nil then
        log("%s texture params: <unavailable>", tag)
        return
    end
    local n = nil
    pcall(function() n = #arr end)
    log("%s texture params: n=%s", tag, tostring(n))
    if type(n) ~= "number" or n <= 0 then return end
    for i = 1, math.min(n, 12) do
        local name, val = nil, nil
        pcall(function() name = arr[i].ParameterInfo.Name:ToString() end)
        pcall(function() val = arr[i].ParameterValue end)
        log("%s  t[%d] %s = %s", tag, i, tostring(name), val and fullName(val) or "-")
    end
end

local function dumpParentChain(tag, mat)
    local cur = mat
    for depth = 1, 4 do
        local ok, parent = pcall(function() return cur.Parent end)
        if not ok or not isLive(parent) then
            log("%s parent%d: none", tag, depth)
            break
        end
        log("%s parent%d = %s (%s)", tag, depth, fullName(parent),
            tostring(parent:GetClass():GetFName()))
        dumpMatParams(tag .. " p" .. depth, parent)
        dumpScalarParams(tag .. " p" .. depth, parent)
        cur = parent
    end
end

local function probeCoat(players)
    for i, p in ipairs(players) do
        local pawn = p.pawn
        if isLive(pawn) then
            log("coat p%d pawn=%s class=%s", i, shortName(pawn), tostring(pawn:GetClass():GetFName()))
            local dmi = nil
            pcall(function() dmi = pawn.PlayerCoatDMI end)
            if isLive(dmi) then
                log("coat p%d PlayerCoatDMI=%s class=%s", i, shortName(dmi),
                    tostring(dmi:GetClass():GetFName()))
                dumpMatParams(string.format("coat p%d dmi", i), dmi)
                dumpScalarParams(string.format("coat p%d dmi", i), dmi)
            else
                log("coat p%d PlayerCoatDMI = nil", i)
            end
            local meshes = {}
            local okm, mesh = pcall(function() return pawn.Mesh end)
            if okm and isLive(mesh) then meshes[#meshes + 1] = mesh end
            for _, c in pairs(FindAllOf("SkeletalMeshComponent") or {}) do
                if isLive(c) then
                    local owner, dup = nil, false
                    pcall(function() owner = c:GetOwner() end)
                    if owner and fullName(owner) == fullName(pawn) then
                        for _, m in ipairs(meshes) do
                            if fullName(m) == fullName(c) then dup = true end
                        end
                        if not dup then meshes[#meshes + 1] = c end
                    end
                end
            end
            for mi, m in ipairs(meshes) do
                local n = 0
                pcall(function() n = m:GetNumMaterials() end)
                log("coat p%d mesh%d=%s class=%s slots=%d", i, mi, shortName(m),
                    tostring(m:GetClass():GetFName()), n)
                for s = 0, n - 1 do
                    local mat = nil
                    pcall(function() mat = m:GetMaterial(s) end)
                    log("coat p%d mesh%d slot%d = %s (%s)", i, mi, s,
                        mat and fullName(mat) or "-",
                        mat and tostring(mat:GetClass():GetFName()) or "-")
                    if isLive(mat) then
                        dumpMatParams(string.format("coat p%d m%d s%d", i, mi, s), mat)
                        dumpTextureParams(string.format("coat p%d m%d s%d", i, mi, s), mat)
                        if s == 1 then
                            dumpParentChain(string.format("coat p%d s%d", i, s), mat)
                        end
                    end
                end
            end
        end
    end
end

-- why does CreatePlayer return nil? try the variants and print the engine-side limits
local function p2test(players)
    local pc1 = players[1] and players[1].pc
    log("p2test: players=%d pc1=%s", #players, pc1 and shortName(pc1) or "-")
    local gi = nil
    if pc1 then pcall(function() gi = pc1:GetGameInstance() end) end
    log("p2test: gi=%s", isLive(gi) and shortName(gi) or "-")
    local n = -1
    if isLive(gi) then
        local lp = nil
        pcall(function() lp = gi.LocalPlayers end)
        pcall(function() n = #lp end)
        log("p2test: LocalPlayers=%s", tostring(n))
        if type(n) == "number" then
            for i = 1, math.min(n, 4) do
                local one, pc = nil, nil
                pcall(function() one = lp[i] end)
                pcall(function() pc = one.PlayerController end)
                log("p2test: lp[%d] pc=%s", i, isLive(pc) and shortName(pc) or "-")
            end
        end
    end
    local gms = GetGameMapsSettings()
    if isLive(gms) then
        log("p2test: gms splitscreen=%s offset=%s max=%s",
            tostring(gms.bUseSplitscreen), tostring(gms.bOffsetPlayerGamepadIds),
            tostring(gms.MaxSplitscreenPlayers))
    end
    ExecuteInGameThread(function()
        local gs = GetGameplayStatics()
        for _, cid in ipairs({ 1, 0, 2 }) do
            local ok, res = pcall(function() return gs:CreatePlayer(pc1, cid, true) end)
            log("p2test: CreatePlayer(cid=%d) ok=%s res=%s", cid, tostring(ok),
                ok and (res and fullName(res) or "<nil>") or tostring(res))
        end
    end)
end

-- a cooked Material keeps its parameter names in CachedExpressionData.Parameters.RuntimeEntries,
-- which is the only way to see them (the MICs override nothing and the editor data is stripped)
local function dumpCachedParams(tag, mat)
    local ok, ced = pcall(function() return mat.CachedExpressionData end)
    if not ok or ced == nil then log("%s: no CachedExpressionData", tag); return end
    local params = nil
    pcall(function() params = ced.Parameters end)
    if params == nil then log("%s: no Parameters", tag); return end
    local function dumpEntry(entry, label)
        if entry == nil then return end
        local infos = nil
        pcall(function() infos = entry.ParameterInfos end)
        local n = 0
        pcall(function() n = #infos end)
        log("%s %s: %d params", tag, label, n)
        for j = 1, math.min(n, 40) do
            local nm = nil
            pcall(function() nm = infos[j].Name:ToString() end)
            if nm == nil then pcall(function() nm = infos[j].ParameterInfo.Name:ToString() end) end
            log("%s   [%d] %s", tag, j, tostring(nm))
        end
    end
    -- UE4SS exposes the fixed array FMaterialCachedParameterEntry[5] as its first element only,
    -- so this shows one parameter kind (the vector one is what we are after)
    local re = nil
    pcall(function() re = params.RuntimeEntries end)
    dumpEntry(re, "RuntimeEntries[0]")
    for i = 1, 4 do
        local e = nil
        if pcall(function() e = params.RuntimeEntries[i] end) and e ~= nil then
            dumpEntry(e, "RuntimeEntries[" .. i .. "]")
        end
    end
    local nv, ns, nt = 0, 0, 0
    pcall(function() nv = #params.VectorValues end)
    pcall(function() ns = #params.ScalarValues end)
    pcall(function() nt = #params.TextureValues end)
    log("%s: VectorValues=%d ScalarValues=%d TextureValues=%d", tag, nv, ns, nt)
end

-- the vector parameter names of a cooked master cannot be read (UE4SS collapses the fixed
-- FMaterialCachedParameterEntry[5] array to its first entry), but any material instance of that
-- master lists the names it overrides, which names the same parameters
local function dumpMICOverrides()
    local seen, n = {}, 0
    for _, m in pairs(FindAllOf("MaterialInstanceConstant") or {}) do
        local cur, isPlayer, depth = m, false, 0
        while isLive(cur) and depth < 4 do
            local nm = fullName(cur)
            if nm:find("MAT_Player_") then isPlayer = true; break end
            local nx = nil
            pcall(function() nx = cur.Parent end)
            cur = nx
            depth = depth + 1
        end
        if isPlayer then
            local name = fullName(m)
            if not seen[name] then
                seen[name] = true
                n = n + 1
                if n <= 20 then
                    log("mic %d: %s", n, name)
                    local cnt = 0
                    local vp = nil
                    pcall(function() vp = m.VectorParameterValues end)
                    pcall(function() cnt = #vp end)
                    for i = 1, math.min(cnt, 10) do
                        local nm, val = "?", nil
                        pcall(function() nm = vp[i].ParameterInfo.Name:ToString() end)
                        pcall(function() val = vp[i].ParameterValue end)
                        log("mic   vec %s = %s", tostring(nm), val and
                            string.format("%.3f,%.3f,%.3f,%.3f", val.R, val.G, val.B, val.A) or "?")
                    end
                    local sp = nil
                    cnt = 0
                    pcall(function() sp = m.ScalarParameterValues end)
                    pcall(function() cnt = #sp end)
                    for i = 1, math.min(cnt, 10) do
                        local nm = "?"
                        pcall(function() nm = sp[i].ParameterInfo.Name:ToString() end)
                        log("mic   scalar %s = %s", tostring(nm), tostring(sp[i].ParameterValue))
                    end
                    local tp = nil
                    cnt = 0
                    pcall(function() tp = m.TextureParameterValues end)
                    pcall(function() cnt = #tp end)
                    for i = 1, math.min(cnt, 10) do
                        local nm = "?"
                        pcall(function() nm = tp[i].ParameterInfo.Name:ToString() end)
                        log("mic   tex %s", tostring(nm))
                    end
                end
            end
        end
    end
    log("mic: %d player material instances scanned", n)
end

-- look for coat-ish material assets the game already ships (e.g. a differently coloured coat)
local function listPlayerMaterials()
    local seen, n = {}, 0
    for _, m in pairs(FindAllOf("MaterialInstanceConstant") or {}) do
        local name = fullName(m)
        if name:find("Player") or name:find("Coat") or name:find("DLC") then
            if not seen[name] then
                seen[name] = true
                n = n + 1
                log("mat %d: %s", n, name)
            end
        end
    end
    log("mat: %d distinct player-ish material instances", n)
end

-- camera framing probe: where does the character sit in this player's view? ---------------------------------
local function camProbe(players)
    local gs = GetGameplayStatics()
    for i, p in ipairs(players or {}) do
        local pc, pawn = p.pc, p.pawn
        if isLive(pc) and isLive(pawn) then
            local fov, sx, sy = nil, nil, nil
            pcall(function() fov = pc.PlayerCameraManager:GetFOVAngle() end)
            pcall(function() sx, sy = pc:GetViewportSize() end)
            local camLoc, camRot = nil, nil
            pcall(function() camLoc = pc.PlayerCameraManager:GetCameraLocation() end)
            pcall(function() camRot = pc.PlayerCameraManager:GetCameraRotation() end)
            local loc = pawn:K2_GetActorLocation()
            local hh = 40.0
            pcall(function() hh = pawn.CapsuleComponent.CapsuleHalfHeight end)
            local function project(z)
                local out = { X = 0.0, Y = 0.0 }
                local ok, res = pcall(function()
                    return gs:ProjectWorldToScreen(pc, { X = loc.X, Y = loc.Y, Z = z }, out, true)
                end)
                return ok, res, out
            end
            local okT, resT, topOut = project(loc.Z + hh)
            local okB, resB, botOut = project(loc.Z - hh)
            log("camprobe p%d fov=%s vp=%sx%s halfH=%.0f", i, tostring(fov), tostring(sx), tostring(sy), hh)
            local camText, rotText = "-", "-"
            if type(camLoc) == "table" then
                camText = string.format("%.0f,%.0f,%.0f", camLoc.X or 0, camLoc.Y or 0, camLoc.Z or 0)
            end
            if type(camRot) == "table" then
                rotText = string.format("%.1f,%.1f,%.1f", camRot.Pitch or 0, camRot.Yaw or 0, camRot.Roll or 0)
            end
            log("camprobe p%d cam=%s rot=%s pawn=%.0f,%.0f,%.0f", i, camText, rotText,
                loc.X, loc.Y, loc.Z)
            log("camprobe p%d head ok=%s res=%s out=%s,%s", i, tostring(okT), tostring(resT),
                tostring(topOut and topOut.X), tostring(topOut and topOut.Y))
            log("camprobe p%d feet ok=%s res=%s out=%s,%s", i, tostring(okB), tostring(resB),
                tostring(botOut and botOut.X), tostring(botOut and botOut.Y))
        else
            log("camprobe p%d: no live pawn/controller", i)
        end
    end
end

pollTestCmd = function(players)
    local ok, f = pcall(io.open, TEST_CMD, "r")
    if not ok or not f then return end
    local line = f:read("l")
    f:close()
    if not line then return end
    line = line:gsub("^%s+", ""):gsub("%s+$", "")
    if line == "" then return end
    pcall(os.remove, TEST_CMD)
    log("test cmd: %s", line)
    if line == "park" then
        parkP1(players, true)
    elseif line == "unpark" then
        parkP1(players, false)
    elseif line:match("^saspect ") then
        local v = tonumber(line:match("^saspect%s+(%d+%.?%d*)"))
        if v and v > 0.5 then
            SPLIT_VIEW_ASPECT = v
            log("saspect: split view aspect = %0.3f", SPLIT_VIEW_ASPECT)
        end
    elseif line:match("^movwatch") then
        -- sampled by its own delayed chain: a block inside tickGameplay only runs while a
        -- gameplay level is being ticked and samples were lost across a level load
        local secs = tonumber(line:match("^movwatch%s+(%d+)")) or 30
        local samples = secs * 2
        local sample
        sample = function(left)
            if left <= 0 then
                log("movwatch: stopped")
                return
            end
            for i, p in ipairs(getPlayers()) do
                if isRealPawn(p.pawn) then
                    local pos, vel, cam, ctrl = "-", "-", "-", "-"
                    pcall(function()
                        local l = p.pawn:K2_GetActorLocation()
                        pos = string.format("%.0f,%.0f,%.0f", l.X, l.Y, l.Z)
                    end)
                    pcall(function()
                        local v = p.pawn:GetVelocity()
                        vel = string.format("%.0f,%.0f,%.0f", v.X, v.Y, v.Z)
                    end)
                    pcall(function()
                        local r = p.pc.PlayerCameraManager:GetCameraRotation()
                        cam = string.format("%.0f,%.0f", r.Pitch, r.Yaw)
                    end)
                    pcall(function()
                        local r = p.pc.ControlRotation
                        ctrl = string.format("%.0f,%.0f", r.Pitch, r.Yaw)
                    end)
                    log("movwatch p%d pos=%s vel=%s cam=%s ctrl=%s", i, pos, vel, cam, ctrl)
                end
            end
            ExecuteWithDelay(500, function() sample(left - 1) end)
        end
        if samples > 0 then
            log("movwatch: %d samples, one every 0.5 s", samples)
            sample(samples)
        else
            log("movwatch: nothing to do")
        end
    elseif line == "camprobe" then
        camProbe(players)
    elseif line == "unpause" then
        local gs = GetGameplayStatics()
        local w = UEHelpers.GetWorld()
        local ok, err = pcall(function() gs:SetGamePaused(w, false) end)
        local paused = nil
        pcall(function() paused = gs:IsGamePaused(w) end)
        log("unpause: ok=%s err=%s paused now=%s", tostring(ok), tostring(err), tostring(paused))
    elseif line == "ispaused" then
        local gs = GetGameplayStatics()
        local w = UEHelpers.GetWorld()
        local paused = nil
        pcall(function() paused = gs:IsGamePaused(w) end)
        log("ispaused: %s", tostring(paused))
    elseif line == "dump" then
        for i = 1, #players do
            local l = locOf(players[i].pawn)
            log("dump p%d at %s", i, l and string.format("%.0f,%.0f,%.0f", l.X, l.Y, l.Z) or "?")
        end
    elseif line == "lpinfo" then
        lpInfo(players)
    elseif line == "cidcycle" then
        startCidTrial(players)
    elseif line == "keylog" then
        startKeyProbe()
    elseif line == "doorinfo" then
        doorInfo(players)
    elseif line == "doorall" then
        doorInfo(players, true)
    elseif line:match("^tp ") then
        local x, y, z = line:match("^tp%s+(-?%d+%.?%d*),%s*(-?%d+%.?%d*),%s*(-?%d+%.?%d*)")
        if not x then
            log("tp: expected tp x,y,z")
        else
            for i, p in ipairs(players) do
                local pawn = p.pawn
                if isLive(pawn) then
                    local loc = { X = tonumber(x) + (i - 1) * 70, Y = tonumber(y), Z = tonumber(z) }
                    ExecuteInGameThread(function()
                        local ok, err = pcall(function() pawn:K2_SetActorLocation(loc, false, {}, true) end)
                        log("tp: p%d -> %s ok=%s err=%s", i, x .. "," .. y .. "," .. z, tostring(ok), tostring(err))
                    end)
                end
            end
        end
    elseif line == "openlevel" then
        local pc = players[1] and players[1].pc
        if not isLive(pc) then
            log("openlevel: no controller yet")
        else
            ExecuteInGameThread(function()
                local gs = GetGameplayStatics()
                local ok, err = pcall(function() gs:OpenLevel(pc, FName("PLVL_Tutorial"), true, "") end)
                log("openlevel: PLVL_Tutorial ok=%s err=%s", tostring(ok), tostring(err))
            end)
        end
    elseif line == "keynames" then
        local names = {}
        local ok, err = pcall(function()
            for k in pairs(Key) do names[#names + 1] = tostring(k) end
        end)
        table.sort(names)
        log("keynames: type=%s ok=%s count=%d err=%s", type(Key), tostring(ok), #names, tostring(err))
        for i = 1, #names, 12 do
            local chunk = {}
            for j = i, math.min(i + 11, #names) do chunk[#chunk + 1] = names[j] end
            log("keynames: %s", table.concat(chunk, " "))
        end
    elseif line == "create1" or line == "create2" or line == "create3" then
        local cid = tonumber(line:match("(%d)"))
        local pc1 = players[1] and players[1].pc
        if not isLive(pc1) then
            log("create%d: no player 1 controller", cid)
        else
            log("create%d: %d local player(s) before", cid, localPlayerCount(players))
            ExecuteInGameThread(function()
                local gs = GetGameplayStatics()
                local ok, res = pcall(function() return gs:CreatePlayer(pc1, cid, true) end)
                log("create%d -> ok=%s res=%s", cid, tostring(ok),
                    isLive(res) and fullName(res) or tostring(res))
            end)
        end
    elseif line == "coat" then
        probeCoat(players)
    elseif line == "coopon" then
        setCoop(true, "test cmd")
    elseif line == "coopoff" then
        setCoop(false, "test cmd")
    elseif line == "tint" then
        tintPlayerCoat(players, #players, { R = 1.0, G = 0.0779, B = 0.0, A = 1.0 })
    elseif line == "paint" then
        paintCoat(players, #players)
    elseif line == "p2test" then
        p2test(players)
    elseif line == "mats" then
        listPlayerMaterials()
    elseif line == "micparams" then
        dumpMICOverrides()
    elseif line == "findvec" then
        findVectorParams(players, #players)
    elseif line == "coattexprobe" or line == "coattex" or line == "coatall"
        or line == "coatdiffuse" or line == "coatblack" then
        local ti = #players
        for i = #players, 1, -1 do
            if isRealPawn(players[i].pawn) then ti = i; break end
        end
        log("%s: target player %d of %d", line, ti, #players)
        if line == "coattexprobe" then
            probeCoatTextures(players, ti)
        elseif line == "coattex" then
            tintCoatTexture(players, ti)
        elseif line == "coatall" then
            setCoatTextureAll(players, ti)
        elseif line == "coatblack" then
            setCoatDiffuse(players, ti, "/Game/UI/Textures/Backgrounds/TEX_PureBlack.TEX_PureBlack")
        else
            setCoatDiffuse(players, ti, nil)
        end
    elseif line == "matparams" then
        local p = players[#players]
        if p and isRealPawn(p.pawn) then
            local mesh = nil
            pcall(function() mesh = p.pawn.Mesh end)
            local mat = nil
            pcall(function() mat = mesh:GetMaterial(1) end)
            if isLive(mat) then
                local cur = mat
                for depth = 1, 4 do
                    local parent = nil
                    pcall(function() parent = cur.Parent end)
                    if not isLive(parent) then
                        log("matparams: depth%d = %s (no parent)", depth, shortName(cur))
                        break
                    end
                    log("matparams: depth%d = %s (%s)", depth, fullName(parent),
                        tostring(select(1, pcall(function() return parent:GetClass():GetFName():ToString() end))))
                    dumpCachedParams("matparams d" .. depth, parent)
                    cur = parent
                end
            else
                log("matparams: no material in slot 1")
            end
        else
            log("matparams: no player")
        end
    end
end

rowWasPressed = false

local function tick()
    local world = UEHelpers.GetWorld()
    local wname = isLive(world) and fullName(world) or ""
    if wname == "" then return end

    local isMenu = (wname:find("Menus") or wname:find("MainMenu") or wname:find("Bootup")) and true or false

    -- test commands are polled here so they also work in the menu, with one player, or while
    -- a level is still loading (tickGameplay returns early in all of those cases)
    if os.clock() - lastCmdPoll > 0.5 then
        lastCmdPoll = os.clock()
        local okCmd, errCmd = pcall(pollTestCmd, getPlayers())
        if not okCmd then log("test cmd failed: %s", tostring(errCmd)) end
    end
    if cidTrial then pcall(pumpCidTrial, os.clock()) end
    if keyProbe then pcall(pumpKeyProbe, os.clock(), getPlayers()) end

    if wname ~= lastWorld then
        log("level: %s", shortLevel(wname))
        lastWorld = wname
        levelSince = os.clock()
        inMenuLevel = isMenu
        fallTicks = 0
        rowForMenu = nil
        -- split only in gameplay: the front-end stays a single, readable view
        if coopEnabled then
            ExecuteInGameThread(function()
                local gms = GetGameMapsSettings()
                if isLive(gms) then gms.bUseSplitscreen = not isMenu end
            end)
        end
    end

    if isMenu then
        ensureMenuRow()
        pollMenuRow()
        -- co-op on by default: create player 2 while the menu is up, so both players spawn
        -- with the level (creating it inside a gameplay level is the unreliable path)
        if not autoStartDone and isLive(findMainMenu()) then
            autoStartDone = true
            if autoCreateSuppressed() then
                coopEnabled = true
                setRowText()
                log("co-op ON (auto at launch, creation suppressed by noauto.txt)")
            else
                setCoop(true, "auto at launch")
            end
        end
        -- exactly one creation attempt at launch: every extra attempt left a stale local player
        -- behind that could not be removed and turned into a third, black viewport
        return
    end

    tickGameplay(getPlayers(), wname)
end

-- Note: no keyboard hotkey. RegisterKeyBind(Key.F2) fired continuously in this build (the key
-- state reads as held), which toggled co-op on/off every tick. The menu row is the control.

log("loaded (v0.11) io=%s", type(io))
LoopAsync(400, function()
    local ok, err = pcall(tick)
    if not ok then log("TICK ERROR: %s", tostring(err)) end
end)

-- fast poll only while a row exists, so a short mouse click is not missed
LoopAsync(100, function()
    if isLive(rowButton) then
        pcall(pollMenuRow)
    end
end)