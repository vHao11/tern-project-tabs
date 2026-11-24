local projects = require("./projects")
local M = {dir = tern.plugin.data .. "/history-archive-v1"}
local known, hidden = {}, {}
local revisionKey = "history-archive-revision"
local seenRevision

-- An OMP id survives a rename or a move between project buckets in the same profile.
function M.identity(file, id)
    local bucket = projects.parent(projects.path(file))
    local root = bucket and projects.parent(bucket)
    return tern.sha256((if root then projects.key(root) else "") .. "\0" .. id)
end

function M.has(key)
    return hidden[key] == true
end

local function accept(batch, data)
    for key in data:gmatch("[^\n]+") do hidden[key] = true end
    known[batch] = true
end

-- Each action publishes a separate immutable file. Concurrent windows can merge
-- their actions without overwriting each other's records or storing transcript text.
function M.refresh(force)
    local revision = tern.kv.get(revisionKey)
    if not force and revision == seenRevision then return false end
    local changed = false
    if tern.fs.exists(M.dir) then
        for _, name in tern.fs.list(M.dir) do
            local batch = name:match("^([0-9a-f]+)%.set$")
            if batch and #batch == 64 and not known[batch] then
                local data = tern.fs.read(M.dir .. "/" .. name, 32 * 1024 * 1024)
                assert(tern.sha256(data) == batch, "invalid archive file")
                accept(batch, data)
                changed = true
            end
        end
    end
    seenRevision = revision
    return changed
end

function M.batch(keys)
    local ids = {}
    for key in keys do
        if not hidden[key] then table.insert(ids, key) end
    end
    if #ids == 0 then return nil end
    table.sort(ids)
    local data = table.concat(ids, "\n") .. "\n"
    return tern.sha256(data), data
end

function M.committed(batch, data)
    accept(batch, data)
    -- Other windows recheck only while their history drawer is open. Reopening
    -- also discovers committed files if the writing window exited before this hint.
    pcall(tern.kv.set, revisionKey, batch)
end

return M
