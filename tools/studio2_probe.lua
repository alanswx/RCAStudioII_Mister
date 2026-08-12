-- ---------------------------------------------------------------------------
-- MAME autoboot script: frame-accurate screenshots and state dumps for the
-- RCA Studio II driver, so MAME can be used as a golden reference for the
-- MiSTer core.
--
-- Driven by environment variables (see ../tools/mame-studio2.sh):
--   S2_FRAMES     total frames to run before exiting          (default 300)
--   S2_SHOTS      comma separated frame numbers to snapshot   (default "")
--   S2_SHOT_EVERY snapshot every N frames                     (default 0 = off)
--   S2_DUMPS      comma separated frame numbers to dump       (default "")
--   S2_DUMP_EVERY dump every N frames                         (default 0 = off)
--   S2_DUMP_FILE  where to write the state dump               (default stdout)
--   S2_VRAM       "1" to include $0800-$09FF hexdumps
--   S2_PRESS      "a5@120:4,b3@200" keypad presses
-- ---------------------------------------------------------------------------

local function getenv(name, default)
    local v = os.getenv(name)
    if v == nil or v == "" then return default end
    return v
end

local function parse_list(s)
    local t = {}
    for n in string.gmatch(s or "", "%-?%d+") do t[tonumber(n)] = true end
    return t
end

local total_frames = tonumber(getenv("S2_FRAMES", "300"))
local shots        = parse_list(getenv("S2_SHOTS", ""))
local shot_every   = tonumber(getenv("S2_SHOT_EVERY", "0"))
local dumps        = parse_list(getenv("S2_DUMPS", ""))
local dump_every   = tonumber(getenv("S2_DUMP_EVERY", "0"))
local dump_file    = getenv("S2_DUMP_FILE", "")
local want_vram    = getenv("S2_VRAM", "0") == "1"

-- Keypad schedule: { [frame] = { {port, bit, press} ... } }
-- KEY is a0..a9 / b0..b9, matching the "A"/"B" input ports in the driver.
local key_sched = {}
local function schedule_key(spec)
    local key, frame, hold = string.match(spec, "^([abAB]%d)@(%d+):?(%d*)$")
    if not key then
        print(string.format("[probe] ignoring malformed --press spec '%s'", spec))
        return
    end
    frame = tonumber(frame)
    hold  = tonumber(hold) or 4
    if hold == 0 then hold = 4 end
    local port = string.upper(string.sub(key, 1, 1))
    local bit  = tonumber(string.sub(key, 2, 2))
    key_sched[frame]        = key_sched[frame]        or {}
    key_sched[frame + hold] = key_sched[frame + hold] or {}
    table.insert(key_sched[frame],        { port = port, bit = bit, press = true })
    table.insert(key_sched[frame + hold], { port = port, bit = bit, press = false })
end
for spec in string.gmatch(getenv("S2_PRESS", ""), "[^,]+") do schedule_key(spec) end

local out = io.stdout
if dump_file ~= "" then
    local f, err = io.open(dump_file, "w")
    if f then out = f else print("[probe] cannot open " .. dump_file .. ": " .. tostring(err)) end
end

local frame = 0
local cpu, mem, held

local function init()
    -- The studio2 driver tags its CDP1802 "ic1", not "maincpu".
    for _, tag in ipairs({ ":ic1", ":maincpu", ":cdp1802" }) do
        local d = manager.machine.devices[tag]
        if d and d.spaces and d.spaces["program"] then cpu = d; break end
    end
    if not cpu then
        for tag, d in pairs(manager.machine.devices) do
            local okstate = pcall(function() return d.state["P"] end)
            if okstate and d.spaces and d.spaces["program"] then
                cpu = d
                print("[probe] using CPU device " .. tag)
                break
            end
        end
    end
    if not cpu then
        print("[probe] ERROR: no CPU device found; state dumps disabled")
        return false
    end
    mem = cpu.spaces["program"]
    held = { A = 0, B = 0 }
    return true
end

local function apply_keys(events)
    for _, e in ipairs(events) do
        if e.press then held[e.port] = held[e.port] | (1 << e.bit)
        else            held[e.port] = held[e.port] & ~(1 << e.bit) end
    end
    for tag, port in pairs(manager.machine.ioport.ports) do
        local short = string.match(tag, "([AB])$")
        if short and held[short] then
            for _, field in pairs(port.fields) do
                local b = nil
                for i = 0, 9 do if field.mask == (1 << i) then b = i end end
                if b then field:set_value(((held[short] >> b) & 1)) end
            end
        end
    end
end

local function hexdump(base, len)
    for r = 0, len - 1, 16 do
        local line = string.format("  %04X: ", base + r)
        for c = 0, 15 do line = line .. string.format("%02X ", mem:read_u8(base + r + c)) end
        out:write(line .. "\n")
    end
end

local function dump_state()
    local s = cpu.state
    out:write(string.format("===== frame %d =====\n", frame))
    out:write("-- CDP1802 --\n")
    out:write(string.format("  PC=%04X  P %X  X %X   I:N %X%X\n",
        s["CURPC"].value, s["P"].value, s["X"].value, s["I"].value, s["N"].value))
    out:write(string.format("  D %02X  DF %d  T %02X  B %02X  IE %d  Q %d\n",
        s["D"].value, s["DF"].value, s["T"].value, s["B"].value,
        s["IE"].value, s["Q"].value))
    for i = 0, 15 do
        if i % 8 == 0 then out:write(string.format("  R%X-R%X  ", i, i + 7)) end
        out:write(string.format("%04X ", s[string.format("R%d", i)].value))
        if i % 8 == 7 then out:write("\n") end
    end
    if want_vram then
        out:write("-- Display RAM $0900-$09FF --\n"); hexdump(0x900, 256)
        out:write("-- System RAM $0800-$08FF --\n");  hexdump(0x800, 256)
    end
    out:write("\n")
    out:flush()
end

local ready = false

emu.add_machine_frame_notifier(function()
    if not ready then ready = init() end

    if ready and key_sched[frame] then
        local ok, err = pcall(apply_keys, key_sched[frame])
        if not ok then print("[probe] key error: " .. tostring(err)) end
    end

    if shots[frame] or (shot_every > 0 and frame % shot_every == 0) then
        manager.machine.video:snapshot()
        print(string.format("[probe] snapshot at frame %d", frame))
    end
    if ready and (dumps[frame] or (dump_every > 0 and frame % dump_every == 0)) then
        local ok, err = pcall(dump_state)
        if not ok then print("[probe] dump error: " .. tostring(err)) end
    end

    frame = frame + 1
    if frame > total_frames then
        print(string.format("[probe] reached %d frames, exiting", total_frames))
        if out ~= io.stdout then out:close() end
        manager.machine:exit()
    end
end)

print(string.format("[probe] running %d frames", total_frames))
