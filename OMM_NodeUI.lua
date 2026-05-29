-- ==============================================================================
-- OMM_NodeUI.lua (The Visual Rendering Engine & Dynamic Schema Loader)
-- Protocol Zero: Config Registry & Beta Sandbox Audio Engine
-- ==============================================================================

local NodeUI = {}
reaper.gmem_attach("OMM_Shared")

local function NormToSlope(v)
    local angle_deg = v <= 0.6666 and (26.56505 + (v / 0.6666) * (45.0 - 26.56505)) or (45.0 + ((v - 0.6666) / (1.0 - 0.6666)) * 90.0)
    if math.abs(angle_deg - 90.0) < 0.1 then return angle_deg > 90 and -500.0 or 500.0 end
    return math.tan(math.rad(angle_deg))
end

local function SlopeToNorm(m)
    local angle_deg = math.deg(math.atan(m))
    if angle_deg < 0 then angle_deg = angle_deg + 180.0 end
    if angle_deg <= 45.0 then return math.max(0.0, ((angle_deg - 26.56505) / (45.0 - 26.56505)) * 0.6666)
    else return math.min(1.0, 0.6666 + ((angle_deg - 45.0) / 90.0) * (1.0 - 0.6666)) end
end

-- ==========================================================
-- PRO CODE: TRUE KINEMATIC TEXT ENGINE (Canvas Exclusive)
-- ==========================================================
function NodeUI.DrawCanvasText(ctx, dl, text, x, y, col, a_mult, z)
    local a = tonumber(a_mult) or 1.0
    local f_sz = 14 * z 
    local final_x = math.floor(x + 0.5)
    local final_y = math.floor(y + 0.5)
    
    local font = NodeUI.Canvas_Font
    
    reaper.ImGui_DrawList_AddTextEx(dl, font, f_sz, final_x+1, final_y+1, 0x00000000 | math.floor(0xFF*a_mult), tostring(text))
    reaper.ImGui_DrawList_AddTextEx(dl, font, f_sz, final_x, final_y, (col & 0xFFFFFF00) | math.floor((col & 0xFF)*a_mult), tostring(text))
end


-- ==========================================================
-- THE 2.5D CLAYMORPHISM COLOR ENGINE
-- ==========================================================
local function ExtractRGB(hex)
    -- Handle 32-bit RGBA (where hex has non-zero alpha or is larger)
    if hex > 0xFFFFFF or (hex & 0xFF) == 0xFF then
        return (hex >> 24) & 0xFF, (hex >> 16) & 0xFF, (hex >> 8) & 0xFF
    else
        return (hex >> 16) & 0xFF, (hex >> 8) & 0xFF, hex & 0xFF
    end
end

local function BuildClayTokens(seed_hex, is_active, env_alpha)
    local r, g, b = ExtractRGB(seed_hex)
    -- Normalize
    r, g, b = r/255, g/255, b/255
    
    -- Fast Luminance approximation
    local lum = (0.299*r + 0.587*g + 0.114*b)
    
    -- Calculate Lighting Deltas
    local h_delta = 0.25 -- Highlight strength
    local s_delta = is_active and 0.40 or 0.55 -- Shadow gets darker if inactive
    local w_delta = 0.70 -- Deep well (milled housing)
    
    -- Generate Tokens (Clamp 0-1)
    local function Pack(tr, tg, tb, alpha)
        return (math.floor(math.max(0, math.min(1, tr))*255) << 24) |
               (math.floor(math.max(0, math.min(1, tg))*255) << 16) |
               (math.floor(math.max(0, math.min(1, tb))*255) << 8) |
               math.floor(alpha * 255)
    end
    
    local alpha = env_alpha or 1.0
    
    return {
        surface   = Pack(r, g, b, alpha),
        highlight = Pack(r + h_delta, g + h_delta, b + h_delta, alpha),
        shadow    = Pack(r - s_delta, g - s_delta, b - s_delta, alpha),
        well      = Pack(r - w_delta, g - w_delta, b - w_delta, alpha),
        text      = lum > 0.6 and Pack(0.1, 0.1, 0.12, alpha) or Pack(0.95, 0.95, 0.95, alpha)
    }
end

-- ==========================================================
-- THE ULTIMATE BUTTON CORE (Single Entity)
-- ==========================================================
local function DrawClayButton(ctx, dl, UI, id, x, y, w, h, label, seed_hex, is_active, is_clicked, env)
    -- 1. Physics State Calculation
    UI.physics_states = UI.physics_states or {}
    UI.physics_states[id] = UI.physics_states[id] or { z = 0, v = 0 }
    
    local target_z = is_clicked and 1.0 or 0.0
    -- SpringDamp: current, target, velocity, tension, friction, dt
    UI.physics_states[id].z, UI.physics_states[id].v = UI.SpringDamp(
        UI.physics_states[id].z, target_z, UI.physics_states[id].v, 
        80.0, 8.0, env.app_dt or 0.016
    )
    
    local anim_z = UI.physics_states[id].z -- 0.0 (rest) to 1.0 (fully depressed)
    local tokens = BuildClayTokens(seed_hex, is_active, env.act_a)
    
    local r = 6.0 -- Global Border Radius (Teenage Engineering standard)
    local gap = 2.0 -- The Milled Tolerance Gap
    
    -- 2. Draw The Milled Housing (The Well)
    reaper.ImGui_DrawList_AddRectFilled(dl, x, y, x+w, y+h, tokens.well, r)
    -- Inner lip shadow to make the well look deep
    reaper.ImGui_DrawList_AddRect(dl, x, y, x+w, y+h, 0x00000066, r, 0, 1.0)
    
    -- 3. Calculate 2.5D Matte Clay Button coordinates based on Z-depth
    -- When pressed, it moves DOWN and RIGHT by 1px, and the shadow compresses.
    local travel = anim_z * 1.5
    local bx, by = x + gap + (travel * 0.5), y + gap + travel
    local bw, bh = w - (gap*2), h - (gap*2)
    
    -- Drop Shadow (Shrinks as Z approaches 1.0)
    local shadow_offset = 2.0 - travel
    reaper.ImGui_DrawList_AddRectFilled(dl, bx, by + shadow_offset, bx + bw, by + bh + shadow_offset, tokens.shadow, r - 1)
    
    -- Matte Surface
    reaper.ImGui_DrawList_AddRectFilled(dl, bx, by, bx + bw, by + bh, tokens.surface, r - 1)
    
    -- Top-Left Inner Highlight (Fades out when pressed)
    local hl_alpha_mod = 1.0 - (anim_z * 0.5)
    local hl_col = (tokens.highlight & 0xFFFFFF00) | math.floor((tokens.highlight & 0xFF) * hl_alpha_mod)
    reaper.ImGui_DrawList_AddRect(dl, bx, by, bx + bw, by + bh, hl_col, r - 1, 0, 1.0)
    
    -- 4. Typography (Centers text, shifts with Z-axis)
    local _, tw, th = pcall(reaper.ImGui_CalcTextSize, ctx, label)
    tw, th = tonumber(tw) or 0, tonumber(th) or 0
    local tx, ty = bx + (bw/2) - (tw/2), by + (bh/2) - (th/2)
    pcall(reaper.ImGui_DrawList_AddText, dl, tx, ty, tokens.text, label)
    
    -- 5. Invisible Hitbox
    local ok_b = pcall(UI.Safe_InvisibleButton, ctx, id, w, h)
    local clicked = ok_b and select(2, pcall(reaper.ImGui_IsItemClicked, ctx))
    local active = ok_b and select(2, pcall(reaper.ImGui_IsItemActive, ctx))
    
    return clicked, active
end

