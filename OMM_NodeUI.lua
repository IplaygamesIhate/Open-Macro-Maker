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
function NodeUI.DrawComponent_RadioStrip(ctx, dl, comp, env, state, is_disabled, val_norm, disp_str, p_state, UI)
    local x = env.p_min_x + env.scroll_x + comp.x
    local y = env.p_min_y + env.scroll_y + comp.y
    local steps = comp.steps or 6
    local base_w = comp.btn_w or 32
    local base_h = comp.btn_h or 24
    
    -- The Housing: A single continuous well
    local total_w = (base_w * steps) + 2 -- +2 for the 1px end caps
    local r = 4.0 -- Outer radius
    
    -- 1. Draw The Milled Well (The continuous trench)
    reaper.ImGui_DrawList_AddRectFilled(dl, x, y, x + total_w, y + base_h + 2, 0x111112FF, r)
    reaper.ImGui_DrawList_AddRect(dl, x, y, x + total_w, y + base_h + 2, 0x00000088, r, 0, 1.0) -- Inner Shadow
    
    local current_val = (state and comp.param_key) and state[comp.param_key] or comp.default_val or 0
    local changed = false
    local new_norm = val_norm
    
    -- Interaction Loop
    for i = 1, steps do
        local bx = x + 1 + ((i - 1) * base_w)
        local by = y + 1
        
        -- Logic: Is this button the currently selected value?
        local step_norm = (i - 1) / (steps - 1)
        local is_active = (math.abs(val_norm - step_norm) < 0.05)
        
        -- Physics State (for the click animation)
        local id = comp.id .. "_seg_" .. i
        UI.physics_states = UI.physics_states or {}
        UI.physics_states[id] = UI.physics_states[id] or { z = 0, v = 0 }
        
        -- Hidden Hitbox
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
        local travel = anim_z * 1.5 -- Max 1.5px travel down
        
        -- Colors (Pulls from Palette if active, otherwise flat dark grey)
        local seed_hex = env.palette[comp.color_token] or 0xFF6B35FF
        local tokens = BuildClayTokens(seed_hex, is_active, env.act_a)
        local base_col = is_active and tokens.surface or 0x333333FF
        
        -- 2. Draw The Button Cap (translates down when pressed)
        local cap_y = by + travel
        local cap_h = base_h - travel
        
        -- Segment Radius Logic (Only round the outer edges)
        local flag = 0
        if i == 1 then flag = reaper.ImGui_DrawFlags_RoundCornersLeft()
        elseif i == steps then flag = reaper.ImGui_DrawFlags_RoundCornersRight()
        else flag = reaper.ImGui_DrawFlags_RoundCornersNone() end
        
        -- The "Fake Bevel Shadow" (Dark bottom edge before the button is drawn)
        if not is_held then
            reaper.ImGui_DrawList_AddRectFilled(dl, bx, by + 2, bx + base_w, by + base_h, 0x00000099, r, flag)
        end
        
        -- The Matte Surface
        reaper.ImGui_DrawList_AddRectFilled(dl, bx, cap_y, bx + base_w, cap_y + cap_h, base_col, r, flag)
        
        -- The Directional Highlight (Top edge)
        if not is_held then
            local hl_col = is_active and tokens.highlight or 0x555555FF
            reaper.ImGui_DrawList_AddLine(dl, bx + 1, cap_y, bx + base_w - 1, cap_y, hl_col, 1.0)
        end
        
        -- Hairline Divider (The 1px gap between buttons)
        if i < steps then
            reaper.ImGui_DrawList_AddLine(dl, bx + base_w, cap_y + 2, bx + base_w, cap_y + cap_h - 2, 0x1A1A1CFF, 1.0)
            reaper.ImGui_DrawList_AddLine(dl, bx + base_w + 1, cap_y + 2, bx + base_w + 1, cap_y + cap_h - 2, 0x444444FF, 1.0)
        end
        
        -- 3. Typography
        local label = comp.labels and comp.labels[i] or tostring(i)
        local _, tw, th = pcall(reaper.ImGui_CalcTextSize, ctx, label)
        tw, th = tonumber(tw) or 0, tonumber(th) or 0
        local tx = bx + (base_w/2) - (tw/2)
        local ty = cap_y + (cap_h/2) - (th/2)
        
        local text_col = is_active and tokens.text or 0x999999FF
        pcall(reaper.ImGui_DrawList_AddText, dl, tx, ty, text_col, label)
        
        -- Logic Commit
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
                -- GLOBAL GRID ENFORCER (Prevents jumping/flickering between modules)
                schema_data.grid_cols = 12
                schema_data.grid_rows = 6

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
    -- If no theme exists, clear it to prevent ghost layouts
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

