-- ==============================================================================
-- OPEN MACRO MAKER MVP v108.1 (Protocol Zero: The Master Orchestrator)
-- ==============================================================================

local script_path = debug.getinfo(1, "S").source:match("@?(.*[\\/])") or ""
local DSP = dofile(script_path .. "OMM_DSP.lua")
local UI = dofile(script_path .. "OMM_UI.lua")
local NodeUI = dofile(script_path .. "OMM_NodeUI.lua")
local DeviceLane = dofile(script_path .. "OMM_DeviceLane.lua")
local Palette = dofile(script_path .. "OMM_Palette.lua")
local Router = dofile(script_path .. "OMM_Router.lua")
NodeUI.Router = Router

local ctx = reaper.ImGui_CreateContext('Open Macro Maker')

reaper.gmem_attach("OMM_Shared")
DSP.InitGMEM()

local COLOR_BG = 0x0F0F0FFF
local COLOR_NODE_BG = 0x222222FF
local COLOR_BORDER = 0x333333FF
local COLOR_ZONE_BG = 0x121212FF
local COLOR_TRACK_BG = 0x121212FF
local COLOR_TEXT_DIM = 0xAAAAAAFF
local COLOR_TEXT = 0xFFFFFFFF
local COLOR_GRID = 0x444444FF
local COLOR_ACCENT = 0x00E5FFFF
local COLOR_LFO_BOTTOM = 0x1A1A1AFF
local HEADER_H = 24
local BASE_GRID = 40.0

local workspaces = {{name = "Canvas 1", nodes = {}, connections = {}}}
local active_ws_idx = 1
local nodes = workspaces[active_ws_idx].nodes
local connections = workspaces[active_ws_idx].connections

local current_view, view_alpha, eco_mode = "NODE", 0.0, false
local is_closing, close_time, boot_time = false, 0, reaper.time_precise()
local master_alpha, anim_toggle_val, anim_toggle_start_val, anim_toggle_start_time = 0.0, 0.0, 0.0, 0.0
local last_app_time, last_mouse_move_time = reaper.time_precise(), reaper.time_precise()
local scroll_x, scroll_y, is_panning, snap_to_grid, global_win_x, global_win_y = 0.0, 0.0, false, true, nil, nil
local active_project = reaper.EnumProjects(-1)
local node_counter, needs_save = 0, false
local recoil_cables, jsfx_deploy_cache, OMM_Last_Valid_Touched = {}, {}, nil
local drag_state = { active = false, node_id = nil, start_x = 0, start_y = 0, col = 0xFFFFFFFF, port_type = nil }
local drag_node_id, drag_offset_x, drag_offset_y = nil, 0.0, 0.0
local double_click_pan_active = false 
local show_canvas_window = true
local DEV_MODE = false
local active_dev_module = nil
local palette = Palette.Generate(0x00A5FFFF)

local mseg_speeds = {{name="32 Bar",beats=128},{name="16 Bar",beats=64},{name="8 Bar",beats=32},{name="4 Bar",beats=16},{name="2 Bar",beats=8},{name="1 Bar",beats=4},{name="1/2",beats=2},{name="1/4",beats=1},{name="1/8",beats=0.5},{name="1/16",beats=0.25},{name="1/32",beats=0.125},{name="1/64",beats=0.0625}}
local preset_names = {"Sine", "Saw Up", "Pluck", "Square"}
local mode_names, dir_names = {"FREE", "RETRIG", "ENVELOPE"}, {"Forward", "Reverse"}
local lfo_presets = {{name="Sine",nodes={{x=0,y=0.5,curve=0},{x=0.25,y=1,curve=0},{x=0.5,y=0.5,curve=0},{x=0.75,y=0,curve=0},{x=1,y=0.5,curve=0}}},{name="Saw Up",nodes={{x=0,y=0,curve=0},{x=0.99999,y=1,curve=0},{x=1,y=0,curve=0}}},{name="Pluck",nodes={{x=0,y=1,curve=-5},{x=1,y=0,curve=0}}},{name="Square",nodes={{x=0,y=1,curve=0},{x=0.5,y=1,curve=0},{x=0.50001,y=0,curve=0},{x=1,y=0,curve=0}}}}
local curve_presets = {{name="Linear",nodes={{x=0,y=0,curve=0},{x=1,y=1,curve=0}}},{name="S-Curve",nodes={{x=0,y=0,curve=0},{x=0.5,y=0.5,curve=0},{x=1,y=1,curve=0}}}}

local function DeepCopy(obj) 
    if type(obj) ~= 'table' then return obj end
    local res = {}
    for k, v in pairs(obj) do res[k] = DeepCopy(v) end
    return res 
end

local function GetNodeById(id) 
    if not id then return nil end
    for _, ws in ipairs(workspaces) do
        for _, n in ipairs(ws.nodes) do 
            if n.id == id then return n end 
        end
    end
    return nil 
end

local LaneUndoStack = {}
local LaneRedoStack = {}

local function PushLaneUndoState()
    table.insert(LaneUndoStack, { nodes = DeepCopy(nodes), connections = DeepCopy(connections) })
    LaneRedoStack = {}
end

local function DeleteNode(id)
    PushLaneUndoState()
    for i, n in ipairs(nodes) do
        if n.id == id then
            table.remove(nodes, i)
            for c = #connections, 1, -1 do
                if connections[c].from_node == id or connections[c].to_node == id then table.remove(connections, c) end
            end
            needs_save = true
            break
        end
    end
end

local function BakeWavetable(node) 
    if not node or not node.id then return end
    local offset = 1000 + (node.id * 1024)
    for i = 0, 1023 do 
        local phase = i / 1023.0
        local val = DSP.GetMSEGValue(node, phase)
        if node.flip then val = 1.0 - val end
        reaper.gmem_write(offset + i, val) 
    end 
end

DSP.EnsureJSFXExists()
DSP.EnsureMIDIHubTrack()

local function ProcessSignalFlow(app_dt, fullbeats, app_time)
    for _, ws in ipairs(workspaces) do
        local nodes = ws.nodes
        local connections = ws.connections
        
        for _, c in ipairs(connections) do 
            local src = GetNodeById(c.from_node)
            local tgt = GetNodeById(c.to_node)
            if src and tgt and src.engine_mode == 1 and tgt.engine_mode == 0 then tgt.engine_mode = 1 end 
        end
        for _, n in ipairs(nodes) do 
            n.in_val, n.depth_in_val, n.mod_sum, n.phase_in_val, n.smooth_in_val, n.delay_in_val, n.rise_in_val, n.vis_pos_mod, n.vis_neg_mod = 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 
            n.glow_alpha = n.glow_alpha or 0.0
            n.strobe_t = n.strobe_t or 0.0
            if not eco_mode then n.strobe_t = DSP.ExpDecay(n.strobe_t, 0.0, app_dt, 5.0) end
            if n.type == "MIDI_IN" then
                local c_i = n.midi_channel or 1
                local cur_pulse = reaper.gmem_read(20016 + (c_i - 1)) or 0.0
                if cur_pulse > (n.last_pulse or 0) then n.glow_alpha = 1.0 end
                n.last_pulse = cur_pulse
                n.glow_alpha = DSP.ExpDecay(n.glow_alpha, 0.0, app_dt, 10.0)
                n.out_val = reaper.gmem_read(20000 + (c_i - 1)) or 0.0
                n.out_max, n.out_min = 1.0, 0.0
            end
        end
        for _, c in ipairs(connections) do
            local src = GetNodeById(c.from_node)
            local tgt = GetNodeById(c.to_node)
            if src and tgt then 
                if c.to_port == "RATE" then tgt.in_val = tgt.in_val + (src.out_val or 0.0) 
                elseif c.to_port == "PHASE" then tgt.phase_in_val = tgt.phase_in_val + (src.out_val or 0.0) 
                elseif c.to_port == "SMOOTH" then tgt.smooth_in_val = tgt.smooth_in_val + (src.out_val or 0.0) 
                elseif c.to_port == "DELAY" then tgt.delay_in_val = tgt.delay_in_val + (src.out_val or 0.0) 
                elseif c.to_port == "RISE" then tgt.rise_in_val = tgt.rise_in_val + (src.out_val or 0.0) 
                elseif c.to_port == "GAIN" then tgt.in_val = tgt.in_val + (src.out_val or 0.0) 
                elseif c.to_port == "MIDI_IN" and not c.bypass then tgt.midi_pulse = math.max(tgt.midi_pulse or 0.0, src.last_pulse or 0.0) end
            end
        end
        
        for _, n in ipairs(nodes) do
            if n.lane_guid then
                local track = nil
                for ti = 0, reaper.CountTracks(0) - 1 do
                    local t = reaper.GetTrack(0, ti)
                    if reaper.GetTrackGUID(t) == n.lane_guid then track = t; break end
                end
                if track then
                    if n.type == "LFO" or n.type == "TRANSFER_CURVE" or n.type == "MACRO" then
                        DSP.EnsureModulatorBridge(jsfx_deploy_cache, track, n.id)
                    elseif n.type == "GAIN" then
                        DSP.EnsureGainBridge(jsfx_deploy_cache, track, n.id)
                    elseif n.type == "COMPRESSOR" then
                        if n.algo ~= 999 then DSP.EnsureCompressorBridge(jsfx_deploy_cache, track, n) end
                    end
                end
            end
    
            if n.type == "LFO" then
                local is_note_on = n.midi_in and (n.midi_pulse or 0) > (n.last_midi_pulse or 0)
                n.last_midi_pulse = n.midi_pulse or 0.0
                local time_mod = 1.0
                if n.trip then time_mod = 0.666666 end
                if n.dot then time_mod = 1.5 end
                local effective_hz = math.max(0.1, n.rate_hz + ((n.in_val or 0.0) * 30.0))
                local max_idx = #mseg_speeds - 1
                local modded_idx = math.max(0, math.min(max_idx, n.speed_idx + math.floor((n.in_val or 0) * max_idx)))
                local beats_per_cycle = math.max(0.00001, mseg_speeds[modded_idx + 1].beats * time_mod)
                if is_note_on then 
                    if n.mode == 1 or n.mode == 2 then n.run_phase = 0.0; n.env_active = true; n.note_on_time = app_time end
                    n.strobe_t = 1.0; n.glow_alpha = 1.0 
                end
                local final_phase = 0.0
                if n.mode == 0 then 
                    if n.sync then final_phase = (fullbeats % beats_per_cycle) / beats_per_cycle 
                    else n.run_phase = (n.run_phase or 0) + (app_dt * effective_hz); final_phase = n.run_phase % 1.0 end 
                else 
                    if n.sync then local hz = (reaper.Master_GetTempo() / 60.0) / beats_per_cycle; n.run_phase = (n.run_phase or 0) + (app_dt * hz) 
                    else n.run_phase = (n.run_phase or 0) + (app_dt * effective_hz) end
                    if n.mode == 1 then final_phase = n.run_phase % 1.0 
                    elseif n.mode == 2 then final_phase = math.min(1.0, n.run_phase); if final_phase >= 1.0 then n.env_active = false end end
                end
                n.phase = final_phase
                local eff_offset = math.max(0.0, math.min(1.0, (n.phase_offset or 0.0) + (n.phase_in_val or 0.0)))
                local p = (n.phase + eff_offset) % 1.0; if n.dir == 1 then p = 1.0 - p end 
                local raw_val = n.flip and (1.0 - DSP.GetMSEGValue(n, p)) or DSP.GetMSEGValue(n, p)
                local time_since_note = app_time - (n.note_on_time or 0)
                local eff_delay = math.max(0.0, math.min(1.0, (n.delay or 0.0) + (n.delay_in_val or 0.0))) * 2.0
                local eff_rise = math.max(0.0, math.min(1.0, (n.rise or 0.0) + (n.rise_in_val or 0.0))) * 2.0
                local amp = 1.0
                if n.midi_in and (n.mode == 1 or n.mode == 2) then 
                    if time_since_note < eff_delay then amp = 0.0 
                    elseif eff_rise > 0.01 then amp = math.min(1.0, (time_since_note - eff_delay) / eff_rise) end
                    if n.mode == 2 and not n.env_active then amp = 0.0 end 
                end
                local target_val = raw_val * amp
                local eff_smooth = math.max(0.0, math.min(1.0, (n.smooth or 0.0) + (n.smooth_in_val or 0.0)))
                if eff_smooth > 0.01 then 
                    local filter_coeff = 1.0 - math.exp(-app_dt / (eff_smooth * 0.5))
                    n.smoothed_val = (n.smoothed_val or target_val) + (target_val - (n.smoothed_val or target_val)) * filter_coeff 
                else n.smoothed_val = target_val end
                n.glow_alpha = DSP.ExpDecay(n.glow_alpha, 0.0, app_dt, 10.0)
                n.out_val, n.out_max, n.out_min = n.smoothed_val, 1.0, 0.0
                
            elseif n.type == "TRANSFER_CURVE" then
                if not n.active then n.out_val, n.out_max, n.out_min = 0.0, 0.0, 0.0 else
                    local in_sum = 0.0
                    for _, c in ipairs(connections) do 
                        if c.to_node == n.id and c.to_port == "IN" then 
                            local src = GetNodeById(c.from_node)
                            if src then in_sum = in_sum + ((src.out_val or 0.0) * (c.depth or 1.0)) end 
                        end 
                    end
                    local in_v = math.max(0.0, math.min(1.0, in_sum))
                    local val = DSP.GetMSEGValue(n, in_v)
                    if n.flip then val = 1.0 - val end
                    local cur_depth = math.max(-1.0, math.min(1.0, ((tonumber(n.depth) or 0.5) - 0.5) * 2.0 + n.depth_in_val))
                    n.out_max = n.bipolar and math.abs(cur_depth) or math.max(0, cur_depth)
                    n.out_min = n.bipolar and -math.abs(cur_depth) or math.min(0, cur_depth)
                    if n.bipolar then n.out_val = (val * 2.0 - 1.0) * cur_depth else n.out_val = val * cur_depth end
                end
                
            elseif n.type == "COMPRESSOR" then
                local node_idx = 40000 + (n.gmem_slot * 32)
                if not n.bypass then
                    reaper.gmem_write(node_idx + 0, n.thresh or 0.0)
                    reaper.gmem_write(node_idx + 1, n.ratio or 4.0)
                    reaper.gmem_write(node_idx + 2, n.attack or 5.0)
                    reaper.gmem_write(node_idx + 3, n.release or 50.0)
                    reaper.gmem_write(node_idx + 4, n.knee or 6.0)
                    reaper.gmem_write(node_idx + 5, n.mix or 1.0)
                    reaper.gmem_write(node_idx + 6, n.mode_rms and 1 or 0)
                    reaper.gmem_write(node_idx + 7, n.mode_fb and 1 or 0)
                    reaper.gmem_write(node_idx + 8, n.makeup or 0.0)
                    reaper.gmem_write(node_idx + 9, n.in_drive or 0.0)
                    
                    n.in_meter_l = reaper.gmem_read(node_idx + 10)
                    n.gr_meter   = reaper.gmem_read(node_idx + 11)
                    n.in_meter_r = reaper.gmem_read(node_idx + 12)
                else
                    n.in_meter_l = 0.0
                    n.in_meter_r = 0.0
                    n.gr_meter = 1.0
                end
                
            elseif n.type == "GAIN" then
                local mod_gain = math.max(0.0, math.min(1.0, (n.val or 0.833333) + (n.in_val or 0.0)))
                local mod_pan = math.max(0.0, math.min(1.0, (n.pan or 0.5) + (n.depth_in_val or 0.0)))
                n.out_val, n.out_max, n.out_min = mod_gain, 1.0, 0.0
                local cur_db = -60.0 + (mod_gain * (60.0 + (n.extended_range and 30.0 or 12.0)))
                n.smooth_db = DSP.ExpDecay(n.smooth_db or -60.0, cur_db, app_dt, 12.0)
                
                reaper.gmem_write(30000 + (n.id * 2), cur_db)
                reaper.gmem_write(30000 + (n.id * 2) + 1, mod_pan)
                
            elseif n.type == "MACRO" then 
                local raw = math.max(0.0, math.min(1.0, n.val))
                n.out_val = n.flip and (1.0 - raw) or raw
                n.out_max, n.out_min = 1.0, 0.0 
            end
        end
        for _, c in ipairs(connections) do
            local src = GetNodeById(c.from_node)
            local tgt = GetNodeById(c.to_node)
            if src and tgt and (tgt.type == "TARGET" or tgt.type == "MACRO") and c.to_port == "IN" and not c.bypass then 
                local mod_val = src.out_val or 0.0
                local eff_depth = ((c.depth or 0.5) - 0.5) * 2.0
                if c.bipolar then 
                    mod_val = (mod_val * 2.0) - 1.0
                    tgt.mod_sum = tgt.mod_sum + (mod_val * eff_depth) 
                else tgt.mod_sum = tgt.mod_sum + (mod_val * eff_depth) end
                if tgt.active_conn_idx and connections[tgt.active_conn_idx] == c then
                    if c.bipolar then 
                        local swing = math.abs(eff_depth)
                        tgt.vis_pos_mod, tgt.vis_neg_mod = swing, -swing 
                    else 
                        if eff_depth > 0 then tgt.vis_pos_mod, tgt.vis_neg_mod = eff_depth, 0.0 
                        else tgt.vis_pos_mod, tgt.vis_neg_mod = 0.0, eff_depth end 
                    end
                end
            end
        end
        local track_channels = {} 
        for _, n in ipairs(nodes) do
            if n.type == "TARGET" then
                local track = n.track_idx == 0 and reaper.GetMasterTrack(0) or reaper.GetTrack(0, n.track_idx - 1)
                if track then
                    local current_vst_val = reaper.TrackFX_GetParamNormalized(track, n.fx_idx, n.param_idx)
                    if not n.is_interacting and (app_time - (n.last_interaction_time or 0)) > 0.5 then
                        if n.last_out_val and math.abs(current_vst_val - n.last_out_val) > 0.001 then 
                            n.base_val = math.max(0.0, math.min(1.0, current_vst_val - n.mod_sum))
                            needs_save = true 
                        end
                    end
                    n.out_val = math.max(0.0, math.min(1.0, n.base_val + n.mod_sum))
                    n.last_out_val = n.out_val 
                    local bridge_idx = DSP.EnsureTrackBridge(jsfx_deploy_cache, track, n.track_idx)
                    reaper.TrackFX_SetParamNormalized(track, n.fx_idx, n.param_idx, n.out_val)
                    if bridge_idx >= 0 then 
                        track_channels[track] = (track_channels[track] or 0) + 1
                        local ch_idx = track_channels[track]
                        if ch_idx <= 16 then 
                            local g_idx = (ch_idx - 1) * 10
                            reaper.gmem_write(g_idx + 1, n.base_val)
                            reaper.gmem_write(g_idx + 6, 1)
                            reaper.gmem_write(g_idx + 0, n.engine_mode == 1 and 2 or 0)
                            reaper.gmem_write(g_idx + 5, n.mod_sum)
                            reaper.gmem_write(g_idx + 2, 1.0)
                            reaper.TrackFX_SetParamNormalized(track, bridge_idx, ch_idx, n.out_val) 
                        end
                    end
                end
            end
        end
    end
