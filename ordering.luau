local tabstate = require("./tabstate")
local ui = tern.ui
local M = {}

local sortModeKey = "tab-sort-mode"
local autoPinKey = "auto-pin-recent"
local autoPinLimitKey = "auto-pin-limit"
local orderKvKey = "tabs-order"
local validLimits = { [1] = true, [3] = true, [5] = true }

local dormantTtlSec = 14 * 24 * 3600
local maxDormantItems = 128
local startupGraceMs = 15000
local saveDebounceMs = 500

local initialized = false
local startedAtMs = 0
local sortMode = "recent"
local autoPinRecent = false
local autoPinLimit = 3
local popoverOpen = false

local fixedSeq, recentSeq, interactedSeq, uidSeq = 0, 0, 0, 0
local orderItems = {}
local boundByTab = {}
local orderDirty = false
local orderSaveTimer = nil
local orderListSorted = false

local function normalizeMode(value)
    return if value == "fixed" then "fixed" else "recent"
end

local function normalizeLimit(value)
    return if type(value) == "number" and validLimits[value] then value else 3
end

local function nextUid()
    uidSeq += 1
    return "ord-" .. tostring(uidSeq)
end

local function serializeItem(item)
    return {
        uid = item.uid,
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
        fixed = if item.fixed and item.fixed > 0 then item.fixed else nil,
        recent = if item.recent and item.recent > 0 then item.recent else nil,
        interacted = if item.interacted and item.interacted > 0 then item.interacted else nil,
        dismissed = if item.dismissed and item.dismissed > 0 then item.dismissed else nil,
        missingSince = item.missingSince,
        legacy = if item.legacy then true else nil,
    }
end

local function writeOrderNow()
    if orderSaveTimer then orderSaveTimer:cancel(); orderSaveTimer = nil end
    orderDirty = false
    if #orderItems == 0 then
        tern.kv.set(orderKvKey, nil)
        return
    end
    local out = {}
    for _, item in orderItems do
        table.insert(out, serializeItem(item))
    end
    tern.kv.set(orderKvKey, {
        fixedSeq = fixedSeq,
        recentSeq = recentSeq,
        interactedSeq = interactedSeq,
        uidSeq = uidSeq,
        items = tern.json.array(out),
    })
end

local function saveOrder(immediate)
    if immediate then
        writeOrderNow()
        return
    end
    orderDirty = true
    if orderSaveTimer then return end
    orderSaveTimer = tern.timer(saveDebounceMs, function()
        orderSaveTimer = nil
        if orderDirty then writeOrderNow() end
    end)
end

function M.flush()
    if orderDirty then writeOrderNow()
    elseif orderSaveTimer then orderSaveTimer:cancel(); orderSaveTimer = nil end
end

local function normalizeItem(raw)
    if type(raw) ~= "table" then return nil end
    local uid = if type(raw.uid) == "string" and raw.uid ~= "" then raw.uid else nextUid()
    local num = tonumber(uid:match("^ord%-(%d+)$") or "")
    if num and num > uidSeq then uidSeq = num end
    local f = if type(raw.fixed) == "number" and raw.fixed > 0 then raw.fixed else 0
    local r = if type(raw.recent) == "number" and raw.recent > 0 then raw.recent else 0
    local i = if type(raw.interacted) == "number" and raw.interacted > 0 then raw.interacted else 0
    local d = if type(raw.dismissed) == "number" and raw.dismissed > 0 then raw.dismissed else nil
    if f > fixedSeq then fixedSeq = f end
    if r > recentSeq then recentSeq = r end
    if i > interactedSeq then interactedSeq = i end
    return {
        uid = uid,
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
        fixed = f,
        recent = r,
        interacted = i,
        dismissed = d,
        missingSince = if type(raw.missingSince) == "number" then raw.missingSince else nil,
        legacy = raw.legacy == true,
    }
end

