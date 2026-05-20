-- ==============================================================================
-- OMM_Router.lua (The Macro Multiplexing Engine)
-- Protocol Zero: 1-to-Many Routing, Parameter Scraping & Depth Inversion
-- ==============================================================================
local Router = {}

-- UNDO BLOCK STATE (Prevents undo queue spam)
Router._undo_active = false
-- DIRTY FLAG CACHE: key = "fx_idx:param_idx" -> last sent value
Router._last_sent = {}

-- ==========================================
-- 1. INTERNAL PARAMETER DICTIONARIES
--    Each module type exposes a fixed set of internal parameters.
--    These are the params you can route an AuraKnob to WITHIN the module.
-- ==========================================
Router.INTERNAL_PARAMS = {
    COMPRESSOR = {
        { key = "thresh",     label = "Threshold",    min = -60.0, max = 0.0,   default = -18.0 },
        { key = "ratio",      label = "Ratio",        min = 1.0,   max = 100.0, default = 4.0   },
        { key = "attack",     label = "Attack",       min = 0.1,   max = 200.0, default = 15.0  },
        { key = "release",    label = "Release",      min = 10.0,  max = 2000.0,default = 150.0 },
        { key = "knee",       label = "Knee",         min = 0.0,   max = 24.0,  default = 6.0   },
        { key = "in_drive",   label = "Input Drive",  min = -24.0, max = 24.0,  default = 0.0   },
        { key = "makeup",     label = "Makeup Gain",  min = -24.0, max = 24.0,  default = 0.0   },
        { key = "mix",        label = "Mix",          min = 0.0,   max = 1.0,   default = 1.0   },
    },
    LFO = {
        { key = "rate_hz",    label = "Rate (Hz)",    min = 0.01,  max = 40.0,  default = 1.0   },
        { key = "depth",      label = "Depth",        min = 0.0,   max = 1.0,   default = 1.0   },
        { key = "phase_offset",label= "Phase Offset", min = 0.0,   max = 1.0,   default = 0.0   },
        { key = "smooth",     label = "Smooth",       min = 0.0,   max = 1.0,   default = 0.0   },
        { key = "delay",      label = "Delay",        min = 0.0,   max = 1.0,   default = 0.0   },
        { key = "rise",       label = "Rise",         min = 0.0,   max = 1.0,   default = 0.0   },
    },
    TRANSFER_CURVE = {
        { key = "depth",      label = "Depth",        min = 0.0,   max = 1.0,   default = 0.5   },
    },
    GAIN = {
        { key = "val",        label = "Volume",       min = 0.0,   max = 1.0,   default = 0.833 },
        { key = "pan",        label = "Pan",          min = 0.0,   max = 1.0,   default = 0.5   },
    },
    MACRO = {
        { key = "val",        label = "Value",        min = 0.0,   max = 1.0,   default = 0.0   },
    },
}

-- ==========================================
-- 2. PARAMETER SCRAPER
--    Reads all VST/JS/AU parameters from a given track.
--    Returns a hierarchical table: { { fx_idx, fx_name, params = { {idx, name}, ... } }, ... }
-- ==========================================
function Router.ScrapeTrackParams(track)
    if not track then return {} end
    local results = {}
    local fx_count = reaper.TrackFX_GetCount(track)
    for fx = 0, fx_count - 1 do
        local _, fx_name = reaper.TrackFX_GetFXName(track, fx)
        -- Filter out our own internal JSFX plugins
        if not string.find(fx_name, "OMM Track Hub") and
           not string.find(fx_name, "OMM Gain") and
           not string.find(fx_name, "OMM Modulator") and
           not string.find(fx_name, "OMM Compressor") and
           not string.find(fx_name, "OMM_Compressor") then
            local clean_name = fx_name:gsub("^VST%d?i?:%s*", ""):gsub("^JS:%s*", ""):gsub("^AUi?:%s*", "")
            clean_name = clean_name:match("^%s*(.-)%s*$") or fx_name
            local params = {}
            local p_count = reaper.TrackFX_GetNumParams(track, fx)
            for p = 0, p_count - 1 do
                local _, p_name = reaper.TrackFX_GetParamName(track, fx, p)
                table.insert(params, { idx = p, name = p_name or ("Param " .. p) })
            end
            table.insert(results, { fx_idx = fx, fx_name = clean_name, params = params })
        end
    end
    return results
end

-- ==========================================
-- 3. ROUTE EXECUTOR (The Core Math Loop)
--    Given a knob's normalized value (0.0–1.0) and its route array,
--    calculates and applies the output to every connected target.
--
--    Route Structure:
--    {
--        type = "INTERNAL" or "EXTERNAL",
--        -- INTERNAL routes:
--        target = "thresh",              -- Key into the node's state table
--        -- EXTERNAL routes:
--        fx_idx = 2,                     -- FX chain index on the linked track
--        param_idx = 4,                  -- Parameter index within the FX
--        -- Common:
--        depth = 1.0,                    -- -1.0 to 1.0 (negative = inverted)
--        label = "Decapitator: Drive",   -- Display label
--        base_val = nil,                 -- Captured base value (auto-set on first run)
--    }
-- ==========================================
-- UNDO BLOCK: Call on mouse-down (knob grab)
function Router.BeginInteraction()
    if not Router._undo_active then
        pcall(reaper.Undo_BeginBlock2, 0)
        pcall(reaper.PreventUIRefresh, 1)
        Router._undo_active = true
    end
end