function NodeUI.DrawComponent_PeakMeter(ctx, dl, comp, env, state, is_disabled, val_norm, disp_str, p_state, UI)
    local x, y = env.p_min_x + env.scroll_x + comp.x, env.p_min_y + env.scroll_y + comp.y
    local w, h = comp.w or 20, comp.h or 100
    -- Dark Frosted Glass Trough
    reaper.ImGui_DrawList_AddRectFilled(dl, x, y, x+w, y+h, 0x050508FF, 8.0)
    reaper.ImGui_DrawList_AddRect(dl, x, y, x+w, y+h, 0x1A1A1FFF, 8.0, 0, 1.5)
    
    -- The Liquid Math
    local fill_h = h * p_state.disp_val
    if fill_h > 2 then
        local c_fill = UI.LerpColor(0x00E5FFFF, 0xFF3333FF, p_state.disp_val)
        reaper.ImGui_DrawList_AddRectFilled(dl, x+2, y + h - fill_h + 2, x+w-2, y+h-2, c_fill, 6.0)
        -- Intense Overdrive Bloom
        if p_state.disp_val > 0.8 then
            reaper.ImGui_DrawList_AddCircleFilled(dl, x+w/2, y + h - fill_h, w, c_fill & 0xFFFFFF00 | math.floor(0x44 * env.act_a))
        end
    end
    return false, val_norm
end

function NodeUI.DrawComponent_VuMeter(ctx, dl, comp, env, state, is_disabled, val_norm, disp_str, p_state, UI)
    local x, y = env.p_min_x + env.scroll_x + comp.x, env.p_min_y + env.scroll_y + comp.y
    local w, h = comp.w or 100, comp.h or 80
    -- Neo-Analog Faceplate
    reaper.ImGui_DrawList_AddRectFilled(dl, x, y, x+w, y+h, 0x161619FF, 6.0)
    reaper.ImGui_DrawList_AddRect(dl, x, y, x+w, y+h, 0x2A2A33FF, 6.0, 0, 1.0)
    
    local pivot_x, pivot_y = x + w/2, y + h * 1.15
    local radius = h * 0.9
    local a_min, a_max = math.pi * 1.25, math.pi * 1.75
    
    -- Crisp Modern Arc
    reaper.ImGui_DrawList_PathArcTo(dl, pivot_x, pivot_y, radius, a_min, a_max, 0)
    reaper.ImGui_DrawList_PathStroke(dl, 0x8E8E93FF, 0, 2.0)
    
    -- Tick Marks
    for i = 0, 5 do
        local t_a = a_min + (a_max - a_min) * (i / 5.0)
        local tx1, ty1 = pivot_x + math.cos(t_a) * radius, pivot_y + math.sin(t_a) * radius
        local tx2, ty2 = pivot_x + math.cos(t_a) * (radius - 8), pivot_y + math.sin(t_a) * (radius - 8)
        reaper.ImGui_DrawList_AddLine(dl, tx1, ty1, tx2, ty2, 0x8E8E93FF, 1.5)
    end
    
    -- Emissive Laser Needle
    local a_val = a_min + (a_max - a_min) * p_state.disp_val
    local n_x, n_y = pivot_x + math.cos(a_val) * (radius + 4), pivot_y + math.sin(a_val) * (radius + 4)
    reaper.ImGui_DrawList_AddLine(dl, pivot_x, pivot_y, n_x, n_y, 0xFF3333FF, 2.0)
    
    -- Overdrive Shadow
    if p_state.disp_val > 0.8 then reaper.ImGui_DrawList_AddCircleFilled(dl, n_x, n_y, 12, 0xFF333333) end
    return false, val_norm