local function makeRecord(tabId, fp)
    local item = {
        uid = nextUid(),
        id = tabId,
        host = if fp then fp.host else "",
        sessionName = if fp then fp.sessionName else "",
        projectKey = if fp then fp.projectKey else "",
        tabName = if fp then fp.tabName else "",
        kind = if fp then fp.kind else "",
        normPath = if fp then fp.normPath else "",
        label = if fp then fp.label else "",
        position = if fp then fp.position else 0,
        sessionFile = if fp then fp.sessionFile else "",
        fixed = 0,
        recent = 0,
        interacted = 0,
        dismissed = nil,
        missingSince = nil,
        legacy = fp == nil,
        _confidence = if fp then 1 else 2,
    }
    table.insert(orderItems, item)
    boundByTab[tabId] = item
    return item
end

local function recordForTab(tabId)
    local rec = boundByTab[tabId]
    if rec then return rec end
    for _, item in orderItems do
        if item.id == tabId then
            boundByTab[tabId] = item
            return item
        end
    end
    return nil
end

local function loadLegacyMap(saved)
    if type(saved) ~= "table" then return false end
    local ids = {}
    local function collectIds(tbl)
        if type(tbl) ~= "table" then return end
        for k, v in tbl do
            local num = tonumber(k)
            if num and type(v) == "number" and v > 0 then ids[num] = true end
        end
    end
    collectIds(saved.fixed)
    collectIds(saved.recent)
    collectIds(saved.interacted)
    collectIds(saved.dismissed)
    if next(ids) == nil then return false end
    local fMap = if type(saved.fixed) == "table" then saved.fixed else {}
    local rMap = if type(saved.recent) == "table" then saved.recent else {}
    local iMap = if type(saved.interacted) == "table" then saved.interacted else {}
    local dMap = if type(saved.dismissed) == "table" then saved.dismissed else {}
    for num in ids do
        local k = tostring(num)
        local item = normalizeItem({
            id = num,
            fixed = fMap[k],
            recent = rMap[k],
            interacted = iMap[k],
            dismissed = dMap[k],
            legacy = true,
        })
        if item then table.insert(orderItems, item) end
    end
    if type(saved.fixedSeq) == "number" and saved.fixedSeq > fixedSeq then fixedSeq = saved.fixedSeq end
    if type(saved.recentSeq) == "number" and saved.recentSeq > recentSeq then recentSeq = saved.recentSeq end
    if type(saved.interactedSeq) == "number" and saved.interactedSeq > interactedSeq then interactedSeq = saved.interactedSeq end
    return #orderItems > 0
end

function M.refreshPrefs()
    local nextMode = normalizeMode(tern.kv.get(sortModeKey))
    local nextAuto = tern.kv.get(autoPinKey) == true
    local nextLimit = normalizeLimit(tern.kv.get(autoPinLimitKey))
    local changed = nextMode ~= sortMode or nextAuto ~= autoPinRecent or nextLimit ~= autoPinLimit
    sortMode, autoPinRecent, autoPinLimit = nextMode, nextAuto, nextLimit
    return changed
end

function M.init(windowStateKey, initialTabs)
    if orderSaveTimer then orderSaveTimer:cancel(); orderSaveTimer = nil end
    orderDirty = false
    orderListSorted = false
    startedAtMs = tern.now()
    M.refreshPrefs()
    orderItems, boundByTab = {}, {}
    fixedSeq, recentSeq, interactedSeq, uidSeq = 0, 0, 0, 0

    local saved = tern.kv.get(orderKvKey)
    local hasSaved = false
    if type(saved) == "table" and type(saved.items) == "table" then
        fixedSeq = if type(saved.fixedSeq) == "number" then saved.fixedSeq else 0
        recentSeq = if type(saved.recentSeq) == "number" then saved.recentSeq else 0
        interactedSeq = if type(saved.interactedSeq) == "number" then saved.interactedSeq else 0
        uidSeq = if type(saved.uidSeq) == "number" then saved.uidSeq else 0
        for _, raw in saved.items do
            local item = normalizeItem(raw)
            if item then table.insert(orderItems, item) end
        end
        hasSaved = #orderItems > 0
    else
        local legacyKeys = { windowStateKey .. ":tabs-order" }
        if windowStateKey ~= "window:" then table.insert(legacyKeys, "window::tabs-order") end
        for _, key in legacyKeys do
            local legacy = tern.kv.get(key)
            if loadLegacyMap(legacy) then
                hasSaved = true
                tern.kv.set(key, nil)
                saveOrder(true)
                break
            end
        end
    end

    if not hasSaved and type(initialTabs) == "table" and #initialTabs > 0 then
        -- Preserve existing tab order on first upgrade; only newly opened tabs prepend afterwards.
        local total = #initialTabs
        for i, tab in initialTabs do
            local rec = makeRecord(tab.id, nil)
            rec.fixed = total - i + 1
        end
        if total > fixedSeq then fixedSeq = total end
        saveOrder(true)
    end
    initialized = true
