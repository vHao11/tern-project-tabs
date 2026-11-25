local projects = require("./projects")
local archive = require("./archive")
local ui = tern.ui
local M = { revision = 0 }
local pageSize = 6
local probeBytes = 2048
local windows = tern.runtime.os == "windows"
local ternCli = if windows then "tern.com" else "tern"
local expanded, loading, restoring = false, false, nil
local timeline = {id = "time", items = {}, page = 1}
local folders = {id = "projects", items = {}, page = 1}
local byPath, visible, navigation = {}, {}, {}
local generation, mode, namesDirty = 0, "projects", false
local cache = {}
local indexedCount, indexedRoots
local worker, loadError, restoreError, windowsReader
local drawnCard, closeTimer
local selection, clearing
local archivingTabs = {}
-- Covers the interval between creating the tab and OMP reporting its session file.
local starting = {}

local function changed(update)
    M.revision += 1
    update()
end

function M.collapse(afterClose)
    generation += 1
    if worker then worker:kill(); worker = nil end
    if closeTimer then closeTimer:cancel(); closeTimer = nil end
    if expanded and afterClose and drawnCard then
        closeTimer = tern.timer(120, function()
            closeTimer, drawnCard = nil, nil
            changed(afterClose)
        end)
    else
        drawnCard = nil
    end
    expanded, loading, restoring, loadError, restoreError = false, false, nil, nil, nil
    visible, navigation = {}, {}
    selection, clearing = nil, nil
    M.revision += 1
end

local function resetIndex()
    timeline.items, folders.items, byPath = {}, {}, {}
    indexedCount = nil
end

function M.namesChanged()
    if expanded then namesDirty = true; M.revision += 1 end
end

local function sessionsRoots()
    local agentDir = tern.getenv("PI_CODING_AGENT_DIR")
    local home = tern.getenv(if windows then "USERPROFILE" else "HOME")
    local profile = (tern.getenv("OMP_PROFILE") or tern.getenv("PI_PROFILE") or ""):match("^%s*(.-)%s*$")
    local suffix = ""
    if profile ~= "" and profile ~= "default" then
        if not profile:match("^[a-z0-9][a-z0-9._-]*$") or #profile > 64 then return nil end
        suffix = "/profiles/" .. profile
    elseif agentDir and agentDir ~= "" then
        if agentDir:sub(1, 2) == "~/" and home then agentDir = home .. agentDir:sub(2) end
        local path = projects.path(agentDir)
        return if projects.isAbsolute(path) then {path .. "/sessions"} else nil
    end
    if not home then return nil end
    local config = tern.getenv("PI_CONFIG_DIR")
    local root = home .. "/" .. (if config and config ~= "" then config else ".omp") .. suffix .. "/agent/sessions"
    local xdg = if not windows then projects.path(tern.getenv("XDG_DATA_HOME")) else nil
    return if projects.isAbsolute(xdg) then {root, xdg .. "/omp" .. suffix} else {root}
end

-- Only the explicit history controls launch workers. Paths never become shell source.
local function run(argv, opts, done)
    local ok = pcall(function()
        tern.process.run(argv, opts, function(result, cx)
            done(if result.status == 0 then result.stdout else nil, cx)
        end)
    end)
    if not ok then done(nil, nil) end
end

local function readerCommand(op)
    if windows then
        if not windowsReader then
            local ok, script = pcall(tern.fs.read, "history-io.ps1", 16384)
            if not ok then return nil end
            windowsReader = script
        end
        return {"powershell.exe", "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", windowsReader}, {PT_HISTORY_OP = op}
    end
    return {"sh", tern.plugin.dir .. "/history-io.sh", op}, nil
end

local function ioRequest(op, paths, done)
    local args, env = readerCommand(op)
    if not args then done(nil, nil); return end
    local opts = {env = env, timeout_ms = 30000}
    if windows or op == "read" then
        opts.stdin = table.concat(paths, "\0") .. (if windows then "" else "\0")
    else
        for _, path in paths do table.insert(args, path) end
    end
    run(args, opts, done)
end

local function probeEnv(env)
    env.PT_HISTORY_PROBE_BYTES = tostring(probeBytes)
    env.PT_HISTORY_FULL_FIRST = if windows then "0" else tostring(pageSize)
    return env