-- ==========================================================
-- THE SEGMENTED CLAY STRIP (High-Density)
-- ==========================================================
function NodeUI.DrawComponent_RadioStrip(ctx, dl, comp, origin_x, origin_y, env, state, is_disabled, val_norm, disp_str, p_state, UI)
    local z = comp.z or 1.0
    local x, y = origin_x + (comp.x * z), origin_y + (comp.y * z)
    local steps = comp.steps or 6
    local base_w = (comp.btn_w or 32) * z
    local base_h = (comp.btn_h or 24) * z
    
    local total_w = (base_w * steps) + (2 * z)
    local r = 4.0 * z
    
    reaper.ImGui_DrawList_AddRectFilled(dl, x, y, x + total_w, y + base_h + (2 * z), 0x111112FF, r)
    reaper.ImGui_DrawList_AddRect(dl, x, y, x + total_w, y + base_h + (2 * z), 0x00000088, r, 0, 1.0 * z)
    
    local current_val = (state and comp.param_key) and state[comp.param_key] or comp.default_val or 0
    local changed = false
    local new_norm = val_norm
    
    for i = 1, steps do
        local bx = x + (1 * z) + ((i - 1) * base_w)
        local by = y + (1 * z)
        
        local step_norm = (i - 1) / (steps - 1)
        local is_active = (math.abs(val_norm - step_norm) < 0.05)
        
        local id = comp.id .. "_seg_" .. i
        UI.physics_states = UI.physics_states or {}
        UI.physics_states[id] = UI.physics_states[id] or { z = 0, v = 0 }
        
        pcall(reaper.ImGui_SetCursorScreenPos, ctx, bx, by)
        UI.Safe_InvisibleButton(ctx, id, base_w, base_h)
        
        local is_held = pcall(reaper.ImGui_IsItemActive, ctx) and reaper.ImGui_IsItemActive(ctx)
        local is_clicked = pcall(reaper.ImGui_IsItemClicked, ctx) and reaper.ImGui_IsItemClicked(ctx)
        
        local target_z = is_held and 1.0 or 0.0
        UI.physics_states[id].z, UI.physics_states[id].v = UI.SpringDamp(
            UI.physics_states[id].z, target_z, UI.physics_states[id].v, 
            80.0, 8.0, env.app_dt or 0.016
        )
        
        local anim_z = UI.physics_states[id].z
        local travel = anim_z * (1.5 * z)
        
        local seed_hex = env.palette[comp.color_token] or 0xFF6B35FF
        local tokens = BuildClayTokens(seed_hex, is_active, env.act_a)
        local base_col = is_active and tokens.surface or 0x333333FF
        
        local cap_y = by + travel
        local cap_h = base_h - travel
        
        local flag = 0
        if i == 1 then flag = reaper.ImGui_DrawFlags_RoundCornersLeft()
        elseif i == steps then flag = reaper.ImGui_DrawFlags_RoundCornersRight()
        else flag = reaper.ImGui_DrawFlags_RoundCornersNone() end
        
        if not is_held then
            reaper.ImGui_DrawList_AddRectFilled(dl, bx, by + (2 * z), bx + base_w, by + base_h, 0x00000099, r, flag)
        end
        
        reaper.ImGui_DrawList_AddRectFilled(dl, bx, cap_y, bx + base_w, cap_y + cap_h, base_col, r, flag)
        
        if not is_held then
            local hl_col = is_active and tokens.highlight or 0x555555FF
            reaper.ImGui_DrawList_AddLine(dl, bx + (1 * z), cap_y, bx + base_w - (1 * z), cap_y, hl_col, 1.0 * z)
        end
        
        if i < steps then
            reaper.ImGui_DrawList_AddLine(dl, bx + base_w, cap_y + (2 * z), bx + base_w, cap_y + cap_h - (2 * z), 0x1A1A1CFF, 1.0 * z)
            reaper.ImGui_DrawList_AddLine(dl, bx + base_w + (1 * z), cap_y + (2 * z), bx + base_w + (1 * z), cap_y + cap_h - (2 * z), 0x444444FF, 1.0 * z)
        end
        
        local label = comp.labels and comp.labels[i] or tostring(i)
        local _, tw, th = pcall(reaper.ImGui_CalcTextSize, ctx, label)
        tw, th = (tonumber(tw) or 0) * z, (tonumber(th) or 0) * z
        local tx = bx + (base_w/2) - (tw/2)
        local ty = cap_y + (cap_h/2) - (th/2)
        local text_col = is_active and tokens.text or 0x999999FF
        NodeUI.DrawCanvasText(ctx, dl, label, tx, ty, text_col, 1.0, z)
        
        if is_clicked and not is_disabled then
            changed = true
            new_norm = step_norm
        end
    end
    
    return changed, new_norm
end

NodeUI.ALGO_NAMES = {
    [0] = "REACOMP STANDARD", [1] = "1175 FET", [2] = "SSL VCA",
    [3] = "FAIRCHILD 670", [4] = "EVENTHORIZON", [5] = "PEAK LIMITER",
    [6] = "LA-2A OPTO", [7] = "CUSTOM", [100] = "LFO Core", [200] = "GAIN Stage",
    [999] = "BETA TEST LAB", -- THE SANDBOX MODULE
    ["VCA"] = "VCA COMPRESSOR", ["FET"] = "FET COMPRESSOR", ["OPTO"] = "OPTO COMPRESSOR"
}

NodeUI.SCHEMAS = {}
NodeUI.PALETTES = {}
NodeUI.CONFIG = { defaults = {} }
NodeUI.script_path = debug.getinfo(1, "S").source:match("@?(.*[\\/])") or ""
NodeUI.PaletteEngine = dofile(NodeUI.script_path .. "OMM_Palette.lua")
NodeUI.Router = dofile(NodeUI.script_path .. "OMM_Router.lua")

-- ==========================================
-- OS CONFIG REGISTRY & SCHEMA LOADER
-- ==========================================
function NodeUI.LoadConfig()
    local filepath = NodeUI.script_path .. "OMM_Config.lua"
    local chunk = loadfile(filepath)
    if chunk then
        local ok, cfg = pcall(chunk)
        if ok and type(cfg) == "table" and cfg.defaults then
            NodeUI.CONFIG = cfg
        end
    end
end

function NodeUI.LoadSchemaFromFile(algo_id)
    local theme_name = NodeUI.CONFIG.defaults[algo_id] or "Default"
    local filepath = NodeUI.script_path .. "OMM_Schema_Algo_" .. tostring(algo_id) .. "_" .. theme_name .. ".lua"
    local file = io.open(filepath, "r")
    if file then
        file:close()
        local chunk, err = loadfile(filepath)
        if chunk then
            local success, schema_data = pcall(chunk)
            if success and type(schema_data) == "table" and schema_data.components then
                -- PRO CODE FIX: Removed Global Grid Enforcer. 
                -- We now trust the IDE's schema_data.grid_cols and grid_rows implicitly.

                -- MIGRATION FALLBACK: Auto-generate routes from legacy param_key
                for _, comp in ipairs(schema_data.components) do
                    if comp.param_key and not comp.routes then
                        if comp.param_key ~= "unmapped" and comp.param_key ~= "" then
                            comp.routes = { { type = "INTERNAL", target = comp.param_key, depth = 1.0, label = comp.param_key } }
                        else
                            comp.routes = {}
                        end
                    end
                end
                NodeUI.SCHEMAS[algo_id] = schema_data
                if schema_data.seed_hex and NodeUI.PaletteEngine then
                    NodeUI.PALETTES[algo_id] = NodeUI.PaletteEngine.Generate(schema_data.seed_hex)
                end
                return true
            end
        end
    end
    NodeUI.SCHEMAS[algo_id] = nil
    NodeUI.PALETTES[algo_id] = nil
    return false
end

function NodeUI.ScanForSchemas()
    NodeUI.LoadConfig()
    -- Scan the script directory for OMM_Schema_Algo_*.lua files
    local i = 0
    while true do
        local f = reaper.EnumerateFiles(NodeUI.script_path, i)
        if not f then break end
        
        local algo_id, theme = f:match("^OMM_Schema_Algo_(%d+)_(.+)\\.lua$")
        if algo_id and theme then
            local num_id = tonumber(algo_id) or algo_id
            -- Only load if this matches the user's active theme selection for this algo
            local active_theme = NodeUI.CONFIG.defaults[num_id] or "Default"
            if theme == active_theme then
                NodeUI.LoadSchemaFromFile(num_id)
            end
        end
        i = i + 1
    end
