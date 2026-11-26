local projects = require("./projects")
local activity = require("./activity")
local indicators = require("./indicators")
local history = require("./history")
local tabstate = require("./tabstate")
local ordering = require("./ordering")
local ui = tern.ui
local action = "plugin.project-tabs.toggle"
local title = "项目标签"
local hideTopTabs = "#tabbar .tb-tabs { display: none !important; }"
local desktop = tern.runtime.os == "windows" or tern.runtime.os == "macos" or tern.runtime.os == "linux"

local initialized, shown, compactTop, unloading = false, true, false, false
local stateKey, ownerNote, panel, panelTab
local folded, remembered, repos = {}, {}, {}
local pinnedFoldKey = "__pinned__"
local roots = {}
local groupIds, nextGroupId = {}, 0
local targets, headings, groupByTab = {}, {}, {}
local lastView, lastContent, width = nil, nil, 0.21
local lastHistoryRevision
local pending, heartbeat, markerTimer, historyTimer, closeCommitTimer, inspectRetryTimer
local pendingClosed = {}
local lastInspectedUnknownKey = ""
local sync, rememberWidth

local function selectedTab(cx)
    local pane = cx.session:focused()
    return pane and cx.session:tab_of(pane)
end

local function requestUpdate(checkHidden, delayMs)
    if not initialized or pending or (not shown and checkHidden ~= true) then return end
    local waitMs = if type(delayMs) == "number" then delayMs else 30
    pending = tern.timer(waitMs, function(cx)
        pending = nil
        sync(cx)
    end)
end

local function requestMarkers()
    if not activity.hasChanges() then return end
    if not shown or not panel then activity.takeChanges(); return end
    if markerTimer then return end
    markerTimer = tern.timer(30, function(cx)
        markerTimer = nil
        if shown and panel and cx.session:tab_of(panel) == panelTab then
            indicators.flush(cx, panel, groupByTab)
        else
            requestUpdate()
        end
    end)
end

local function tick()
    if not shown or heartbeat then return end
    heartbeat = tern.timer(1100, function(cx)
        heartbeat = nil
        if shown then
            roots = tern.kv.get("project-folders") or {}
            indicators.motion(tern.kv.get("running-breathing") == true)
            tabstate.refreshPins()
            ordering.refreshPrefs()
            history.refreshArchive()
            sync(cx)
            tick()
        end
    end)
end

local function nativeTabs(compact)
    if compactTop ~= compact then
        tern.css("native-tabs", if compact then hideTopTabs else "")
        compactTop = compact
    end
end

local function refreshSessionFiles(cx)
    if unloading then return end
    tabstate.inspectSessions(cx:window_key(), function(current)
        if not unloading and shown and current then sync(current) end
    end)
end

local function initialize(cx)
    if initialized then return end
    unloading = false
    lastInspectedUnknownKey = ""
    local key = cx:window_key()
    stateKey = "window:" .. key
    ownerNote = "Project tab navigation (" .. key .. ")"
    shown = tern.kv.get(stateKey .. ":visible") ~= false
    local saved = tern.kv.get(stateKey .. ":folded")
    if type(saved) == "table" then folded = saved end
    local savedWidth = tern.kv.get(stateKey .. ":width")
    if type(savedWidth) == "number" and savedWidth > 0 and savedWidth < 1 then width = savedWidth end
    roots = tern.kv.get("project-folders") or {}
    indicators.motion(tern.kv.get("running-breathing") == true)
    tabstate.initPins(stateKey)
    ordering.init(stateKey, cx.session:tabs())
    activity.reconcile(cx, cx.session:panes(), false)
    initialized = true
end

-- A restored split and its canvas metadata can reach the window in separate updates.
-- Keep the sidebar already in the active tab, including when returning to another session.
local function reconcilePanels(cx, active)
    local owners, matches = {}, {}
    local keepTab = panel and cx.session:tab_of(panel)
    local keep = if keepTab then panel else nil
    for _, canvas in cx.canvas:list() do
        local id = canvas.pane
        owners[id] = canvas.owner
        if canvas.owner == "project-tabs" and canvas.about == ownerNote then
            local tab = cx.session:tab_of(id)
            if tab then
                table.insert(matches, id)
                if not keep or (tab == active and keepTab ~= active) then
                    keep, keepTab = id, tab
                end
            end
        end
    end
    if keep ~= panel then lastView = nil end
    panel, panelTab = keep, keepTab
    for _, id in matches do
        if id ~= keep then cx.layout:close(id) end
    end
    return owners
end

local function dropPanel(cx)
    reconcilePanels(cx, selectedTab(cx))
    local id = panel
    if id and panelTab then rememberWidth(cx.session:layout(panelTab)) end
    panel, panelTab, lastView = nil, nil, nil
    targets, headings, groupByTab = {}, {}, {}
    if markerTimer then markerTimer:cancel(); markerTimer = nil end
    if historyTimer then historyTimer:cancel(); historyTimer = nil end
    indicators.reset()
    nativeTabs(false)
    if id and cx.session:pane(id) then cx.layout:close(id) end
end

local function setVisible(cx, visible)
    shown = visible
    tern.kv.set(stateKey .. ":visible", visible)
    if visible then
        indicators.motion(tern.kv.get("running-breathing") == true)
        tabstate.refreshPins()
        ordering.refreshPrefs()
        sync(cx)
        tick()
    else
        history.collapse()
        ordering.closePopover()
        if pending then pending:cancel(); pending = nil end
        if heartbeat then heartbeat:cancel(); heartbeat = nil end
        dropPanel(cx)
    end