end

local function CreateMacroNode(x, y, guid) node_counter = node_counter + 1; table.insert(nodes, {id=node_counter, lane_guid=guid, type="MACRO", x=x, y=y, target_x=x, target_y=y, w=160, h=160, val=0.0, out_val=0.0, col=0x00E5FFFF, hide=false, bypass=false, flip=false, engine_mode=0, mod_sum=0, vis_pos_mod=0, vis_neg_mod=0, flash_time=0.0, shadow_spread=6.0, shockwave_time=0.0, active_conn_idx=1}); needs_save = true; return node_counter end
local function CreateLFONode(x, y, guid) node_counter = node_counter + 1; local n = {id=node_counter, lane_guid=guid, type="LFO", x=x, y=y, target_x=x, target_y=y, w=560, h=240, sync=true, speed_float=5.0, speed_idx=5, rate_hz=1.0, depth=1.0, phase_offset=0.0, smooth=0.0, delay=0.0, rise=0.0, mode=0, dir=0, preset_idx=0, grid_x=8.0, grid_y=8.0, trip=false, dot=false, draw_mode=0, midi_in=false, midi_trig=0.0, last_midi_trig=0.0, phase=0.0, run_phase=0.0, midi_pulse=0, last_midi_pulse=0, env_active=true, note_on_time=0.0, smoothed_val=0.0, in_val=0.0, out_val=0.0, flip=false, col=0x00E5FFFF, engine_mode=1, dragged_node=-1, dragged_curve_node=-1, mod_sum=0, flash_time=0.0, shadow_spread=6.0, shockwave_time=0.0, mseg_nodes=DeepCopy(lfo_presets[1].nodes)}; table.insert(nodes, n); BakeWavetable(n); needs_save = true; return node_counter end
local function CreateTransferCurveNode(x, y, guid) node_counter = node_counter + 1; local n = {id=node_counter, lane_guid=guid, type="TRANSFER_CURVE", x=x, y=y, target_x=x, target_y=y, w=240, h=240, grid_x=6.0, grid_y=6.0, depth=0.5, expanded=false, in_val=0.0, out_val=0.0, flip=false, col=0xFFE600FF, bipolar=false, active=true, unipolar=true, engine_mode=0, dragged_node=-1, dragged_curve_node=-1, mod_sum=0, flash_time=0.0, shadow_spread=6.0, shockwave_time=0.0, mseg_nodes=DeepCopy(curve_presets[1].nodes)}; table.insert(nodes, n); BakeWavetable(n); needs_save = true; return n.id end
local function CreateTargetNode(x, y, t_i, f_i, p_i, p_n, b_v, guid) node_counter = node_counter + 1; table.insert(nodes, {id=node_counter, lane_guid=guid, type="TARGET", x=x, y=y, target_x=x, target_y=y, w=160, h=160, track_idx=t_i, fx_idx=f_i, param_idx=p_i, param_name=p_n, base_val=b_v, in_val=0.0, out_val=0.0, depth=1.0, col=0xEEEEEEFF, engine_mode=0, mod_sum=0, vis_pos_mod=0, vis_neg_mod=0, flash_time=0.0, shadow_spread=6.0, shockwave_time=0.0, active_conn_idx=1}); needs_save = true; return node_counter end
local function CreateGainNode(x, y, guid) node_counter = node_counter + 1; table.insert(nodes, {id=node_counter, lane_guid=guid, type="GAIN", x=x, y=y, target_x=x, target_y=y, w=160, h=80, val=0.833333, pan=0.5, extended_range=false, track_idx=0, in_val=0.0, depth_in_val=0.0, out_val=0.0, smooth_db=-60.0, col=0x00FF88FF, flash_time=0.0, shadow_spread=6.0, shockwave_time=0.0, dot_pop_alpha=0.0}); needs_save = true; return node_counter end

local function CreateCompressorNode(x, y, guid, variant) 
    node_counter = node_counter + 1
    local last_slot = reaper.gmem_read(39999) or 0
    local new_slot = last_slot + 1
    reaper.gmem_write(39999, new_slot)

    -- CHANGED: 'algo' now defaults strictly to integer 0 (ReaComp), killing the "VCA" string virus.
    local n = {
        id=node_counter, lane_guid=guid, type="COMPRESSOR", algo=variant or 0, x=x, y=y, target_x=x, target_y=y, 
        w=560, h=240, thresh=0.0, in_drive=0.0, ratio=4.0, attack=5.0, release=50.0, 
        knee=6.0, mix=1.0, mode_rms=false, mode_fb=false, makeup=0.0, col=0x00E5FFFF, bypass=false,
        vis_mode=0, gmem_slot=new_slot
    }
    table.insert(nodes, n)
    needs_save = true

    local track = nil
    if guid then
        for ti = 0, reaper.CountTracks(0) - 1 do
            local t = reaper.GetTrack(0, ti)
            if reaper.GetTrackGUID(t) == guid then track = t; break end
        end
    end
    if track and (variant ~= 999) then
        DSP.EnsureCompressorBridge(jsfx_deploy_cache, track, n)
    end

    return node_counter 
end

local function CreateBetaLabNode(x, y, guid) 
    node_counter = node_counter + 1
    local last_slot = reaper.gmem_read(39999) or 0
    local new_slot = last_slot + 1
    reaper.gmem_write(39999, new_slot)

    table.insert(nodes, {
        id=node_counter, lane_guid=guid, type="COMPRESSOR", algo=999, x=x, y=y, target_x=x, target_y=y, 
        w=560, h=240, thresh=0.0, in_drive=0.0, ratio=4.0, attack=5.0, release=50.0, 
        knee=6.0, mix=1.0, mode_rms=false, mode_fb=false, makeup=0.0, col=0x00E5FFFF, bypass=false,
        vis_mode=0, track_idx=0, val=0.5, pan=0.5, extended_range=false, gmem_slot=new_slot
    })
    needs_save = true
    return node_counter 