end

function M.mode()
    return sortMode
end

function M.autoPin()
    return autoPinRecent
end

function M.autoPinCap()
    return autoPinLimit
end

function M.isOpen()
    return popoverOpen
end

function M.closePopover()
    if not popoverOpen then return false end
    popoverOpen = false
    return true
end

function M.setMode(value)
    local nextMode = normalizeMode(value)
    if nextMode == sortMode then return false end
    sortMode = nextMode
    tern.kv.set(sortModeKey, sortMode)
    return true
end

function M.setAutoPin(enabled)
    local nextAuto = enabled == true
    if nextAuto == autoPinRecent then return false end
    autoPinRecent = nextAuto
    tern.kv.set(autoPinKey, autoPinRecent)
    return true
end

function M.setAutoPinCap(limit)
    local nextLimit = normalizeLimit(limit)
    if nextLimit == autoPinLimit then return false end
    autoPinLimit = nextLimit
    tern.kv.set(autoPinLimitKey, autoPinLimit)
    return true
end

function M.onTabCreated(tabId)
    if not initialized or not tabId then return false end
    local existing = recordForTab(tabId)
    if existing and existing.fixed > 0 then return false end
    local rec = existing or makeRecord(tabId, nil)
    fixedSeq += 1
    rec.fixed = fixedSeq
    recentSeq += 1
    rec.recent = recentSeq
    orderListSorted = false
    saveOrder(false)
    return true
end

function M.onInteraction(tabId)
    if not initialized or not tabId then return false end
    local rec = recordForTab(tabId) or makeRecord(tabId, nil)
    local changed = false
    if rec.fixed <= 0 then
        fixedSeq += 1
        rec.fixed = fixedSeq
        changed = true
    end
    if rec.recent ~= recentSeq or recentSeq == 0 then
        recentSeq += 1
        rec.recent = recentSeq
        changed = true
    end
    if rec.dismissed ~= nil or rec.interacted ~= interactedSeq or interactedSeq == 0 then
        rec.dismissed = nil
        interactedSeq += 1
        rec.interacted = interactedSeq
        changed = true
    end
    if changed then
        orderListSorted = false
        saveOrder(false)
    end
    return changed and (sortMode == "recent" or autoPinRecent)
end

function M.suppressAutoPin(tabId)
    if not initialized or not tabId then return false end
    local rec = recordForTab(tabId)
    if rec and rec.interacted > 0 then
        rec.dismissed = rec.interacted
        saveOrder(true)
        return true
    end
    return false
end

function M.clearSuppression(tabId)
    if not initialized or not tabId then return false end
    local rec = recordForTab(tabId)
    if rec and rec.dismissed ~= nil then
        rec.dismissed = nil
        saveOrder(true)
        return true
    end
    return false
end

-- Called only after an explicit live-session tab close (never during Tern shutdown/unload).
function M.onTabClosed(tabId)
    if not tabId then return false end
    local rec = recordForTab(tabId)
    if not rec then return false end
    local kept = {}
    for _, item in orderItems do
        if item.uid ~= rec.uid then table.insert(kept, item) end
    end
    orderItems = kept
    boundByTab[tabId] = nil
    if initialized then saveOrder(true) end
    return true
end