end

-- Saftey Fallback if a UI file is completely missing
function NodeUI.GetSchema(algo_id)
    if NodeUI.SCHEMAS[algo_id] then return NodeUI.SCHEMAS[algo_id] end
    return {
        grid_cols = 12, grid_rows = 6, seed_hex = 0xFF0000, module_type = "ERROR",
        components = {
            { id = "err_bg", type = "BackPanel", x = 0, y = 0, w = 480, h = 180, color_token = "Base" },
            { id = "err_txt", type = "TogglePill", x = 120, y = 60, w = 240, h = 60, align = 1, 
              color_token = "Primary", label = "SCHEMA MISSING", default_val = 1.0, get_format = function() return "ERROR" end }
        }
    }
end

NodeUI.ScanForSchemas()

function NodeUI.HotReload(algo_id, UI_engine)
    NodeUI.LoadConfig()
    if NodeUI.LoadSchemaFromFile(algo_id) then
        if UI_engine and UI_engine.physics_states then
            for key, _ in pairs(UI_engine.physics_states) do UI_engine.physics_states[key] = nil end
        end
        return true
    end
    return false
end

local function ScaleDB(db_val, mode_exp)
    local min_db, max_db = -60.0, mode_exp and 12.0 or 0.0
    if db_val <= min_db then return 0.0 end
    if db_val >= max_db then return 1.0 end
    return (db_val - min_db) / (max_db - min_db)
end

-- ==========================================================
-- PRO CODE: KINEMATIC AURAKNOB
-- ==========================================================
function NodeUI.DrawComponent_AuraKnob(ctx, dl, comp, origin_x, origin_y, env, state, is_disabled, val_norm, disp_str, p_state, UI)
    local z = comp.z or 1.0
    -- MATHEMATICAL GEOMETRY SCALING
    local rad = (comp.radius or 16) * z
    local x, y = origin_x + (comp.x * z), origin_y + (comp.y * z)
    local cx, cy = x + rad, y + rad
    
    local active_col = UI.LerpColor(env.palette and env.palette[comp.color_token] or 0x00A5FFFF, 0xFFFFFFFF, p_state.flash or 0.0)
    local a_min, a_max = math.pi * 0.75, math.pi * 2.25
    local disp_val = p_state.disp_val or val_norm
    local a_val = a_min + (a_max - a_min) * disp_val
    
    local has_depth = comp.routes and comp.routes[1]
    local depth_val = has_depth and comp.routes[1].depth or 0.0
    local is_bipolar = comp.is_bipolar or false

    -- SCALED INTERACTION HITBOX
    reaper.ImGui_SetCursorScreenPos(ctx, x, y)
    UI.Safe_InvisibleButton(ctx, comp.id.."_knob", rad*2, rad*2)
    local changed, new_norm = false, val_norm
    local hov = reaper.ImGui_IsItemHovered(ctx)
    local is_active = reaper.ImGui_IsItemActive(ctx)
    
    if UI.edit_mode and hov and reaper.ImGui_IsMouseDoubleClicked(ctx, 0) then
        comp.is_bipolar = not comp.is_bipolar
        changed = true; p_state.flash = 1.0
    end

    if is_active and not is_disabled then
        local ok, dx, dy = pcall(reaper.ImGui_GetMouseDelta, ctx)
        if ok and tonumber(dy) and dy ~= 0 then
            local mx, my = reaper.ImGui_GetMousePos(ctx)
            local dist = math.sqrt((mx - cx)^2 + (my - cy)^2)
            local shift = select(2, pcall(reaper.ImGui_IsKeyDown, ctx, reaper.ImGui_Mod_Shift()))
            local speed = shift and 0.0005 or 0.003
            
            if dist > (rad * 0.6) and has_depth and UI.edit_mode then
                comp.routes[1].depth = math.max(-1.0, math.min(1.0, depth_val - (dy * speed * 2.0)))
                changed = true; p_state.flash = 1.0
            elseif not UI.edit_mode then
                new_norm = math.max(0.0, math.min(1.0, val_norm - (dy * speed)))
                changed = true
            end
        end
    end

    -- SCALED VOLUMETRIC SHADOW
    reaper.ImGui_DrawList_AddCircleFilled(dl, cx, cy + (4 * z), rad, 0x00000044 | math.floor(0xFF * env.act_a))
    
    -- SCALED BASE TRACK
    reaper.ImGui_DrawList_PathArcTo(dl, cx, cy, rad, a_min, a_max, 0)
    reaper.ImGui_DrawList_PathStroke(dl, 0x05050500 | math.floor(0xFF * env.act_a), 0, 4.0 * z)
    
    -- SCALED DEPTH RING
    if has_depth and math.abs(depth_val) > 0.01 then
        local t_max, t_min = disp_val + depth_val, disp_val
        if is_bipolar then
            t_max = disp_val + math.abs(depth_val); t_min = disp_val - math.abs(depth_val)
        elseif depth_val < 0 then
            t_max, t_min = disp_val, disp_val + depth_val
        end
        t_max, t_min = math.max(0.0, math.min(1.0, t_max)), math.max(0.0, math.min(1.0, t_min))
        local a_lim_max = a_min + (t_max * 1.5 * math.pi); local a_lim_min = a_min + (t_min * 1.5 * math.pi)
        if math.abs(a_lim_max - a_lim_min) > 0.01 then
            reaper.ImGui_DrawList_PathArcTo(dl, cx, cy, rad, math.min(a_lim_min, a_lim_max), math.max(a_lim_min, a_lim_max), 0)
            reaper.ImGui_DrawList_PathStroke(dl, (active_col & 0xFFFFFF00) | math.floor(255 * 0.35 * env.act_a), 0, 4.0 * z)
        end
    end
    
    -- SCALED VALUE CORE
    local draw_st, draw_en = a_min, a_val
    if draw_en - draw_st > 0.01 then
        reaper.ImGui_DrawList_PathArcTo(dl, cx, cy, rad, draw_st, draw_en, 0)
        reaper.ImGui_DrawList_PathStroke(dl, active_col & 0xFFFFFF00 | math.floor(0xAA * env.act_a), 0, 3.0 * z)
    end
    
    -- SCALED INNER CAP
    local cap_bg = is_active and 0x08080800 or 0x1A1A1E00
    reaper.ImGui_DrawList_AddCircleFilled(dl, cx, cy, rad - (4 * z), cap_bg | math.floor(0xFF * env.act_a))
    
    -- SCALED NEEDLE
    local lx, ly = cx + math.cos(a_val) * (rad - (2 * z)), cy + math.sin(a_val) * (rad - (2 * z))
    reaper.ImGui_DrawList_AddLine(dl, cx, cy, lx, ly, 0x1C1C1EFF & 0xFFFFFF00 | math.floor(0xFF * env.act_a), 2.0 * z)
    
    -- SCALED LABELS (True Kinematics)
    local _, tw, th = pcall(reaper.ImGui_CalcTextSize, ctx, comp.label)
    tw, th = (tonumber(tw) or 0) * z, (tonumber(th) or 0) * z
    NodeUI.DrawCanvasText(ctx, dl, comp.label, cx - tw/2, cy - rad - (20 * z), 0x8E8E93FF, env.act_a, z)
    
    local _, vw, vh = pcall(reaper.ImGui_CalcTextSize, ctx, disp_str)
    vw, vh = (tonumber(vw) or 0) * z, (tonumber(vh) or 0) * z
    NodeUI.DrawCanvasText(ctx, dl, disp_str, cx - vw/2, cy + rad + (6 * z), active_col, env.act_a, z)
    
    return changed, new_norm
end