end

local function tabPanes(cx, active, owners)
    local byId, first, terminals, sessionFiles = {}, {}, {}, {}
    local awaitingPanel = false
    local panes = cx.session:panes()
    local interacted = activity.reconcile(cx, panes, initialized)
    if interacted then
        for tabId in interacted do ordering.onInteraction(tabId) end
    end
    for _, pane in panes do
        -- The title is only a hint to wait. Closing a pane requires the owner and window tag above.
        if pane.block == "tern.canvas" and not owners[pane.pane] and pane.title == title then
            if pane.tab == active then awaitingPanel = true end
        elseif pane.tab and pane.pane ~= panel and owners[pane.pane] ~= "project-tabs" and not pane.parked then
            byId[pane.pane] = pane
            if pane.kind == "terminal" or pane.kind == "agent" then terminals[pane.tab] = true end
            local sf = tabstate.sessionFileForPane(pane.pane)
            if sf and not sessionFiles[pane.tab] then sessionFiles[pane.tab] = sf end
            if not first[pane.tab] or (first[pane.tab].floating and not pane.floating) then
                first[pane.tab] = pane
            end
        end
    end
    return byId, first, awaitingPanel, terminals, sessionFiles
end

-- .git is a directory in a checkout and a file in a linked worktree. Cache all ancestors
-- visited so opening several files in one project doesn't walk to the drive root each time.
local function projectPath(cx, path, remote, quota)
    if not path or remote then return path end
    local custom = projects.projectRoot(path, roots)
    if custom then return custom end
    local key = projects.key(path)
    if repos[key] ~= nil then return repos[key] or path end
    if quota.left <= 0 then return path end
    quota.left -= 1
    if path:sub(1, 2) == "//" then
        -- Keep network share IO off the window thread.
        repos[key] = false
        cx.git:repo(path):next(function(repo)
            if repo and repo.root then repos[key] = projects.path(repo.root); requestUpdate() end
        end)
        return path
    end
    local root, at, visited = false, path, {}
    while at do
        local ancestor = projects.key(at)
        if repos[ancestor] ~= nil then root = repos[ancestor]; break end
        table.insert(visited, ancestor)
        local sep = if at:sub(-1) == "/" then "" else "/"
        if tern.fs.exists(at .. sep .. ".git") then root = at; break end
        at = projects.parent(at)
    end
    for _, ancestor in visited do repos[ancestor] = root end
    return root or path
end

local function collect(cx, active)
    local owners = reconcilePanels(cx, active)
    local panes, first, awaitingPanel, terminals, sessionFiles = tabPanes(cx, active, owners)
    local groups, byKey, liveTabs, liveTabList = {}, {}, {}, {}
    local hosts, sessions, hasConnectingHost = {}, {}, false
    for _, host in cx.hosts:list() do
        if host.kind == "remote" then
            if host.state == "connecting" or host.state == "reconnecting" or host.state == "stalled" then
                hasConnectingHost = true
            end
            for _, id in host.sessions do hosts[id] = host.address or host.name end
        end
    end
    for _, session in cx.session:sessions() do sessions[session.id] = session.name end
    local quota = { left = 8 }
    local content
    for _, tab in cx.session:tabs() do
        local p = panes[tab.pane] or panes[remembered[tab.id]]
        if not p or p.tab ~= tab.id then p = first[tab.id] end
        if p and p.tab == tab.id then
            liveTabs[tab.id] = p.pane
            if tab.id == active then content = p.pane end
            local remote = hosts[tab.session]
            local path = projectPath(cx, projects.folder(p, tab), remote, quota)
            local pathKey = if path then projects.key(path) else "session:" .. tab.session
            local key = (remote or "") .. "|" .. pathKey
            local group = byKey[key]
            if not group then
                if not groupIds[key] then
                    nextGroupId += 1
                    groupIds[key] = "p" .. nextGroupId
                end
                local name = if path then projects.name(path) else (sessions[tab.session] or "其他标签")
                group = { key = key, id = groupIds[key], name = name, path = path,
                    host = remote, tabs = {} }
                byKey[key] = group
                table.insert(groups, group)
            end
            local entry = {
                id = tab.id, pane = p.pane, session = tab.session,
                sessionName = sessions[tab.session] or "",
                host = remote or "",
                projectKey = key,
                position = tab.position,
                rawName = if tab.name and tab.name ~= "" then tab.name else "",
                canArchive = not remote and terminals[tab.id] == true,
                label = projects.label(p, tab),
                kind = p.kind,
                path = p.path or p.cwd or "",
                normPath = p.path or p.cwd or p.url or "",
                sessionFile = tabstate.sessionFileForPane(p.pane) or sessionFiles[tab.id] or "",
            }
            table.insert(group.tabs, entry)
            table.insert(liveTabList, entry)
        end
    end
    remembered = liveTabs
    local needPinInspect = tabstate.reconcilePins(liveTabList, hasConnectingHost)
    local needOrderInspect = ordering.reconcileTabs(liveTabList, hasConnectingHost)
    if (needPinInspect or needOrderInspect) and not unloading then
        -- Gate subprocess inspect by the exact set of unidentified local terminal/agent panes so
        -- unmatched dormant records never cause periodic tern.com spawns on heartbeats/events.
        local unknownIds = {}
        for _, entry in liveTabList do
            if entry.canArchive and entry.sessionFile == "" then
                table.insert(unknownIds, tostring(entry.pane))
            end
        end
        if #unknownIds > 0 then
            table.sort(unknownIds)
            local unknownKey = table.concat(unknownIds, ",")
            if unknownKey ~= lastInspectedUnknownKey then
                lastInspectedUnknownKey = unknownKey
                refreshSessionFiles(cx)
                if inspectRetryTimer then inspectRetryTimer:cancel() end
                inspectRetryTimer = tern.timer(2500, function(current)
                    inspectRetryTimer = nil
                    if not unloading and shown then refreshSessionFiles(current) end
                end)
            end
        end
    end
    activity.prune(liveTabs)
    table.sort(groups, function(a, b)
        local left, right = string.lower(a.name), string.lower(b.name)
        if left == right then return a.key < b.key end
        return left < right
    end)
    return groups, content, panes, awaitingPanel
