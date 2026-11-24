local activity = require("./activity")
local ui = tern.ui
local M = {}
local paintedTabs, paintedGroups = {}, {}
local breathing = false
local labels = { running = "正在运行", unread = "后台已完成，点击查看", waiting = "等待确认或输入" }

local function mark(key, state, text, label, action)
    return ui.el("span", { key = key, class = "pt-mark pt-mark-" .. state,
        text = text, title = label, aria = label, actions = { click = action } })
end

local function empty()
    return ui.el("span", { key = "activity", class = "pt-mark-empty" })
end

function M.reset()
    paintedTabs, paintedGroups = {}, {}
end

function M.tab(id)
    local state = activity.state(id)
    paintedTabs[id] = state
    if state == "idle" then return empty() end
    return mark("activity", state, if state == "waiting" then "!" else "●", labels[state], "t" .. id)
end

local function groupCounts(group)
    local waiting, unread = 0, 0
    for _, tab in group.tabs do
        local state = activity.state(tab.id)
        if state == "waiting" then waiting += 1
        elseif state == "unread" then unread += 1 end
    end
    return waiting, unread
end

local function groupMark(id, waiting, unread)
    paintedGroups[id] = { waiting = waiting, unread = unread }
    if unread == 0 and waiting == 0 then return empty() end
    local marks = {}
    if waiting > 0 then
        table.insert(marks, mark("waiting", "waiting", "!", waiting .. " 个标签等待确认或输入", id))
    end
    if unread > 0 then
        table.insert(marks, mark("unread", "unread", "● " .. unread, unread .. " 个标签已在后台完成", id))
    end
    return ui.el("div", { key = "activity", class = "pt-group-marks" }, marks)
end

function M.group(group)
    return groupMark(group.id, groupCounts(group))
end

-- Patch only mounted markers. A folded project's children share one summary update.
function M.flush(cx, panel, groupByTab)
    if not activity.hasChanges() then return end
    local dirty = activity.takeChanges()
    if not panel then return end
    local patches, groups = {}, {}
    for id in dirty do
        local group = groupByTab[id]
        if group and group.closed then
            groups[group.id] = group
        elseif group and paintedTabs[id] and paintedTabs[id] ~= activity.state(id) then
            patches["t" .. id .. ".activity"] = M.tab(id)
        end
    end
    for id, group in groups do
        local waiting, unread = groupCounts(group)
        local previous = paintedGroups[id]
        if previous and (previous.waiting ~= waiting or previous.unread ~= unread) then
            patches[id .. ".activity"] = groupMark(id, waiting, unread)
        end
    end
    if next(patches) then cx.canvas:set(panel, { set = patches }) end
end

function M.motion(enabled)
    if breathing == enabled then return end
    breathing = enabled
    tern.css("running-indicators", if enabled then [[
        .pt-mark-running { animation: pt-project-tabs-breathe 1800ms ease-in-out infinite; }
        @media (prefers-reduced-motion: reduce) { .pt-mark-running { animation: none; } }
    ]] else "")
end

return M