-- ==========================================================
-- PRO CODE: KINEMATIC INLINE TEXT
-- ==========================================================
function NodeUI.DrawComponent_InlineDrag(ctx, dl, comp, origin_x, origin_y, env, state, is_disabled, val_norm, disp_str, p_state, UI)
    local z = comp.z or 1.0
    -- MATHEMATICAL GEOMETRY SCALING
    local x, y = origin_x + (comp.x * z), origin_y + (comp.y * z)
    local w, h = (comp.w or 60) * z, (comp.h or 20) * z
    local align = comp.align or 1 
    
    local lbl = type(comp.label) == "function" and comp.label(state) or comp.label
    local full_str = tostring(lbl) .. " " .. tostring(disp_str)
    
    local _, tw, th = pcall(reaper.ImGui_CalcTextSize, ctx, full_str)
    tw, th = (tonumber(tw) or 0) * z, (tonumber(th) or 0) * z
    local tx = x + (4 * z)
    if align == 1 then tx = x + (w/2) - (tw/2)
    elseif align == 2 then tx = x + w - tw - (4 * z) end
    local ty = y + (h/2) - (th/2)
    local col = UI.LerpColor(0x005F73FF, 0xFFFFFFFF, p_state.flash or 0.0)
    NodeUI.DrawCanvasText(ctx, dl, full_str, tx, ty, col, env.act_a, z)
    
    return false, val_norm
end

-- ==========================================================
-- PRO CODE: KINEMATIC PEAK METER
-- ==========================================================
function NodeUI.DrawComponent_PeakMeter(ctx, dl, comp, origin_x, origin_y, env, state, is_disabled, val_norm, disp_str, p_state, UI)
    local z = comp.z or 1.0
    -- MATHEMATICAL GEOMETRY SCALING
    local x, y = origin_x + (comp.x * z), origin_y + (comp.y * z)
    local w, h = (comp.w or 20) * z, (comp.h or 100) * z
    local active_a = math.floor(0xFF * env.act_a)
    
    reaper.ImGui_DrawList_AddRectFilled(dl, x, y, x+w, y+h, 0x050508FF, 12.0 * z)
    reaper.ImGui_DrawList_AddRect(dl, x, y, x+w, y+h, 0x1A1A1FFF & 0xFFFFFF00 | active_a, 12.0 * z, 0, 1.5 * z)
    
    local fill_h = h * p_state.disp_val
    if fill_h > 2 * z then
        local c_fill = UI.LerpColor(0x00E5FFFF, 0xFF3333FF, p_state.disp_val)
        reaper.ImGui_DrawList_AddRectFilled(dl, x + (2 * z), y + h - fill_h + (2 * z), x + w - (2 * z), y + h - (2 * z), c_fill & 0xFFFFFF00 | active_a, 6.0 * z)
        if p_state.disp_val > 0.8 then 
            reaper.ImGui_DrawList_AddCircleFilled(dl, x + w/2, y + h - fill_h, w, c_fill & 0xFFFFFF00 | math.floor(0x44 * env.act_a)) 
        end
    end
    return false, val_norm
end

-- ==========================================================
-- PRO CODE: KINEMATIC VU METER
-- ==========================================================
function NodeUI.DrawComponent_VuMeter(ctx, dl, comp, origin_x, origin_y, env, state, is_disabled, val_norm, disp_str, p_state, UI)
    local z = comp.z or 1.0
    -- MATHEMATICAL GEOMETRY SCALING
    local x, y = origin_x + (comp.x * z), origin_y + (comp.y * z)
    local w, h = (comp.w or 100) * z, (comp.h or 80) * z
    local active_a = math.floor(0xFF * env.act_a)
    
    reaper.ImGui_DrawList_AddRectFilled(dl, x, y, x+w, y+h, 0x161619FF, 6.0 * z)
    reaper.ImGui_DrawList_AddRect(dl, x, y, x+w, y+h, 0x2A2A33FF, 6.0 * z, 0, 1.0 * z)
    
    local pivot_x, pivot_y = x + w/2, y + h * 1.15
    local radius = h * 0.9
    local a_min, a_max = math.pi * 1.25, math.pi * 1.75
    
    reaper.ImGui_DrawList_PathArcTo(dl, pivot_x, pivot_y, radius, a_min, a_max, 0)
    reaper.ImGui_DrawList_PathStroke(dl, 0x8E8E93FF & 0xFFFFFF00 | active_a, 0, 2.0 * z)
    
    for i = 0, 5 do
        local t_a = a_min + (a_max - a_min) * (i / 5.0)
        local tx1, ty1 = pivot_x + math.cos(t_a) * radius, pivot_y + math.sin(t_a) * radius
        local tx2, ty2 = pivot_x + math.cos(t_a) * (radius - (8 * z)), pivot_y + math.sin(t_a) * (radius - (8 * z))
        reaper.ImGui_DrawList_AddLine(dl, tx1, ty1, tx2, ty2, 0x8E8E93FF & 0xFFFFFF00 | active_a, 1.5 * z)
    end
    
    local a_val = a_min + (a_max - a_min) * p_state.disp_val
    local n_x, n_y = pivot_x + math.cos(a_val) * (radius + (4 * z)), pivot_y + math.sin(a_val) * (radius + (4 * z))
    reaper.ImGui_DrawList_AddLine(dl, pivot_x, pivot_y, n_x, n_y, 0xFF3333FF & 0xFFFFFF00 | active_a, 2.0 * z)
    
    if p_state.disp_val > 0.8 then 
        reaper.ImGui_DrawList_AddCircleFilled(dl, n_x, n_y, 12 * z, 0xFF333300 | math.floor(0x44 * env.act_a)) 
    end
    return false, val_norm
end

-- ==========================================================
-- PRO CODE: KINEMATIC TOGGLE PILL
-- ==========================================================
function NodeUI.DrawComponent_TogglePill(ctx, dl, comp, origin_x, origin_y, env, state, is_disabled, val_norm, disp_str, p_state, UI)
    local z = comp.z or 1.0
    -- MATHEMATICAL GEOMETRY SCALING
    local x, y = origin_x + (comp.x * z), origin_y + (comp.y * z)
    local w, h = (comp.w or 50) * z, (comp.h or 24) * z
    local r = math.min(w,h)/2
    local is_active = val_norm > 0.5
    
    reaper.ImGui_SetCursorScreenPos(ctx, x, y)
    UI.Safe_InvisibleButton(ctx, comp.id, w, h)
    local changed, new_norm = false, val_norm
    if not UI.edit_mode and reaper.ImGui_IsItemClicked(ctx) then 
        new_norm = is_active and 0.0 or 1.0
        changed = true 
    end
    p_state.ghost_norm = new_norm
    
    local c_bg = is_active and 0x00E5FFFF or 0x2A2A33FF
    reaper.ImGui_DrawList_AddRectFilled(dl, x, y, x+w, y+h, c_bg & 0xFFFFFF00 | math.floor(0xFF * env.act_a), r)
    
    local t_size = r * 1.5
    local t_x, t_y = x + (3 * z), y + h/2 - t_size/2
    if w > h then 
        t_x = x + (3 * z) + (w - t_size - (6 * z)) * p_state.disp_val
    else 
        t_x = x + w/2 - t_size/2
        t_y = y + (3 * z) + (h - t_size - (6 * z)) * (1.0 - p_state.disp_val) 
    end
    
    reaper.ImGui_DrawList_AddCircleFilled(dl, t_x + t_size/2, t_y + t_size/2, t_size/2, 0xFFFFFFFF & 0xFFFFFF00 | math.floor(0xFF * env.act_a))
    return changed, new_norm
end