end

local function row(className, key, button, trailing, marker)
    local titleChildren = { button }
    if trailing then table.insert(titleChildren, trailing) end
    local children = {
        ui.el("div", { key = "title", class = "pt-title-area" }, titleChildren),
    }
    -- Activity patches target <row>.activity. Keep the marker outside the hover overlay.
    if marker then table.insert(children, marker) end
    return ui.el("div", { class = className, key = key, attrs = { ["data-pt-key"] = key } }, children)
end

local function menuItems(key, isTab)
    if isTab then
        local target = targets[key]
        local items = {}
        if target and target.pinKind == "auto" then
            table.insert(items, { id = "dismiss-" .. key, label = "移回原项目", icon = "folder" })
        end
        table.insert(items, { id = "rename-" .. key, label = "重命名标签", icon = "pen" })
        table.insert(items, { id = "close-" .. key, label = "关闭标签", icon = "x" })
        if target and target.canArchive then
            table.insert(items, { id = "archive-" .. key, label = "关闭并移出历史", icon = "trash", danger = true })
        end
        return items
    end
    local items = {}
    if headings[key] and projects.isAbsolute(headings[key].path) then
        table.insert(items, { id = "new-" .. key, label = "新建对话", icon = "plus" })
    end
    table.insert(items, { id = "rename-" .. key, label = "重命名项目", icon = "pen" })
    return items
end

local function actionMenu(title, items, fallback, anchored)
    if not anchored then
        return ui.button("⋯", { key = "more", role = "pt-more", title = title, aria = title,
            size = "sm", variant = "quiet", actions = { click = fallback } })
    end
    return ui.node("menu", {
        key = "more", title = title, trigger = "quiet", size = "sm", align = "end", items = items,
    })
end

local function rowMenu(key, label, isTab, anchored)
    local title = (if isTab then "标签" else "项目") .. "「" .. label .. "」的操作"
    return actionMenu(title, menuItems(key, isTab), "more-" .. key, anchored)
end

local function paintHistory(cx)
    if lastHistoryRevision == history.revision then return end
    -- The native picker keeps row actions reachable at the edge of the scrolling card.
    cx.canvas:set(panel, {set = {["topbar.history"] = history.view(actionMenu)}})
    lastHistoryRevision = history.revision
end

local function requestHistoryUpdate()
    if not shown or historyTimer then return end
    historyTimer = tern.timer(0, function(cx)
        historyTimer = nil
        if panel and lastView and cx.session:tab_of(panel) == selectedTab(cx) then
            paintHistory(cx)
        else
            requestUpdate()
        end
    end)
end