end


local function SaveState()
    local full_str = ""
    for _, ws in ipairs(workspaces) do
        full_str = full_str .. "CANVAS|" .. ws.name .. "||"
        for _, n in ipairs(ws.nodes) do
            local g_str = tostring(n.lane_guid or "")
            if n.type == "MACRO" then full_str = full_str .. "MACRO|"..n.id.."|"..n.target_x.."|"..n.target_y.."|"..n.val.."|"..n.col.."|"..g_str.."||"
            elseif n.type == "LFO" then full_str = full_str .. "LFO|"..n.id.."|"..n.target_x.."|"..n.target_y.."|"..tostring(n.sync).."|"..n.speed_idx.."|"..n.rate_hz.."|"..n.mode.."|"..n.dir.."|"..n.preset_idx.."|"..(n.midi_in and 1 or 0).."|"..n.phase_offset.."|"..n.smooth.."|"..n.delay.."|"..n.rise.."|"..g_str.."||"
            elseif n.type == "TARGET" then full_str = full_str .. "TARGET|"..n.id.."|"..n.target_x.."|"..n.target_y.."|"..n.track_idx.."|"..n.fx_idx.."|"..n.param_idx.."|"..n.param_name.."|"..n.base_val.."|"..n.col.."|"..g_str.."||"
            elseif n.type == "MIDI_IN" then full_str = full_str .. "MIDI_IN|"..n.id.."|"..n.target_x.."|"..n.target_y.."|"..(n.midi_channel or 1).."|"..n.col.."|"..g_str.."||"
            elseif n.type == "GAIN" then full_str = full_str .. "GAIN|"..n.id.."|"..n.target_x.."|"..n.target_y.."|"..(n.val or 0.833).."|"..(n.pan or 0.5).."|"..(n.extended_range and 1 or 0).."|"..(n.track_idx or 0).."|"..g_str.."||"
            elseif n.type == "COMPRESSOR" then full_str = full_str .. "COMP|"..n.id.."|"..n.target_x.."|"..n.target_y.."|"..n.thresh.."|"..n.in_drive.."|"..n.ratio.."|"..n.attack.."|"..n.release.."|"..n.knee.."|"..n.mix.."|"..(n.mode_rms and 1 or 0).."|"..(n.mode_fb and 1 or 0).."|"..n.makeup.."|"..g_str.."|"..(n.vis_mode or 0).."|"..(n.gmem_slot or 1).."|"..tostring(n.algo or "VCA").."||"
            elseif n.type == "TRANSFER_CURVE" then full_str = full_str .. "CURVE|"..n.id.."|"..n.target_x.."|"..n.target_y.."|"..n.grid_x.."|"..n.grid_y.."|"..n.col.."|"..n.depth.."|"..(n.unipolar and 1 or 0).."|"..(n.bipolar and 1 or 0).."|"..(n.active and 1 or 0).."|"..(n.flip and 1 or 0).."|"..(n.expanded and 1 or 0).."|"..n.engine_mode.."|"..g_str.."||" end
        end
        full_str = full_str .. "WS_CONNS||"
        for _, c in ipairs(ws.connections) do full_str = full_str .. c.from_node..","..c.to_node..","..c.to_port..","..c.depth..","..(c.bipolar and 1 or 0)..","..(c.bypass and 1 or 0).."||" end
        full_str = full_str .. "WS_END||"
    end
    reaper.SetProjExtState(0, "OpenMacroMaker", "CanvasDataV30", full_str)
    needs_save = false
end

local function LoadState()
    local rv_n, n_str = reaper.GetProjExtState(0, "OpenMacroMaker", "CanvasDataV30")
    if rv_n > 0 and n_str ~= "" then 
        workspaces = {}
        local active_ws = nil
        local max_id = 0
        for chunk in string.gmatch(n_str, "(.-)||") do
            local pts = {}
            for p in string.gmatch(chunk, "([^|]+)") do table.insert(pts, p) end
            
            if pts[1] == "CANVAS" then 
                active_ws = {name = pts[2] or "Canvas", nodes = {}, connections = {}}
                table.insert(workspaces, active_ws)
            elseif active_ws and pts[1] == "MACRO" then 
                local id = math.floor(tonumber(pts[2]) or 0); max_id = math.max(max_id, id)
                table.insert(active_ws.nodes, {id = id, lane_guid = pts[7]=="" and nil or pts[7], type = "MACRO", x = tonumber(pts[3]) or 0, y = tonumber(pts[4]) or 0, target_x = tonumber(pts[3]) or 0, target_y = tonumber(pts[4]) or 0, w = 160, h = 160, val = tonumber(pts[5]) or 0.0, col = math.floor(tonumber(pts[6]) or 0x00E5FFFF), hide = false, bypass = false, flip = false, engine_mode = 0, in_val = 0.0, out_val = 0.0, mod_sum = 0, vis_pos_mod = 0, vis_neg_mod = 0, flash_time = 0.0, shadow_spread = 6.0, shockwave_time = 0.0, active_conn_idx = 1})
            elseif active_ws and pts[1] == "LFO" then 
                local id = math.floor(tonumber(pts[2]) or 0); max_id = math.max(max_id, id)
                local mseg_arr = {}
                for m_chunk in string.gmatch(pts[22] or "", "([^;]+)") do 
                    local m_parts = {}
                    for mp in string.gmatch(m_chunk, "([^,]+)") do table.insert(m_parts, tonumber(mp)) end
                    if #m_parts >= 2 then table.insert(mseg_arr, {x=m_parts[1], y=m_parts[2], curve=m_parts[3] or 0.0}) end 
                end
                if #mseg_arr < 2 then mseg_arr = DeepCopy(lfo_presets[1].nodes) end
                local n_lfo = {id=id, lane_guid = pts[16]=="" and nil or pts[16], type="LFO", x=tonumber(pts[3]) or 0, y=tonumber(pts[4]) or 0, target_x=tonumber(pts[3]) or 0, target_y=tonumber(pts[4]) or 0, w=560, h=240, sync=pts[5]=="true", speed_float=5.0, speed_idx=math.floor(tonumber(pts[6]) or 5), rate_hz=tonumber(pts[7]) or 1.0, mode=math.floor(tonumber(pts[8]) or 0), dir=math.floor(tonumber(pts[9]) or 0), preset_idx=math.floor(tonumber(pts[10]) or 0), grid_x=8.0, grid_y=8.0, col=0x00E5FFFF, flip=false, engine_mode=1, depth=1.0, trip=false, dot=false, midi_in=tonumber(pts[11])==1, phase_offset=tonumber(pts[12]) or 0.0, smooth=tonumber(pts[13]) or 0.0, delay=tonumber(pts[14]) or 0.0, rise=tonumber(pts[15]) or 0.0, phase=0.0, run_phase=0.0, midi_pulse=0, last_midi_pulse=0, env_active=true, note_on_time=0.0, smoothed_val=0.0, in_val=0.0, out_val=0.0, draw_mode=0, mseg_nodes=mseg_arr, dragged_node=-1, dragged_curve_node=-1, midi_trig=0.0, last_midi_trig=0.0, mod_sum=0, flash_time=0.0, shadow_spread=6.0, shockwave_time=0.0}
                table.insert(active_ws.nodes, n_lfo); BakeWavetable(n_lfo)
            elseif active_ws and pts[1] == "CURVE" then 
                local id = math.floor(tonumber(pts[2]) or 0); max_id = math.max(max_id, id)
                local mseg_arr = {}
                for m_chunk in string.gmatch(pts[15] or "", "([^;]+)") do 
                    local m_parts = {}
                    for mp in string.gmatch(m_chunk, "([^,]+)") do table.insert(m_parts, tonumber(mp)) end
                    if #m_parts >= 2 then table.insert(mseg_arr, {x=m_parts[1], y=m_parts[2], curve=m_parts[3] or 0.0}) end 
                end
                if #mseg_arr < 2 then mseg_arr = DeepCopy(curve_presets[1].nodes) end
                local exp = tonumber(pts[13])==1
                local n_c = {id=id, lane_guid = pts[16]=="" and nil or pts[16], type="TRANSFER_CURVE", x=tonumber(pts[3]) or 0, y=tonumber(pts[4]) or 0, target_x=tonumber(pts[3]) or 0, target_y=tonumber(pts[4]) or 0, w=exp and 480 or 240, h=240, grid_x=tonumber(pts[5]) or 6, grid_y=tonumber(pts[6]) or 6, col=math.floor(tonumber(pts[7]) or 0xFFE600FF), depth=tonumber(pts[8]) or 0.5, unipolar=tonumber(pts[9])==1, bipolar=tonumber(pts[10])==1, active=tonumber(pts[11])==1, flip=tonumber(pts[12])==1, expanded=exp, engine_mode=math.floor(tonumber(pts[14]) or 0), in_val=0.0, depth_in_val=0.0, out_val=0.0, mseg_nodes=mseg_arr, dragged_node=-1, dragged_curve_node=-1, mod_sum=0, flash_time=0.0, shadow_spread=6.0, shockwave_time=0.0}
                table.insert(active_ws.nodes, n_c); BakeWavetable(n_c)
            elseif active_ws and pts[1] == "COMP" then
                local id = math.floor(tonumber(pts[2]) or 0); max_id = math.max(max_id, id)
                local g_slot = math.floor(tonumber(pts[17]) or 0)
                if g_slot == 0 then
                    local last_slot = reaper.gmem_read(39999) or 0
                    g_slot = last_slot + 1
                    reaper.gmem_write(39999, g_slot)
                end
                local algo_val = pts[18] or "VCA"
                if tonumber(algo_val) then
                    local n_algo = tonumber(algo_val)
                    if n_algo == 999 then algo_val = 999
                    else algo_val = n_algo end
                end
                table.insert(active_ws.nodes, {id=id, lane_guid = pts[15]=="" and nil or pts[15], type="COMPRESSOR", algo=algo_val, x=tonumber(pts[3]) or 0, y=tonumber(pts[4]) or 0, target_x=tonumber(pts[3]) or 0, target_y=tonumber(pts[4]) or 0, w=560, h=240, thresh=tonumber(pts[5]) or 0.0, in_drive=tonumber(pts[6]) or 0.0, ratio=tonumber(pts[7]) or 4.0, attack=tonumber(pts[8]) or 5.0, release=tonumber(pts[9]) or 50.0, knee=tonumber(pts[10]) or 6.0, mix=tonumber(pts[11]) or 1.0, mode_rms=tonumber(pts[12])==1, mode_fb=tonumber(pts[13])==1, makeup=tonumber(pts[14]) or 0.0, col=0x00E5FFFF, bypass=false, vis_mode=math.floor(tonumber(pts[16]) or 0), gmem_slot=g_slot})
            elseif active_ws and pts[1] == "TARGET" then 
                local id = math.floor(tonumber(pts[2]) or 0); max_id = math.max(max_id, id)
                table.insert(active_ws.nodes, {id = id, lane_guid = pts[11]=="" and nil or pts[11], type = "TARGET", x = tonumber(pts[3]) or 0, y = tonumber(pts[4]) or 0, target_x = tonumber(pts[3]) or 0, target_y = tonumber(pts[4]) or 0, w = 160, h = 160, track_idx = math.floor(tonumber(pts[5]) or 0), fx_idx = math.floor(tonumber(pts[6]) or 0), param_idx = math.floor(tonumber(pts[7]) or 0), param_name = pts[8] or "Param", base_val = tonumber(pts[9]) or 0.0, depth = 1.0, col = math.floor(tonumber(pts[10]) or 0xEEEEEEFF), engine_mode = 0, in_val = 0.0, out_val = 0.0, mod_sum = 0, vis_pos_mod = 0, vis_neg_mod = 0, flash_time = 0.0, shadow_spread = 6.0, shockwave_time = 0.0, active_conn_idx = 1})
            elseif active_ws and pts[1] == "MIDI_IN" then 
                local id = math.floor(tonumber(pts[2]) or 0); max_id = math.max(max_id, id)
                table.insert(active_ws.nodes, {id = id, lane_guid = pts[7]=="" and nil or pts[7], type = "MIDI_IN", x = tonumber(pts[3]) or 0, y = tonumber(pts[4]) or 0, target_x = tonumber(pts[3]) or 0, target_y = tonumber(pts[4]) or 0, w = 160, h = 80, midi_channel = math.floor(tonumber(pts[5]) or 1), col = math.floor(tonumber(pts[6]) or 0xFF4000FF), out_val = 0.0, flash_time = 0.0, shadow_spread = 6.0, last_note_on = 0.0})
            elseif active_ws and pts[1] == "GAIN" then 
                local id = math.floor(tonumber(pts[2]) or 0); max_id = math.max(max_id, id)
                table.insert(active_ws.nodes, {id = id, lane_guid = pts[9]=="" and nil or pts[9], type = "GAIN", x = tonumber(pts[3]) or 0, y = tonumber(pts[4]) or 0, target_x = tonumber(pts[3]) or 0, target_y = tonumber(pts[4]) or 0, w = 160, h = 80, val = tonumber(pts[5]) or 0.833333, pan = tonumber(pts[6]) or 0.5, extended_range = tonumber(pts[7]) == 1, track_idx = math.floor(tonumber(pts[8]) or 0), in_val = 0.0, depth_in_val = 0.0, out_val = 0.0, smooth_db = -60.0, col = 0x00FF88FF, flash_time = 0.0, shadow_spread = 6.0, shockwave_time = 0.0, dot_pop_alpha = 0.0})
            elseif active_ws and string.find(chunk, ",") then 
                local cp = {}
                for c in string.gmatch(chunk, "([^,]+)") do table.insert(cp, c) end
                if #cp >= 4 then table.insert(active_ws.connections, {from_node = math.floor(tonumber(cp[1]) or 0), to_node = math.floor(tonumber(cp[2]) or 0), to_port = cp[3] or "IN", depth = tonumber(cp[4]) or 0.5, bipolar = (tonumber(cp[5]) == 1), bypass = (tonumber(cp[6]) == 1)}) end 
            end
        end
        node_counter = max_id
        if #workspaces == 0 then table.insert(workspaces, {name = "Canvas 1", nodes = {}, connections = {}}) end
        active_ws_idx = 1; nodes = workspaces[1].nodes; connections = workspaces[1].connections
    else 
        workspaces = {{name = "Canvas 1", nodes = {}, connections = {}}}
        active_ws_idx = 1; nodes = workspaces[1].nodes; connections = workspaces[1].connections 
    end