function NodeUI.DrawComponent_ToggleLever(ctx, dl, comp, origin_x, origin_y, env, state, is_disabled, val_norm, disp_str, p_state, UI)
    -- EXTRACT THE ZOOM
    local z = comp.z or 1.0 
    
    -- MULTIPLY LOCAL COORDINATES AND DIMENSIONS BY Z
    local x = origin_x + (comp.x * z)
    local y = origin_y + (comp.y * z)
    local w, h = (comp.w or 24) * z, (comp.h or 50) * z
    local is_active = val_norm > 0.5
    
    reaper.ImGui_SetCursorScreenPos(ctx, x, y)
    UI.Safe_InvisibleButton(ctx, comp.id, w, h)
    local changed, new_norm = false, val_norm
    if not UI.edit_mode and reaper.ImGui_IsItemClicked(ctx) then new_norm = is_active and 0.0 or 1.0; changed = true end

    p_state.ghost_norm = new_norm
    local a = math.floor(0xFF * env.act_a)
    
    -- SCALE CHASSIS BORDERS
    reaper.ImGui_DrawList_AddRectFilled(dl, x, y, x+w, y+h, 0x1A1A1CFF & 0xFFFFFF00 | a, 4.0 * z)
    reaper.ImGui_DrawList_AddRect(dl, x, y, x+w, y+h, 0x08080AFF & 0xFFFFFF00 | a, 4.0 * z, 0, 2.0 * z)
    
    -- SCALE INTERNAL LEVER MATH
    local l_y = y + (4 * z) + (h - (24 * z) - (8 * z)) * (1.0 - p_state.disp_val)
    reaper.ImGui_DrawList_AddRectFilled(dl, x+(4 * z), l_y+(4 * z), x+w-(4 * z), l_y+(24 * z)+(4 * z), 0x00000088 & 0xFFFFFF00 | a, 2.0 * z)
    reaper.ImGui_DrawList_AddRectFilled(dl, x+(2 * z), l_y, x+w-(2 * z), l_y+(24 * z), 0xDDDDDDFF & 0xFFFFFF00 | a, 2.0 * z)
    reaper.ImGui_DrawList_AddLine(dl, x+(4 * z), l_y+(12 * z), x+w-(4 * z), l_y+(12 * z), 0x888888FF & 0xFFFFFF00 | a, 2.0 * z)
    
    return changed, new_norm
end

-- ==========================================
-- EXTRACTED LEGACY: FADER (VCA Slider with dB Math)
-- Legacy Location: GAIN module DrawGainModule (~line 2101)
-- ==========================================
-- ==========================================
-- EXTRACTED LEGACY COMPONENT RENDERERS
-- ==========================================

function NodeUI.DrawComponent_BackPanel(ctx, dl, comp, origin_x, origin_y, env, state, is_disabled, val_norm, disp_str, p_state, UI)
    local z = comp.z or 1.0
    local x, y = origin_x + (comp.x * z), origin_y + (comp.y * z)
    local w, h = (comp.w or 200) * z, (comp.h or 100) * z
    local col = env.palette and env.palette[comp.color_token] or 0x1C1C1EFF
    
    reaper.ImGui_DrawList_AddRectFilled(dl, x, y, x+w, y+h, col, 12.0 * z, reaper.ImGui_DrawFlags_RoundCornersTop())
    reaper.ImGui_DrawList_AddLine(dl, x+(12*z), y, x+w-(12*z), y, 0xFFFFFF22, 2.0 * z)
    reaper.ImGui_DrawList_AddRectFilledMultiColor(dl, x, y, x+w, y+(20*z), 0xFFFFFF08, 0xFFFFFF08, 0x00000000, 0x00000000)
    return false, val_norm
end

function NodeUI.DrawComponent_ScrewDecal(ctx, dl, comp, origin_x, origin_y, env, state, is_disabled, val_norm, disp_str, p_state, UI)
    local z = comp.z or 1.0
    local x, y = origin_x + (comp.x * z), origin_y + (comp.y * z)
    local rad = 5 * z
    local cx, cy = x + rad, y + rad
    
    reaper.ImGui_DrawList_AddCircleFilled(dl, cx, cy+(1*z), rad, 0xFFFFFF11)
    reaper.ImGui_DrawList_AddCircleFilled(dl, cx, cy, rad, 0x0A0A0AFF)
    reaper.ImGui_DrawList_AddLine(dl, cx-rad+(2*z), cy-rad+(2*z), cx+rad-(2*z), cy+rad-(2*z), 0x222222FF, 2.0 * z)
    return false, val_norm
end

function NodeUI.DrawComponent_VFDScreen(ctx, dl, comp, origin_x, origin_y, env, state, is_disabled, val_norm, disp_str, p_state, UI)
    local z = comp.z or 1.0
    local x, y = origin_x + (comp.x * z), origin_y + (comp.y * z)
    local w, h = (comp.w or 100) * z, (comp.h or 24) * z
    local col = env.palette and env.palette[comp.color_token] or 0x00E5FFFF
    
    reaper.ImGui_DrawList_AddRectFilled(dl, x, y, x+w, y+h, 0x0A0A0AFF, 4.0 * z)
    reaper.ImGui_DrawList_AddRect(dl, x, y, x+w, y+h, 0x222222FF, 4.0 * z, 0, 1.0 * z)
    
    local txt = (disp_str and disp_str ~= "") and disp_str or (comp.label or "88.8")
    local _, tw, th = pcall(reaper.ImGui_CalcTextSize, ctx, txt)
    tw, th = (tonumber(tw) or 0) * z, (tonumber(th) or 0) * z
    local tx, ty = x + (w/2) - (tw/2), y + (h/2) - (th/2)
    NodeUI.DrawCanvasText(ctx, dl, txt, tx, ty, col, env.act_a, z)
    return false, val_norm
end

function NodeUI.DrawComponent_Dropdown(ctx, dl, comp, origin_x, origin_y, env, state, is_disabled, val_norm, disp_str, p_state, UI)
    local z = comp.z or 1.0
    local x, y = origin_x + (comp.x * z), origin_y + (comp.y * z)
    local w, h = (comp.w or 120) * z, (comp.h or 24) * z
    local col = env.palette and env.palette[comp.color_token] or 0x00E5FFFF
    
    local current_val = (state and comp.param_key) and state[comp.param_key] or comp.default_val or 0
    local display_val = tostring(current_val)
    
    -- The Authentic Master Registry
    local auth_algos = {
        [0] = "ReaComp", [1] = "1175", [2] = "Bus SSL", [3] = "FairlyChild",
        [4] = "EventHorizon", [5] = "Peak Limiter", [6] = "Opto"
    }

    -- FORCE NATIVE INTEGER STATE
    if comp.param_key == "algo" then
        local num_val = 0 -- Default to ReaComp
        if type(current_val) == "number" then
            num_val = math.floor(current_val)
        elseif type(current_val) == "string" then
            if current_val == "VCA" then num_val = 2
            elseif current_val == "FET" then num_val = 1
            elseif current_val == "OPTO" then num_val = 6
            else num_val = tonumber(current_val) or 0
            end
        end
        
        -- Override the global state immediately to prevent Schema reversion
        if state and comp.param_key then
            state[comp.param_key] = num_val
        end
        
        display_val = auth_algos[num_val] or "ReaComp"
    end
    
    -- Frosted Selector Pill
    reaper.ImGui_DrawList_AddRectFilled(dl, x, y, x+w, y+h, 0x1A1A1EFF, 6.0 * z)
    reaper.ImGui_DrawList_AddRect(dl, x, y, x+w, y+h, 0x444444FF, 6.0 * z, 0, 1.0 * z)
    
    local txt = comp.label .. ": " .. display_val
    NodeUI.DrawCanvasText(ctx, dl, txt, x + (8*z), y + (h/2) - (7*z), col, env.act_a, z)
    
    reaper.ImGui_DrawList_AddTriangleFilled(dl, x+w-(15*z), y+(h/2)-(2*z), x+w-(5*z), y+(h/2)-(2*z), x+w-(10*z), y+(h/2)+(3*z), col & 0xFFFFFF00 | math.floor(0xFF * env.act_a))
    
    reaper.ImGui_SetCursorScreenPos(ctx, x, y)
    UI.Safe_InvisibleButton(ctx, comp.id.."_drop", w, h)
    local clicked = reaper.ImGui_IsItemClicked(ctx)
    local changed, new_norm = false, val_norm
    
    local popup_name = "popup_" .. comp.id
    if clicked and not is_disabled then
        reaper.ImGui_OpenPopup(ctx, popup_name)
    end
    
    if reaper.ImGui_BeginPopup(ctx, popup_name) then
        if comp.param_key == "algo" then
            for i = 0, 6 do
                if reaper.ImGui_MenuItem(ctx, auth_algos[i]) then
                    new_norm = i
                    changed = true
                end
            end
        else
            if reaper.ImGui_MenuItem(ctx, "Default") then
                new_norm = 0.0
                changed = true
            end
        end
        reaper.ImGui_EndPopup(ctx)
    end
    
    return changed, new_norm