local function describe(groups, active)
    local clicks, folds, membership, signature = {}, {}, {}, {}
    table.insert(signature, ordering.signature())
    projects.labelGroups(groups)
    local pinned = tabstate.pinnedMap()
    local autoPinnedTabs, autoPinnedSet = ordering.selectAutoPinned(groups, pinned)
    local manualPinnedTabs, visibleGroups = {}, {}
    for _, g in groups do
        local rest = {}
        for _, tab in g.tabs do
            tab.projectLabel = g.label
            tab.projectKey = g.key
            local order = pinned[tostring(tab.id)]
            if order then
                tab.pinned = true
                tab.pinKind = "manual"
                tab.pinOrder = order
                table.insert(manualPinnedTabs, tab)
            elseif autoPinnedSet[tab.id] then
                tab.pinned = true
                tab.pinKind = "auto"
                tab.pinOrder = nil
            else
                tab.pinned = false
                tab.pinKind = nil
                table.insert(rest, tab)
            end
        end
        if #rest > 0 then
            ordering.sortGroupTabs(rest)
            g.tabs = rest
            table.insert(visibleGroups, g)
        end
    end
    table.sort(manualPinnedTabs, function(a, b)
        if a.pinOrder == b.pinOrder then return a.id < b.id end
        return a.pinOrder > b.pinOrder
    end)
    local allPinnedTabs = {}
    for _, tab in manualPinnedTabs do table.insert(allPinnedTabs, tab) end
    for _, tab in autoPinnedTabs do table.insert(allPinnedTabs, tab) end
    local pinnedGroup
    if #allPinnedTabs > 0 then
        pinnedGroup = {
            id = "pinned", key = pinnedFoldKey, name = "置顶", label = "置顶",
            tabs = allPinnedTabs, manualTabs = manualPinnedTabs, autoTabs = autoPinnedTabs,
            closed = folded[pinnedFoldKey] == true, pinned = true,
        }
        folds[pinnedGroup.id] = pinnedGroup
        table.insert(signature, { pinnedGroup.key, #manualPinnedTabs, #autoPinnedTabs, pinnedGroup.closed })
        for _, tab in allPinnedTabs do
            membership[tab.id] = pinnedGroup
            if pinnedGroup.closed then
                table.insert(signature, { tab.id, tab.pinKind })
            else
                tab.button = "t" .. tostring(tab.id)
                tab.current = active == tab.id
                clicks[tab.button] = tab
                table.insert(signature, { tab.button, tab.label, tab.projectLabel, tab.path, tab.kind or "", tab.current, tab.canArchive, tab.pinKind })
            end
        end
    end
    for _, g in visibleGroups do
        g.closed = folded[g.key] == true
        folds[g.id] = g
        table.insert(signature, { g.key, g.label, #g.tabs, g.closed })
        for _, tab in g.tabs do
            membership[tab.id] = g
            if g.closed then
                table.insert(signature, tab.id)
            else
                tab.button = "t" .. tostring(tab.id)
                tab.current = active == tab.id
                clicks[tab.button] = tab
                table.insert(signature, { tab.button, tab.label, tab.path, tab.kind or "", tab.current, tab.canArchive, false })
            end
        end
    end
    targets, headings, groupByTab = clicks, folds, membership
    return tern.json.encode(signature), pinnedGroup, visibleGroups
end

local function tabRow(tab, anchored, pinKind)
    local isPinned = pinKind ~= nil
    local isManual = pinKind == "manual"
    local isAuto = pinKind == "auto"
    local tip = if isAuto then
        tab.label .. "\n" .. tab.projectLabel .. " · 最近交互自动置顶" .. (if tab.path == "" then "" else "\n" .. tab.path)
    elseif isManual then
        tab.label .. "\n" .. tab.projectLabel .. (if tab.path == "" then "" else "\n" .. tab.path)
    elseif tab.path == "" then tab.label
    else tab.label .. "\n" .. tab.path
    local button = ui.button(tab.label, {
        key = "switch", variant = "quiet", on = tab.current, size = "sm",
        icon = if tab.kind == "terminal" or tab.kind == "agent" then "terminal" else "file",
        title = tip,
        actions = { click = tab.button },
    })
    local pinTitle = if isManual then "取消置顶" elseif isAuto then "固定置顶" else "置顶标签"
    local pinBtn = ui.button("", {
        key = "pin", role = "pt-pin", icon = "pin", size = "sm", variant = "quiet",
        on = isManual,
        title = pinTitle,
        aria = pinTitle .. "「" .. tab.label .. "」",
        actions = { click = "pin-" .. tab.button },
    })
    local actions = ui.el("div", { key = "actions", class = "pt-row-actions" }, {
        pinBtn,
        rowMenu(tab.button, tab.label, true, anchored),
    })
    local className = "pt-tab"
    if isPinned then className ..= " pt-pinned" end
    if isAuto then className ..= " pt-auto-pinned" end
    if tab.current then className ..= " pt-current" end
    return row(className, tab.button, button, actions, indicators.tab(tab.id))
end

local function render(pinnedGroup, groups, anchored)
    local topbar = ui.el("div", { key = "topbar", class = "pt-topbar" }, {
        history.view(actionMenu),
        ordering.trigger(),
    })
    local nodes = { topbar }
    local popover = ordering.popover()
    if popover then table.insert(nodes, popover) end
    indicators.reset()
    if pinnedGroup then
        local count = tostring(#pinnedGroup.tabs)
        local autoOnly = #pinnedGroup.manualTabs == 0 and #pinnedGroup.autoTabs > 0
        local headChildren = {
            ui.el("span", { class = "pt-group-caret", text = if pinnedGroup.closed then "▸" else "▾" }),
            ui.el("span", { class = "pt-group-name", text = "置顶" }),
        }
        if autoOnly then
            table.insert(headChildren, ui.el("span", { class = "pt-pinned-tag", text = "最近" }))
        end
        table.insert(headChildren, ui.el("span", { class = "pt-group-count", text = count }))
        local heading = ui.el("button", {
            key = "fold", class = "pt-group-btn pt-pinned-btn",
            title = if autoOnly then "展开或收起最近交互自动置顶的标签" else "展开或收起已置顶的标签",
            aria = "置顶，" .. count .. " 个标签",
            attrs = { ["aria-expanded"] = tostring(not pinnedGroup.closed) },
            actions = { click = pinnedGroup.id },
        }, headChildren)
        table.insert(nodes, row(if pinnedGroup.closed then "pt-group pt-pinned-group pt-group-closed" else "pt-group pt-pinned-group",
            pinnedGroup.id, heading, nil, if pinnedGroup.closed then indicators.group(pinnedGroup) else nil))
        if not pinnedGroup.closed then
            for _, tab in pinnedGroup.manualTabs do
                table.insert(nodes, tabRow(tab, anchored, "manual"))
            end
            if #pinnedGroup.manualTabs > 0 and #pinnedGroup.autoTabs > 0 then
                table.insert(nodes, ui.el("div", { key = "pinned-subsep", class = "pt-pinned-subsep" }, {
                    ui.el("span", { class = "pt-pinned-subsep-label", text = "最近交互" }),
                }))
            end
            for _, tab in pinnedGroup.autoTabs do
                table.insert(nodes, tabRow(tab, anchored, "auto"))
            end
        end
        if #groups > 0 then
            table.insert(nodes, ui.el("div", { key = "pinned-sep", class = "pt-pinned-sep" }))
        end
    end
    for _, g in groups do
        local location = g.path or g.name
        local count = tostring(#g.tabs)
        local heading = ui.el("button", {
            key = "fold", class = "pt-group-btn",
            title = if g.alias then g.label .. "\n" .. location else location,
            aria = g.label .. "，" .. count .. " 个标签",
            attrs = { ["aria-expanded"] = tostring(not g.closed) },
            actions = { click = g.id },
        }, {
            ui.el("span", { class = "pt-group-caret", text = if g.closed then "▸" else "▾" }),
            ui.el("span", { class = "pt-group-name", text = g.label }),
            ui.el("span", { class = "pt-group-count", text = count }),
        })
        table.insert(nodes, row(if g.closed then "pt-group pt-group-closed" else "pt-group",
            g.id, heading, rowMenu(g.id, g.label, false, anchored),
            if g.closed then indicators.group(g) else nil))
        if not g.closed then
            for _, tab in g.tabs do
                table.insert(nodes, tabRow(tab, anchored, nil))
            end
        end
    end
    return ui.el("div", { class = if desktop then "pt-list pt-hover-menus" else "pt-list", key = "projects" }, nodes)
end

local function preferredTarget(layout, fallback, panes)
    local node = layout and layout.root
    while node and not node.pane do node = node[1] end
    return if node and panes[node.pane] then node.pane else fallback
end

-- A dropdown in a vertically split canvas can extend into an adjacent terminal, which
-- receives the click. Use the window picker when the sidebar has a split above or below.
local function spansHeight(node, pane)
    if not node then return false end
    if node.pane then return node.pane == pane end
    return node.split == "right" and (spansHeight(node[1], pane) or spansHeight(node[2], pane))
end

rememberWidth = function(layout)
    local function find(node)
        if not node or node.pane then return nil end
        if node.split == "right" and node[1] and node[1].pane == panel then return node.ratio end
        return find(node[1]) or find(node[2])
    end
    local ratio = layout and find(layout.root)
    if ratio and ratio > 0 and ratio < 1 and math.abs(ratio - width) > 0.0001 then
        width = ratio
        tern.kv.set(stateKey .. ":width", width)
    end
end

sync = function(cx)
    if not shown then dropPanel(cx); return end
    local active = selectedTab(cx)
    if not active then nativeTabs(false); return end
    activity.seen(active)
    local groups, content, panes, awaitingPanel = collect(cx, active)
    if awaitingPanel and panelTab ~= active then return end
    if not content then
        if panel and active == panelTab then dropPanel(cx) end
        return
    end
    lastContent = content
    local layout = cx.session:layout(active)
    local mounted = panel and panelTab == active and cx.session:tab_of(panel) == active
    local target = if mounted then panel else preferredTarget(layout, content, panes)
    local anchored = spansHeight(layout and layout.root, target)
    local desc, pinnedGroup, visibleGroups = describe(groups, active)
    local signature = (if anchored then "menu" else "picker") .. desc
    if mounted then
        if lastView ~= signature then cx.canvas:set(panel, { view = render(pinnedGroup, visibleGroups, anchored) })
        else paintHistory(cx) end
    else
        local view = render(pinnedGroup, visibleGroups, anchored)
        local old = panel
        if old and panelTab then rememberWidth(cx.session:layout(panelTab)) end
        local id = cx.canvas:open({
            title = title, about = ownerNote, view = view, target = target, dir = "left",
            ratio = width, focus = false,
            dock = ui.button("隐藏项目栏", { key = "hide", role = "pt-hide", variant = "quiet", size = "sm",
                actions = { click = "hide" } }),
        })
        if not id then nativeTabs(false); return end
        panel, panelTab = id, active
        if old and cx.session:pane(old) then
            -- Swap only our two canvases. This keeps the existing list and its scroll position
            -- while the new split supplies the left-hand position and width on the next tab.
            if cx.layout:move(old, id, "swap", { focus = false }) then
                panel = old
                cx.layout:close(id)
                cx.canvas:set(old, { view = view })
            else
                cx.layout:close(old)
            end
        end
    end
    lastView, lastHistoryRevision = signature, history.revision
    nativeTabs(true)
    indicators.flush(cx, panel, groupByTab)
end

local function toggle(cx)
    initialize(cx)
    setVisible(cx, not shown)
end

local function chooseMotion(cx)
    local enabled = tern.kv.get("running-breathing") == true
    cx:pick({ placeholder = "运行绿点的显示方式", action = "应用", items = {
        { label = "常亮（默认）", current = not enabled, pulse = false },
        { label = "呼吸", current = enabled, pulse = true },
    } }):next(function(choice)
        if choice then
            tern.kv.set("running-breathing", choice.pulse)
            indicators.motion(choice.pulse)
        end
    end)
end

local function contentPane(cx)
    local focused = cx.session:focused()
    if focused ~= panel then return focused end
    if lastContent and cx.session:tab_of(lastContent) == panelTab then return lastContent end
    return nil
end

local function focusTab(cx, tab)
    if not tab then return false end
    local target = tab.pane
    if cx.session:tab_of(target) ~= tab.id then
        local layout = cx.session:layout(tab.id)
        target = layout and layout.focus
    end
    if not target or target == panel then return false end
    if cx.sessions:current().id ~= tab.session then cx.sessions:switch(tab.session) end
    cx.layout:focus(target)
    local focused = cx.session:focused()
    return focused ~= nil and cx.session:tab_of(focused) == tab.id
end

local function historySession(cx, cwd)
    local current = cx.sessions:current().id
    local key = "|" .. projects.key(projectPath(cx, cwd, false, {left = 1}))
    local sameProject
    for _, group in headings do
        for _, tab in group.tabs do
            if group.key == key or tab.projectKey == key then
                if tab.session == current then return current end
                sameProject = sameProject or tab.session
            end
        end
    end
    if sameProject then return sameProject end
    if cx.hosts:current().kind == "local" then return current end
    for _, host in cx.hosts:list() do
        if host.kind == "local" then return host.sessions[1] end
    end
    return nil
end

local function revealHistory(cx, cwd, pane)
    local tabId = cx.session:tab_of(pane)
    local group = groupByTab[tabId]
    local key = if group then group.key else "|" .. projects.key(projectPath(cx, cwd, false, {left = 1}))
    if folded[key] then
        folded[key] = nil
        tern.kv.set(stateKey .. ":folded", folded)
    end
    for _, tab in cx.session:tabs() do
        if tab.id == tabId then
            focusTab(cx, {id = tab.id, session = tab.session, pane = pane})
            break
        end
    end
    requestUpdate()
end

local function closeTab(cx, tab)
    local previous = contentPane(cx)
    local previousTab = previous and cx.session:tab_of(previous)
    local previousSession = cx.sessions:current().id
    if not focusTab(cx, tab) then requestUpdate(); return end
    -- Native Close Tab applies to the focused tab and owns its confirmation and cancellation.
    cx:command("close_tab")
    if not cx.session:layout(tab.id) then
        pendingClosed[tab.id] = nil
        tabstate.removeClosedTab(tab.id)
        ordering.onTabClosed(tab.id)
        if previousTab and previousTab ~= tab.id
            and cx.session:tab_of(previous) == previousTab then
            if cx.sessions:current().id ~= previousSession then cx.sessions:switch(previousSession) end
            cx.layout:focus(previous)
        end
    end
    sync(cx)
end

local function newConversation(cx, key)
    -- A directory or session can change while the row menu is open.
    local groups = collect(cx, selectedTab(cx))
    local group
    for _, candidate in groups do
        if candidate.id == key then group = candidate; break end
    end
    if not group or not projects.isAbsolute(group.path) then
        cx:toast("info", "这个项目的目录已不可用")
        requestUpdate()
        return
    end
    local path = group.path
    if not group.host and path:sub(1, 2) ~= "//" and not tern.fs.exists(path .. "/.") then
        cx:toast("error", "项目目录不存在或无法访问", path)
        return
    end
    local command = cx.settings:get("agent_command")
    if type(command) ~= "string" or not command:find("%S") then
        cx:toast("error", "请先在 Tern 设置中选择对话使用的 Agent")
        return
    end

    local previous = cx.sessions:current().id
    local destination = group.tabs[1].session
    for _, tab in group.tabs do
        if tab.session == previous then destination = previous; break end
    end
    local ok, pane = pcall(function()
        if destination ~= previous then cx.sessions:switch(destination) end
        if cx.sessions:current().id ~= destination then return nil end
        if group.host and cx.hosts:current().state ~= "connected" then return nil end
        -- An explicit command opens a native Agent tab with an empty composer.
        return cx.layout:new_tab({ cwd = path, command = command }, { focus = true })
    end)
    if not ok or not pane then
        if cx.sessions:current().id ~= previous then
            pcall(function() cx.sessions:switch(previous) end)
        end
        cx:toast("error", "无法在项目目录新建对话", path)
        requestUpdate()
        return
    end
    if folded[group.key] then
        folded[group.key] = nil
        tern.kv.set(stateKey .. ":folded", folded)
    end
    sync(cx)
end

local function renameFromRow(cx, key)
    local group, tab = headings[key], targets[key]
    if not group and not tab then return end
    local pane = contentPane(cx)
    if pane and cx.session:focused() == panel then cx.layout:focus(pane) end
    local initial = if group then group.alias or group.defaultName else tab.label
    local hint = if group then "项目显示名（留空恢复目录名）" else "标签标题（留空恢复自动标题）"
    cx:prompt({ value = initial, placeholder = hint, icon = "pen", action = "保存" }):next(function(value, _, current)
        if value == nil then return end
        local name = value:match("^%s*(.-)%s*$")
        if name == initial then return end
        if group then
            tern.kv.set("project-name:" .. group.key, if name == "" then nil else name)
            history.namesChanged()
        elseif current.session:layout(tab.id) then
            current.layout:name_tab(tab.id, if name == "" then nil else name)
        end
        sync(current)
    end)
end

local function togglePin(cx, key)
    local tab = targets[key]
    if not tab then return end
    if tabstate.isPinned(tab.id) then
        tabstate.unpinTab(tab.id)
        -- Keep an unpinned tab in its project until its next interaction.
        ordering.suppressAutoPin(tab.id)
        if tab.projectKey and folded[tab.projectKey] then
            folded[tab.projectKey] = nil
            tern.kv.set(stateKey .. ":folded", folded)
        end
    else
        tabstate.pinTab(tab)
        ordering.clearSuppression(tab.id)
        if tab.canArchive and (not tab.sessionFile or tab.sessionFile == "") then
            refreshSessionFiles(cx)
        end
        if folded[pinnedFoldKey] then
            folded[pinnedFoldKey] = nil
            tern.kv.set(stateKey .. ":folded", folded)
        end
    end
    if lastContent and cx.session:pane(lastContent) then cx.layout:focus(lastContent) end
    sync(cx)
end

local function dismissAutoPin(cx, key)
    local tab = targets[key]
    if not tab then return end
    ordering.suppressAutoPin(tab.id)
    if tab.projectKey and folded[tab.projectKey] then
        folded[tab.projectKey] = nil
        tern.kv.set(stateKey .. ":folded", folded)
    end
    if lastContent and cx.session:pane(lastContent) then cx.layout:focus(lastContent) end
    sync(cx)
end

local function runRowAction(cx, act)
    local verb, key = act:match("^(%a+)%-(.+)$")
    if verb == "pin" then
        togglePin(cx, key)
    elseif verb == "dismiss" then
        dismissAutoPin(cx, key)
    elseif verb == "new" then
        newConversation(cx, key)
    elseif verb == "rename" then
        renameFromRow(cx, key)
    elseif verb == "archive" then
        history.archiveTab(cx, targets[key], requestHistoryUpdate, closeTab)
    elseif verb == "close" then
        closeTab(cx, targets[key])
    else
        return false
    end
    return true
end

local function pickRowAction(cx, key)
    local target = targets[key] or headings[key]
    if not target then return end
    local origin = panel
    cx:pick({ placeholder = target.label, action = "选择", items = menuItems(key, targets[key] ~= nil) })
        :next(function(choice, _, current)
            if choice and shown and origin == panel then runRowAction(current, choice.id) end
        end)
end

local function addFolder(cx)
    initialize(cx)
    local focused = cx.session:focused()
    local id = if focused == panel then lastContent else focused
    local pane = id and cx.session:pane(id)
    local folder = pane and projects.folder(pane, {})
    cx:prompt({ value = folder or "", placeholder = "项目根目录的完整路径（包含子目录）",
        icon = "folder", action = "添加" }):next(function(value, _, current)
        if value == nil then return end
        local path = projects.path(value)
        if not projects.isAbsolute(path) then
            current:toast("error", "请输入项目目录的完整路径")
            return
        end
        roots = tern.kv.get("project-folders") or {}
        for _, root in roots do
            if projects.key(root) == projects.key(path) then return end
        end
        table.insert(roots, path)
        tern.kv.set("project-folders", roots)
        if shown then sync(current) end
    end)
end

local function removeFolder(cx)
    roots = tern.kv.get("project-folders") or {}
    if #roots == 0 then cx:toast("info", "尚未添加自定义项目目录"); return end
    local items = {}
    for _, root in roots do table.insert(items, { label = root, icon = "folder" }) end
    cx:pick({ items = items, placeholder = "选择要取消分组的项目目录", action = "移除" }):next(function(item, _, current)
        if not item then return end
        local nextRoots = {}
        for _, root in tern.kv.get("project-folders") or {} do
            if root ~= item.label then table.insert(nextRoots, root) end
        end
        roots = nextRoots
        tern.kv.set("project-folders", roots)
        if shown then sync(current) end
    end)
end

local function chooseSortMode(cx)
    initialize(cx)
    ordering.chooseSortMode(cx, function(current)
        if shown then sync(current) end
    end)
end

local function chooseAutoPin(cx)
    initialize(cx)
    ordering.chooseAutoPin(cx, function(current)
        if shown then sync(current) end
    end)
end

local function noteInteraction(tabId)
    if not initialized or not tabId then return end
    if ordering.onInteraction(tabId) then requestUpdate() end
end

tern.command({ id = "toggle", title = "显示 / 隐藏项目标签栏", group = "项目标签",
    icon = "folder", keys = { "alt+f9" }, run = toggle })
tern.command({ id = "add-folder", title = "添加项目根目录…", group = "项目标签", icon = "folder", run = addFolder })
tern.command({ id = "remove-folder", title = "移除自定义项目根目录…", group = "项目标签", icon = "folder", run = removeFolder })
tern.command({ id = "sort-mode", title = "设置标签排序模式…", group = "项目标签", run = chooseSortMode })
tern.command({ id = "auto-pin-recent", title = "设置最近交互自动放置顶…", group = "项目标签", run = chooseAutoPin })
tern.command({ id = "running-indicator", title = "设置运行绿点…", group = "项目标签", run = chooseMotion })
tern.files.button({ id = "projects", title = "显示 / 隐藏项目标签栏", icon = "folder",
    run = function(_, cx) toggle(cx) end })
tern.chrome.status(function()
    return { { text = "项目", icon = "folder", command = action } }
end)

tern.on("canvas_action", function(ev, cx)
    if ev.pane ~= panel then return false end
    if ev.act == "history-toggle" and ordering.closePopover() then
        sync(cx)
    end
    if ordering.handle(ev.act, function() history.collapse() end) then
        if lastContent and cx.session:pane(lastContent) then cx.layout:focus(lastContent) end
        sync(cx)
        return true
    end
    if history.handle(cx, ev.act, requestHistoryUpdate, historySession, revealHistory) then
        paintHistory(cx)
        return true
    end
    if runRowAction(cx, ev.act) then return true end
    local more = ev.act:match("^more%-(.+)$")
    if ev.act == "hide" then
        setVisible(cx, false)
    elseif more then
        pickRowAction(cx, more)
    elseif headings[ev.act] then
        local key = headings[ev.act].key
        folded[key] = if folded[key] then nil else true
        tern.kv.set(stateKey .. ":folded", folded)
        if lastContent and cx.session:pane(lastContent) then cx.layout:focus(lastContent) end
        sync(cx)
    elseif focusTab(cx, targets[ev.act]) then
        sync(cx)
    end
    return true
end)

local function start(cx)
    initialize(cx)
    if shown then
        sync(cx)
        requestUpdate()
        tick()
    else
        dropPanel(cx)
        requestUpdate(true)
    end
end
tern.on("window_start", start)
-- Tern only delivers window_start once per plugin id, including across in-place upgrades.
tern.timer(0, function(cx)
    if not initialized and cx.session:focused() then start(cx) end
end)
tern.on("focus", function(ev, cx)
    if ev.tab == selectedTab(cx) then activity.seen(ev.tab) end
    requestMarkers()
    if initialized then requestUpdate(true) else start(cx) end
end)
tern.on("command_started", function(ev, cx)
    local pane = cx.session:pane(ev.pane)
    if activity.shell(pane, false) and pane and pane.tab then noteInteraction(pane.tab) end
    requestMarkers()
end)
tern.on("command_finished", function(ev, cx)
    local pane = cx.session:pane(ev.pane)
    if activity.shell(pane, true, selectedTab(cx)) and pane and pane.tab then noteInteraction(pane.tab) end
    requestMarkers()
end)
tern.on("agent_state", function(ev, cx)
    local tab = cx.session:tab_of(ev.pane)
    if activity.agentChanged(ev.pane, tab, ev.old, ev.new, selectedTab(cx)) and tab then noteInteraction(tab) end
    requestMarkers()
end)
tern.on("agent_finished", function(ev, cx)
    local tab = cx.session:tab_of(ev.pane)
    if activity.agentFinished(ev.pane, tab, ev.result, selectedTab(cx)) and tab then noteInteraction(tab) end
    requestMarkers()
end)
tern.on("tab_created", function(ev)
    if initialized then ordering.onTabCreated(ev.tab) end
    requestUpdate()
end)
tern.on("title", function(ev, cx)
    if not initialized or not shown then return end
    local tabId = cx.session:tab_of(ev.pane)
    if tabId then
        local group = groupByTab[tabId]
        if group and group.closed then return end
        local target = targets["t" .. tostring(tabId)]
        if target and target.rawName ~= "" then return end
    end
    requestUpdate(false, 120)
end)
for _, event in { "cwd", "pane_created", "session_ended" } do
    tern.on(event, function() requestUpdate() end)
end
local function scheduleClosedCleanup()
    if closeCommitTimer then closeCommitTimer:cancel() end
    -- Delay persisting tab_closed removals so Tern shutdown / Stop Sessions and Quit
    -- never wipes pinned tabs or tab order before unload cancels this timer.
    closeCommitTimer = tern.timer(700, function(cx)
        closeCommitTimer = nil
        if unloading then pendingClosed = {}; return end
        local remaining = cx.session:tabs()
        if #remaining == 0 then pendingClosed = {}; return end
        local stillLive = {}
        for _, t in remaining do stillLive[t.id] = true end
        local removedAny = false
        for tabId in pendingClosed do
            if not stillLive[tabId] then
                if tabstate.removeClosedTab(tabId) then removedAny = true end
                if ordering.onTabClosed(tabId) then removedAny = true end
            end
        end
        pendingClosed = {}
        if removedAny and shown then requestUpdate() end
    end)
end

tern.on("tab_closed", function(ev)
    activity.removeTab(ev.tab)
    if not unloading then
        pendingClosed[ev.tab] = true
        scheduleClosedCleanup()
    end
    requestUpdate()
end)
tern.on("pane_closed", function(ev, cx)
    history.closed(ev.pane)
    tabstate.clearPane(ev.pane)
    activity.removePane(ev.pane)
    requestMarkers()
    if ev.pane == panel then
        local previousTab = panelTab
        panel, panelTab, lastView = nil, nil, nil
        nativeTabs(false)
        if previousTab and cx.session:layout(previousTab) then
            setVisible(cx, false)
        elseif shown then
            sync(cx)
        end
    end
    requestUpdate()
end)
tern.on("unload", function(cx)
    unloading = true
    shown = false
    pendingClosed = {}
    if closeCommitTimer then closeCommitTimer:cancel(); closeCommitTimer = nil end
    if inspectRetryTimer then inspectRetryTimer:cancel(); inspectRetryTimer = nil end
    tabstate.flushPins()
    ordering.flush()
    history.collapse()
    ordering.closePopover()
    if pending then pending:cancel(); pending = nil end
    if heartbeat then heartbeat:cancel(); heartbeat = nil end
    dropPanel(cx)
end)