end

local function windowsIndex(ticket)
    local onLine, onEnd
    local function endBatch(ok)
        local done = onEnd
        onLine, onEnd = nil, nil
        if done then done(ok) end
    end
    return function(op, paths, receive, done)
        onLine, onEnd = receive, done
        local ok = pcall(function()
            if not worker then
                local args, env = readerCommand("index")
                worker = tern.process.spawn(args, {
                    env = probeEnv(env), split = "lines",
                    stdout = function(line)
                        if ticket ~= generation or not onLine then return end
                        if line == "." then endBatch(true) else onLine(line) end
                    end,
                    exit = function()
                        if ticket ~= generation then return end
                        worker = nil
                        endBatch(false)
                    end,
                })
            end
            worker:write(op .. " " .. tern.base64.encode(table.concat(paths, "\0")) .. "\n")
        end)
        if not ok then endBatch(false) end
    end
end

local function posixRequest(op, paths, receive, done)
    if op == "list" then
        ioRequest(op, paths, function(output)
            if output then receive(output) end
            done(output ~= nil)
        end)
        return
    end
    local args = readerCommand(op)
    local ok = pcall(function()
        worker = tern.process.spawn(args, {
            env = if op == "probe" then probeEnv({}) else nil, split = "lines", stdout = receive,
            exit = function(result) done(result.status == 0) end,
        })
        worker:write(table.concat(paths, "\0") .. "\0")
        worker:close_stdin()
    end)
    if not ok then
        if worker then worker:kill() end
        done(false)
    end
end

local function closeIndex()
    if windows and worker then worker:close_stdin() end
    worker, loading = nil, false
end

local function shortText(value)
    if type(value) ~= "string" then return nil end
    local first = value:match("^%s*([^\r\n]+)")
    if not first then return nil end
    first = first:gsub("%c", " "):gsub("%s+", " "):match("^%s*(.-)%s*$")
    if first == "" then return nil end
    local cut = utf8.offset(first, 97)
    return if cut then first:sub(1, cut - 1) .. "…" else first
end

local function promptText(content)
    if type(content) == "string" then return shortText(content) end
    if type(content) == "table" then
        for _, part in content do
            if type(part) == "table" and part.type == "text" then
                local text = shortText(part.text)
                if text then return text end
            end
        end
    end
    return nil
end

local function parseEntry(file, encoded, allowEmpty, probe)
    if not encoded or encoded == "" then return nil end
    local bytes = tern.base64.decode(encoded)
    local shortProbe = probe and #bytes == probeBytes
    local lines = if shortProbe then bytes:match("^(.*\n)") or "" else bytes
    local header, name, first, hasMessage
    for line in lines:gmatch("[^\n]+") do
        local ok, item = pcall(tern.json.decode, line)
        if ok and type(item) == "table" then
            if item.type == "title" then name = shortText(item.title) or name
            elseif item.type == "session" then header = item; name = name or shortText(item.title)
            elseif item.type == "message" and type(item.message) == "table" then
                hasMessage = true
                if item.message.role == "user" then first = promptText(item.message.content) end
            end
        end
        if header and (name or first) then break end
    end
    -- A short probe is definitive only at EOF or once the normal parser would stop.
    if shortProbe and not (header and (name or first)) then return nil, true end
    if not header or type(header.id) ~= "string" or header.id == "" then return nil end
    local cwd = projects.path(header.cwd)
    if not projects.isAbsolute(cwd) then return nil end
    -- A large first turn can cross the prefix boundary. Keep that session accessible.
    if not allowEmpty and not (name or hasMessage) and #bytes < 32768 then return nil end
    return {file = file.path, cwd = cwd, id = header.id, label = name or first or "未命名会话",
        identity = archive.identity(file.path, header.id),
        date = os.date("%Y-%m-%d %H:%M", math.floor(file.time)), key = "hist-" .. tern.sha256(file.path)}
end