end

function NodeUI.DrawComponent_Fader(ctx, dl, comp, origin_x, origin_y, env, state, is_disabled, val_norm, disp_str, p_state, UI)
    local z = comp.z or 1.0
    local x, y = origin_x + (comp.x * z), origin_y + (comp.y * z)
    local w, h = (comp.w or 40) * z, (comp.h or 120) * z
    local col = env.palette and env.palette[comp.color_token] or 0x00E5FFFF
    local cx = x + (w/2)
    
    reaper.ImGui_DrawList_AddRectFilled(dl, cx - (2*z), y, cx + (2*z), y + h, 0x000000FF, 2.0 * z)
    local fill_y = y + h - (p_state.disp_val * h)
    reaper.ImGui_DrawList_AddRectFilled(dl, cx - (1*z), fill_y, cx + (1*z), y + h, col & 0xFFFFFF00 | math.floor(0xFF * env.act_a), 2.0 * z)
    
    local cap_h = 20 * z
    local cap_y = y + h - (p_state.disp_val * h) - (cap_h/2)
    reaper.ImGui_DrawList_AddRectFilled(dl, x + (4*z), cap_y, x + w - (4*z), cap_y + cap_h, 0x222222FF, 4.0 * z)
    reaper.ImGui_DrawList_AddRect(dl, x + (4*z), cap_y, x + w - (4*z), cap_y + cap_h, col & 0xFFFFFF00 | math.floor(0xFF * env.act_a), 4.0 * z, 0, 1.0 * z)
    reaper.ImGui_DrawList_AddLine(dl, x + (8*z), cap_y + (cap_h/2), x + w - (8*z), cap_y + (cap_h/2), 0xFFFFFF88, 2.0 * z)
    
    reaper.ImGui_SetCursorScreenPos(ctx, x, y)
    UI.Safe_InvisibleButton(ctx, comp.id.."_fader", w, h)
    local changed, new_norm = false, val_norm
    if reaper.ImGui_IsItemActive(ctx) then
        local _, my = reaper.ImGui_GetMousePos(ctx)
        new_norm = math.max(0.0, math.min(1.0, 1.0 - ((my - y) / h)))
        changed = true
    end
    return changed, new_norm
end


function NodeUI.DrawNodeBlock(ctx, dl, n, n_idx, nodes, connections, env, UI, DSP, sc_x, sc_y, is_lane)
    local needs_save = false
    local is_sandbox = (n.algo == 999)

    -- Inject Beta Lab Fake Audio Math
    if is_sandbox then
        local t = reaper.time_precise()
        n["_dummy_audio"] = math.abs(math.sin(t * 3.0))
        n["_dummy_gr"] = 0.5 + 0.5 * math.cos(t * 1.5)
    end

    -- Resolve the linked track for external routing
    local route_track = n.lane_guid and NodeUI.Router.GetTrackByGUID(n.lane_guid) or nil

    if n.type == "COMPRESSOR" or n.type == "LFO" or n.type == "GAIN" or is_sandbox then
        local schema = NodeUI.GetSchema(n.algo)
        local active_schema = schema.components
        local active_palette = NodeUI.PALETTES[n.algo] or NodeUI.PALETTES[0]
        if not active_palette and schema.seed_hex and NodeUI.PaletteEngine then
            active_palette = NodeUI.PaletteEngine.Generate(schema.seed_hex)
            NodeUI.PALETTES[n.algo] = active_palette
        end
        if active_palette then env.palette = active_palette end

        -- Only engage eco mode if a node is ACTIVELY moving, not just clicked.
        local is_moving = env.eco_mode and (env.drag_node_id == n.id) and select(2, pcall(reaper.ImGui_IsMouseDragging, ctx, 0))
        if not is_moving then
            for _, comp in ipairs(active_schema) do
                if not (comp.is_hidden and comp.is_hidden(n)) then
                    local p_state = UI.physics_states[n.id .. comp.id]
                    if not p_state then
                        local real_val = n[comp.param_key] or comp.default_val or 0.5
                        local init_norm = comp.real_to_norm and comp.real_to_norm(real_val, n) or real_val
                        p_state = { ghost_norm = init_norm, disp_val = init_norm, vel = 0.0, flash = 0.0 }
                        UI.physics_states[n.id .. comp.id] = p_state
                    end

                    local is_disabled = comp.is_disabled and comp.is_disabled(n) or false
                    local real_val = n[comp.param_key] or comp.default_val
                    
                    -- Feed fake sandbox data if needed (mapped in Strike 2)
                    p_state.disp_val, p_state.vel = UI.SpringDamp(p_state.disp_val, p_state.ghost_norm, p_state.vel, 300.0, 20.0, env.app_dt)
                    p_state.flash = math.max(0.0, p_state.flash - (env.app_dt * 5.0))

                    local disp_str = comp.get_format and comp.get_format(n, (comp.norm_to_real and comp.norm_to_real(p_state.disp_val, n) or p_state.disp_val)) or tostring(real_val)
                    local changed, new_norm = false, p_state.ghost_norm

                    local cx = comp.x or 0
                    local cy = comp.y or 0
                    local crad = comp.radius
                    local cw = comp.w
                    local ch = comp.h

                    -- ==========================================================
                    -- PRO CODE: UNIFIED KINEMATIC ROUTER
                    -- ==========================================================
                    local z_factor = is_lane and (n.z or 1.0) or (UI.camera and UI.camera.zoom or 1.0)

                    local c_comp = { 
                        id = n.id..comp.id, 
                        z = z_factor, -- THIS INJECTS THE ZOOM MULTIPLIER TO THE COMPONENT
                        x = cx, 
                        y = cy, 
                        w = cw, 
                        h = ch, 
                        radius = crad, 
                        align = comp.align, 
                        color_token = comp.color_token, 
                        label = comp.label, 
                        default_val = comp.default_val, 
                        norm_to_real = comp.norm_to_real, 
                        real_to_norm = comp.real_to_norm, 
                        snap_array = comp.snap_array,
                        steps = comp.steps, 
                        axis = comp.axis, 
                        wrap_at = comp.wrap_at, 
                        btn_w = comp.btn_w, 
                        btn_h = comp.btn_h, 
                        labels = comp.labels
                    }

                    -- 1. Z-Override Fallback
                    local target_layer = comp.z_override
                    if not target_layer then
                        if comp.type == "Text" or comp.type == "BackPanel" then target_layer = 3
                        elseif comp.type == "Dropdown" or comp.type == "Tooltip" then target_layer = 5
                        else target_layer = 4 end
                    end
                    
                    -- 2. THE FILTER LOGIC (Early Exit)
                    if env.filter_layer and target_layer ~= env.filter_layer then
                        goto skip_component
                    end

                    -- 3. THE LOCK LOGIC (Disable Interaction)
                    local is_locked = (env.locked_layer and target_layer ~= env.locked_layer)
                    if is_locked then pcall(reaper.ImGui_BeginDisabled, ctx) end

                    pcall(reaper.ImGui_DrawList_ChannelsSetCurrent, dl or draw_list, target_layer)

                    -- ==========================================================
                    -- PRO CODE: UNIVERSAL COMPONENT CALLER
                    -- ==========================================================
                    local renderer = NodeUI.Registry[comp.type]
                    


                    if renderer then
                        -- One call rules them all. Zero hacks. Zero global math.
                        changed, new_norm = renderer(ctx, dl, c_comp, sc_x, sc_y, env, n, is_disabled, p_state.ghost_norm, disp_str, p_state, UI)
                    else
                        reaper.ShowConsoleMsg("OMM Error: Missing Component Renderer for Type -> " .. tostring(comp.type) .. "\n")
                    end
                    -- ==========================================================

                    if changed then 
                        p_state.ghost_norm = new_norm
                        
                        -- Param Key Binding (Backward compatible & normalized fallback)
                        if comp.param_key and comp.param_key ~= "unmapped" then 
                            if comp.norm_to_real then
                                local ok, r_val = pcall(comp.norm_to_real, new_norm, n)
                                n[comp.param_key] = ok and r_val or new_norm
                            else
                                n[comp.param_key] = new_norm
                            end
                        end
                        
                        -- MACRO MULTIPLEXING: Execute all connected routes with CORRECT argument order
                        if comp.routes and #comp.routes > 0 and NodeUI.Router then
                            NodeUI.Router.ExecuteRoutes(route_track, new_norm, comp.routes, n)
                        end
                        needs_save = true 
                    end

                    if is_locked then pcall(reaper.ImGui_EndDisabled, ctx) end
                    
                    ::skip_component::
                end
            end
        end
        if not is_sandbox then DSP.PushStateToMemory(n) end
        -- UNDO BLOCK: Close on mouse-up (entire drag = 1 undo point)
        if NodeUI.Router._undo_active and reaper.ImGui_IsMouseReleased(ctx, 0) then
            NodeUI.Router.EndInteraction()
        end
    end
    return needs_save