function M.reconcileTabs(liveTabs, hasConnectingHost)
    if not initialized then return false end

    -- Only sort orderItems when there are live tabs not yet bound in this window session.
    local hasUnboundLive = false
    for _, tab in liveTabs do
        if not boundByTab[tab.id] then hasUnboundLive = true; break end
    end
    if hasUnboundLive and not orderListSorted and #orderItems > 1 then
        table.sort(orderItems, function(a, b)
            if a.interacted ~= b.interacted then return a.interacted > b.interacted end
            if a.recent ~= b.recent then return a.recent > b.recent end
            if a.fixed ~= b.fixed then return a.fixed > b.fixed end
            return a.uid < b.uid
        end)
        orderListSorted = true
    end

    local nextBound, matched, rebinds = tabstate.match(orderItems, liveTabs, boundByTab)
    boundByTab = nextBound

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
    for _, item in orderItems do
        local entry = matched[item]
        if entry then
            if tabstate.syncRecord(item, entry.fp, nowMs) then dirty = true end
            if hasUnknownTerminal and item.interacted > 0 and item.sessionFile ~= "" and item._confidence and item._confidence > 1 and entry.fp.sessionFile == "" then
                needsInspect = true
            end
        else
            if hasUnknownTerminal and item.interacted > 0 and item.sessionFile ~= "" then needsInspect = true end
            if pastGrace then
                if not item.missingSince then
                    item.missingSince = nowSec
                    dirty = true
                end
                table.insert(dormant, item)
            end
        end
    end

    -- Assign new order entries to any brand-new live tabs not yet matched.
    local unseen = {}
    for _, tab in liveTabs do
        if not boundByTab[tab.id] then table.insert(unseen, tab) end
    end
    if #unseen > 0 then
        if #orderItems == 0 then
            -- First-ever seed (when init had no tabs yet): preserve current visual order.
            local total = #unseen
            for i, tab in unseen do
                local rec = makeRecord(tab.id, tabstate.fingerprint(tab))
                rec.fixed = total - i + 1
            end
            if total > fixedSeq then fixedSeq = total end
        else
            for _, tab in unseen do
                local rec = makeRecord(tab.id, tabstate.fingerprint(tab))
                fixedSeq += 1
                rec.fixed = fixedSeq
                recentSeq += 1
                rec.recent = recentSeq
            end
        end
        orderListSorted = false
        dirty = true
    end

    -- Garbage-collect only long-expired dormant entries (>14 days or beyond cap).
    if #dormant > 0 then
        local expired = {}
        for _, item in dormant do
            if item.missingSince and (nowSec - item.missingSince) >= dormantTtlSec then
                expired[item.uid] = true
            end
        end
        if #dormant > maxDormantItems then
            table.sort(dormant, function(a, b)
                return (a.missingSince or 0) < (b.missingSince or 0)
            end)
            for i = 1, #dormant - maxDormantItems do
                expired[dormant[i].uid] = true
            end
        end
        if next(expired) ~= nil then
            local kept = {}
            for _, item in orderItems do
                if not expired[item.uid] then table.insert(kept, item) end
            end
            orderItems = kept
            dirty = true
        end
    end

    if dirty then saveOrder(false) end
    return needsInspect
end

function M.sortGroupTabs(tabs)
    table.sort(tabs, function(a, b)
        local ra, rb = recordForTab(a.id), recordForTab(b.id)
        if sortMode == "recent" then
            local ar = if ra then ra.recent else 0
            local br = if rb then rb.recent else 0
            if ar ~= br then return ar > br end
        end
        local af = if ra then ra.fixed else 0
        local bf = if rb then rb.fixed else 0
        if af ~= bf then return af > bf end
        return a.id > b.id
    end)
end

