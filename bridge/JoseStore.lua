local ffi = require 'ffi'
local bit = require 'bit'
ffi.cdef[[
    unsigned long __stdcall GetCurrentProcessId(void);
    unsigned long long __stdcall GetTickCount64(void);
    unsigned long __stdcall GetFileAttributesA(const char*);
    int __stdcall MoveFileExA(const char*, const char*, unsigned long);
]]
local game = getGameDirectory()
local root = game .. '\\Efeh\\JoseStore'
local ipc = root .. '\\ipc'
local pid = tonumber(ffi.C.GetCurrentProcessId())
local function clock() return tonumber(ffi.C.GetTickCount64()) end
local instance = tostring(pid) .. '-' .. tostring(clock())
local seenSession, seenSequence, lastReply = '', 0, nil
local function safePart(s)
    if type(s) ~= 'string' or #s == 0 or #s > 64 or s:find('[^%w_.%-]') or s:find('..', 1, true) or s:sub(-1) == '.' then return false end
    local stem = (s:match('^[^.]+') or ''):upper()
    return stem ~= 'CON' and stem ~= 'PRN' and stem ~= 'AUX' and stem ~= 'NUL' and not stem:match('^COM[1-9]$') and not stem:match('^LPT[1-9]$')
end
local function safePath(s)
    if type(s) ~= 'string' or #s > 179 or s:find('\\', 1, true) or s:sub(1,1) == '/' or s:sub(-1) == '/' or s:find('//', 1, true) then return false end
    for part in s:gmatch('[^/]+') do if not safePart(part) then return false end end
    return #s > 0
end
local function plain(path)
    local cursor = ''
    for part in path:gmatch('[^\\]+') do
        cursor = cursor == '' and part or cursor .. '\\' .. part
        local attr = tonumber(ffi.C.GetFileAttributesA(cursor))
        if attr ~= 4294967295 and bit.band(attr, 0x400) ~= 0 then return false end
    end
    return true
end
local function read(path)
    if not plain(path) then return nil end
    local f = io.open(path, 'rb'); if not f then return nil end
    local value = f:read(1048577); f:close()
    if not value or #value > 1048576 then return nil end
    local ok, obj = pcall(decodeJson, value)
    if ok and type(obj) == 'table' then return obj end
end
local function write(path, value)
    if not plain(path) or not plain(path .. '.tmp') then return false end
    local ok, text = pcall(encodeJson, value); if not ok then return false end
    local f = io.open(path .. '.tmp', 'wb'); if not f then return false end
    f:write(text); f:close()
    return ffi.C.MoveFileExA(path .. '.tmp', path, 0x1 + 0x8) ~= 0
end
local function normalized(path) return (path or ''):gsub('/', '\\'):lower() end
local function byPath(path)
    for _, s in ipairs(script.list()) do if normalized(s.path) == normalized(path) then return s end end
end
local function manifest(cmd)
    if not safePart(cmd.id) or not safePart(cmd.version) or not safePath(cmd.entry) or cmd.entry:sub(-4) ~= '.lua' then return nil end
    local base = root .. '\\packages\\' .. cmd.id .. '\\' .. cmd.version
    local p = read(base .. '\\package.json')
    if not p or p.id ~= cmd.id or p.version ~= cmd.version or p.entry ~= cmd.entry or p.type ~= 'lua' then return nil end
    local path = base .. '\\' .. cmd.entry:gsub('/', '\\')
    if not plain(path) then return nil end
    return path
end
local function perform(cmd)
    local registered = false
    local installed = read(root .. '\\installed.json')
    for _, m in ipairs(installed and installed.mods or {}) do
        local p = m.package
        if type(p) == 'table' and p.id == cmd.id and p.version == cmd.version and p.entry == cmd.entry then registered = true end
    end
    if not registered then return false, 'store.missing' end
    local path = manifest(cmd); if not path then return false, 'store.manifest' end
    local s = byPath(path)
    if cmd.action == 'load' then
        if not s then s = script.load(path) end
        if not s then return false, 'store.lua' end
    elseif cmd.action == 'unload' then
        if s then s:unload() end
    else return false, 'store.command' end
    return true
end
local function status()
    local active = {}
    local state = read(root .. '\\installed.json')
    for _, m in ipairs(state and state.mods or {}) do
        local p = m.package
        if type(p) == 'table' and p.type == 'lua' then
            local path = manifest(p)
            if path and byPath(path) then active[#active+1] = { id = p.id, version = p.version } end
        end
    end
    write(ipc .. '\\status.json', { protocol=1, pid=pid, instance=instance, tick=clock(), active=active })
end
local function process()
    local cmd = read(ipc .. '\\request.json')
    if not cmd or cmd.protocol ~= 1 or cmd.pid ~= pid or cmd.instance ~= instance or
       type(cmd.session) ~= 'string' or #cmd.session > 100 or type(cmd.sequence) ~= 'number' or
       cmd.sequence < 1 or cmd.sequence ~= math.floor(cmd.sequence) or type(cmd.tick) ~= 'number' or
       clock() - cmd.tick > 10000 or cmd.tick > clock() then return end
    if cmd.session == seenSession and cmd.sequence <= seenSequence then
        if cmd.sequence == seenSequence and lastReply then write(ipc .. '\\reply.json', lastReply) end
        return
    end
    seenSession, seenSequence = cmd.session, cmd.sequence
    local success, ok, err = pcall(perform, cmd)
    if not success then ok, err = false, 'store.lua' end
    -- Esperar al siguiente tick antes de confirmar la liberación.
    wait(0)
    local path = manifest(cmd)
    if ok and path then
        local exists = byPath(path) ~= nil
        if (cmd.action == 'load' and not exists) or (cmd.action == 'unload' and exists) then ok, err = false, 'store.lua' end
    end
    lastReply = {session=cmd.session, sequence=cmd.sequence, instance=instance, ok=ok == true, error=err or ''}
    status(); write(ipc .. '\\reply.json', lastReply)
end
function main()
    if not plain(root) then return end
    for _, dir in ipairs({game .. '\\Efeh', root, ipc}) do
        if not doesDirectoryExist(dir) then createDirectory(dir) end
    end
    while true do
        pcall(process)
        pcall(status)
        wait(250)
    end
end
function onExitScript()
    write(ipc .. '\\status.json', {protocol=1, pid=pid, instance=instance, tick=0, active={}})
end
