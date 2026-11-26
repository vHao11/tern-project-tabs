local projects = require("./projects")
local M = {}

local windows = tern.runtime.os == "windows"
local ternCli = if windows then "tern.com" else "tern"

local pinnedKvKey = "pinned-tabs"
local dormantTtlSec = 14 * 24 * 3600
local maxDormantPins = 64
local startupGraceMs = 15000
local saveDebounceMs = 500

local pinSeq, pinRev, pinUidSeq = 0, 0, 0
local lastKnownRev = nil
local pinItems = {}
local boundPinByTab = {}
local pinByUid = {}
local startedAtMs = 0
local pinsDirty = false
local pinSaveTimer = nil

local sessionFilesByPane = {}
local inspectInFlight = false
local lastInspectMs = 0

local function normFile(path)
    local clean = projects.path(path)
    return if clean then projects.key(clean) else ""
end

local function normPathValue(raw)
    if type(raw) ~= "string" or raw == "" then return "" end
    local clean = projects.path(raw)
    if clean and projects.isAbsolute(clean) then return projects.key(clean) end
    return raw
end

local function isTerminalFamily(kind)
    return kind == "terminal" or kind == "agent"
end

local function kindsCompatible(savedKind, liveKind)
    if savedKind == "" or liveKind == "" then return true end
    if savedKind == liveKind then return true end
    return isTerminalFamily(savedKind) and isTerminalFamily(liveKind)
end

function M.fingerprint(tab)
    local rawPath = tab.normPath or tab.path
    local np = tab._normPath
    if np == nil or tab._normPathRaw ~= rawPath then
        np = normPathValue(rawPath)
        tab._normPath = np
        tab._normPathRaw = rawPath
    end
    return {
        id = tab.id,
        host = tab.host or "",
        sessionName = tab.sessionName or "",
        projectKey = tab.projectKey or "",
        tabName = tab.rawName or "",
        kind = tab.kind or "",
        normPath = np,
        label = tab.label or "",
        position = tab.position or 0,
        sessionFile = if type(tab.sessionFile) == "string" then tab.sessionFile else "",
    }
end

function M.sessionFileForPane(paneId)
    return sessionFilesByPane[paneId]
end

function M.clearPane(paneId)
    sessionFilesByPane[paneId] = nil
end

function M.inspectSessions(windowKey, onUpdated)
    if inspectInFlight then return end
    local now = tern.now()
    if now - lastInspectMs < 400 then return end
    inspectInFlight = true
    lastInspectMs = now
    local ok = pcall(function()
        tern.process.run({ ternCli, "inspect", "--json", "--window", windowKey or "" }, { timeout_ms = 6000 }, function(result, cx)
            inspectInFlight = false
            if not result or result.status ~= 0 then return end
            local decoded, data = pcall(tern.json.decode, result.stdout or "")
            if not decoded or type(data) ~= "table" or type(data.panes) ~= "table" then return end
            local changed = false
            local seen = {}
            for _, pane in data.panes do
                if type(pane) == "table" and type(pane.pane) == "number" then
                    local file = normFile(pane.omp_session_file)
                    if file ~= "" then
                        seen[pane.pane] = file
                        if sessionFilesByPane[pane.pane] ~= file then
                            sessionFilesByPane[pane.pane] = file
                            changed = true
                        end
                    end
                end
            end
            for paneId in sessionFilesByPane do
                if not seen[paneId] then
                    sessionFilesByPane[paneId] = nil
                end
            end
            if changed and onUpdated then onUpdated(cx) end
        end)
    end)
    if not ok then inspectInFlight = false end
end

local function isIdCompatible(rec, fp)
    if rec.legacy then return true end
    if rec.sessionFile ~= "" and fp.sessionFile ~= "" and rec.sessionFile ~= fp.sessionFile then
        return false
    end
    if rec.tabName ~= "" and fp.tabName ~= "" and rec.tabName ~= fp.tabName then
        return false
    end
    if rec.host ~= fp.host then return false end
    -- For unnamed terminal/agent tabs on reopen, require the saved position to match too so a
    -- recycled tab ID after daemon restart doesn't steal another tab's pin in the same project.
    if rec.tabName == "" and isTerminalFamily(rec.kind) and rec.position > 0 and fp.position > 0 and rec.position ~= fp.position then
        return false
    end
    if rec.projectKey ~= "" and fp.projectKey ~= "" and rec.projectKey == fp.projectKey then
        return true
    end
    if rec.normPath ~= "" and fp.normPath ~= "" and rec.normPath == fp.normPath then
        return true
    end
    if rec.tabName ~= "" and fp.tabName == rec.tabName then
        return true
    end
    if rec.projectKey == "" and rec.normPath == "" and rec.tabName == "" then
        return true
    end
    return false