end
LoadState()

local function loop()
    local ok_m, mx, my = pcall(reaper.ImGui_GetMousePos, ctx)
    local mouse_x, mouse_y = tonumber(mx) or 0, tonumber(my) or 0
    
    if not DEV_MODE then
        if select(2, pcall(reaper.ImGui_IsKeyPressed, ctx, reaper.ImGui_Key_Z())) and select(2, pcall(reaper.ImGui_IsKeyDown, ctx, reaper.ImGui_Mod_Ctrl())) then
            if select(2, pcall(reaper.ImGui_IsKeyDown, ctx, reaper.ImGui_Mod_Shift())) then
                if #LaneRedoStack > 0 then
                    table.insert(LaneUndoStack, { nodes = DeepCopy(nodes), connections = DeepCopy(connections) })
                    local state = table.remove(LaneRedoStack)
                    nodes = state.nodes; connections = state.connections
                    workspaces[active_ws_idx].nodes = nodes; workspaces[active_ws_idx].connections = connections
                    needs_save = true
                end
            else
                if #LaneUndoStack > 0 then
                    table.insert(LaneRedoStack, { nodes = DeepCopy(nodes), connections = DeepCopy(connections) })
                    local state = table.remove(LaneUndoStack)
                    nodes = state.nodes; connections = state.connections
                    workspaces[active_ws_idx].nodes = nodes; workspaces[active_ws_idx].connections = connections
                    needs_save = true
                end
            end
        end
    end
    
    local app_time = reaper.time_precise()
    local app_dt = math.max(0, app_time - last_app_time)
    last_app_time = app_time
    
    local cur_proj = reaper.EnumProjects(-1)
    if cur_proj ~= active_project then 
        active_project = cur_proj
        workspaces = {{name="Canvas 1",nodes={},connections={}}}
        active_ws_idx=1; nodes=workspaces[1].nodes; connections=workspaces[1].connections; node_counter=0
        LoadState(); DSP.EnsureMIDIHubTrack() 
    end
    
    local sel_track = reaper.GetSelectedTrack(0, 0)
    local is_playing = reaper.GetPlayState() & 1 == 1
    local cur_t = reaper.time_precise()
    local e_pos = 0
    if is_playing then 
        local rp = reaper.GetPlayPosition()
        if rp == last_raw_play_pos then e_pos = e_pos + (cur_t - last_time_precise) * (reaper.Master_GetPlayRate(0) or 1.0) 
        else e_pos = rp; last_raw_play_pos = rp end 
    else 
        e_pos = reaper.GetCursorPosition(); last_raw_play_pos = e_pos 
    end
    last_time_precise = cur_t
    local _, _, _, fullbeats = reaper.TimeMap2_timeToBeats(0, e_pos)

    local is_typing = select(2, pcall(reaper.ImGui_IsAnyItemActive, ctx))
    if not is_typing then pcall(reaper.ImGui_SetNextFrameWantCaptureKeyboard, ctx, false) end

    local canvas_open = false
    local avail_w, avail_h = 0, 0
    
    if show_canvas_window then
        pcall(reaper.ImGui_PushStyleColor, ctx, reaper.ImGui_Col_WindowBg(), COLOR_BG)
        pcall(reaper.ImGui_PushStyleVar, ctx, reaper.ImGui_StyleVar_WindowPadding(), 0.0, 0.0) 

        if global_win_x and global_win_y then 
            pcall(reaper.ImGui_SetNextWindowPos, ctx, global_win_x, global_win_y)
            global_win_x, global_win_y = nil, nil 
        end
        if not is_closing then master_alpha = 1.0 - (1.0 - math.min(1.0, (app_time - boot_time) / 0.35))^3 
        else master_alpha = 1.0 - math.min(1.0, (app_time - close_time) / 0.15)^3 end
        
        for i = #recoil_cables, 1, -1 do if (app_time - recoil_cables[i].time) > 0.25 then table.remove(recoil_cables, i) end end
        
        local win_flags = reaper.ImGui_WindowFlags_NoScrollbar() | reaper.ImGui_WindowFlags_NoTitleBar() | reaper.ImGui_WindowFlags_NoCollapse() | reaper.ImGui_WindowFlags_NoScrollWithMouse() | reaper.ImGui_WindowFlags_NoMove()
        local ok, visible, open = pcall(reaper.ImGui_Begin, ctx, 'OMM Canvas', true, win_flags)
        canvas_open = open
        
        if ok and visible then
            local ok_a, aw, ah = pcall(reaper.ImGui_GetContentRegionAvail, ctx)
            avail_w, avail_h = tonumber(aw) or 0, tonumber(ah) or 0
            
            local ok_p, raw_px, raw_py = pcall(reaper.ImGui_GetCursorScreenPos, ctx)
            p_min_x_cache, p_min_y_cache = tonumber(raw_px) or p_min_x_cache or 0.0, tonumber(raw_py) or p_min_y_cache or 0.0
            local p_min_x, p_min_y = p_min_x_cache, p_min_y_cache

            local retval, tNum, fNum, pNum = reaper.GetLastTouchedFX()
            if retval then
                local trk = tNum == 0 and reaper.GetMasterTrack(0) or reaper.GetTrack(0, tNum - 1)
                if trk then
                    local rv1, fname = reaper.TrackFX_GetFXName(trk, fNum)
                    if rv1 and not string.find(fname, "OMM") then 
                        local rv2, pname = reaper.TrackFX_GetParamName(trk, fNum, pNum)
                        if rv2 then
                            local bval = reaper.TrackFX_GetParamNormalized(trk, fNum, pNum)
                            OMM_Last_Valid_Touched = { trackNum = tNum, fxNum = fNum, paramNum = pNum, param_name = pname, base_val = bval }
                        end
                    end
                end
            end

            ProcessSignalFlow(app_dt, fullbeats, app_time)
            
            local header_cy = p_min_y + 60
            local menu_w, menu_h = 260, 36
            local menu_x, menu_y = p_min_x + (avail_w / 2) - (menu_w / 2), header_cy - (menu_h / 2)
            local sw, sh = 160, 30
            local sx = p_min_x + ((menu_x - p_min_x) / 2) - (sw / 2)
            local s_y = header_cy - (sh / 2)

            local is_ui_hovered = false
            if mouse_y <= p_min_y + 28 then is_ui_hovered = true end
            if mouse_x >= menu_x and mouse_x <= menu_x + menu_w and mouse_y >= menu_y and mouse_y <= menu_y + menu_h then is_ui_hovered = true end
            if mouse_x >= sx and mouse_x <= sx + sw and mouse_y >= s_y and mouse_y <= s_y + sh then is_ui_hovered = true end
            
            local rv_y, wheel_y = pcall(reaper.ImGui_GetMouseWheel, ctx); if not rv_y then wheel_y = 0 end
            local rv_x, wheel_x = pcall(reaper.ImGui_GetMouseWheelH, ctx); if not rv_x then wheel_x = 0 end
            
            local is_any_window_hovered = select(2, pcall(reaper.ImGui_IsWindowHovered, ctx, reaper.ImGui_HoveredFlags_AnyWindow() | reaper.ImGui_HoveredFlags_AllowWhenBlockedByActiveItem()))
            local is_canvas_bg_hovered = select(2, pcall(reaper.ImGui_IsWindowHovered, ctx)) 
            local is_ui_interaction = is_ui_hovered or (is_any_window_hovered and not is_canvas_bg_hovered)
            
            if (wheel_x ~= 0 or wheel_y ~= 0) and not drag_state.active and not is_ui_interaction then 
                scroll_x = scroll_x + (wheel_x * 40.0); scroll_y = scroll_y + (wheel_y * 40.0) 
            end
            
            if drag_state.active then 
                local ps = 600.0 * app_dt
                if mouse_x < p_min_x + 50 then scroll_x = scroll_x + ps end
                if mouse_x > p_min_x + avail_w - 50 then scroll_x = scroll_x - ps end
                if mouse_y < p_min_y + 78 then scroll_y = scroll_y + ps end
                if mouse_y > p_min_y + avail_h - 50 then scroll_y = scroll_y - ps end 
            end
            
            local bg_hovered = select(2, pcall(reaper.ImGui_IsWindowHovered, ctx)) and not is_ui_hovered
            if bg_hovered and select(2, pcall(reaper.ImGui_IsMouseDoubleClicked, ctx, 0)) then double_click_pan_active = true end
            if not select(2, pcall(reaper.ImGui_IsMouseDown, ctx, 0)) then double_click_pan_active = false end
            if select(2, pcall(reaper.ImGui_IsWindowHovered, ctx)) and (select(2, pcall(reaper.ImGui_IsMouseDragging, ctx, 2)) or (double_click_pan_active and select(2, pcall(reaper.ImGui_IsMouseDragging, ctx, 0)))) and not is_ui_hovered then 
                local rv, dx, dy = pcall(reaper.ImGui_GetMouseDelta, ctx)
                if rv and (dx ~= 0 or dy ~= 0) then scroll_x, scroll_y = scroll_x + dx, scroll_y + dy end
                pcall(reaper.ImGui_SetMouseCursor, ctx, reaper.ImGui_MouseCursor_ResizeAll())
                is_panning = true 
            else last_pan_mx, last_pan_my = nil, nil; is_panning = false end

            if bg_hovered and select(2, pcall(reaper.ImGui_IsMouseReleased, ctx, 1)) then pcall(reaper.ImGui_OpenPopup, ctx, "CanvasMenu") end
            if select(2, pcall(reaper.ImGui_BeginPopup, ctx, "CanvasMenu")) then
                pcall(reaper.ImGui_TextColored, ctx, COLOR_TEXT_DIM, "Add Node")
                pcall(reaper.ImGui_Separator, ctx)
                
                local function GetNextSpawnX()
                    local mx = 50
                    for _, n in ipairs(nodes) do
                        if n.target_x and n.target_x + (n.w or 240) + 40 > mx then mx = n.target_x + (n.w or 240) + 40 end
                    end
                    return mx
                end

                if select(2, pcall(reaper.ImGui_MenuItem, ctx, "Add LFO")) then CreateLFONode(GetNextSpawnX(), mouse_y - p_min_y - scroll_y, nil); needs_save = true end
                if select(2, pcall(reaper.ImGui_MenuItem, ctx, "Add Attenuator")) then CreateTransferCurveNode(GetNextSpawnX(), mouse_y - p_min_y - scroll_y, nil); needs_save = true end
                if select(2, pcall(reaper.ImGui_MenuItem, ctx, "Add Compressor")) then CreateCompressorNode(GetNextSpawnX(), mouse_y - p_min_y - scroll_y, nil); needs_save = true end
                if select(2, pcall(reaper.ImGui_MenuItem, ctx, "Add Macro")) then CreateMacroNode(GetNextSpawnX(), mouse_y - p_min_y - scroll_y, nil); needs_save = true end
                if select(2, pcall(reaper.ImGui_MenuItem, ctx, "Add Gain")) then CreateGainNode(GetNextSpawnX(), mouse_y - p_min_y - scroll_y, nil); needs_save = true end
                if select(2, pcall(reaper.ImGui_MenuItem, ctx, "Add Beta Lab (Sandbox)")) then CreateBetaLabNode(GetNextSpawnX(), mouse_y - p_min_y - scroll_y, nil); needs_save = true end
                pcall(reaper.ImGui_Separator, ctx)
                
                local touch_lbl = "Add Target (Touch a parameter first)"
                if OMM_Last_Valid_Touched then touch_lbl = "Add Last Touched: " .. tostring(OMM_Last_Valid_Touched.param_name) end
                
                if select(2, pcall(reaper.ImGui_MenuItem, ctx, touch_lbl)) then 
                    if OMM_Last_Valid_Touched then
                        local t_data = OMM_Last_Valid_Touched
                        local found_node = nil
                        for _, n in ipairs(nodes) do
                            if n.type == "TARGET" and n.track_idx == t_data.trackNum and n.fx_idx == t_data.fxNum and n.param_idx == t_data.paramNum then
                                found_node = n; break
                            end
                        end
                        if found_node then
                            scroll_x = -(found_node.target_x - (avail_w/2) + (found_node.w/2))
                            scroll_y = -(found_node.target_y - (avail_h/2) + (found_node.h/2))
                        else
                            local p_name = type(t_data.param_name) == "string" and t_data.param_name or "Param "..tostring(t_data.paramNum)
                            CreateTargetNode(mouse_x - p_min_x - scroll_x, mouse_y - p_min_y - scroll_y, t_data.trackNum, t_data.fxNum, t_data.paramNum, p_name, t_data.base_val, nil)
                            needs_save = true
                        end
                    else
                        CreateTargetNode(mouse_x - p_min_x - scroll_x, mouse_y - p_min_y - scroll_y, 0, 0, 0, "Param", 0.0, nil)
                        needs_save = true
                    end
                end
                pcall(reaper.ImGui_EndPopup, ctx)
            end
            
            local vdom = { headers = {}, crosshairs = {}, dropzones = {} }
            for i = #nodes, 1, -1 do 
                local n = nodes[i]
                if not n.spawn_logged then n.flash_time = app_time; n.spawn_logged = true; needs_save = true end
                if n.type == "LFO" then n.w, n.h = 560, 240
                elseif n.type == "COMPRESSOR" then n.w, n.h = 560, 240
                elseif n.type == "TRANSFER_CURVE" then n.w, n.h = (n.expanded and 480 or 240), 240
                elseif n.type == "MIDI_IN" or n.type == "GAIN" then n.w, n.h = 160, 80
                else n.w, n.h = 160, 160 end
                
                if drag_node_id == n.id then 
                    n.target_x = (mouse_x - p_min_x - scroll_x) + drag_offset_x
                    n.target_y = (mouse_y - p_min_y - scroll_y) + drag_offset_y
                    n.x, n.y = n.target_x, n.target_y 
                else n.x, n.y = DSP.Lerp(n.x, n.target_x, app_dt * 15.0), DSP.Lerp(n.y, n.target_y, app_dt * 15.0) end
                local n_sx, n_sy = math.floor(p_min_x + scroll_x + n.x), math.floor(p_min_y + scroll_y + n.y)
                table.insert(vdom.headers, {id=n.id, x=n_sx, y=n_sy, w=n.w - 60, h=HEADER_H, idx=i})
                
                if n.type ~= "TARGET" then 
                    local cx, cy = n_sx + n.w - 35, n_sy + n.h - 26 
                    if n.type == "LFO" then cx = n_sx + n.w - 74; cy = n_sy + 2 end 
                    if n.type == "GAIN" then cx = n_sx + n.w - 50; cy = n_sy + 2 end 
                    if n.type == "COMPRESSOR" then cx = n_sx + n.w - 30; cy = n_sy + 2 end
                    if n.type ~= "MIDI_IN" then table.insert(vdom.crosshairs, {id = n.id, x = cx, y = cy, w = 24, h = 20, col = n.col}) else table.insert(vdom.crosshairs, {id = n.id, x = n_sx + 106 - 12, y = n_sy + n.h - 13 - 10, w = 24, h = 20, col = n.col}) end 
                end
                if n.type == "TARGET" or n.type == "MACRO" then 
                    local ky = n_sy + HEADER_H + 50
                    if n.type == "TARGET" then ky = ky + 10 end
                    table.insert(vdom.dropzones, {id=n.id, port="IN", x=n_sx+(n.w/2), y=ky, rad=45}) 
                elseif n.type == "TRANSFER_CURVE" then table.insert(vdom.dropzones, {id=n.id, port="IN", x=n_sx+10+(n.w-60)/2, y=n_sy+HEADER_H+10+(n.h-HEADER_H-55)/2, rad=45}) 
                elseif n.type == "LFO" then local by = n_sy+n.h-60; table.insert(vdom.dropzones, {id=n.id, port="RATE", x=n_sx+215, y=by+30, rad=20}); table.insert(vdom.dropzones, {id=n.id, port="MIDI_IN", x=n_sx+40, y=by+30, rad=20}); table.insert(vdom.dropzones, {id=n.id, port="RISE", x=n_sx+320, y=by+20, rad=12}); table.insert(vdom.dropzones, {id=n.id, port="DELAY", x=n_sx+385, y=by+20, rad=12}); table.insert(vdom.dropzones, {id=n.id, port="SMOOTH", x=n_sx+450, y=by+20, rad=12}); table.insert(vdom.dropzones, {id=n.id, port="PHASE", x=n_sx+515, y=by+20, rad=12}) 
                elseif n.type == "GAIN" then table.insert(vdom.dropzones, {id=n.id, port="GAIN", x=n_sx+n.w/2, y=n_sy+n.h/2, rad=80}) end
            end

            local dl = select(2, pcall(reaper.ImGui_GetWindowDrawList, ctx))
            if current_view == "NODE" then
                if select(2, pcall(reaper.ImGui_IsMouseClicked, ctx, 0)) and not is_ui_hovered then 
                    local c_ch = false
                    for _, ch in ipairs(vdom.crosshairs) do 
                        if mouse_x >= ch.x and mouse_x <= ch.x + ch.w and mouse_y >= ch.y and mouse_y <= ch.y + ch.h then 
                            drag_state.active = true; drag_state.node_id = ch.id; drag_state.start_x = ch.x + ch.w/2; drag_state.start_y = ch.y + ch.h/2; drag_state.col = ch.col; drag_state.port_type = "OUT"; c_ch = true; break 
                        end 
                    end
                    -- Native overlapping button in NodeUI handles node drag identification instead
                end
                if drag_node_id and not select(2, pcall(reaper.ImGui_IsMouseDown, ctx, 0)) then 
                    for _, n in ipairs(nodes) do 
                        if n.id == drag_node_id then 
                            if snap_to_grid then n.target_x = math.floor(n.target_x / BASE_GRID + 0.5) * BASE_GRID; n.target_y = math.floor(n.target_y / BASE_GRID + 0.5) * BASE_GRID end
                            break 
                        end 
                    end
                    drag_node_id = nil; needs_save = true 
                end
                if drag_state.active then 
                    local snap_x, snap_y = mouse_x, mouse_y
                    local snapped_dz = nil
                    ocean_pulse_target = 0.0 
                    
                    for _, dz in ipairs(vdom.dropzones) do
                        local dist = math.sqrt((mouse_x - dz.x)^2 + (mouse_y - dz.y)^2)
                        if dist < (dz.rad * 1.5) then
                            snap_x, snap_y = dz.x, dz.y
                            snapped_dz = dz
                            ocean_pulse_target = 1.0 - (dist / (dz.rad * 1.5)) 
                            if dl then pcall(reaper.ImGui_DrawList_AddCircle, dl, dz.x, dz.y, dz.rad + 4, 0xFFFFFFFF, 0, 2.0) end
                            break
                        end
                    end
                    
                    drag_state.cur_x, drag_state.cur_y = snap_x, snap_y
                    
                    if select(2, pcall(reaper.ImGui_IsMouseReleased, ctx, 0)) then 
                        if snapped_dz then
                            local exists = false
                            for _, c in ipairs(connections) do
                                if c.from_node == drag_state.node_id and c.to_node == snapped_dz.id and c.to_port == snapped_dz.port then exists = true; break end
                            end
                            if not exists then 
                                table.insert(connections, {from_node=drag_state.node_id, to_node=snapped_dz.id, to_port=snapped_dz.port, depth=0.5, bipolar=false, bypass=false})
                                local drop_tgt = GetNodeById(snapped_dz.id)
                                if drop_tgt then drop_tgt.shockwave_time = app_time end
                                needs_save = true 
                            end
                        else
                            table.insert(recoil_cables, {x=snap_x, y=snap_y, start_x=drag_state.start_x, start_y=drag_state.start_y, col=drag_state.col, time=app_time})
                        end
                        drag_state.active = false
                    end
                else
                    ocean_pulse_target = 0.0
                end
            end 
            
            local shift_held = select(2, pcall(reaper.ImGui_IsKeyDown, ctx, reaper.ImGui_Mod_Shift()))
            -- CRITICAL FIX: The 90-pixel guillotine to protect the Header/HUD Z-order
            pcall(reaper.ImGui_SetCursorScreenPos, ctx, p_min_x, p_min_y + 90)
            if reaper.ImGui_SetNextItemAllowOverlap then pcall(reaper.ImGui_SetNextItemAllowOverlap, ctx) end
            UI.Safe_InvisibleButton(ctx, "##canvas_bg_catcher", avail_w, math.max(1.0, avail_h - 90))
            if reaper.ImGui_SetItemAllowOverlap then pcall(reaper.ImGui_SetItemAllowOverlap, ctx) end
            
            view_alpha = view_alpha + (((current_view == "MATRIX") and 1.0 or 0.0) - view_alpha) * (app_dt * 35.0)
            local n_a, m_a = math.max(0, 1.0 - view_alpha), math.max(0, view_alpha)

            if n_a > 0.001 and dl then 
                for y = -BASE_GRID, avail_h + BASE_GRID, BASE_GRID do 
                    for x = -BASE_GRID, avail_w + BASE_GRID, BASE_GRID do 
                        pcall(reaper.ImGui_DrawList_AddCircleFilled, dl, p_min_x + x + math.fmod(scroll_x, BASE_GRID), p_min_y + y + math.fmod(scroll_y, BASE_GRID), 1.5, COLOR_GRID & 0xFFFFFF00 | math.floor(0xFF * n_a * master_alpha)) 
                    end 
                end 
            end

            ocean_pulse_alpha = (ocean_pulse_alpha or 0.0) + (((ocean_pulse_target or 0.0) - (ocean_pulse_alpha or 0.0)) * app_dt * 10.0)
            local ocean_render_alpha = math.max(m_a, ocean_pulse_alpha)

            if ocean_render_alpha > 0.001 and dl and not eco_mode then
                for y = 0, math.floor(avail_h), 40 do
                    for x = 0, math.floor(avail_w), 20 do
                        local nx = p_min_x + x
                        local ny = p_min_y + y
                        local wave1 = math.sin((x * 0.005) + app_time * 0.8) * 35
                        local wave2 = math.cos((y * 0.01) - app_time * 0.4) * 25
                        local wave3 = math.sin(((x+y) * 0.003) + app_time * 0.2) * 15
                        pcall(reaper.ImGui_DrawList_PathLineTo, dl, nx, ny + wave1 + wave2 + wave3)
                    end
                    pcall(reaper.ImGui_DrawList_PathStroke, dl, 0xFFFFFF00 | math.floor(0x1A * ocean_render_alpha * master_alpha), 0, 1.0)
                end
            end

            pcall(reaper.ImGui_PushClipRect, ctx, p_min_x, p_min_y + 28, p_min_x + avail_w, p_min_y + avail_h, true)

            UI.hovered_component = nil -- CLEAR THE GUARD EVERY FRAME

            -- Hover Guard for crosshairs and dropzones
            for _, ch in ipairs(vdom.crosshairs) do
                if mouse_x >= ch.x and mouse_x <= ch.x + ch.w and mouse_y >= ch.y and mouse_y <= ch.y + ch.h then
                    UI.hovered_component = "crosshair_" .. ch.id
                end
            end
            for _, dz in ipairs(vdom.dropzones) do
                local dist = math.sqrt((mouse_x - dz.x)^2 + (mouse_y - dz.y)^2)
                if dist <= (dz.rad or 45) then
                    UI.hovered_component = "dropzone_" .. dz.id .. "_" .. (dz.port or "")
                end
            end

            local env = {
                p_min_x = p_min_x, p_min_y = p_min_y, scroll_x = scroll_x, scroll_y = scroll_y,
                mouse_x = mouse_x, mouse_y = mouse_y, app_dt = app_dt, app_time = app_time,
                eco_mode = eco_mode, act_a = master_alpha, drag_node_id = drag_node_id, is_ui_hovered = is_ui_hovered, edit_mode = UI.edit_mode,
                filter_layer = UI.filter_layer,
                locked_layer = UI.locked_layer,
                shift_held = shift_held, HEADER_H = HEADER_H, COLOR_NODE_BG = COLOR_NODE_BG,
                COLOR_BORDER = COLOR_BORDER, COLOR_TEXT = COLOR_TEXT, COLOR_TEXT_DIM = COLOR_TEXT_DIM,
                COLOR_ACCENT = COLOR_ACCENT, COLOR_LFO_BOTTOM = COLOR_LFO_BOTTOM, COLOR_GRID = COLOR_GRID,
                COLOR_ZONE_BG = COLOR_ZONE_BG, COLOR_TRACK_BG = COLOR_TRACK_BG, GetNodeById = GetNodeById,
                BakeWavetable = BakeWavetable, DeepCopy = DeepCopy, mode_names = mode_names,
                dir_names = dir_names, preset_names = preset_names, lfo_presets = lfo_presets, mseg_speeds = mseg_speeds,
                DEV_MODE = DEV_MODE, active_dev_module = active_dev_module, palette = palette
            }

            if n_a > 0.01 and dl then
                local ns = NodeUI.DrawAllNodes(ctx, dl, nodes, connections, env, UI, DSP)
                if ns then needs_save = true end

                if env.drag_node_id and env.drag_node_id ~= drag_node_id then
                    local active_drag_id = env.drag_node_id
                    for idx, n in ipairs(nodes) do
                        if n.id == active_drag_id then
                            drag_node_id = active_drag_id
                            drag_offset_x = n.target_x - (mouse_x - p_min_x - scroll_x)
                            drag_offset_y = n.target_y - (mouse_y - p_min_y - scroll_y)
                            table.remove(nodes, idx)
                            table.insert(nodes, n)
                            break
                        end
                    end
                end

                local function DrawPremiumCable(sx, sy, ex, ey, col, a)
                    local dist_x = math.abs(ex - sx)
                    local sag = math.max(20, dist_x * 0.3)
                    if ex < sx then sag = sag + (sx - ex) * 0.4 end 
                    local p1x, p1y = sx + 40, sy
                    local p2x, p2y = ex - 40, ey + sag
                    pcall(reaper.ImGui_DrawList_AddBezierCubic, dl, sx, sy, p1x, p1y, p2x, p2y, ex, ey, col & 0xFFFFFF00 | math.floor(0x33 * a), 8.0)
                    pcall(reaper.ImGui_DrawList_AddBezierCubic, dl, sx, sy, p1x, p1y, p2x, p2y, ex, ey, col & 0xFFFFFF00 | math.floor(0xAA * a), 3.0)
                    pcall(reaper.ImGui_DrawList_AddBezierCubic, dl, sx, sy, p1x, p1y, p2x, p2y, ex, ey, 0xFFFFFFFF & 0xFFFFFF00 | math.floor(0xFF * a), 1.0)
                end

                local check_alt = reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Key_LeftAlt()) or reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Key_RightAlt())
                if check_alt then
                    for _, c in ipairs(connections) do
                        local sx, sy, ex, ey
                        for _, ch in ipairs(vdom.crosshairs) do if ch.id == c.from_node then sx, sy = ch.x + ch.w/2, ch.y + ch.h/2; break end end
                        for _, dz in ipairs(vdom.dropzones) do if dz.id == c.to_node and dz.port == c.to_port then ex, ey = dz.x, dz.y; break end end
                        if sx and sy and ex and ey then
                            local c_col = 0x555555FF; local src_n = GetNodeById(c.from_node)
                            if src_n and not c.bypass then c_col = src_n.col or COLOR_ACCENT end
                            DrawPremiumCable(sx, sy, ex, ey, c_col, master_alpha * n_a * 0.4)
                        end
                    end
                end
                
                for i = #recoil_cables, 1, -1 do
                    local rc = recoil_cables[i]; local t = (app_time - rc.time) / 0.25
                    if t <= 1.0 then
                        local ease_t = 1.0 - (1.0 - t)^3
                        local cur_x = rc.x + (rc.start_x - rc.x) * ease_t
                        local cur_y = rc.y + (rc.start_y - rc.y) * ease_t
                        DrawPremiumCable(rc.start_x, rc.start_y, cur_x, cur_y, rc.col, (1.0 - t) * master_alpha * n_a)
                    end
                end
                
                if drag_state.active then
                    DrawPremiumCable(drag_state.start_x, drag_state.start_y, drag_state.cur_x or mouse_x, drag_state.cur_y or mouse_y, drag_state.col, master_alpha * n_a)
                end
            end
            
            pcall(reaper.ImGui_PopClipRect, ctx)

            if m_a > 0.01 and dl then
                local ok_mat, mat_err = pcall(function()
                    local mat_margin = 20
                    local mx, my = p_min_x + mat_margin, p_min_y + 100
                    local mw, mh = avail_w - (mat_margin * 2), avail_h - 120
                    pcall(reaper.ImGui_DrawList_AddRect, dl, mx, my, mx + mw, my + mh, 0xFFFFFF00 | math.floor(0x1A * m_a), 6.0)
                    
                    local hy = my + 5
                    local cols = {
                        {name="SOURCE", x=10, w=140},
                        {name="AMOUNT", x=160, w=200},
                        {name="POL", x=370, w=40},
                        {name="DESTINATION", x=420, w=140},
                        {name="OUTPUT", x=570, w=200},
                        {name="BYP", x=780, w=40},
                        {name="", x=830, w=30} 
                    }
                    for _, c in ipairs(cols) do
                        local ok_txt, tw = pcall(reaper.ImGui_CalcTextSize, ctx, c.name); tw = tonumber(tw) or 0
                        UI.DrawStandardText(dl, mx + c.x + c.w/2 - tw/2, hy, c.name, COLOR_TEXT_DIM, m_a)
                    end
                    pcall(reaper.ImGui_DrawList_AddLine, dl, mx, my + 25, mx + mw, my + 25, 0xFFFFFF00 | math.floor(0x1A * m_a), 1.0)
                    
                    pcall(reaper.ImGui_SetCursorScreenPos, ctx, mx, my + 26)
                    local ok_c, vis_c = pcall(reaper.ImGui_BeginChild, ctx, "matrix_rows", mw, mh - 26, 0, reaper.ImGui_WindowFlags_AlwaysVerticalScrollbar())
                    if ok_c and vis_c then
                        local cdl = select(2, pcall(reaper.ImGui_GetWindowDrawList, ctx))
                        local ok_pos, cx = pcall(reaper.ImGui_GetCursorScreenPos, ctx)
                        cx = tonumber(cx) or 0
                        
                        local row_h = 36
                        for i = #connections, 1, -1 do
                            local conn = connections[i]
                            local ry_local = (#connections - i) * row_h
                            pcall(reaper.ImGui_SetCursorPos, ctx, 0, ry_local)
                            local ok_rpos, rx, ry = pcall(reaper.ImGui_GetCursorScreenPos, ctx)
                            rx, ry = tonumber(rx) or 0, tonumber(ry) or 0
                            
                            local bg_col = (i % 2 == 0) and 0x11111100 or 0x00000000
                            pcall(reaper.ImGui_DrawList_AddRectFilled, cdl, rx, ry, rx + mw, ry + row_h, bg_col | math.floor(0x55 * m_a))
                            
                            UI.Safe_InvisibleButton(ctx, "row_"..i, mw, row_h)
                            if reaper.ImGui_SetItemAllowOverlap then pcall(reaper.ImGui_SetItemAllowOverlap, ctx) end -- PUNCHES THE HOLE
                            if select(2, pcall(reaper.ImGui_IsItemHovered, ctx)) then
                                pcall(reaper.ImGui_DrawList_AddRectFilled, cdl, rx, ry, rx + mw, ry + row_h, 0xFFFFFF00 | math.floor(0x0A * m_a))
                            end

                            local src = GetNodeById(conn.from_node)
                            local dst = GetNodeById(conn.to_node)
                            
                            local sx, sw = rx + cols[1].x, cols[1].w
                            local src_name = src and (string.sub(src.type,1,4).." "..src.id) or "None"
                            pcall(reaper.ImGui_SetCursorScreenPos, ctx, sx, ry + 4)
                            pcall(reaper.ImGui_PushItemWidth, ctx, sw)
                            pcall(reaper.ImGui_PushStyleColor, ctx, reaper.ImGui_Col_FrameBg(), 0x111111FF)
                            if select(2, pcall(reaper.ImGui_BeginCombo, ctx, "##src"..i, src_name)) then
                                for _, n in ipairs(nodes) do
                                    if n.type == "MACRO" or n.type == "LFO" or n.type == "MIDI_IN" then
                                        local n_name = string.sub(n.type,1,4).." "..n.id
                                        if select(2, pcall(reaper.ImGui_Selectable, ctx, n_name, conn.from_node == n.id)) then conn.from_node = n.id; needs_save = true end
                                    end
                                end
                                pcall(reaper.ImGui_EndCombo, ctx)
                            end
                            pcall(reaper.ImGui_PopStyleColor, ctx, 1); pcall(reaper.ImGui_PopItemWidth, ctx)
                            
                            local am_x, am_w = rx + cols[2].x, cols[2].w
                            local depth_val = conn.depth or 0.5
                            pcall(reaper.ImGui_SetCursorScreenPos, ctx, am_x, ry + 8)
                            local s_ok, n_val = UI.DrawAttenuverterSlider(ctx, "amt"..i, depth_val, am_x, ry + 13, am_w, 10, COLOR_TRACK_BG, src and src.col or COLOR_ACCENT, cdl, m_a)
                            if s_ok then conn.depth = n_val; needs_save = true end
                            
                            local pol_x = rx + cols[3].x
                            if UI.DrawFixedTextToggleNoBorder(ctx, "pol"..i, conn.bipolar and "<->" or "->", conn.bipolar, pol_x, ry + 8, 30, 20, cdl, m_a, app_dt, COLOR_TEXT) then conn.bipolar = not conn.bipolar; needs_save = true end
                            
                            local dx, dw = rx + cols[4].x, cols[4].w
                            local dst_name = dst and (string.sub(dst.type,1,4).." "..dst.id.." ["..conn.to_port.."]") or "None"
                            pcall(reaper.ImGui_SetCursorScreenPos, ctx, dx, ry + 4)
                            pcall(reaper.ImGui_PushItemWidth, ctx, dw)
                            pcall(reaper.ImGui_PushStyleColor, ctx, reaper.ImGui_Col_FrameBg(), 0x111111FF)
                            if select(2, pcall(reaper.ImGui_BeginCombo, ctx, "##dst"..i, dst_name)) then
                                local def_ports = {TARGET={"IN"}, COMPRESSOR={"IN"}, GAIN={"GAIN"}, TRANSFER_CURVE={"IN"}, LFO={"RATE","MIDI_IN","RISE","DELAY","SMOOTH","PHASE"}}
                                for _, n in ipairs(nodes) do
                                    if def_ports[n.type] then
                                        for _, p in ipairs(def_ports[n.type]) do
                                            local n_name = string.sub(n.type,1,4).." "..n.id.." ["..p.."]"
                                            if select(2, pcall(reaper.ImGui_Selectable, ctx, n_name, conn.to_node == n.id and conn.to_port == p)) then conn.to_node = n.id; conn.to_port = p; needs_save = true end
                                        end
                                    end
                                end
                                pcall(reaper.ImGui_EndCombo, ctx)
                            end
                            pcall(reaper.ImGui_PopStyleColor, ctx, 1); pcall(reaper.ImGui_PopItemWidth, ctx)
                            
                            local out_x, out_w = rx + cols[5].x, cols[5].w
                            pcall(reaper.ImGui_DrawList_AddRectFilled, cdl, out_x, ry + 13, out_x + out_w, ry + 23, COLOR_TRACK_BG | math.floor(0xFF * m_a), 5.0)
                            if src then
                                local s_out = src.out_val or 0.0; local eff_depth = (depth_val - 0.5) * 2.0; local cx_center = out_x + (out_w / 2); local bar_col = src.col or COLOR_ACCENT
                                if conn.bipolar then
                                    s_out = (s_out * 2.0) - 1.0; local fin = s_out * eff_depth; local mw = math.abs(fin) * (out_w / 2)
                                    if fin > 0 then pcall(reaper.ImGui_DrawList_AddRectFilled, cdl, cx_center, ry + 13, cx_center + mw, ry + 23, bar_col & 0xFFFFFF00 | math.floor(0xFF * m_a), 5.0)
                                    else pcall(reaper.ImGui_DrawList_AddRectFilled, cdl, cx_center - mw, ry + 13, cx_center, ry + 23, bar_col & 0xFFFFFF00 | math.floor(0xFF * m_a), 5.0) end
                                else
                                    local fin = s_out * eff_depth
                                    if eff_depth > 0 then local mw = fin * out_w; pcall(reaper.ImGui_DrawList_AddRectFilled, cdl, out_x, ry + 13, out_x + mw, ry + 23, bar_col & 0xFFFFFF00 | math.floor(0xFF * m_a), 5.0)
                                    else local mw = math.abs(fin) * out_w; pcall(reaper.ImGui_DrawList_AddRectFilled, cdl, out_x + out_w - mw, ry + 13, out_x + out_w, ry + 23, bar_col & 0xFFFFFF00 | math.floor(0xFF * m_a), 5.0) end
                                end
                            end
                            
                            local bx = rx + cols[6].x
                            if UI.DrawFixedTextToggleNoBorder(ctx, "byp"..i, conn.bypass and "OFF" or "ON", not conn.bypass, bx, ry + 8, 30, 20, cdl, m_a, app_dt, COLOR_TEXT) then conn.bypass = not conn.bypass; needs_save = true end
                            
                            local del_x = rx + cols[7].x
                            if UI.DrawFixedTextToggleNoBorder(ctx, "del"..i, "X", false, del_x, ry + 8, 20, 20, cdl, m_a, app_dt, COLOR_TEXT) then table.remove(connections, i); needs_save = true end
                        end
                        
                        local add_vy = (#connections * row_h) + 10
                        pcall(reaper.ImGui_SetCursorPos, ctx, mw/2 - 60, add_vy)
                        pcall(reaper.ImGui_PushStyleColor, ctx, reaper.ImGui_Col_Button(), 0x333333FF)
                        if select(2, pcall(reaper.ImGui_Button, ctx, "+ Add Assignment", 120, 24)) then table.insert(connections, {from_node = 0, to_node = 0, to_port = "IN", depth = 0.5, bipolar = false, bypass = false}); needs_save = true end
                        pcall(reaper.ImGui_PopStyleColor, ctx, 1)
                    end
                    pcall(reaper.ImGui_EndChild, ctx)
                end)
                if not ok_mat then reaper.ShowConsoleMsg("OMM Matrix Render Error: " .. tostring(mat_err) .. "\n") end
            end
            if dl then
                local wx, wy = p_min_x, p_min_y; local wh = 28
                pcall(reaper.ImGui_SetCursorScreenPos, ctx, wx + 100, wy); UI.Safe_InvisibleButton(ctx, "HDZ", avail_w - 200, wh)
                if select(2, pcall(reaper.ImGui_IsItemActive, ctx)) and select(2, pcall(reaper.ImGui_IsMouseDragging, ctx, 0)) then local _, dx, dy = pcall(reaper.ImGui_GetMouseDelta, ctx); if tonumber(dx) and tonumber(dy) and (dx ~= 0 or dy ~= 0) then global_win_x, global_win_y = wx + dx, wy + dy end end
                if select(2, pcall(reaper.ImGui_BeginPopupContextItem, ctx, "header_ctx")) then if select(2, pcall(reaper.ImGui_MenuItem, ctx, "Dock to Reaper")) then pcall(reaper.ImGui_SetNextWindowDockID, ctx, ~0) end; pcall(reaper.ImGui_EndPopup, ctx) end
                pcall(reaper.ImGui_DrawList_AddRectFilledMultiColor, dl, wx, wy, wx+avail_w, wy+wh, 0x2A2A2A00 | math.floor(0xCC * master_alpha), 0x2A2A2A00 | math.floor(0xCC * master_alpha), 0x11111100 | math.floor(0x88 * master_alpha), 0x11111100 | math.floor(0x88 * master_alpha))
                local hcx = wx + 18; local th = 14; local cy_btn = wy + 14 - (th / 2); if UI.DrawFixedTextToggleNoBorder(ctx, "sb", "SAVE", false, hcx, cy_btn, 40, th, dl, master_alpha, app_dt) then SaveState() end
                local cbx = wx + avail_w - 38; pcall(reaper.ImGui_SetCursorScreenPos, ctx, cbx, cy_btn - 3); UI.Safe_InvisibleButton(ctx, "cb", 20, 20)
                if select(2, pcall(reaper.ImGui_IsItemHovered, ctx)) then pcall(reaper.ImGui_DrawList_AddCircleFilled, dl, cbx+10, cy_btn+7, 20, 0xFF000000 | math.floor(0x11 * master_alpha)); pcall(reaper.ImGui_DrawList_AddCircleFilled, dl, cbx+10, cy_btn+7, 12, 0xFF000000 | math.floor(0x33 * master_alpha)); pcall(reaper.ImGui_DrawList_AddCircleFilled, dl, cbx+10, cy_btn+7, 6, 0xFF000000 | math.floor(0x66 * master_alpha)); if select(2, pcall(reaper.ImGui_IsItemClicked, ctx)) then is_closing, close_time = true, app_time end end
                UI.DrawStandardText(dl, cbx+6, cy_btn, "X", COLOR_TEXT, master_alpha)
                if UI.DrawFixedTextToggleNoBorder(ctx, "eb", "ECO", eco_mode, cbx - 50, cy_btn, 40, th, dl, master_alpha, app_dt) then eco_mode = not eco_mode; needs_save = true end

                local menu_w, menu_h = 240, 44
                local menu_x = p_min_x + (avail_w / 2) - (menu_w / 2)
                local menu_y = p_min_y + 28 + 10
                pcall(reaper.ImGui_DrawList_AddRectFilled, dl, menu_x, menu_y, menu_x + menu_w, menu_y + menu_h, UI.ApplyAlpha(0x1A1A1AFF, master_alpha), 22.0)
                pcall(reaper.ImGui_DrawList_AddRectFilled, dl, menu_x + 3, menu_y + 3, menu_x + menu_w - 3, menu_y + menu_h - 3, UI.ApplyAlpha(0x0A0A0AFF, master_alpha), 19.0)
                pcall(reaper.ImGui_DrawList_AddRect, dl, menu_x, menu_y, menu_x + menu_w, menu_y + menu_h, UI.ApplyAlpha(0x2A2A2AFF, master_alpha), 22.0, 0, 1.0)
                
                local bw, bh, by = 110, menu_h - 8, menu_y + 4
                local target_offset = (current_view == "NODE") and 0 or (menu_w - 8 - bw)
                local t_anim = math.min(1.0, (app_time - anim_toggle_start_time) / 0.4)
                local c1, c3 = 1.70158, 2.70158; local t_1 = t_anim - 1; local spring_t = 1 + c3 * (t_1^3) + c1 * (t_1^2)
                anim_toggle_val = anim_toggle_start_val + (target_offset - anim_toggle_start_val) * spring_t
                
                local ax = menu_x + 4 + anim_toggle_val
                pcall(reaper.ImGui_DrawList_AddRectFilled, dl, ax, by, ax + bw, by + bh, UI.ApplyAlpha(0x1F1F1FFF, master_alpha), 18.0)
                pcall(reaper.ImGui_DrawList_AddRect, dl, ax, by, ax + bw, by + bh, UI.ApplyAlpha(0x00E5FFFF, master_alpha), 18.0, 0, 1.0)
                
                pcall(reaper.ImGui_SetCursorScreenPos, ctx, menu_x + 4, by); UI.Safe_InvisibleButton(ctx, "nn", bw, bh)
                if select(2, pcall(reaper.ImGui_IsItemActive, ctx)) then pcall(reaper.ImGui_DrawList_AddRectFilled, dl, menu_x+6, by+2, menu_x+2+bw, by+bh-2, UI.ApplyAlpha(0x050505FF, master_alpha), 18.0) end
                if select(2, pcall(reaper.ImGui_IsItemClicked, ctx)) and current_view ~= "NODE" then current_view = "NODE"; anim_toggle_start_val = anim_toggle_val; anim_toggle_start_time = app_time end
                local _, ntw, nth = pcall(reaper.ImGui_CalcTextSize, ctx, "NODE"); ntw = tonumber(ntw) or 0; nth = tonumber(nth) or 0
                UI.DrawSharpGlowingText(dl, menu_x + 4 + bw/2 - ntw/2, by + bh/2 - nth/2, "NODE", (current_view == "NODE") and COLOR_TEXT or COLOR_TEXT_DIM, master_alpha)
                
                pcall(reaper.ImGui_SetCursorScreenPos, ctx, menu_x + menu_w - 4 - bw, by); UI.Safe_InvisibleButton(ctx, "nm", bw, bh)
                if select(2, pcall(reaper.ImGui_IsItemActive, ctx)) then pcall(reaper.ImGui_DrawList_AddRectFilled, dl, menu_x+menu_w-2-bw, by+2, menu_x+menu_w-6, by+bh-2, UI.ApplyAlpha(0x050505FF, master_alpha), 18.0) end
                if select(2, pcall(reaper.ImGui_IsItemClicked, ctx)) and current_view ~= "MATRIX" then current_view = "MATRIX"; anim_toggle_start_val = anim_toggle_val; anim_toggle_start_time = app_time end
                local _, mtw, mth = pcall(reaper.ImGui_CalcTextSize, ctx, "MATRIX"); mtw = tonumber(mtw) or 0; mth = tonumber(mth) or 0
                UI.DrawSharpGlowingText(dl, menu_x + menu_w - 4 - bw + bw/2 - mtw/2, by + bh/2 - mth/2, "MATRIX", (current_view == "MATRIX") and COLOR_TEXT or COLOR_TEXT_DIM, master_alpha)
                
                local sub_w, sub_h = 160, 30; local space_left = (menu_x - p_min_x); local sub_x = p_min_x + (space_left / 2) - (sub_w / 2); local sub_y = menu_y + 7
                pcall(reaper.ImGui_DrawList_AddRectFilled, dl, sub_x, sub_y, sub_x + sub_w, sub_y + sub_h, UI.ApplyAlpha(0x1A1A1AFF, master_alpha * 0.02), 15.0)
                pcall(reaper.ImGui_DrawList_AddRect, dl, sub_x, sub_y, sub_x + sub_w, sub_y + sub_h, UI.ApplyAlpha(0x2A2A2AFF, master_alpha * 0.02), 15.0, 0, 1.0)
                local cwn = workspaces[active_ws_idx] and workspaces[active_ws_idx].name or "Canvas 1"
                local _, ctw, cth = pcall(reaper.ImGui_CalcTextSize, ctx, cwn); ctw = tonumber(ctw) or 0; cth = tonumber(cth) or 0
                local text_x = sub_x + (sub_w/2) - ctw/2; local text_y = sub_y + (sub_h/2) - cth/2
                pcall(reaper.ImGui_DrawList_AddText, dl, text_x+1, text_y+1, 0x00000000 | math.floor(0xFF * master_alpha), cwn)
                UI.DrawStandardText(dl, text_x, text_y, cwn, COLOR_TEXT_DIM, master_alpha)

                pcall(reaper.ImGui_SetCursorScreenPos, ctx, sub_x, sub_y); UI.Safe_InvisibleButton(ctx, "canvas_dropdown_btn", sub_w, sub_h)
                if select(2, pcall(reaper.ImGui_IsItemClicked, ctx)) then pcall(reaper.ImGui_OpenPopup, ctx, "WH") end
                if select(2, pcall(reaper.ImGui_IsItemHovered, ctx)) then pcall(reaper.ImGui_SetMouseCursor, ctx, reaper.ImGui_MouseCursor_Hand()) end
                
                local pop_h_target = math.min(avail_h * 0.7, (#workspaces * 135) + 60)
                pcall(reaper.ImGui_SetNextWindowPos, ctx, sx + (sw/2) - 110, s_y + sh + 10)
                pcall(reaper.ImGui_SetNextWindowSize, ctx, 220, pop_h_target)
                pcall(reaper.ImGui_PushStyleColor, ctx, reaper.ImGui_Col_PopupBg(), 0x00000000)
                pcall(reaper.ImGui_PushStyleVar, ctx, reaper.ImGui_StyleVar_WindowPadding(), 0.0, 0.0) 
                
                if select(2, pcall(reaper.ImGui_BeginPopup, ctx, "WH")) then
                    local _, px, py = pcall(reaper.ImGui_GetWindowPos, ctx); local _, pw, ph = pcall(reaper.ImGui_GetWindowSize, ctx); local pdl = select(2, pcall(reaper.ImGui_GetWindowDrawList, ctx))
                    px = tonumber(px) or 0; py = tonumber(py) or 0; pw = tonumber(pw) or 220; ph = tonumber(ph) or pop_h_target
                    pcall(reaper.ImGui_DrawList_AddRectFilled, pdl, px+5, py+5, px+pw+5, py+ph+5, 0x00000088, 12.0)
                    pcall(reaper.ImGui_DrawList_AddRectFilledMultiColor, pdl, px, py, px+pw, py+ph, 0x14181CE6, 0x0A1C24E6, 0x030303E6, 0x080808E6)
                    pcall(reaper.ImGui_DrawList_AddRect, pdl, px, py, px+pw, py+ph, 0xFFFFFF15, 12.0, 0, 1.0) 
                    pcall(reaper.ImGui_PushStyleColor, ctx, reaper.ImGui_Col_ChildBg(), 0x00000000)
                    pcall(reaper.ImGui_BeginChild, ctx, "hs", pw, ph, 0, reaper.ImGui_WindowFlags_NoScrollbar())
                    local _, scx, scy = pcall(reaper.ImGui_GetCursorScreenPos, ctx); scx = tonumber(scx) or 0; scy = tonumber(scy) or 0
                    local mapw, maph, oy = 160, 98, 30
                    
                    for i, ws in ipairs(workspaces) do
                        local mpx, mpy = scx + 30, scy + oy
                        pcall(reaper.ImGui_SetCursorScreenPos, ctx, mpx, mpy); UI.Safe_InvisibleButton(ctx, "wm"..i, mapw, maph)
                        if select(2, pcall(reaper.ImGui_IsItemHovered, ctx)) then pcall(reaper.ImGui_SetMouseCursor, ctx, reaper.ImGui_MouseCursor_Hand()) end
                        if select(2, pcall(reaper.ImGui_IsItemClicked, ctx)) then active_ws_idx = i; nodes = workspaces[active_ws_idx].nodes; connections = workspaces[active_ws_idx].connections; pcall(reaper.ImGui_CloseCurrentPopup, ctx) end
                        local is_act = (active_ws_idx == i); local text_a = is_act and 1.0 or 0.5
                        UI.DrawStandardText(pdl, mpx, mpy - 22, ws.name, COLOR_TEXT, text_a)
                        if is_act then pcall(reaper.ImGui_DrawList_AddRectFilled, pdl, scx + 12, mpy, scx + 15, mpy + maph, COLOR_ACCENT, 2.0) end
                        pcall(reaper.ImGui_DrawList_AddRectFilled, pdl, mpx, mpy, mpx+mapw, mpy+maph, 0x050505AA, 4.0)
                        pcall(reaper.ImGui_DrawList_AddRect, pdl, mpx, mpy, mpx+mapw, mpy+maph, 0xFFFFFF15, 4.0)
                        
                        if ws.nodes and #ws.nodes > 0 then
                            local min_n_x, min_n_y, max_n_x, max_n_y = math.huge, math.huge, -math.huge, -math.huge
                            for _, mn in ipairs(ws.nodes) do
                                local nx, ny = tonumber(mn.x) or 0, tonumber(mn.y) or 0
                                min_n_x = math.min(min_n_x, nx); min_n_y = math.min(min_n_y, ny)
                                max_n_x = math.max(max_n_x, nx + mn.w); max_n_y = math.max(max_n_y, ny + mn.h)
                            end
                            local pad = 15; local bw = math.max(100, max_n_x - min_n_x); local bh = math.max(100, max_n_y - min_n_y)
                            local scale = math.min((mapw - pad*2) / bw, (maph - pad*2) / bh)
                            local off_x = mpx + pad + ((mapw - pad*2) - (bw * scale)) / 2
                            local off_y = mpy + pad + ((maph - pad*2) - (bh * scale)) / 2
                            pcall(reaper.ImGui_PushClipRect, ctx, mpx, mpy, mpx+mapw, mpy+maph, true)
                            for _, mn in ipairs(ws.nodes) do
                                local nx = off_x + ((tonumber(mn.x) or 0) - min_n_x) * scale
                                local ny = off_y + ((tonumber(mn.y) or 0) - min_n_y) * scale
                                local nw = math.max(2, mn.w * scale); local nh = math.max(2, mn.h * scale)
                                pcall(reaper.ImGui_DrawList_AddRectFilled, pdl, nx, ny, nx+nw, ny+nh, 0xFFFFFF10, 2.0)
                                pcall(reaper.ImGui_DrawList_AddRect, pdl, nx, ny, nx+nw, ny+nh, mn.col & 0xFFFFFF00 | math.floor(0xFF * (is_act and 0.8 or 0.4)), 2.0, 0, 1.0)
                            end
                            if is_act then
                                local v_sx = off_x + ((-scroll_x - min_n_x) * scale)
                                local v_sy = off_y + ((-scroll_y - min_n_y) * scale)
                                local v_ex = v_sx + (avail_w * scale); local v_ey = v_sy + (avail_h * scale)
                                pcall(reaper.ImGui_DrawList_AddRectFilled, pdl, v_sx, v_sy, v_ex, v_ey, 0xFFFFFF08)
                                pcall(reaper.ImGui_DrawList_AddRect, pdl, v_sx, v_sy, v_ex, v_ey, 0xFFFFFF44, 0.0, 0, 1.0)
                            end
                            pcall(reaper.ImGui_PopClipRect, ctx)
                        end
                        oy = oy + maph + 40
                    end
                    
                    pcall(reaper.ImGui_SetCursorScreenPos, ctx, scx + 30, scy + oy)
                    pcall(reaper.ImGui_PushStyleColor, ctx, reaper.ImGui_Col_Button(), 0x1A1A1AFF)
                    if select(2, pcall(reaper.ImGui_Button, ctx, "+ New Canvas", mapw, 30)) then 
                        table.insert(workspaces, {name = "Canvas " .. (#workspaces + 1), nodes = {}, connections = {}})
                        active_ws_idx = #workspaces; nodes = workspaces[active_ws_idx].nodes; connections = workspaces[active_ws_idx].connections
                        needs_save = true; pcall(reaper.ImGui_CloseCurrentPopup, ctx) 
                    end
                    pcall(reaper.ImGui_PopStyleColor, ctx, 1)
                    
                    local _, syv = pcall(reaper.ImGui_GetScrollY, ctx); local _, smax = pcall(reaper.ImGui_GetScrollMaxY, ctx); syv, smax = tonumber(syv) or 0, tonumber(smax) or 0
                    if smax > 0 then 
                        local sr = syv / smax; local barh = math.max(20, (ph / (smax + ph)) * ph); local bary = py + (sr * (ph - barh)); local is_scroll_hov = (mouse_x > px + pw - 15 and mouse_y > py and mouse_y < py + ph) and not is_ui_hovered
                        local barw = is_scroll_hov and 6 or 2; local barcol = is_scroll_hov and COLOR_ACCENT or 0xFFFFFF33
                        pcall(reaper.ImGui_DrawList_AddRectFilled, pdl, px + pw - 2 - barw, bary, px + pw - 2, bary + barh, barcol, 4.0) 
                    end
                    pcall(reaper.ImGui_EndChild, ctx); pcall(reaper.ImGui_PopStyleColor, ctx, 1); pcall(reaper.ImGui_EndPopup, ctx)
                end
                pcall(reaper.ImGui_PopStyleVar, ctx, 1); pcall(reaper.ImGui_PopStyleColor, ctx, 1)
            end
        end
        pcall(reaper.ImGui_End, ctx)
        pcall(reaper.ImGui_PopStyleColor, ctx, 1); pcall(reaper.ImGui_PopStyleVar, ctx, 1)
    end
    
    local dev_state = { 
        sel_track = sel_track, 
        sel_track_guid = sel_track and reaper.GetTrackGUID(sel_track) or nil,
        show_canvas = show_canvas_window,
        nodes = nodes,
        connections = connections,
        pending_fx_move = nil,
        jsfx_cache = jsfx_deploy_cache, 
        GetNodeById = GetNodeById,
        DeleteNode = DeleteNode,
        env = { 
            p_min_x = 0, p_min_y = 0, scroll_x = 0, scroll_y = 0, 
            mouse_x = mouse_x, mouse_y = mouse_y, app_dt = app_dt, app_time = app_time,
            eco_mode = eco_mode, act_a = 1.0, drag_node_id = nil, is_ui_hovered = false,
            filter_layer = UI.filter_layer,
            locked_layer = UI.locked_layer,
            shift_held = select(2, pcall(reaper.ImGui_IsKeyDown, ctx, reaper.ImGui_Mod_Shift())), 
            HEADER_H = HEADER_H, COLOR_NODE_BG = COLOR_NODE_BG,
            COLOR_BORDER = COLOR_BORDER, COLOR_TEXT = COLOR_TEXT, COLOR_TEXT_DIM = COLOR_TEXT_DIM,
            COLOR_ACCENT = COLOR_ACCENT, COLOR_LFO_BOTTOM = COLOR_LFO_BOTTOM, COLOR_GRID = COLOR_GRID,
            COLOR_ZONE_BG = COLOR_ZONE_BG, COLOR_TRACK_BG = COLOR_TRACK_BG, GetNodeById = GetNodeById,
            BakeWavetable = BakeWavetable, DeepCopy = DeepCopy, mode_names = mode_names,
            dir_names = dir_names, preset_names = preset_names, lfo_presets = lfo_presets, mseg_speeds = mseg_speeds,
            DEV_MODE = DEV_MODE, active_dev_module = active_dev_module, palette = palette,
            Router = Router
        },
        NodeUI = NodeUI,
        DSP = DSP,
        UI = UI,
        AddNode = function(type_name)
            PushLaneUndoState()
            local safe_h = avail_h > 100 and avail_h or 600; local cy = -scroll_y + (safe_h / 2) - 80
            local function GetNextSpawnX()
                local mx = 50
                for _, n in ipairs(nodes) do if n.target_x and n.target_x + (n.w or 240) + 40 > mx then mx = n.target_x + (n.w or 240) + 40 end end
                return mx
            end
            local cx = GetNextSpawnX(); local guid = sel_track and reaper.GetTrackGUID(sel_track) or nil
            if type_name == "LFO" then CreateLFONode(cx, cy, guid)
            elseif type_name == "TRANSFER_CURVE" then CreateTransferCurveNode(cx, cy, guid)
            elseif type_name == "GAIN" then CreateGainNode(cx, cy, guid)
            elseif type_name == "COMPRESSOR" then CreateCompressorNode(cx, cy, guid)
            elseif type_name == "BETA_LAB" then CreateBetaLabNode(cx, cy, guid) end
        end,
        LinkNode = function(id) local n = GetNodeById(id); if n and sel_track then n.lane_guid = reaper.GetTrackGUID(sel_track); needs_save = true end end
    }
    
    local ok_dl, ns2, sc_update, l_op = pcall(DeviceLane.Draw, ctx, dev_state, UI)
    if ok_dl then
        if ns2 then needs_save = true end
        show_canvas_window = sc_update
        DEV_MODE = dev_state.env.DEV_MODE
    end

    -- ==========================================
    -- STANDALONE DEVELOPMENT INSPECTOR RUN TIME
    -- ==========================================
    if DEV_MODE then
        local wb_env = {
            DEV_MODE = DEV_MODE,
            palette = palette,
            palette_engine = Palette, -- Injecting the engine reference here
            app_dt = app_dt,
            act_a = master_alpha,
            NodeUI = NodeUI,
            Router = Router,
            edit_mode = UI.edit_mode,
            filter_layer = UI.filter_layer,
            locked_layer = UI.locked_layer
        }
        UI.DrawWorkbenchWindow(ctx, wb_env)
    end

    if dev_state.pending_fx_move and sel_track then
        reaper.TrackFX_CopyToTrack(sel_track, dev_state.pending_fx_move.from, sel_track, dev_state.pending_fx_move.to, true)
        needs_save = true
    end

    if needs_save then SaveState() end
    if (canvas_open or l_op) and not (is_closing and master_alpha <= 0.05) then reaper.defer(loop) end
end

reaper.defer(loop)