end

function NodeUI.DrawComponent_TogglePill(ctx, dl, comp, env, state, is_disabled, val_norm, disp_str, p_state, UI)
    local x, y = env.p_min_x + env.scroll_x + comp.x, env.p_min_y + env.scroll_y + comp.y
    local w, h = comp.w or 50, comp.h or 24
    local r = math.min(w,h)/2
    local is_active = val_norm > 0.5
    
    reaper.ImGui_SetCursorScreenPos(ctx, x, y)
    UI.Safe_InvisibleButton(ctx, comp.id, w, h)
    local changed, new_norm = false, val_norm
    if reaper.ImGui_IsItemClicked(ctx) then new_norm = is_active and 0.0 or 1.0; changed = true end

    p_state.ghost_norm = new_norm
    local c_bg = is_active and 0x00E5FFFF or 0x2A2A33FF
    reaper.ImGui_DrawList_AddRectFilled(dl, x, y, x+w, y+h, c_bg, r)
    
    local t_size = r * 1.5
    local t_x, t_y = x + 3, y + h/2 - t_size/2
    if w > h then t_x = x + 3 + (w - t_size - 6) * p_state.disp_val
    else t_x = x + w/2 - t_size/2; t_y = y + 3 + (h - t_size - 6) * (1.0 - p_state.disp_val) end
    
    reaper.ImGui_DrawList_AddCircleFilled(dl, t_x + t_size/2, t_y + t_size/2, t_size/2, 0xFFFFFFFF)
    return changed, new_norm
end

function NodeUI.DrawComponent_ToggleLever(ctx, dl, comp, env, state, is_disabled, val_norm, disp_str, p_state, UI)
    local x, y = env.p_min_x + env.scroll_x + comp.x, env.p_min_y + env.scroll_y + comp.y
    local w, h = comp.w or 24, comp.h or 50
    local is_active = val_norm > 0.5
    
    reaper.ImGui_SetCursorScreenPos(ctx, x, y)
    UI.Safe_InvisibleButton(ctx, comp.id, w, h)
    local changed, new_norm = false, val_norm
    if reaper.ImGui_IsItemClicked(ctx) then new_norm = is_active and 0.0 or 1.0; changed = true end

    p_state.ghost_norm = new_norm
    -- Metallic Base Plate
    reaper.ImGui_DrawList_AddRectFilled(dl, x, y, x+w, y+h, 0x1A1A1CFF, 4.0)
    reaper.ImGui_DrawList_AddRect(dl, x, y, x+w, y+h, 0x08080AFF, 4.0, 0, 2.0)
    
    -- Physical Lever Math
    local l_y = y + 4 + (h - 24 - 8) * (1.0 - p_state.disp_val)
    reaper.ImGui_DrawList_AddRectFilled(dl, x+4, l_y+4, x+w-4, l_y+24+4, 0x00000088, 2.0) -- Drop Shadow
    reaper.ImGui_DrawList_AddRectFilled(dl, x+2, l_y, x+w-2, l_y+24, 0xDDDDDDFF, 2.0) -- Silver Lever
    reaper.ImGui_DrawList_AddLine(dl, x+4, l_y+12, x+w-4, l_y+12, 0x888888FF, 2.0) -- Texture grip
    
    return changed, new_norm
end

-- ==========================================
-- EXTRACTED LEGACY: FADER (VCA Slider with dB Math)
-- Legacy Location: GAIN module DrawGainModule (~line 2101)
-- ==========================================
-- ==========================================
-- EXTRACTED LEGACY COMPONENT RENDERERS
-- ==========================================