end

local function bestUnbound(bucket, usedTab, rec, filter)
    if not bucket then return nil end
    local best, bestScore = nil, -1
    for _, entry in bucket do
        if not usedTab[entry.tab.id] then
            local fp = entry.fp
            if not filter or filter(fp) then
                local score = 0
                if rec.sessionFile ~= "" and fp.sessionFile == rec.sessionFile then score += 1000 end
                if rec.tabName ~= "" and fp.tabName == rec.tabName then score += 200 end
                if rec.projectKey ~= "" and fp.projectKey == rec.projectKey then score += 100 end
                if rec.kind ~= "" and fp.kind == rec.kind then score += 50 end
                if rec.label ~= "" and fp.label == rec.label then score += 30 end
                if rec.position > 0 and fp.position > 0 then
                    score += math.max(0, 20 - math.abs(rec.position - fp.position))
                end
                if rec.id and fp.id == rec.id then score += 10 end
                if score > bestScore then
                    best, bestScore = entry, score
                end
            end
        end
    end
    return best
end

local function addBucket(map, key, entry)
    local bucket = map[key]
    if bucket then
        table.insert(bucket, entry)
    else
        map[key] = { entry }
    end
end

-- O(R + L) one-to-one matcher with O(L) steady-state fast path when all live tabs are already bound.
function M.match(records, liveTabs, existingBoundByTab)
    local liveById, liveEntries = {}, {}
    local totalLive = #liveTabs
    for i = 1, totalLive do
        local tab = liveTabs[i]
        local entry = { tab = tab, fp = M.fingerprint(tab) }
        liveById[tab.id] = entry
        liveEntries[i] = entry
    end

    local nextBoundByTab = {}
    local usedTab = {}
    local matchedRecord = {}
    local boundLiveCount, boundRecCount, rebindCount = 0, 0, 0
    local hasTentativeWithSf = false

    -- Step 1: Preserve existing live-session bindings first.
    if existingBoundByTab then
        for tabId, rec in existingBoundByTab do
            local entry = liveById[tabId]
            if entry and not matchedRecord[rec] and not usedTab[tabId] then
                local sfConflict = (not rec._confidence or rec._confidence > 1)
                    and rec.sessionFile ~= "" and entry.fp.sessionFile ~= ""
                    and rec.sessionFile ~= entry.fp.sessionFile
                if not sfConflict then
                    nextBoundByTab[tabId] = rec
                    usedTab[tabId] = true
                    matchedRecord[rec] = entry
                    boundLiveCount += 1
                    boundRecCount += 1
                    if rec._confidence and rec._confidence > 1 and rec.sessionFile ~= "" and entry.fp.sessionFile ~= rec.sessionFile then
                        hasTentativeWithSf = true
                    end
                end
            end
        end
    end

    -- Fast path: all live tabs or all saved records are already cleanly bound with no sessionFile upgrades possible.
    if (boundLiveCount == totalLive or boundRecCount == #records) and not hasTentativeWithSf then
        return nextBoundByTab, matchedRecord, 0
    end

    -- Build O(1) hash indexes over unbound live tabs only.
    local bySf, byNonTermPath, byProjTabName, bySessTabName, byProjSlot, byProjLabel = {}, {}, {}, {}, {}, {}
    local function indexEntry(entry)
        local fp = entry.fp
        if fp.sessionFile ~= "" then addBucket(bySf, fp.sessionFile, entry) end
        local hs = fp.host .. "\0" .. fp.sessionName
        if fp.normPath ~= "" and not isTerminalFamily(fp.kind) then
            addBucket(byNonTermPath, hs .. "\0" .. fp.kind .. "\0" .. fp.normPath, entry)
        end
        if fp.tabName ~= "" then
            addBucket(byProjTabName, hs .. "\0" .. fp.projectKey .. "\0" .. fp.tabName, entry)
            addBucket(bySessTabName, hs .. "\0" .. fp.tabName, entry)
        end
        if fp.projectKey ~= "" and fp.position > 0 then
            addBucket(byProjSlot, hs .. "\0" .. fp.projectKey .. "\0" .. tostring(fp.position), entry)
        end
        if fp.projectKey ~= "" and fp.label ~= "" then
            addBucket(byProjLabel, hs .. "\0" .. fp.projectKey .. "\0" .. fp.label, entry)
        end
    end

    for _, entry in liveEntries do
        if not usedTab[entry.tab.id] then indexEntry(entry) end
    end

    -- Step 1b: O(1) check whether an exact omp_session_file just resolved for an unbound live tab
    -- that belongs to a record bound only by a non-UUID tier (> 1).
    if hasTentativeWithSf then
        for _, rec in records do
            local cur = matchedRecord[rec]
            if cur and rec._confidence and rec._confidence > 1 and rec.sessionFile ~= "" and cur.fp.sessionFile ~= rec.sessionFile then
                local exact = bestUnbound(bySf[rec.sessionFile], usedTab, rec)
                if exact then
                    nextBoundByTab[cur.tab.id] = nil
                    usedTab[cur.tab.id] = nil
                    matchedRecord[rec] = nil
                    indexEntry(cur)
                end
            end
        end
    end

    local function bind(rec, entry, confidence)
        nextBoundByTab[entry.tab.id] = rec
        usedTab[entry.tab.id] = true
        matchedRecord[rec] = entry
        rec._confidence = confidence
        if rec.id ~= entry.tab.id then rebindCount += 1 end
    end

    -- Collect unbound records once so each tier scans only unmatched records.
    local unboundRecs = {}
    for _, rec in records do
        if not matchedRecord[rec] then table.insert(unboundRecs, rec) end
    end
    if #unboundRecs == 0 then
        return nextBoundByTab, matchedRecord, rebindCount
    end

    -- Tier 1: Exact OMP session file UUID.
    for _, rec in unboundRecs do
        if not matchedRecord[rec] and rec.sessionFile ~= "" then
            local match = bestUnbound(bySf[rec.sessionFile], usedTab, rec)
            if match then bind(rec, match, 1) end
        end
    end

    -- Tier 2: Exact numeric tab.id (with compatibility guard against recycled IDs after daemon restart).
    for _, rec in unboundRecs do
        if not matchedRecord[rec] and type(rec.id) == "number" then
            local entry = liveById[rec.id]
            if entry and not usedTab[entry.tab.id] and isIdCompatible(rec, entry.fp) then
                bind(rec, entry, 2)
            end
        end
    end

    -- Tier 3: Exact non-terminal file / doc / git / notebook / board / browser path.
    for _, rec in unboundRecs do
        if not matchedRecord[rec] and rec.normPath ~= "" and not isTerminalFamily(rec.kind) then
            local key = rec.host .. "\0" .. rec.sessionName .. "\0" .. rec.kind .. "\0" .. rec.normPath
            local match = bestUnbound(byNonTermPath[key], usedTab, rec)
            if match then bind(rec, match, 3) end
        end
    end

    -- Tier 4: Exact user-assigned tab.name (same host + session + project, else unique within host + session).
    for _, rec in unboundRecs do
        if not matchedRecord[rec] and rec.tabName ~= "" then
            local hs = rec.host .. "\0" .. rec.sessionName
            local match = bestUnbound(byProjTabName[hs .. "\0" .. rec.projectKey .. "\0" .. rec.tabName], usedTab, rec)
            if not match then
                local bucket = bySessTabName[hs .. "\0" .. rec.tabName]
                if bucket then
                    local sole
                    local count = 0
                    for _, entry in bucket do
                        if not usedTab[entry.tab.id] then
                            sole = entry
                            count += 1
                            if count > 1 then break end
                        end
                    end
                    if count == 1 then match = sole end
                end
            end
            if match then bind(rec, match, 4) end
        end
    end

    -- Tier 5: Exact restored session slot (host + sessionName + projectKey + compatible kind + position).
    for _, rec in unboundRecs do
        if not matchedRecord[rec] and rec.projectKey ~= "" and rec.position > 0 then
            local key = rec.host .. "\0" .. rec.sessionName .. "\0" .. rec.projectKey .. "\0" .. tostring(rec.position)
            local match = bestUnbound(byProjSlot[key], usedTab, rec, function(fp)
                return kindsCompatible(rec.kind, fp.kind)
            end)
            if match then bind(rec, match, 5) end
        end
    end

    -- Tier 6: Fallback same project + compatible kind + displayed label (closest position).
    for _, rec in unboundRecs do
        if not matchedRecord[rec] and rec.projectKey ~= "" and rec.label ~= "" then
            local key = rec.host .. "\0" .. rec.sessionName .. "\0" .. rec.projectKey .. "\0" .. rec.label
            local match = bestUnbound(byProjLabel[key], usedTab, rec, function(fp)
                return kindsCompatible(rec.kind, fp.kind)
            end)
            if match then bind(rec, match, 6) end
        end
    end

    return nextBoundByTab, matchedRecord, rebindCount
end

-- Updates a record's stored fingerprint from a matched live tab.
-- Returns true when a structural field changed (or label changed outside the throttle window).
function M.syncRecord(rec, fp, nowMs)
    local structural = false
    if rec.legacy then rec.legacy = nil; structural = true end
    if rec.id ~= fp.id then rec.id = fp.id; structural = true end
    if fp.host ~= rec.host then rec.host = fp.host; structural = true end
    if fp.sessionName ~= "" and fp.sessionName ~= rec.sessionName then rec.sessionName = fp.sessionName; structural = true end
    if fp.projectKey ~= "" and fp.projectKey ~= rec.projectKey then rec.projectKey = fp.projectKey; structural = true end
    if fp.tabName ~= rec.tabName then rec.tabName = fp.tabName; structural = true end
    if fp.kind ~= "" and fp.kind ~= rec.kind then rec.kind = fp.kind; structural = true end
    if fp.normPath ~= "" and fp.normPath ~= rec.normPath then rec.normPath = fp.normPath; structural = true end
    if fp.position > 0 and fp.position ~= rec.position then rec.position = fp.position; structural = true end
    if fp.sessionFile ~= "" and fp.sessionFile ~= rec.sessionFile then rec.sessionFile = fp.sessionFile; structural = true end
    if rec.missingSince ~= nil then rec.missingSince = nil; structural = true end

    local labelChanged = false
    if fp.label ~= "" and fp.label ~= rec.label then
        rec.label = fp.label
        if not rec._lastLabelSaveMs or (nowMs - rec._lastLabelSaveMs >= 15000) then
            rec._lastLabelSaveMs = nowMs
            labelChanged = true
        end
    end
    return structural or labelChanged
end

local function normalizePinItem(raw)
    if type(raw) ~= "table" or type(raw.order) ~= "number" then return nil end
    local uid = if type(raw.uid) == "string" and raw.uid ~= "" then raw.uid else nil
    if not uid then
        pinUidSeq += 1
        uid = "pin-" .. tostring(pinUidSeq)
    else
        local num = tonumber(uid:match("^pin%-(%d+)$") or "")
        if num and num > pinUidSeq then pinUidSeq = num end
    end
    if raw.order > pinSeq then pinSeq = raw.order end
    return {
        uid = uid,
        order = raw.order,
        id = if type(raw.id) == "number" then raw.id else nil,
        host = if type(raw.host) == "string" then raw.host else "",
        sessionName = if type(raw.sessionName) == "string" then raw.sessionName else "",
        projectKey = if type(raw.projectKey) == "string" then raw.projectKey else "",
        tabName = if type(raw.tabName) == "string" then raw.tabName else "",
        kind = if type(raw.kind) == "string" then raw.kind else "",
        normPath = if type(raw.normPath) == "string" then raw.normPath else "",
        label = if type(raw.label) == "string" then raw.label else "",
        position = if type(raw.position) == "number" then raw.position else 0,
        sessionFile = if type(raw.sessionFile) == "string" then raw.sessionFile else "",
        updatedAt = if type(raw.updatedAt) == "number" then raw.updatedAt else os.time(),
        missingSince = if type(raw.missingSince) == "number" then raw.missingSince else nil,
        legacy = raw.legacy == true,
    }
end

local function serializePinItem(item)
    return {
        uid = item.uid,
        order = item.order,
        id = item.id,
        host = item.host,
        sessionName = item.sessionName,
        projectKey = item.projectKey,
        tabName = item.tabName,
        kind = item.kind,
        normPath = item.normPath,
        label = item.label,
        position = item.position,
        sessionFile = if item.sessionFile ~= "" then item.sessionFile else nil,
        updatedAt = item.updatedAt,
        missingSince = item.missingSince,
        legacy = if item.legacy then true else nil,
    }
end

local function rebuildPinIndex()
    table.sort(pinItems, function(a, b)
        if a.order ~= b.order then return a.order > b.order end
        return a.uid < b.uid
    end)
    pinByUid = {}
    for _, item in pinItems do pinByUid[item.uid] = item end
end

local function writePinsNow()
    if pinSaveTimer then pinSaveTimer:cancel(); pinSaveTimer = nil end
    pinsDirty = false
    pinRev += 1
    lastKnownRev = pinRev
    local out = {}
    for _, item in pinItems do
        table.insert(out, serializePinItem(item))
    end
    tern.kv.set(pinnedKvKey, {
        rev = pinRev,
        seq = pinSeq,
        uidSeq = pinUidSeq,
        items = tern.json.array(out),
    })
end

local function scheduleSavePins()
    pinsDirty = true
    if pinSaveTimer then return end
    pinSaveTimer = tern.timer(saveDebounceMs, function()
        pinSaveTimer = nil
        if pinsDirty then writePinsNow() end
    end)
end

function M.flushPins()
    if pinsDirty then writePinsNow()
    elseif pinSaveTimer then pinSaveTimer:cancel(); pinSaveTimer = nil end
end

local function loadPinsFromKv(saved)
    pinItems = {}
    pinByUid = {}
    if type(saved) == "table" then
        pinRev = if type(saved.rev) == "number" then saved.rev else 0
        pinSeq = if type(saved.seq) == "number" then saved.seq else 0
        pinUidSeq = if type(saved.uidSeq) == "number" then saved.uidSeq else 0
        if type(saved.items) == "table" then
            for _, raw in saved.items do
                local item = normalizePinItem(raw)
                if item then table.insert(pinItems, item) end
            end
        end
    else
        pinRev, pinSeq, pinUidSeq = 0, 0, 0
    end
    rebuildPinIndex()
    lastKnownRev = pinRev
end

function M.initPins(stateKey)
    if pinSaveTimer then pinSaveTimer:cancel(); pinSaveTimer = nil end
    pinsDirty = false
    startedAtMs = tern.now()
    boundPinByTab = {}
    local saved = tern.kv.get(pinnedKvKey)
    if type(saved) == "table" and type(saved.items) == "table" then
        loadPinsFromKv(saved)
        return
    end
    -- Migrate legacy per-window pinned map (`window:<key>:pinned` or `window::pinned`).
    pinItems, pinByUid, pinSeq, pinRev, pinUidSeq = {}, {}, 0, 0, 0
    local legacyKeys = { stateKey .. ":pinned" }
    if stateKey ~= "window:" then table.insert(legacyKeys, "window::pinned") end
    local migrated = false
    local seenIds = {}
    for _, key in legacyKeys do
        local legacy = tern.kv.get(key)
        if type(legacy) == "table" then
            for idStr, order in legacy do
                local num = tonumber(idStr)
                if num and type(order) == "number" and not seenIds[num] then
                    seenIds[num] = true
                    pinUidSeq += 1
                    if order > pinSeq then pinSeq = order end
                    table.insert(pinItems, {
                        uid = "pin-" .. tostring(pinUidSeq),
                        order = order,
                        id = num,
                        host = "",
                        sessionName = "",
                        projectKey = "",
                        tabName = "",
                        kind = "",
                        normPath = "",
                        label = "",
                        position = 0,
                        sessionFile = "",
                        updatedAt = os.time(),
                        legacy = true,
                    })
                    migrated = true
                end
            end
            tern.kv.set(key, nil)
        end
    end
    rebuildPinIndex()
    if migrated then
        writePinsNow()
    else
        lastKnownRev = 0
    end
end

function M.refreshPins()
    if pinsDirty then return false end
    local saved = tern.kv.get(pinnedKvKey)
    if type(saved) ~= "table" then return false end
    local rev = if type(saved.rev) == "number" then saved.rev else 0
    if rev == lastKnownRev then return false end
    local oldByUidTab = {}
    for tabId, item in boundPinByTab do
        oldByUidTab[item.uid] = tabId
    end
    loadPinsFromKv(saved)
    local nextBound = {}
    for _, item in pinItems do
        local tabId = oldByUidTab[item.uid]
        if tabId then nextBound[tabId] = item end
    end
    boundPinByTab = nextBound
    return true
end

function M.reconcilePins(liveTabs, hasConnectingHost)
    if #pinItems == 0 then
        boundPinByTab = {}
        return false
    end
    local nextBound, matched, rebinds = M.match(pinItems, liveTabs, boundPinByTab)
    boundPinByTab = nextBound

    local nowMs = tern.now()
    local nowSec = os.time()
    local dirty = rebinds > 0
    local hasUnknownTerminal = false
    for _, tab in liveTabs do
        if tab.canArchive and (not tab.sessionFile or tab.sessionFile == "") then
            hasUnknownTerminal = true
            break
        end
    end
    local needsInspect = false
    local pastGrace = (nowMs - startedAtMs) >= startupGraceMs and not hasConnectingHost and #liveTabs > 0

    local dormant = {}
    for _, item in pinItems do
        local entry = matched[item]
        if entry then
            if M.syncRecord(item, entry.fp, nowMs) then dirty = true end
            if hasUnknownTerminal and item.sessionFile ~= "" and item._confidence and item._confidence > 1 and entry.fp.sessionFile == "" then
                needsInspect = true
            end
        else
            if hasUnknownTerminal and item.sessionFile ~= "" then needsInspect = true end
            if pastGrace then
                if not item.missingSince then
                    item.missingSince = nowSec
                    dirty = true
                end
                table.insert(dormant, item)
            end
        end
    end

    if #dormant > 0 then
        local expired = {}
        for _, item in dormant do
            if item.missingSince and (nowSec - item.missingSince) >= dormantTtlSec then
                expired[item.uid] = true
            end
        end
        if #dormant > maxDormantPins then
            table.sort(dormant, function(a, b)
                return (a.missingSince or 0) < (b.missingSince or 0)
            end)
            for i = 1, #dormant - maxDormantPins do
                expired[dormant[i].uid] = true
            end
        end
        if next(expired) ~= nil then
            local kept = {}
            for _, item in pinItems do
                if not expired[item.uid] then table.insert(kept, item) end
            end
            pinItems = kept
            rebuildPinIndex()
            dirty = true
        end
    end

    if dirty then scheduleSavePins() end
    return needsInspect
end

function M.pinnedMap()
    local map = {}
    for tabId, item in boundPinByTab do
        map[tostring(tabId)] = item.order
    end
    return map
end

function M.isPinned(tabId)
    return boundPinByTab[tabId] ~= nil
end

function M.pinTab(tab)
    if not tab then return false end
    M.refreshPins()
    if boundPinByTab[tab.id] then return false end
    local fp = M.fingerprint(tab)
    pinSeq += 1
    pinUidSeq += 1
    local item = {
        uid = "pin-" .. tostring(pinUidSeq),
        order = pinSeq,
        id = fp.id,
        host = fp.host,
        sessionName = fp.sessionName,
        projectKey = fp.projectKey,
        tabName = fp.tabName,
        kind = fp.kind,
        normPath = fp.normPath,
        label = fp.label,
        position = fp.position,
        sessionFile = fp.sessionFile,
        updatedAt = os.time(),
        _confidence = 1,
    }
    table.insert(pinItems, item)
    rebuildPinIndex()
    boundPinByTab[tab.id] = item
    writePinsNow()
    return true
end

function M.unpinTab(tabId)
    if not tabId then return false end
    M.refreshPins()
    local item = boundPinByTab[tabId]
    if not item then
        for _, candidate in pinItems do
            if candidate.id == tabId then item = candidate; break end
        end
    end
    if not item then return false end
    local kept = {}
    for _, existing in pinItems do
        if existing.uid ~= item.uid then table.insert(kept, existing) end
    end
    pinItems = kept
    boundPinByTab[tabId] = nil
    rebuildPinIndex()
    writePinsNow()
    return true
end

function M.removeClosedTab(tabId)
    return M.unpinTab(tabId)
end

return M