local function addEntry(entry, previousGroups)
    if archive.has(entry.identity) then return end
    table.insert(timeline.items, entry)
    -- The storage bucket is encoded and can contain sessions moved from another cwd.
    local key = "|" .. projects.key(entry.cwd)
    local group = byPath[key]
    if not group then
        group = {id = "folder-" .. tern.sha256(key), key = key, path = entry.cwd, items = {}, page = 1}
        local previous = previousGroups and previousGroups[key]
        if previous then group.page, group.open = previous.page, previous.open end
        byPath[key] = group
        table.insert(folders.items, group)
        namesDirty = true
    end
    table.insert(group.items, entry)
end

local function clampPage(list)
    list.page = math.clamp(list.page, 1, math.max(1, math.ceil(#list.items / pageSize)))
end

local function filterArchived()
    local items, previous = timeline.items, byPath
    timeline.items, folders.items, byPath, visible, navigation = {}, {}, {}, {}, {}
    for _, entry in items do addEntry(entry) end
    for key, group in byPath do
        group.page, group.open = previous[key].page, previous[key].open
        clampPage(group)
    end
    clampPage(timeline)
    clampPage(folders)
    if selection then
        for key in selection do
            if archive.has(key) then selection[key] = nil end
        end
    end
    M.revision += 1
end

function M.refreshArchive()
    if not expanded or loadError then return end
    local ok, modified = pcall(archive.refresh, false)
    if not ok then
        M.collapse()
        resetIndex()
        expanded, loadError = true, "无法读取归档记录，请重试"
    elseif modified then
        filterArchived()
    end
end

local function persist(cx, keys, update, done)
    local batch, data = archive.batch(keys)
    if not batch then done(true, cx); return end
    local args, env = readerCommand("archive")
    if not args then done(false, cx); return end
    env = env or {}
    env.PT_ARCHIVE_DIR, env.PT_ARCHIVE_BATCH = archive.dir, batch
    run(args, {env = env, stdin = data, timeout_ms = 30000}, function(output, current)
        if output == nil then done(false, current); return end
        archive.committed(batch, data)
        filterArchived()
        if expanded then update() end
        done(true, current)
    end)
end

local function confirm(cx, subject, label, detail, done)
    cx:pick({placeholder = subject, action = "选择", items = {
        {label = "取消"}, {label = label, detail = detail, accept = true},
    }}):next(function(choice, _, current)
        done(choice ~= nil and choice.accept == true, current)
    end)
end

local function indexFiles(files, ticket, update, request)
    local previous = cache
    cache = {}
    local missing = {}
    for _, file in files do
        local saved = previous[file.path]
        if saved and saved.stamp == file.stamp then
            file.ready, file.entry = true, saved.entry
            cache[file.path] = saved
        else
            table.insert(missing, file)
        end
    end
    if #missing == 0 and indexedCount == #files then
        closeIndex()
        changed(update)
        return
    end

    -- Consume in mtime order, including when a new file precedes already cached ones.
    -- A project's first valid entry is its latest, so both lists stay ordered.
    local previousGroups = byPath
    resetIndex()
    local cursor, nextPaint = 1, 0
    local readDone, publishTimer = #missing == 0, nil
    local function finish(ok)
        if ticket ~= generation or not loading then return end
        closeIndex()
        if ok and cursor > #files then
            indexedCount = #files
        else
            loadError = "读取历史记录失败，请重试"
        end
        clampPage(timeline)
        clampPage(folders)
        for _, group in folders.items do clampPage(group) end
        changed(update)
    end
    local function publishReady()
        if publishTimer then return end
        local start = cursor
        -- One late prefix can unblock thousands of cached entries on the UI thread.
        while files[cursor] and files[cursor].ready and cursor - start < 128 do
            local entry = files[cursor].entry
            if entry then addEntry(entry, previousGroups) end
            cursor += 1
        end
        if cursor ~= start and tern.now() >= nextPaint then
            changed(update)
            nextPaint = tern.now() + 120
        end
        if files[cursor] and files[cursor].ready then
            publishTimer = tern.timer(0, function()
                publishTimer = nil
                if ticket == generation and loading then publishReady() end
            end)
        elseif readDone then
            finish(cursor > #files)
        end
    end
    publishReady()
    if readDone then return end

    -- Read the newest page in full. Older files usually need only the header and
    -- first prompt. Batch any ambiguous probes into one full-prefix retry.
    local function scan(batch, probe, done)
        local paths, retry, received = {}, {}, 0
        for _, file in batch do table.insert(paths, file.path) end
        request(if probe then "probe" else "read", paths, function(line)
            if ticket ~= generation or not loading then return end
            received += 1
            local file = batch[received]
            if not file or line:sub(1, 1) ~= ":" then return end
            local parsed, entry, incomplete = pcall(parseEntry, file, line:sub(2), false, probe)
            if parsed and incomplete then
                table.insert(retry, file)
                return
            end
            file.ready, file.entry = true, if parsed then entry else nil
            if parsed and #line > 1 then cache[file.path] = {stamp = file.stamp, entry = entry} end
            publishReady()
        end, function(ok)
            if ticket ~= generation or not loading then return end
            if not ok or received ~= #batch then finish(false)
            elseif #retry > 0 then scan(retry, false, done)
            else done() end
        end)
    end
    local function allRead()
        readDone = true
        publishReady()
    end
    if windows and #missing > pageSize then
        local first = table.move(missing, 1, pageSize, 1, {})
        local rest = table.move(missing, pageSize + 1, #missing, 1, {})
        scan(first, false, function()
            changed(update)
            -- Let the first page paint before the same worker streams the remainder.
            tern.timer(16, function()
                if ticket == generation then scan(rest, true, allRead) end
            end)
        end)
    else
        scan(missing, #missing > pageSize, allRead)
    end
end

local function readDirectory(roots, ticket, update)
    local request = if windows then windowsIndex(ticket) else posixRequest
    local parts = {}
    request("list", roots, function(part) table.insert(parts, part) end, function(complete)
        if ticket ~= generation then return end
        local output = table.concat(parts)
        if not complete or (#output > 0 and output:sub(-1) ~= "\0") then
            closeIndex()
            resetIndex()
            loadError = "无法完整读取 OMP 历史目录，请重试"
            changed(update)
            return
        end
        local files = {}
        for stamp, size, path in output:gmatch("([%d%.]+)\t(%d+)\t([^%z]+)%z") do
            local time = tonumber(stamp)
            if time then table.insert(files, {path = path, time = time, stamp = stamp .. ":" .. size}) end
        end
        table.sort(files, function(a, b)
            if a.time == b.time then return a.path > b.path end
            return a.time > b.time
        end)
        indexFiles(files, ticket, update, request)
    end)
end

local function list(update)
    M.collapse()
    expanded, loading = true, true
    mode = if tern.kv.get("history-view") == "time" then "time" else "projects"
    local ticket, roots = generation, sessionsRoots()
    local rootsKey = roots and table.concat(roots, "\0")
    if indexedRoots ~= rootsKey then
        resetIndex()
        cache, indexedRoots = {}, rootsKey
    end
    timeline.page, folders.page = 1, 1
    for _, group in folders.items do group.page, group.open = 1, false end
    namesDirty = true
    local ok, modified = pcall(archive.refresh, true)
    if not ok then
        resetIndex()
        loading, loadError = false, "无法读取归档记录，请重试"
        changed(update)
        return
    end
    if modified then filterArchived() end
    if not roots then
        loading, loadError = false, "无法确定 OMP 历史目录"
        changed(update)
        return
    end
    changed(update)
    tern.timer(16, function()
        if ticket == generation then readDirectory(roots, ticket, update) end
    end)
end

local function button(text, role, action, props)
    props = props or {}
    props.key, props.role, props.actions = role, role, {click = action}
    if not props.variant then props.variant = "quiet" end
    if not props.size then props.size = "sm" end
    return ui.button(text, props)
end

local function addPager(nodes, list)
    local pages = math.ceil(#list.items / pageSize)
    if pages < 2 then return end
    local prev, nextPage = "history-prev-" .. list.id, "history-next-" .. list.id
    if list.page > 1 then navigation[prev] = {list = list, page = list.page - 1} end
    if list.page < pages then navigation[nextPage] = {list = list, page = list.page + 1} end
    local projectsPage = list == folders
    table.insert(nodes, ui.el("div", {key = "pager-" .. list.id, class = "pt-history-pager",
        attrs = {["data-pt-pages"] = list.id}}, {
        button(if projectsPage then "‹ 上页项目" else "‹ 上一页", "pt-history-prev", prev,
            {disabled = not navigation[prev] or restoring ~= nil}),
        ui.el("span", {class = "pt-history-page", text = tostring(list.page) .. " / " .. tostring(pages)}),
        button(if projectsPage then "下页项目 ›" else "下一页 ›", "pt-history-next", nextPage,
            {disabled = not navigation[nextPage] or restoring ~= nil}),
    }))
end

local function historyActions(key)
    if key == "root" then
        return {
            {id = "history-select", label = "多选清除…"},
            {id = "history-clear-all", label = "清空全部历史…", danger = true},
        }
    end
    local target = visible[key]
    if not target then return {} end
    return {{id = "hclear-" .. key, label = if target.items then "清除此项目历史…" else "从历史中移除…", danger = true}}
end

local function withMenu(key, label, control, menu)
    return ui.el("div", {key = "actions-" .. key, class = "pt-title-area pt-history-actions",
        attrs = {["data-pt-history-actions"] = key}}, {
        control, menu(label .. "的操作", historyActions(key), "hmore-" .. key),
    })
end

local function keyCount(keys)
    local count = 0
    for _ in keys do count += 1 end
    return count
end

local function addSessions(nodes, list, menu)
    local grouped = list ~= timeline
    for i = (list.page - 1) * pageSize + 1, math.min(list.page * pageSize, #list.items) do
        local item = list.items[i]
        visible[item.key] = item
        local meta = {}
        if not grouped then
            table.insert(meta, ui.el("span", {class = "pt-history-project", text = projects.name(item.cwd)}))
        end
        table.insert(meta, ui.el("span", {class = "pt-history-date", text = item.date}))
        local checked = selection and selection[item.identity] == true
        local headNodes = {}
        if selection then
            table.insert(headNodes, ui.el("span", {
                class = if checked then "pt-history-check pt-history-checked" else "pt-history-check",
                text = if checked then "✓" else "",
            }))
        end
        table.insert(headNodes, ui.el("span", {class = "pt-history-name", text = item.label}))
        local control = ui.el("button", {key = item.key,
            class = if grouped then "pt-history-item pt-history-child" else "pt-history-item",
            title = item.label .. "\n" .. item.cwd .. "\n" .. item.date,
            attrs = {["data-pt-history"] = item.key, ["aria-pressed"] = if selection then tostring(checked) else nil},
            actions = {click = item.key}}, {
            ui.el("div", {class = "pt-history-head"}, headNodes),
            ui.el("div", {class = "pt-history-meta"}, meta),
        })
        table.insert(nodes, if selection then control else withMenu(item.key, item.label, control, menu))
    end
    addPager(nodes, list)
end

local function addProjects(nodes, menu)
    if namesDirty then
        projects.labelGroups(folders.items)
        namesDirty = false
    end
    for i = (folders.page - 1) * pageSize + 1, math.min(folders.page * pageSize, #folders.items) do
        local group = folders.items[i]
        visible[group.id] = group
        local count = tostring(#group.items)
        local control = ui.el("button", {key = group.id, class = "pt-history-folder", title = group.path,
            aria = group.label .. "，" .. count .. " 个历史会话", actions = {click = group.id},
            attrs = {["data-pt-folder"] = group.id, ["aria-expanded"] = if group.open then "true" else "false"}}, {
            ui.el("span", {class = "pt-history-caret", text = if group.open then "▾" else "▸"}),
            ui.el("span", {class = "pt-history-folder-name", text = group.label}),
            ui.el("span", {class = "pt-history-count", text = count}),
        })
        table.insert(nodes, if selection then control else withMenu(group.id, group.label, control, menu))
        if group.open then addSessions(nodes, group, menu) end
    end
    addPager(nodes, folders)
end

local function historyCard(menu)
    local seg = ui.el("div", {key = "seg", class = "pt-history-seg"}, {
        button("按时间", "pt-history-by-time", "history-time",
            {on = mode == "time", disabled = restoring ~= nil, title = "查看所有项目最近更新的对话"}),
        button("按项目", "pt-history-by-project", "history-projects",
            {on = mode == "projects", disabled = restoring ~= nil, title = "按 OMP 启动目录分组"}),
    })
    local tools = {seg}
    if not selection then table.insert(tools, menu("历史会话操作", historyActions("root"), "hmore-root")) end
    local card = {ui.el("div", {key = "views", class = "pt-history-views"}, tools)}
    if selection then
        local count = keyCount(selection)
        table.insert(card, ui.el("div", {key = "selection", class = "pt-history-selection"}, {
            button("清除所选（" .. count .. "）", "pt-history-clear-selected", "history-clear-selected",
                {variant = if count > 0 then "danger" else "quiet", disabled = count == 0 or clearing ~= nil}),
            button("取消", "pt-history-end-select", "history-end-select"),
        }))
    end
    local rows = {}
    if mode == "time" then addSessions(rows, timeline, menu) else addProjects(rows, menu) end
    local note = loadError or restoreError or (if restoring then "正在打开会话…"
        elseif loading then "正在读取历史…" elseif #timeline.items == 0 then "暂无历史会话" else nil)
    if note then table.insert(rows, ui.el("div", {key = "note", class = "pt-history-note", text = note})) end
    if loadError then table.insert(rows, button("重试", "pt-history-retry", "history-retry")) end
    table.insert(card, ui.el("div", {key = "rows", class = "pt-history-scroll"}, rows))
    return ui.el("div", {key = "card", class = "pt-history-card", aria = "OMP 历史会话",
        attrs = {role = "dialog"}}, card)
end

function M.view(menu)
    visible, navigation = {}, {}
    local header = ui.el("button", {
        key = "pt-history-toggle",
        role = "pt-history-toggle",
        class = if expanded then "pt-history-toggle pt-history-open" else "pt-history-toggle",
        title = "展开或收起本机所有项目的 OMP 历史会话",
        aria = "OMP 历史会话",
        attrs = {["aria-expanded"] = tostring(expanded)},
        actions = {click = "history-toggle"},
    }, {
        ui.el("span", {class = "pt-history-toggle-label", text = "OMP 历史会话"}),
        ui.el("span", {class = "pt-history-toggle-caret", text = if expanded then "▾" else "▸"}),
    })
    local nodes = {header}
    if expanded then drawnCard = historyCard(menu) end
    if drawnCard then
        table.insert(nodes, ui.el("div", {key = "layer",
            class = if expanded then "pt-history-layer" else "pt-history-layer pt-history-leaving"}, {
            ui.el("div", {key = "outside", class = "pt-history-dismiss", attrs = {["aria-hidden"] = "true"},
                actions = {click = "history-close"}}),
            drawnCard,
        }))
    end
    return ui.el("div", {key = "history", class = "pt-history"}, nodes)
end

local function clearHistory(cx, subject, entries, update, fromSelection)
    if clearing or restoring then return end
    local keys = {}
    if fromSelection then
        for key in selection do keys[key] = true end
    else
        for _, entry in entries do keys[entry.identity] = true end
    end
    local count = keyCount(keys)
    if count == 0 then cx:toast("info", "没有可清除的历史会话"); return end
    local ticket = generation
    clearing = ticket
    confirm(cx, subject, "确认清除 " .. count .. " 条记录", "从插件历史中移除，保留原始对话和已打开的标签。",
        function(accepted, current)
            if generation ~= ticket then return end
            if not accepted then clearing = nil; return end
            persist(current, keys, update, function(ok, fresh)
                if ticket ~= generation then return end
                clearing = nil
                if ok and fromSelection then selection = nil end
                restoreError = if ok then nil else "清除失败，无法保存归档记录，请重试"
                if fresh and not ok then fresh:toast("error", restoreError) end
                changed(update)
            end)
        end)
end

local function fileKey(path)
    local clean = projects.path(path)
    return clean and projects.key(clean)
end

local function inspectPanes(window, done)
    run({ternCli, "inspect", "--json", "--window", window}, {timeout_ms = 6000}, function(raw, cx)
        local ok, data = pcall(tern.json.decode, raw or "")
        done(if ok and type(data) == "table" and type(data.panes) == "table" then data.panes else nil, cx)
    end)
end

local function sessionFile(pane)
    local file = projects.path(pane.omp_session_file)
    if projects.isAbsolute(file) then starting[pane.pane] = nil; return file end
    local start = starting[pane.pane]
    if start and tern.now() < start.untilMs then return start.file end
    starting[pane.pane] = nil
    return nil
end

local function tabSessions(cx, id, panes)
    if not cx.session:layout(id) then return nil end
    local files, seen, shape = {}, {}, {}
    for _, pane in cx.session:panes() do
        if pane.tab == id and pane.block ~= "tern.canvas" then table.insert(shape, tostring(pane.pane)) end
    end
    for _, pane in panes do
        if cx.session:tab_of(pane.pane) == id then
            local file = sessionFile(pane)
            if file then
                local key = fileKey(file)
                table.insert(shape, tostring(pane.pane) .. "=" .. key)
                if not seen[key] then seen[key] = true; table.insert(files, file) end
            end
        end
    end
    table.sort(shape)
    return files, tern.json.encode(shape)
end

local function readIdentities(files, done)
    ioRequest("read", files, function(raw, cx)
        local keys, index = {}, 0
        for line in (raw or ""):gmatch("([^\n]*)\n") do
            index += 1
            local path = files[index]
            if not path or line:sub(1, 1) ~= ":" then done(nil, cx); return end
            local encoded = line:sub(2):gsub("\r$", "")
            local ok, entry = pcall(parseEntry, {path = path, time = 0}, encoded, true)
            if ok and entry then
                keys[entry.identity] = true
            else
                -- A new OMP tab may already report its generated filename before its first save.
                local id = path:match("_([%x]+%-%x+%-%x+%-%x+%-%x+)%.jsonl$")
                if encoded ~= "" or tern.fs.exists(path) or not id or #id ~= 36
                    or not id:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$") then
                    done(nil, cx); return
                end
                keys[archive.identity(path, id)] = true
            end
        end
        done(if index == #files then keys else nil, cx)
    end)
end

function M.archiveTab(cx, tab, update, close)
    if not tab or not tab.canArchive or archivingTabs[tab.id] then return end
    local window, id = cx:window_key(), tab.id
    archivingTabs[id] = true
    local function stop(current, errorText)
        archivingTabs[id] = nil
        if errorText and current then current:toast("error", errorText) end
    end
    local function readTarget(done)
        inspectPanes(window, function(panes, current)
            if not panes or not current then stop(current, "无法核对标签中的 OMP 会话，请重试"); return end
            local files, shape = tabSessions(current, id, panes)
            if not files then stop(current); return end
            done(files, shape, current)
        end)
    end
    readTarget(function(files, original, first)
        if #files == 0 then stop(first); close(first, tab); return end
        readIdentities(files, function(keys, verified)
            if not keys then stop(verified, "无法核对 OMP 会话文件，标签保留，请重试"); return end
            persist(verified, keys, update, function(ok, saved)
                if not ok then stop(saved, "无法移出历史记录，标签保留，请重试"); return end
                readTarget(function(_, finalShape, fresh)
                    if finalShape ~= original then stop(fresh, "已移出插件历史，标签内容已变更，已保留标签"); return end
                    stop(fresh)
                    close(fresh, tab)
                end)
            end)
        end)
    end)
end

local function restore(cx, entry, update, destination, reveal)
    M.refreshArchive()
    if restoring or clearing or loadError or archive.has(entry.identity) then update(); return end
    restoring, restoreError = entry.key, nil
    local ticket, window = generation, cx:window_key()
    changed(update)
    local function fail(message)
        if ticket ~= generation then return end
        restoring, restoreError = nil, message
        changed(update)
    end
    local function finish(current, pane)
        M.collapse()
        reveal(current, entry.cwd, pane)
        update()
    end
    inspectPanes(window, function(panes, current)
        if ticket ~= generation then return end
        if not panes then fail("无法核对已打开的 Tern 标签，请重试"); return end
        local key = fileKey(entry.file)
        for _, pane in panes do
            if (pane.exited == nil or pane.exited == tern.json.null)
                and fileKey(sessionFile(pane)) == key then
                if current.session:tab_of(pane.pane) then finish(current, pane.pane)
                else fail("这段会话已在另一个窗口或停放的窗格中打开") end
                return
            end
        end
        ioRequest("check", {entry.file, entry.cwd}, function(prefix, ready)
            if ticket ~= generation then return end
            M.refreshArchive()
            if ticket ~= generation then return end
            if archive.has(entry.identity) then fail("这条会话已从插件历史移除"); return end
            if prefix == "missing-cwd" then fail("原项目目录不存在或无法访问"); return end
            if not prefix then fail("无法读取历史会话文件"); return end
            local fresh = parseEntry({path = entry.file, time = 0}, (prefix:gsub("%s+$", "")))
            if not fresh or fresh.id ~= entry.id or fileKey(fresh.cwd) ~= fileKey(entry.cwd) then
                fail("会话文件已变更或移除，请重新展开历史列表"); return
            end
            local session = destination(ready, entry.cwd)
            if not session then fail("没有可用于恢复历史的本机 Tern 会话"); return end
            -- Tern's CLI accepts argv directly. Spaces, quotes and shell characters in paths stay literal.
            run({ternCli, "new", "tab", tostring(session), "--window", window, "--json", "--cwd", entry.cwd,
                "--", "omp", "--resume", entry.file}, {timeout_ms = 10000}, function(result, opened)
                local good, block = pcall(tern.json.decode, result or "")
                if not good or type(block) ~= "table" or type(block.block) ~= "number" then
                    fail("Tern 无法在原目录打开 OMP 会话"); return
                end
                starting[block.block] = {file = entry.file, untilMs = tern.now() + 45000}
                if ticket == generation then finish(opened, block.block) end
            end)
        end)
    end)
end

function M.handle(cx, act, update, destination, reveal)
    if act == "history-toggle" then
        if expanded then M.collapse(update); update() else list(update) end
    elseif act == "history-close" then
        if expanded then M.collapse(update); update() end
    elseif not expanded then return false
    elseif act == "history-retry" then list(update)
    elseif act:sub(1, 6) == "hmore-" then
        local key, ticket = act:sub(7), generation
        local items = historyActions(key)
        if not restoring and not clearing and #items > 0 then
            cx:pick({placeholder = "历史会话操作", action = "选择", items = items}):next(function(choice, _, current)
                if choice and ticket == generation then M.handle(current, choice.id, update, destination, reveal) end
            end)
        end
    elseif act == "history-select" or act == "history-end-select" then
        if not clearing and not restoring then
            selection = if act == "history-select" then {} else nil
            changed(update)
        end
    elseif act == "history-clear-selected" then
        if selection then clearHistory(cx, "清除勾选的历史会话？", nil, update, true) end
    elseif act == "history-clear-all" or act:sub(1, 7) == "hclear-" then
        local item = visible[act:sub(8)]
        if act == "history-clear-all" or (item and item.items) then
            if loading or loadError then cx:toast("info", "完整读取历史后即可清除")
            elseif item then clearHistory(cx, "清除「" .. item.label .. "」的全部历史？", item.items, update)
            else clearHistory(cx, "清除所有项目当前的历史会话？", timeline.items, update) end
        elseif item then clearHistory(cx, "移除「" .. item.label .. "」？", {item}, update) end
    elseif not restoring and (act == "history-projects" or act == "history-time") then
        local nextMode = if act == "history-time" then "time" else "projects"
        if mode ~= nextMode then
            mode, restoreError = nextMode, nil
            tern.kv.set("history-view", mode)
            changed(update)
        end
    elseif not restoring and navigation[act] then
        local target = navigation[act]
        target.list.page, restoreError = target.page, nil
        changed(update)
    elseif visible[act] then
        local item = visible[act]
        if item.items then
            if not restoring then
                item.open, restoreError = not item.open, nil
                changed(update)
            end
        elseif selection then
            if not clearing then
                selection[item.identity] = if selection[item.identity] then nil else true
                changed(update)
            end
        else
            restore(cx, item, update, destination, reveal)
        end
    else return false end
    return true
end

function M.closed(pane)
    starting[pane] = nil
end

return M