function NodeUI.DrawComponent_BackPanel(ctx, dl, comp, env, state, is_disabled, val_norm, disp_str, p_state, UI)
    local x, y = env.p_min_x + env.scroll_x + comp.x, env.p_min_y + env.scroll_y + comp.y
    local w, h = comp.w or 200, comp.h or 100
    local col = env.palette and env.palette[comp.color_token] or 0x1C1C1EFF
    
    -- Skeuomorphic Chassis: Rounded top corners, sharp bottom, 1px highlight
    reaper.ImGui_DrawList_AddRectFilled(dl, x, y, x+w, y+h, col, 12.0, reaper.ImGui_DrawFlags_RoundCornersTop())
    reaper.ImGui_DrawList_AddLine(dl, x+12, y, x+w-12, y, 0xFFFFFF22, 2.0)
    reaper.ImGui_DrawList_AddRectFilledMultiColor(dl, x, y, x+w, y+20, 0xFFFFFF08, 0xFFFFFF08, 0x00000000, 0x00000000)
    return false, val_norm
end

function NodeUI.DrawComponent_ScrewDecal(ctx, dl, comp, env, state, is_disabled, val_norm, disp_str, p_state, UI)
    local x, y = env.p_min_x + env.scroll_x + comp.x, env.p_min_y + env.scroll_y + comp.y
    local rad = 5
    local cx, cy = x + rad, y + rad
    
    -- 3D Recessed Illusion
    reaper.ImGui_DrawList_AddCircleFilled(dl, cx, cy+1, rad, 0xFFFFFF11)
    reaper.ImGui_DrawList_AddCircleFilled(dl, cx, cy, rad, 0x0A0A0AFF)
    reaper.ImGui_DrawList_AddLine(dl, cx-rad+2, cy-rad+2, cx+rad-2, cy+rad-2, 0x222222FF, 2.0)
    return false, val_norm
end

function NodeUI.DrawComponent_VFDScreen(ctx, dl, comp, env, state, is_disabled, val_norm, disp_str, p_state, UI)
    local x, y = env.p_min_x + env.scroll_x + comp.x, env.p_min_y + env.scroll_y + comp.y
    local w, h = comp.w or 100, comp.h or 24
    local col = env.palette and env.palette[comp.color_token] or 0x00E5FFFF
    
    -- Inset Glass Panel
    reaper.ImGui_DrawList_AddRectFilled(dl, x, y, x+w, y+h, 0x0A0A0AFF, 4.0)
    reaper.ImGui_DrawList_AddRect(dl, x, y, x+w, y+h, 0x222222FF, 4.0, 0, 1.0)
    
    -- Vintage Blooming Text
    local txt = (disp_str and disp_str ~= "") and disp_str or (comp.label or "88.8")
    local tw, th = reaper.ImGui_CalcTextSize(ctx, txt)
    local tx, ty = x + (w/2) - (tw/2), y + (h/2) - (th/2)
    reaper.ImGui_DrawList_AddText(dl, tx, ty, col & 0xFFFFFF00 | math.floor(0x44 * env.act_a), txt)
    reaper.ImGui_DrawList_AddText(dl, tx, ty, col & 0xFFFFFF00 | math.floor(0xFF * env.act_a), txt)
    return false, val_norm
end

function NodeUI.DrawComponent_Dropdown(ctx, dl, comp, env, state, is_disabled, val_norm, disp_str, p_state, UI)
    local x, y = env.p_min_x + env.scroll_x + comp.x, env.p_min_y + env.scroll_y + comp.y
    local w, h = comp.w or 120, comp.h or 24
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
    reaper.ImGui_DrawList_AddRectFilled(dl, x, y, x+w, y+h, 0x1A1A1EFF, 6.0)
    reaper.ImGui_DrawList_AddRect(dl, x, y, x+w, y+h, 0x444444FF, 6.0, 0, 1.0)
    
    local txt = comp.label .. ": " .. display_val
    reaper.ImGui_DrawList_AddText(dl, x + 8, y + (h/2) - 7, col & 0xFFFFFF00 | math.floor(0xFF * env.act_a), txt)
    reaper.ImGui_DrawList_AddTriangleFilled(dl, x+w-15, y+(h/2)-2, x+w-5, y+(h/2)-2, x+w-10, y+(h/2)+3, col & 0xFFFFFF00 | math.floor(0xFF * env.act_a))
    
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

