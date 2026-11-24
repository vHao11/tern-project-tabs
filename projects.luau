local M = {}

function M.path(value)
    if type(value) ~= "string" or value == "" then return nil end
    local path = value:gsub("\\", "/")
    path = path:gsub("^//%?/UNC/", "//"):gsub("^//%?/", "")
    local prefix = if path:sub(1, 2) == "//" then "//" else ""
    path = prefix .. path:sub(#prefix + 1):gsub("/+", "/")
    if path == "/" or path:match("^%a:/$") then return path end
    return (path:gsub("/$", ""))
end

function M.key(path)
    if path:match("^%a:") or path:sub(1, 2) == "//" then return string.lower(path) end
    return path
end

function M.isAbsolute(path)
    return path ~= nil and (path:sub(1, 1) == "/" or path:match("^%a:/") ~= nil)
end

function M.projectRoot(path, roots)
    local key, best = M.key(path), nil
    for _, root in roots do
        local base = M.key(root)
        local prefix = if base:sub(-1) == "/" then base else base .. "/"
        if (key == base or key:sub(1, #prefix) == prefix) and (not best or #root > #best) then
            best = root
        end
    end
    return best
end

function M.parent(path)
    if path == "/" or path:match("^%a:/$") or path:match("^//[^/]+/[^/]+$") then return nil end
    local dir = path:match("^(.*)/[^/]+$")
    if dir == nil then return nil end
    if dir == "" then return "/" end
    if dir:match("^%a:$") then return dir .. "/" end
    return dir
end

-- Shortest unique suffix keeps the distinguishing directory visible in a narrow sidebar.
function M.names(groups)
    local counts, labels = {}, {}
    for _, group in groups do
        local suffixes = {}
        local at, suffix = group.path or group.name, ""
        while at do
            local part = M.name(at)
            if suffix == "" then
                suffix = part
            else
                suffix = part .. (if part:sub(-1) == "/" then "" else "/") .. suffix
            end
            table.insert(suffixes, suffix)
            local key = (group.host or "") .. "|" .. string.lower(suffix)
            counts[key] = (counts[key] or 0) + 1
            at = M.parent(at)
        end
        labels[group.key] = suffixes
    end
    for _, group in groups do
        local label = group.path or group.name
        for _, suffix in labels[group.key] do
            if counts[(group.host or "") .. "|" .. string.lower(suffix)] == 1 then
                label = suffix
                break
            end
        end
        labels[group.key] = if group.host then group.host .. " · " .. label else label
    end
    return labels
end

function M.labelGroups(groups)
    local names, counts = M.names(groups), {}
    for _, group in groups do
        group.alias = tern.kv.get("project-name:" .. group.key)
        group.defaultName = names[group.key]
        group.label = group.alias or group.defaultName
        local name = string.lower(group.label)
        counts[name] = (counts[name] or 0) + 1
    end
    for _, group in groups do
        if group.alias and counts[string.lower(group.label)] > 1 then
            group.label = group.label .. " · " .. group.defaultName
        end
    end
end

function M.name(path)
    return path:match("([^/]+)$") or path
end

local fileKinds = { file = true, notebook = true, database = true, board = true, profile = true }

function M.folder(pane, tab)
    local path = M.path(pane.path)
    if path and fileKinds[pane.kind] then
        local parent = M.parent(path)
        if parent then return parent end
    elseif path and pane.kind == "git" then
        return path
    end
    return M.path(pane.cwd) or M.path(tab.cwd)
end

function M.label(pane, tab)
    if tab.name and tab.name ~= "" then return tab.name end
    local path = M.path(pane.path)
    if path and fileKinds[pane.kind] then return M.name(path) end
    if pane.title and pane.title ~= "" then return pane.title end
    if pane.program and pane.program ~= "" then return pane.program end
    return "标签 " .. tostring(tab.position)
end

return M
