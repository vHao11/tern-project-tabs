local projects = require("./projects")
local activity = require("./activity")
local indicators = require("./indicators")
local history = require("./history")
local ui = tern.ui
local action = "plugin.project-tabs.toggle"
local title = "项目标签"
local hideTopTabs = "#tabbar .tb-tabs { display: none !important; }"
local desktop = tern.runtime.os == "windows" or tern.runtime.os == "macos" or tern.runtime.os == "linux"

local initialized, shown, compactTop = false, true, false
local stateKey, ownerNote, panel, panelTab
local folded, remembered, repos = {}, {}, {}
local roots = {}
local groupIds, nextGroupId = {}, 0
local targets, headings, groupByTab = {}, {}, {}
local lastView, lastContent, width = nil, nil, 0.21
local lastHistoryRevision
local pending, heartbeat, markerTimer, historyTimer
local sync, rememberWidth

local function selectedTab(cx)
    local pane = cx.session:focused()
    return pane and cx.session:tab_of(pane)
end

local function requestUpdate(checkHidden)
    if not initialized or pending or (not shown and checkHidden ~= true) then return end
    pending = tern.timer(30, function(cx)
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

local function initialize(cx)
    if initialized then return end
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
    activity.reconcile(cx, cx.session:panes())
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
        sync(cx)
        tick()
    else
        history.collapse()
        if pending then pending:cancel(); pending = nil end
        if heartbeat then heartbeat:cancel(); heartbeat = nil end
        dropPanel(cx)
    end
end

local function tabPanes(cx, active, owners)
    local byId, first, terminals = {}, {}, {}
    local awaitingPanel = false
    local panes = cx.session:panes()
    activity.reconcile(cx, panes)
    for _, pane in panes do
        -- The title is only a hint to wait. Closing a pane requires the owner and window tag above.
        if pane.block == "tern.canvas" and not owners[pane.pane] and pane.title == title then
            if pane.tab == active then awaitingPanel = true end
        elseif pane.tab and pane.pane ~= panel and owners[pane.pane] ~= "project-tabs" and not pane.parked then
            byId[pane.pane] = pane
            if pane.kind == "terminal" or pane.kind == "agent" then terminals[pane.tab] = true end
            if not first[pane.tab] or (first[pane.tab].floating and not pane.floating) then
                first[pane.tab] = pane
            end
        end
    end
    return byId, first, awaitingPanel, terminals
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
    local panes, first, awaitingPanel, terminals = tabPanes(cx, active, owners)
    local groups, byKey, liveTabs = {}, {}, {}
    local hosts, sessions = {}, {}
    for _, host in cx.hosts:list() do
        if host.kind == "remote" then
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
            table.insert(group.tabs, { id = tab.id, pane = p.pane, session = tab.session,
                canArchive = not remote and terminals[tab.id] == true,
                label = projects.label(p, tab), kind = p.kind, path = p.path or p.cwd or "" })
        end
    end
    remembered = liveTabs
    activity.prune(liveTabs)
    table.sort(groups, function(a, b)
        local left, right = string.lower(a.name), string.lower(b.name)
        if left == right then return a.key < b.key end
        return left < right
    end)
    return groups, content, panes, awaitingPanel
end

local function row(className, key, button, menu, marker)
    local children = {
        ui.el("div", { key = "title", class = "pt-title-area" }, { button, menu }),
    }
    -- Activity patches target <row>.activity. Keep the marker outside the hover overlay.
    if marker then table.insert(children, marker) end
    return ui.el("div", { class = className, key = key, attrs = { ["data-pt-key"] = key } }, children)
end

local function menuItems(key, isTab)
    if isTab then
        local items = {{ id = "rename-" .. key, label = "重命名标签", icon = "pen" }}
        if targets[key] and targets[key].canArchive then
            table.insert(items, {id = "archive-" .. key, label = "归档并关闭…"})
        end
        table.insert(items, { id = "close-" .. key, label = "关闭标签", icon = "x", danger = true })
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
    cx.canvas:set(panel, {set = {history = history.view(actionMenu)}})
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
    projects.labelGroups(groups)
    for _, g in groups do
        g.closed = folded[g.key] == true
        folds[g.id] = g
        table.insert(signature, {g.key, g.label, #g.tabs, g.closed})
        for _, tab in g.tabs do
            membership[tab.id] = g
            if g.closed then
                table.insert(signature, tab.id)
            else
                tab.button = "t" .. tostring(tab.id)
                tab.current = active == tab.id
                clicks[tab.button] = tab
                table.insert(signature, {tab.button, tab.label, tab.path, tab.kind or "", tab.current, tab.canArchive})
            end
        end
    end
    targets, headings, groupByTab = clicks, folds, membership
    return tern.json.encode(signature)
end

local function render(groups, anchored)
    local nodes = {history.view(actionMenu)}
    indicators.reset()
    for _, g in groups do
        local caret = if g.closed then "▸  " else "▾  "
        local location = g.path or g.name
        local heading = ui.button(caret .. g.label .. "  (" .. #g.tabs .. ")", {
            key = "fold", variant = "quiet", title = if g.alias then g.label .. "\n" .. location else location,
            actions = { click = g.id },
        })
        table.insert(nodes, row("pt-group", g.id, heading, rowMenu(g.id, g.label, false, anchored),
            if g.closed then indicators.group(g) else nil))
        if not g.closed then
            for _, tab in g.tabs do
                local button = ui.button(tab.label, {
                    key = "switch", variant = "quiet", on = tab.current, size = "sm",
                    icon = if tab.kind == "terminal" or tab.kind == "agent" then "terminal" else "file",
                    title = if tab.path == "" then tab.label else tab.label .. "\n" .. tab.path,
                    actions = { click = tab.button },
                })
                table.insert(nodes, row(if tab.current then "pt-tab pt-current" else "pt-tab", tab.button,
                    button, rowMenu(tab.button, tab.label, true, anchored), indicators.tab(tab.id)))
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
    local signature = (if anchored then "menu" else "picker") .. describe(groups, active)
    if mounted then
        if lastView ~= signature then cx.canvas:set(panel, { view = render(groups, anchored) })
        else paintHistory(cx) end
    else
        local view = render(groups, anchored)
        local old = panel
        if old and panelTab then rememberWidth(cx.session:layout(panelTab)) end
        local id = cx.canvas:open({
            title = title, about = ownerNote, view = view, target = target, dir = "left",
            ratio = width, focus = false,
            dock = ui.button("隐藏项目栏", { key = "hide", variant = "quiet", actions = { click = "hide" } }),
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
        if group.key == key then
            for _, tab in group.tabs do
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
    if not cx.session:layout(tab.id) and previousTab and previousTab ~= tab.id
        and cx.session:tab_of(previous) == previousTab then
        if cx.sessions:current().id ~= previousSession then cx.sessions:switch(previousSession) end
        cx.layout:focus(previous)
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

local function runRowAction(cx, act)
    local verb, key = act:match("^(%a+)%-(.+)$")
    if verb == "new" then
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

tern.command({ id = "toggle", title = "显示 / 隐藏项目标签栏", group = "项目标签",
    icon = "folder", keys = { "alt+f9" }, run = toggle })
tern.command({ id = "add-folder", title = "添加项目根目录…", group = "项目标签", icon = "folder", run = addFolder })
tern.command({ id = "remove-folder", title = "移除自定义项目根目录…", group = "项目标签", icon = "folder", run = removeFolder })
tern.command({ id = "running-indicator", title = "设置运行绿点…", group = "项目标签", run = chooseMotion })
tern.files.button({ id = "projects", title = "显示 / 隐藏项目标签栏", icon = "folder",
    run = function(_, cx) toggle(cx) end })
tern.chrome.status(function()
    return { { text = "项目", icon = "folder", command = action } }
end)

tern.on("canvas_action", function(ev, cx)
    if ev.pane ~= panel then return false end
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
    activity.shell(cx.session:pane(ev.pane), false)
    requestMarkers()
end)
tern.on("command_finished", function(ev, cx)
    activity.shell(cx.session:pane(ev.pane), true, selectedTab(cx))
    requestMarkers()
end)
tern.on("agent_state", function(ev, cx)
    activity.agentChanged(ev.pane, cx.session:tab_of(ev.pane), ev.old, ev.new, selectedTab(cx))
    requestMarkers()
end)
tern.on("agent_finished", function(ev, cx)
    activity.agentFinished(ev.pane, cx.session:tab_of(ev.pane), ev.result, selectedTab(cx))
    requestMarkers()
end)
for _, event in { "cwd", "title", "tab_created", "pane_created", "session_ended" } do
    tern.on(event, requestUpdate)
end
tern.on("tab_closed", function(ev)
    activity.removeTab(ev.tab)
    requestUpdate()
end)
tern.on("pane_closed", function(ev, cx)
    history.closed(ev.pane)
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
    shown = false
    history.collapse()
    if pending then pending:cancel() end
    if heartbeat then heartbeat:cancel() end
    dropPanel(cx)
end)