function NodeUI.DrawComponent_Fader(ctx, dl, comp, env, state, is_disabled, val_norm, disp_str, p_state, UI)
    local x, y = env.p_min_x + env.scroll_x + comp.x, env.p_min_y + env.scroll_y + comp.y
    local w, h = comp.w or 40, comp.h or 120
    local col = env.palette and env.palette[comp.color_token] or 0x00E5FFFF
    local cx = x + (w/2)
    
    -- Laser Track & Emissive Fill
    reaper.ImGui_DrawList_AddRectFilled(dl, cx - 2, y, cx + 2, y + h, 0x000000FF, 2.0)
    local fill_y = y + h - (p_state.disp_val * h)
    reaper.ImGui_DrawList_AddRectFilled(dl, cx - 1, fill_y, cx + 1, y + h, col & 0xFFFFFF00 | math.floor(0xFF * env.act_a), 2.0)
    
    -- Console Cap
    local cap_h = 20
    local cap_y = y + h - (p_state.disp_val * h) - (cap_h/2)
    reaper.ImGui_DrawList_AddRectFilled(dl, x + 4, cap_y, x + w - 4, cap_y + cap_h, 0x222222FF, 4.0)
    reaper.ImGui_DrawList_AddRect(dl, x + 4, cap_y, x + w - 4, cap_y + cap_h, col & 0xFFFFFF00 | math.floor(0xFF * env.act_a), 4.0, 0, 1.0)
    reaper.ImGui_DrawList_AddLine(dl, x + 8, cap_y + (cap_h/2), x + w - 8, cap_y + (cap_h/2), 0xFFFFFF88, 2.0)
    
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

                    local cx = is_lane and ((comp.x or 0) * 0.8) or comp.x
                    local cy = is_lane and ((comp.y or 0) * 0.8) or comp.y
                    local crad = comp.radius and (is_lane and (comp.radius * 0.8) or comp.radius) or nil
                    local cw = comp.w and (is_lane and (comp.w * 0.8) or comp.w) or nil
                    local ch = comp.h and (is_lane and (comp.h * 0.8) or comp.h) or nil

                    -- CRITICAL FIX: Subtract absolute panning offsets to prevent double-scroll detachment
                    local c_comp = { 
                        id = n.id..comp.id, 
                        x = sc_x + cx - ((env.p_min_x or 0) + (env.scroll_x or 0)), 
                        y = sc_y + cy - ((env.p_min_y or 0) + (env.scroll_y or 0)), 
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

                    if comp.type == "AuraKnob" then
                        changed, new_norm = UI.DrawComponent_AuraKnob(ctx, dl, c_comp, env, n, is_disabled, p_state.ghost_norm, disp_str, p_state)
                    elseif comp.type == "InlineDrag" then
                        changed, new_norm = UI.DrawComponent_InlineDrag(ctx, dl, c_comp, env, n, is_disabled, p_state.ghost_norm, disp_str, p_state)
                    elseif comp.type == "PeakMeter" then
                        changed, new_norm = UI.DrawComponent_PeakMeter(ctx, dl, c_comp, env, n, is_disabled, p_state.ghost_norm, disp_str, p_state)
                    elseif comp.type == "VuMeter" then
                        changed, new_norm = UI.DrawComponent_VuMeter(ctx, dl, c_comp, env, n, is_disabled, p_state.ghost_norm, disp_str, p_state)
                    elseif comp.type == "TogglePill" then
                        changed, new_norm = UI.DrawComponent_TogglePill(ctx, dl, c_comp, env, n, is_disabled, p_state.ghost_norm, disp_str, p_state)
                    elseif comp.type == "ToggleLever" then
                        changed, new_norm = UI.DrawComponent_ToggleLever(ctx, dl, c_comp, env, n, is_disabled, p_state.ghost_norm, disp_str, p_state)
                    elseif comp.type == "Fader" then
                        changed, new_norm = NodeUI.DrawComponent_Fader(ctx, dl, c_comp, env, n, is_disabled, p_state.ghost_norm, disp_str, p_state, UI)
                    elseif comp.type == "VFDScreen" then
                        changed, new_norm = NodeUI.DrawComponent_VFDScreen(ctx, dl, c_comp, env, n, is_disabled, p_state.ghost_norm, disp_str, p_state, UI)
                    elseif comp.type == "Dropdown" then
                        changed, new_norm = NodeUI.DrawComponent_Dropdown(ctx, dl, c_comp, env, n, is_disabled, p_state.ghost_norm, disp_str, p_state, UI)
                    elseif comp.type == "BackPanel" then
                        changed, new_norm = NodeUI.DrawComponent_BackPanel(ctx, dl, c_comp, env, n, is_disabled, p_state.ghost_norm, disp_str, p_state, UI)
                    elseif comp.type == "ScrewDecal" then
                        changed, new_norm = NodeUI.DrawComponent_ScrewDecal(ctx, dl, c_comp, env, n, is_disabled, p_state.ghost_norm, disp_str, p_state, UI)
                    elseif comp.type == "RadioStrip" then
                        changed, new_norm = NodeUI.DrawComponent_RadioStrip(ctx, dl, c_comp, env, n, is_disabled, p_state.ghost_norm, disp_str, p_state, UI)
                    end

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
    for i = #nodes, 1, -1 do 
        local n = nodes[i]
        local sc_x, sc_y = math.floor(env.p_min_x + env.scroll_x + n.x), math.floor(env.p_min_y + env.scroll_y + n.y)

        n.algo = n.algo or 0
        n.show_picker = n.show_picker or false

        if not env.eco_mode then 
            pcall(reaper.ImGui_DrawList_ChannelsSplit, dl, 6)
            pcall(reaper.ImGui_DrawList_ChannelsSetCurrent, dl, 0) -- CRITICAL: Force Chassis to Layer 0

            pcall(reaper.ImGui_DrawList_AddRectFilled, dl, sc_x, sc_y, sc_x + n.w, sc_y + n.h, env.COLOR_NODE_BG, 8.0)
            pcall(reaper.ImGui_DrawList_AddRect, dl, sc_x, sc_y, sc_x + n.w, sc_y + n.h, env.COLOR_BORDER, 8.0, 0, 2.0)
        end

        pcall(reaper.ImGui_DrawList_ChannelsSetCurrent, dl, 4) -- Interactive Layer

        local header_txt = "[ CIRCUIT: " .. (NodeUI.ALGO_NAMES[n.algo] or "UNKNOWN") .. " ]"
        local _, hw = pcall(reaper.ImGui_CalcTextSize, ctx, header_txt)
        local hx, hy = sc_x + (n.w/2) - ((tonumber(hw) or 0)/2), sc_y + 8
        
        -- PLAY MODE LOCK: Only draw the drag-hitbox if Edit Mode is active
        if env.edit_mode then
            pcall(reaper.ImGui_SetCursorScreenPos, ctx, sc_x, sc_y)
            UI.Safe_InvisibleButton(ctx, "chassis_hitbox_"..n.id, n.w or 480, n.h or 240)
        end
        
        local h_hover = false
        if env.edit_mode then
            local ok_m, mx, my = pcall(reaper.ImGui_GetMousePos, ctx)
            if ok_m then
                mx, my = tonumber(mx) or 0, tonumber(my) or 0
                if mx >= sc_x and mx <= sc_x + n.w and my >= sc_y and my <= sc_y + 24 then
                    h_hover = true
                end
            end
        end
        if h_hover and select(2, pcall(reaper.ImGui_IsMouseClicked, ctx, 0)) then n.show_picker = not n.show_picker end
        
        local h_col = h_hover and 0x00A5FFFF or 0x888888FF
        pcall(reaper.ImGui_DrawList_AddText, dl, hx, hy, h_col & 0xFFFFFF00 | math.floor(0xFF * env.act_a), header_txt)
        pcall(reaper.ImGui_DrawList_AddLine, dl, sc_x, sc_y + 26, sc_x + n.w, sc_y + 26, env.COLOR_BORDER, 1.0)

        if n.show_picker then
            pcall(reaper.ImGui_DrawList_AddRectFilled, dl, sc_x, sc_y + 27, sc_x + n.w, sc_y + n.h, 0x0A0A0DF0, 8.0)
            local bx, by = sc_x + 20, sc_y + 40
            
            -- Including 999 Sandbox in live lane picker
            local valid_algos = {0,1,2,3,4,5,6,999}
            for _, a_idx in ipairs(valid_algos) do
                pcall(reaper.ImGui_SetCursorScreenPos, ctx, bx, by)
                local b_col = (n.algo == a_idx) and 0x005F73FF or 0x1C1C1EFF
                pcall(reaper.ImGui_DrawList_AddRectFilled, dl, bx, by, bx + 120, by + 30, b_col, 4.0)
                pcall(reaper.ImGui_DrawList_AddRect, dl, bx, by, bx + 120, by + 30, 0x333333FF, 4.0, 0, 1.0)
                
                local a_txt = NodeUI.ALGO_NAMES[a_idx]
                local _, aw = pcall(reaper.ImGui_CalcTextSize, ctx, a_txt)
                pcall(reaper.ImGui_DrawList_AddText, dl, bx + 60 - ((tonumber(aw) or 0)/2), by + 8, 0xE5E5EAFF, a_txt)
                
                UI.Safe_InvisibleButton(ctx, "pick_"..n.id.."_"..a_idx, 120, 30)
                if select(2, pcall(reaper.ImGui_IsItemHovered, ctx)) then
                    pcall(reaper.ImGui_DrawList_AddRect, dl, bx, by, bx + 120, by + 30, 0x00A5FFFF, 4.0, 0, 1.0)
                    if select(2, pcall(reaper.ImGui_IsMouseClicked, ctx, 0)) then n.algo = a_idx; n.show_picker = false; needs_save = true end
                end
                bx = bx + 130
                if bx > sc_x + n.w - 120 then bx = sc_x + 20; by = by + 40 end
            end
        else
            -- Call isolated block drawer for inside lane
            local chg = NodeUI.DrawNodeBlock(ctx, dl, n, i, nodes, connections, env, UI, DSP, sc_x, sc_y, false)
            if chg then needs_save = true end

            local o_x, o_y, o_w, o_h = sc_x + 60, sc_y + 40, 260, 150
            local scr_x, scr_w = o_x + 10, o_w - 20
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

        -- ==========================================================
        -- DESIGN MODE DRAG MATH (Locks the Chassis in Play Mode)
        -- ==========================================================
        if env.edit_mode then
            local ok_m, mx, my = pcall(reaper.ImGui_GetMousePos, ctx)
            mx, my = tonumber(mx) or 0, tonumber(my) or 0
            local is_clicked = select(2, pcall(reaper.ImGui_IsMouseClicked, ctx, 0))
            local is_down = select(2, pcall(reaper.ImGui_IsMouseDown, ctx, 0))
            local in_bounds = (mx >= sc_x and mx <= sc_x + (n.w or 480) and my >= sc_y and my <= sc_y + (n.h or 240))
            
            if in_bounds and is_clicked and not env.drag_node_id then
                env.drag_node_id = n.id
            end
            
            if not is_down and env.drag_node_id == n.id then
                env.drag_node_id = nil
            end
        else
            -- Force release if user switches to Play Mode while dragging
            if env.drag_node_id == n.id then env.drag_node_id = nil end
        end
        pcall(reaper.ImGui_DrawList_ChannelsMerge, dl)
        -- ==========================================================
    end
    return needs_save, nil
end

return NodeUI