end

function NodeUI.DrawAllNodes(ctx, dl, nodes, connections, env, UI, DSP)
    local needs_save = false
    
    -- ==========================================================
    -- PRO CODE: KINEMATIC NODE CANVAS ZOOM & ATOMIC FONT
    -- ==========================================================
    local mw = select(2, pcall(reaper.ImGui_GetMouseWheel, ctx)) or 0
    local mx, my = select(2, pcall(reaper.ImGui_GetMousePos, ctx))
    mx, my = tonumber(mx) or 0, tonumber(my) or 0
    
    local ctrl_held = false
    if pcall(reaper.ImGui_Mod_Ctrl) then
        if select(2, pcall(reaper.ImGui_IsKeyDown, ctx, reaper.ImGui_Mod_Ctrl())) then ctrl_held = true end
    elseif pcall(reaper.ImGui_ModFlags_Ctrl) then
        local ok_mods, mods = pcall(reaper.ImGui_GetKeyMods, ctx)
        local ok_flag, ctrl_flag = pcall(reaper.ImGui_ModFlags_Ctrl)
        if ok_mods and ok_flag and (mods & ctrl_flag) ~= 0 then ctrl_held = true end
    end
    if not ctrl_held then
        local lk = (type(reaper.ImGui_Key_LeftCtrl) == "function") and reaper.ImGui_Key_LeftCtrl() or reaper.ImGui_Key_LeftCtrl
        local rk = (type(reaper.ImGui_Key_RightCtrl) == "function") and reaper.ImGui_Key_RightCtrl() or reaper.ImGui_Key_RightCtrl
        if lk and select(2, pcall(reaper.ImGui_IsKeyDown, ctx, lk)) then ctrl_held = true end
        if rk and select(2, pcall(reaper.ImGui_IsKeyDown, ctx, rk)) then ctrl_held = true end
    end

    local phys = UI.canvas_physics
    local dt = env.app_dt or 0.016
    
    -- PRO FIX: Native ImGui Hover (Protects the Canvas from the IDE)
    local is_hovered = select(2, pcall(reaper.ImGui_IsWindowHovered, ctx))

    if is_hovered and ctrl_held and mw ~= 0 then
        phys.anchor_world_x = (mx - env.p_min_x - UI.camera.pan_x) / phys.current_scale
        phys.anchor_world_y = (my - env.p_min_y - UI.camera.pan_y) / phys.current_scale
        phys.anchor_mx = mx
        phys.anchor_my = my
        
        -- PRO FIX: Directional Threshold Stepper
        local steps = {0.50, 0.75, 0.90, 1.00, 1.10, 1.25, 1.50, 1.75, 2.00}
        local current_z = phys.target_scale
        local eps = 0.001
        
        if mw > 0 then
            for i = 1, #steps do
                if steps[i] > current_z + eps then
                    phys.target_scale = steps[i]
                    break
                end
            end
        elseif mw < 0 then
            for i = #steps, 1, -1 do
                if steps[i] < current_z - eps then
                    phys.target_scale = steps[i]
                    break
                end
            end
        end
        
        phys.target_scale = math.max(phys.min_scale, math.min(phys.max_scale, phys.target_scale))
        phys.is_zooming = true
    end

    if math.abs(phys.current_scale - phys.target_scale) > 0.0001 then
        phys.current_scale = phys.current_scale + ((phys.target_scale - phys.current_scale) * (dt * phys.lerp_speed))
        if phys.is_zooming then
            UI.camera.pan_x = (phys.anchor_mx - env.p_min_x) - (phys.anchor_world_x * phys.current_scale)
            UI.camera.pan_y = (phys.anchor_my - env.p_min_y) - (phys.anchor_world_y * phys.current_scale)
        end
    else
        phys.current_scale = phys.target_scale
        phys.is_zooming = false
    end
    UI.camera.zoom = phys.current_scale


    -- ==========================================================

    for i = #nodes, 1, -1 do 
        local n = nodes[i]
        local z = UI.camera and UI.camera.zoom or 1.0
        local px = UI.camera and UI.camera.pan_x or 0.0
        local py = UI.camera and UI.camera.pan_y or 0.0

        -- Apply transform to the coordinates and dimensions
        local sc_x = math.floor(env.p_min_x + ((n.x + px) * z))
        local sc_y = math.floor(env.p_min_y + ((n.y + py) * z))
        local n_w = math.floor((n.w or 380) * z)
        local n_h = math.floor((n.h or 220) * z)

        n.algo = n.algo or 0
        n.show_picker = n.show_picker or false

        if not env.eco_mode then 
            pcall(reaper.ImGui_DrawList_ChannelsSplit, dl, 6)
            pcall(reaper.ImGui_DrawList_ChannelsSetCurrent, dl, 0) -- CRITICAL: Force Chassis to Layer 0

            pcall(reaper.ImGui_DrawList_AddRectFilled, dl, sc_x, sc_y, sc_x + n_w, sc_y + n_h, env.COLOR_NODE_BG, 8.0)
            pcall(reaper.ImGui_DrawList_AddRect, dl, sc_x, sc_y, sc_x + n_w, sc_y + n_h, env.COLOR_BORDER, 8.0, 0, 2.0)
        end

        pcall(reaper.ImGui_DrawList_ChannelsSetCurrent, dl, 4) -- Interactive Layer

        -- The Header
        local header_txt = "[ CIRCUIT: " .. (NodeUI.ALGO_NAMES[n.algo] or "UNKNOWN") .. " ]"
        local _, hw = pcall(reaper.ImGui_CalcTextSize, ctx, header_txt)
        hw = (tonumber(hw) or 0) * z
        local hx, hy = sc_x + (n_w/2) - (hw/2), sc_y + 8*z
        

        
        local h_hover = false
        if env.edit_mode then
            local ok_m, mx, my = pcall(reaper.ImGui_GetMousePos, ctx)
            if ok_m then
                mx, my = tonumber(mx) or 0, tonumber(my) or 0
                if mx >= sc_x and mx <= sc_x + n_w and my >= sc_y and my <= sc_y + 24*z then
                    h_hover = true
                end
            end
        end
        if h_hover and select(2, pcall(reaper.ImGui_IsMouseClicked, ctx, 0)) then n.show_picker = not n.show_picker end
        
        local h_col = h_hover and 0x00A5FFFF or 0x888888FF
        NodeUI.DrawCanvasText(ctx, dl, header_txt, hx, hy, h_col, env.act_a, z)
        pcall(reaper.ImGui_DrawList_AddLine, dl, sc_x, sc_y + 26*z, sc_x + n_w, sc_y + 26*z, env.COLOR_BORDER, 1.0)

        if n.show_picker then
            pcall(reaper.ImGui_DrawList_AddRectFilled, dl, sc_x, sc_y + 27*z, sc_x + n_w, sc_y + n_h, 0x0A0A0DF0, 8.0)
            local bx, by = sc_x + 20*z, sc_y + 40*z
            
            -- Including 999 Sandbox in live lane picker
            local valid_algos = {0,1,2,3,4,5,6,999}
            for _, a_idx in ipairs(valid_algos) do
                pcall(reaper.ImGui_SetCursorScreenPos, ctx, bx, by)
                local b_col = (n.algo == a_idx) and 0x005F73FF or 0x1C1C1EFF
                pcall(reaper.ImGui_DrawList_AddRectFilled, dl, bx, by, bx + 120*z, by + 30*z, b_col, 4.0)
                pcall(reaper.ImGui_DrawList_AddRect, dl, bx, by, bx + 120*z, by + 30*z, 0x333333FF, 4.0, 0, 1.0)
                
                local a_txt = NodeUI.ALGO_NAMES[a_idx]
                local _, aw = pcall(reaper.ImGui_CalcTextSize, ctx, a_txt)
                aw = (tonumber(aw) or 0) * z
                NodeUI.DrawCanvasText(ctx, dl, a_txt, bx + 60*z - (aw/2), by + 8*z, 0xE5E5EAFF, 1.0, z)
                
                UI.Safe_InvisibleButton(ctx, "pick_"..n.id.."_"..a_idx, 120*z, 30*z)
                if select(2, pcall(reaper.ImGui_IsItemHovered, ctx)) then
                    pcall(reaper.ImGui_DrawList_AddRect, dl, bx, by, bx + 120*z, by + 30*z, 0x00A5FFFF, 4.0, 0, 1.0)
                    if select(2, pcall(reaper.ImGui_IsMouseClicked, ctx, 0)) then n.algo = a_idx; n.show_picker = false; needs_save = true end
                end
                bx = bx + 130*z
                if bx > sc_x + n_w - 120*z then bx = sc_x + 20*z; by = by + 40*z end
            end
        else
            -- Call isolated block drawer for inside lane
            local chg = NodeUI.DrawNodeBlock(ctx, dl, n, i, nodes, connections, env, UI, DSP, sc_x, sc_y, false)
            if chg then needs_save = true end

            local o_x, o_y, o_w, o_h = sc_x + (60*z), sc_y + (40*z), 260*z, 150*z
            local scr_x, scr_w = o_x + (10*z), o_w - (20*z)
            local g_idx = 100000 + (n.gmem_slot or 0) * 2048
            local head_ptr = reaper.gmem_read(g_idx + 18) or 0
            local pts_to_draw = math.floor(scr_w)
            
            for _, g_db in ipairs(n.mode_exp and {12, 0, -12, -24, -48} or {0, -12, -24, -48}) do
                local g_y = o_y + o_h - (ScaleDB(g_db, n.mode_exp) * o_h)
                if g_y >= o_y and g_y <= o_y + o_h then
                    pcall(reaper.ImGui_DrawList_AddLine, dl, scr_x, g_y, scr_x + scr_w, g_y, 0xFFFFFF00 | ((g_db == 0) and 0x33 or 0x15), 1.0)
                end
            end

            local cur_bin_gr, bin_min_gr, bin_max_exp, bin_px_gr, bin_max_in = -1, 1.0, 1.0, 0.0, 0.0
            pcall(reaper.ImGui_DrawList_PathClear, dl)
            for j = pts_to_draw - 1, 0, -1 do
                local read_idx = (head_ptr - j) % 1024
                if read_idx < 0 then read_idx = read_idx + 1024 end
                
                local raw_val, gr_amp
                if n.algo == 999 then -- Sandbox Graph Physics
                    local t = reaper.time_precise()
                    raw_val = math.abs(math.sin(t * 2.0 - (j * 0.05)))
                    gr_amp = 0.5 + 0.5 * math.cos(t * 1.5 - (j * 0.05))
                else
                    raw_val = reaper.gmem_read(g_idx + read_idx) or 0
                    gr_amp = reaper.gmem_read(g_idx + 1024 + read_idx) or 1.0
                end
                
                local px = scr_x + scr_w - ((j - 1.0) * (scr_w / (pts_to_draw - 1)))
                local px_int = math.floor(px)
                if px_int > cur_bin_gr then
                    if cur_bin_gr ~= -1 then
                        if n.mode_exp and bin_max_exp > 1.01 then
                            local py_bot = o_y + o_h - (ScaleDB(bin_max_in <= 0.00001 and -60.0 or 20 * math.log(bin_max_in, 10), n.mode_exp) * o_h)
                            local py_top = o_y + o_h - (ScaleDB(20 * math.log(bin_max_in * bin_max_exp, 10), n.mode_exp) * o_h)
                            pcall(reaper.ImGui_DrawList_AddRectFilled, dl, bin_px_gr - 0.25, py_top, bin_px_gr + 0.25, py_bot, 0x00A5FFFF & 0xFFFFFF00 | math.floor(0x88 * env.act_a))
                        elseif not n.mode_exp and bin_min_gr < 0.99 then
                            local py = o_y + math.min(1.0, (-20 * math.log(math.max(0.00001, bin_min_gr), 10)) / 30.0) * (o_h * 0.75)
                            pcall(reaper.ImGui_DrawList_PathLineTo, dl, bin_px_gr - 0.25, py); pcall(reaper.ImGui_DrawList_PathLineTo, dl, bin_px_gr + 0.25, py)
                        end
                    end
                    cur_bin_gr = px_int; bin_min_gr = gr_amp; bin_max_exp = gr_amp; bin_px_gr = px; bin_max_in = raw_val
                else
                    if gr_amp < bin_min_gr then bin_min_gr = gr_amp end
                    if gr_amp > bin_max_exp then bin_max_exp = gr_amp end
                    if raw_val > bin_max_in then bin_max_in = raw_val end
                end
            end
            if not n.mode_exp then pcall(reaper.ImGui_DrawList_PathStroke, dl, 0xFF6B35FF & 0xFFFFFF00 | math.floor(0xFF * env.act_a), 0, 2.0) end
        end

        pcall(reaper.ImGui_DrawList_ChannelsMerge, dl)
    end
    
    -- ==========================================================
    -- PRO CODE: FINAL ATOMIC CLEANUP
    -- ==========================================================

    
    return needs_save, nil
end

-- PRO CODE: The Universal Component Registry
NodeUI.Registry = {
    ["AuraKnob"]     = NodeUI.DrawComponent_AuraKnob,
    ["InlineDrag"]   = NodeUI.DrawComponent_InlineDrag,
    ["PeakMeter"]    = NodeUI.DrawComponent_PeakMeter,
    ["VuMeter"]      = NodeUI.DrawComponent_VuMeter,
    ["TogglePill"]   = NodeUI.DrawComponent_TogglePill,
    ["ToggleLever"]  = NodeUI.DrawComponent_ToggleLever,
    ["BackPanel"]    = NodeUI.DrawComponent_BackPanel,
    ["ScrewDecal"]   = NodeUI.DrawComponent_ScrewDecal,
    ["VFDScreen"]    = NodeUI.DrawComponent_VFDScreen,
    ["Dropdown"]     = NodeUI.DrawComponent_Dropdown,
    ["Fader"]        = NodeUI.DrawComponent_Fader,
    ["RadioStrip"]   = NodeUI.DrawComponent_RadioStrip
}

return NodeUI