-- UNDO BLOCK: Call on mouse-up (knob release)
function Router.EndInteraction()
    if Router._undo_active then
        pcall(reaper.PreventUIRefresh, -1)
        pcall(reaper.Undo_EndBlock2, 0, "OMM Macro Routing", -1)
        Router._undo_active = false
        -- Clear dirty cache so base values recapture on next interaction
        Router._last_sent = {}
    end
end

function Router.ExecuteRoutes(track, knob_value, routes, node)
    if not routes then return end
    for _, route in ipairs(routes) do
        local calculated_val = knob_value * (route.depth or 1.0)

        if route.type == "INTERNAL" then
            -- Write directly to the node's state table
            local param_def = nil
            local dict = node and Router.INTERNAL_PARAMS[node.type]
            if dict then
                for _, p in ipairs(dict) do
                    if p.key == route.target then param_def = p; break end
                end
            end
            if param_def then
                local base = route.base_val or param_def.default
                local range = param_def.max - param_def.min
                local final = base + (calculated_val * range)
                final = math.max(param_def.min, math.min(param_def.max, final))
                node[route.target] = final
            end

        elseif route.type == "EXTERNAL" then
            if track and route.fx_idx and route.param_idx then
                -- Capture base value on first contact
                if not route.base_val then
                    route.base_val = reaper.TrackFX_GetParamNormalized(track, route.fx_idx, route.param_idx)
                end
                local final = math.max(0.0, math.min(1.0, route.base_val + calculated_val))
                
                -- DIRTY FLAG: Only fire the API if value actually changed
                local dirty_key = tostring(route.fx_idx) .. ":" .. tostring(route.param_idx)
                local last = Router._last_sent[dirty_key]
                if not last or math.abs(final - last) > 0.001 then
                    -- Open undo block if not already open
                    Router.BeginInteraction()
                    reaper.TrackFX_SetParamNormalized(track, route.fx_idx, route.param_idx, final)
                    Router._last_sent[dirty_key] = final
                end
            end
        end
    end
end

-- ==========================================
-- 4. ROUTE MANAGEMENT (Add / Remove / Clear)
-- ==========================================
function Router.AddInternalRoute(component, target_key, label, depth)
    if not component.routes then component.routes = {} end
    -- Prevent duplicates
    for _, r in ipairs(component.routes) do
        if r.type == "INTERNAL" and r.target == target_key then return false end
    end
    table.insert(component.routes, {
        type = "INTERNAL",
        target = target_key,
        depth = depth or 1.0,
        label = label or target_key,
        base_val = nil
    })
    return true
end

function Router.AddExternalRoute(component, fx_idx, param_idx, label, depth)
    if not component.routes then component.routes = {} end
    -- Prevent duplicates
    for _, r in ipairs(component.routes) do
        if r.type == "EXTERNAL" and r.fx_idx == fx_idx and r.param_idx == param_idx then return false end
    end
    table.insert(component.routes, {
        type = "EXTERNAL",
        fx_idx = fx_idx,
        param_idx = param_idx,
        depth = depth or 1.0,
        label = label or ("FX " .. fx_idx .. " P" .. param_idx),
        base_val = nil
    })
    return true
end

function Router.RemoveRoute(component, route_idx)
    if component.routes and component.routes[route_idx] then
        table.remove(component.routes, route_idx)
        return true
    end
    return false
end

function Router.ClearRoutes(component)
    component.routes = {}
end

-- ==========================================
-- 5. SERIALIZATION HELPERS (For the Schema Compiler)
-- ==========================================
function Router.SerializeRoutes(routes)
    if not routes or #routes == 0 then return "routes = {}" end
    local lines = { "routes = {" }
    for _, r in ipairs(routes) do
        if r.type == "INTERNAL" then
            table.insert(lines, string.format(
                "        { type = 'INTERNAL', target = '%s', depth = %.4f, label = '%s' },",
                r.target, r.depth or 1.0, (r.label or r.target):gsub("'", "\\'")
            ))
        elseif r.type == "EXTERNAL" then
            table.insert(lines, string.format(
                "        { type = 'EXTERNAL', fx_idx = %d, param_idx = %d, depth = %.4f, label = '%s' },",
                r.fx_idx, r.param_idx, r.depth or 1.0, (r.label or ""):gsub("'", "\\'")
            ))
        end
    end
    table.insert(lines, "      }")
    return table.concat(lines, "\n")
end

function Router.DeserializeRoutes(route_table)
    -- Route tables loaded from schema files are already in the correct format
    -- This function validates and fills in defaults
    if not route_table then return {} end
    local clean = {}
    for _, r in ipairs(route_table) do
        if r.type == "INTERNAL" and r.target then
            table.insert(clean, {
                type = "INTERNAL",
                target = r.target,
                depth = r.depth or 1.0,
                label = r.label or r.target,
                base_val = nil
            })
        elseif r.type == "EXTERNAL" and r.fx_idx and r.param_idx then
            table.insert(clean, {
                type = "EXTERNAL",
                fx_idx = r.fx_idx,
                param_idx = r.param_idx,
                depth = r.depth or 1.0,
                label = r.label or ("FX " .. r.fx_idx .. " P" .. r.param_idx),
                base_val = nil
            })
        end
    end
    return clean
end

-- ==========================================
-- 6. UTILITY: Get Track from lane_guid
-- ==========================================
function Router.GetTrackByGUID(guid)
    if not guid then return nil end
    for i = 0, reaper.CountTracks(0) - 1 do
        local t = reaper.GetTrack(0, i)
        if reaper.GetTrackGUID(t) == guid then return t end
    end
    return nil
end

return Router
