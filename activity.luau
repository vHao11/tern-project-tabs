-- This module is local to one window. Only active jobs and recognized agents need pane records.
local M = {}
local panes, totals, unread, dirty, agentEnds = {}, {}, {}, {}, {}

local function adjust(tab, phase, delta)
    if not tab or not phase then return end
    local counts = totals[tab] or { running = 0, waiting = 0 }
    counts[phase] += delta
    totals[tab] = if counts.running == 0 and counts.waiting == 0 then nil else counts
    dirty[tab] = true
end

local function assign(id, tab, phase, agent)
    local old = panes[id]
    if old and old.tab == tab and old.phase == phase and old.agent == agent then return end
    if old then adjust(old.tab, old.phase, -1) end
    if phase or agent then
        panes[id] = { tab = tab, phase = phase, agent = agent }
        adjust(tab, phase, 1)
    else
        panes[id] = nil
    end
end

local function agentPhase(state)
    if state == "working" then return "running" end
    if state == "waiting_input" then return "waiting" end
    return nil
end

local function completed(tab, active)
    if tab and tab ~= active and not unread[tab] then
        unread[tab] = true
        dirty[tab] = true
    end
end

function M.state(tab)
    local counts = totals[tab]
    if counts and counts.waiting > 0 then return "waiting" end
    if counts and counts.running > 0 then return "running" end
    return if unread[tab] then "unread" else "idle"
end

function M.seen(tab)
    if tab and unread[tab] then
        unread[tab] = nil
        dirty[tab] = true
    end
end

function M.shell(pane, finished, active)
    if not pane or pane.kind ~= "terminal" then return end
    local old = panes[pane.pane]
    assign(pane.pane, pane.tab, if finished then nil else "running", false)
    -- The shell wrapping an agent can exit after its final turn was already seen.
    if finished and not (old and old.agent) then completed(pane.tab, active) end
end

-- Some agents only report progress going idle. Others also send an explicit turn end.
-- A delayed idle sample can confirm an explicit end even after the user has read it.
local function agentEnd(id, tab, active, source)
    local prior, now = agentEnds[id], tern.now()
    if prior and prior.source ~= source and (source == "state" or now - prior.time <= 750) then
        agentEnds[id] = nil
        return
    end
    agentEnds[id] = { source = source, time = now }
    completed(tab, active)
end

function M.agentChanged(id, tab, previous, state, active)
    local before, after = agentPhase(previous), agentPhase(state)
    if after and not before then agentEnds[id] = nil end
    assign(id, tab, after, true)
    if before and not after then agentEnd(id, tab, active, "state") end
end

function M.agentFinished(id, tab, result, active)
    local old = panes[id]
    if result == "closed" then
        agentEnds[id] = nil
        assign(id, nil, nil, false)
        return
    end
    -- A pending question survives a completion for an earlier turn.
    local phase = if result ~= "exited" and old and old.phase == "waiting" then "waiting" else nil
    assign(id, tab, phase, true)
    if result == "done" or result == "failed" or (result == "exited" and old and old.phase) then
        agentEnd(id, tab, active, "turn")
    end
end

-- Reuse the sidebar's pane snapshot. It also covers work already running at load time and
-- panes moved or restored without a creation event. An idle snapshot does not mean 'unread'.
function M.reconcile(cx, list)
    local live, agents = {}, nil
    for _, p in list do
        local id = p.pane
        live[id] = true
        if p.kind == "agent" then
            local old = panes[id]
            if old and old.agent then
                assign(id, p.tab, old.phase, true)
            else
                if not agents then
                    agents = {}
                    for _, a in cx.agents:list() do agents[a.pane] = a.state end
                end
                assign(id, p.tab, agentPhase(agents[id]), true)
            end
        elseif p.kind == "terminal" then
            agentEnds[id] = nil
            local running = p.exited == nil and (p.running ~= nil or p.busy == true)
            assign(id, p.tab, if running then "running" else nil, false)
        elseif panes[id] then
            M.removePane(id)
        end
    end
    for id in panes do
        if not live[id] then M.removePane(id) end
    end
end

function M.removePane(id)
    agentEnds[id] = nil
    assign(id, nil, nil, false)
end

function M.removeTab(tab)
    unread[tab], dirty[tab] = nil, nil
end

function M.prune(liveTabs)
    for tab in unread do
        if not liveTabs[tab] then M.removeTab(tab) end
    end
end

function M.hasChanges()
    return next(dirty) ~= nil
end

function M.takeChanges()
    local changes = dirty
    dirty = {}
    return changes
end

return M