function M.selectAutoPinned(groups, pinned)
    if not autoPinRecent then return {}, {} end
    local candidates = {}
    for _, g in groups do
        for _, tab in g.tabs do
            local idKey = tostring(tab.id)
            if not pinned[idKey] then
                local rec = recordForTab(tab.id)
                local score = if rec then rec.interacted else 0
                local suppressed = if rec then rec.dismissed else nil
                if score > 0 and (not suppressed or score > suppressed) then
                    table.insert(candidates, { tab = tab, score = score, recent = rec.recent })
                end
            end
        end
    end
    table.sort(candidates, function(a, b)
        if a.score ~= b.score then return a.score > b.score end
        if a.recent ~= b.recent then return a.recent > b.recent end
        return a.tab.id > b.tab.id
    end)
    local list, set = {}, {}
    local cap = math.min(#candidates, autoPinLimit)
    for i = 1, cap do
        local tab = candidates[i].tab
        table.insert(list, tab)
        set[tab.id] = true
    end
    return list, set
end

function M.signature()
    return { sortMode, autoPinRecent, autoPinLimit, popoverOpen }
end

local function summaryTip()
    local modeLabel = if sortMode == "recent" then "最近交互优先" else "固定顺序"
    local pinLabel = if autoPinRecent then ("已开启（最多 " .. tostring(autoPinLimit) .. " 个）") else "未开启"
    return "标签排序与自动置顶设置\n排序模式：" .. modeLabel .. "\n最近交互自动放置顶：" .. pinLabel
end

local function segButton(text, key, act, active, title)
    return ui.button(text, {
        key = key,
        role = key,
        variant = "quiet",
        size = "sm",
        on = active,
        title = title,
        actions = { click = act },
    })
end

function M.trigger()
    local className = "pt-sort-trigger"
    if popoverOpen then className ..= " pt-sort-trigger-open" end
    if autoPinRecent then className ..= " pt-sort-trigger-pin" end
    local glyph = if sortMode == "recent" then "⇅" else "≡"
    local children = {
        ui.el("span", { class = "pt-sort-trigger-glyph", text = glyph }),
    }
    if autoPinRecent then
        table.insert(children, ui.el("span", { class = "pt-sort-trigger-dot", attrs = { ["aria-hidden"] = "true" } }))
    end
    return ui.el("button", {
        key = "sort-toggle",
        role = "pt-sort-toggle",
        class = className,
        title = summaryTip(),
        aria = "标签排序与自动置顶设置",
        attrs = { ["aria-expanded"] = tostring(popoverOpen) },
        actions = { click = "sort-toggle" },
    }, children)
end

function M.popover()
    if not popoverOpen then return nil end
    local modeDesc = if sortMode == "recent"
        then "有对话或命令交互时自动排到工作区最前；新开标签始终最前。"
        else "保持现有标签位置不变；新开标签始终排到工作区最前。"

    local cardChildren = {
        ui.el("div", { key = "mode-sec", class = "pt-sort-section" }, {
            ui.el("div", { class = "pt-sort-heading", text = "工作区标签排序" }),
            ui.el("div", { key = "mode-seg", class = "pt-sort-seg" }, {
                segButton("最近交互", "pt-sort-recent", "sort-mode-recent", sortMode == "recent",
                    "有对话消息或终端命令交互时自动排到工作区前面"),
                segButton("固定顺序", "pt-sort-fixed", "sort-mode-fixed", sortMode == "fixed",
                    "保持标签固定位置，仅新开标签排在工作区最前"),
            }),
            ui.el("div", { class = "pt-sort-desc", text = modeDesc }),
        }),
        ui.el("div", { key = "sep", class = "pt-sort-sep" }),
    }

    local autoSection = {
        ui.el("button", {
            key = "auto-pin-toggle",
            role = "pt-auto-pin-toggle",
            class = if autoPinRecent then "pt-sort-switch-row pt-sort-switch-on" else "pt-sort-switch-row",
            title = "独立开关：将最近有交互的标签动态归入顶部「置顶」分组，不修改手动置顶",
            aria = "最近交互自动放置顶",
            attrs = { role = "switch", ["aria-checked"] = tostring(autoPinRecent) },
            actions = { click = "sort-autopin-toggle" },
        }, {
            ui.el("span", { class = "pt-sort-switch-label", text = "最近交互自动放置顶" }),
            ui.el("span", { class = "pt-sort-switch", attrs = { ["aria-hidden"] = "true" } }, {
                ui.el("span", { class = "pt-sort-switch-thumb" }),
            }),
        }),
        ui.el("div", { class = "pt-sort-desc", text = "将最近活跃的标签动态归入顶部「置顶」，不改手动置顶。" }),
    }

    if autoPinRecent then
        table.insert(autoSection, ui.el("div", { key = "limit-row", class = "pt-sort-limit-row" }, {
            ui.el("span", { class = "pt-sort-limit-label", text = "自动置顶上限" }),
            ui.el("div", { key = "limit-seg", class = "pt-sort-seg pt-sort-limit-seg" }, {
                segButton("1", "pt-sort-cap-1", "sort-cap-1", autoPinLimit == 1, "最多自动置顶 1 个最近交互标签"),
                segButton("3", "pt-sort-cap-3", "sort-cap-3", autoPinLimit == 3, "最多自动置顶 3 个最近交互标签"),
                segButton("5", "pt-sort-cap-5", "sort-cap-5", autoPinLimit == 5, "最多自动置顶 5 个最近交互标签"),
            }),
        }))
    end

    table.insert(cardChildren, ui.el("div", { key = "autopin-sec", class = "pt-sort-section" }, autoSection))

    return ui.el("div", { key = "sort-layer", class = "pt-sort-layer" }, {
        ui.el("div", {
            key = "sort-outside",
            class = "pt-sort-dismiss",
            attrs = { ["aria-hidden"] = "true" },
            actions = { click = "sort-close" },
        }),
        ui.el("div", {
            key = "sort-card",
            class = "pt-sort-card",
            aria = "标签排序与自动置顶设置",
            attrs = { role = "dialog" },
        }, cardChildren),
    })
end

function M.handle(act, onOpenPopover)
    if act == "sort-toggle" then
        popoverOpen = not popoverOpen
        if popoverOpen and onOpenPopover then onOpenPopover() end
        return true
    elseif act == "sort-close" then
        if popoverOpen then popoverOpen = false; return true end
        return false
    elseif act == "sort-mode-recent" then
        M.setMode("recent")
        return true
    elseif act == "sort-mode-fixed" then
        M.setMode("fixed")
        return true
    elseif act == "sort-autopin-toggle" then
        M.setAutoPin(not autoPinRecent)
        return true
    elseif act == "sort-cap-1" then
        M.setAutoPinCap(1)
        return true
    elseif act == "sort-cap-3" then
        M.setAutoPinCap(3)
        return true
    elseif act == "sort-cap-5" then
        M.setAutoPinCap(5)
        return true
    end
    return false
end

function M.chooseSortMode(cx, onChanged)
    cx:pick({
        placeholder = "工作区标签排序模式（新开标签始终最前）",
        action = "应用",
        items = {
            {
                label = "最近交互优先（默认）",
                detail = "有对话或命令交互的标签自动排到工作区前面",
                current = sortMode == "recent",
                mode = "recent",
            },
            {
                label = "固定顺序",
                detail = "保持标签位置固定，仅新开标签排到工作区最前",
                current = sortMode == "fixed",
                mode = "fixed",
            },
        },
    }):next(function(choice, _, current)
        if choice and M.setMode(choice.mode) and onChanged then
            onChanged(current)
        end
    end)
end

function M.chooseAutoPin(cx, onChanged)
    cx:pick({
        placeholder = "最近交互标签自动放置顶（独立开关，不改手动置顶）",
        action = "应用",
        items = {
            {
                label = "关闭（默认）",
                detail = "仅展示手动置顶的标签",
                current = not autoPinRecent,
                enabled = false,
            },
            {
                label = "开启（最多 1 个）",
                detail = "将最新 1 个交互标签动态归入顶部「置顶」",
                current = autoPinRecent and autoPinLimit == 1,
                enabled = true,
                limit = 1,
            },
            {
                label = "开启（最多 3 个）",
                detail = "将最近 3 个交互标签动态归入顶部「置顶」",
                current = autoPinRecent and autoPinLimit == 3,
                enabled = true,
                limit = 3,
            },
            {
                label = "开启（最多 5 个）",
                detail = "将最近 5 个交互标签动态归入顶部「置顶」",
                current = autoPinRecent and autoPinLimit == 5,
                enabled = true,
                limit = 5,
            },
        },
    }):next(function(choice, _, current)
        if not choice then return end
        local changed = M.setAutoPin(choice.enabled)
        if choice.limit then
            changed = M.setAutoPinCap(choice.limit) or changed
        end
        if changed and onChanged then
            onChanged(current)
        end
    end)
end

return M
