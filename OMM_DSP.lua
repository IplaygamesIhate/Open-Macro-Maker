-- ==============================================================================
-- OMM_DSP.lua (The Audio & Math Engine)
-- Protocol Zero: Pointer Arithmetic, Dark Silicon & Safe RAM Allocation
-- ==============================================================================
local DSP = {}

function DSP.InitGMEM() reaper.gmem_attach("OMM_Shared") end
function DSP.Lerp(a, b, t) return a + (b - a) * t end
function DSP.ExpDecay(a, b, dt, speed) return a + (b - a) * math.min(1.0, dt * speed) end
function DSP.EaseOutBack(t) local c1, c3 = 1.70158, 2.70158; local t_1 = t - 1; return 1 + c3 * (t_1^3) + c1 * (t_1^2) end
function DSP.ApplyCurve(t, curve) if math.abs(curve) < 0.01 then return t end; return (math.exp(curve * t) - 1) / (math.exp(curve) - 1) end

function DSP.GetMSEGValue(node, phase)
    local n_arr = node.mseg_nodes
    if not n_arr or #n_arr == 0 then return 0.5 end
    if phase <= n_arr[1].x then return n_arr[1].y end
    if phase >= n_arr[#n_arr].x then return n_arr[#n_arr].y end
    for i = 1, #n_arr - 1 do
        local n1 = n_arr[i]
        local n2 = n_arr[i+1]
        if phase >= n1.x and phase <= n2.x then
            local t = (phase - n1.x) / (n2.x - n1.x)
            t = DSP.ApplyCurve(t, n1.curve or 0.0)
            return DSP.Lerp(n1.y, n2.y, t)
        end
    end
    return 0.5
end

-- ==========================================
-- THE MEMORY ALLOCATOR & SYNC (Pointer Arithmetic)
-- ==========================================
function DSP.PushStateToMemory(n)
    if not n or not n.gmem_slot then return end
    
    -- RULE 1: Every module gets an isolated 2,048-slot chunk in RAM
    local base_mem = 100000 + (n.gmem_slot * 2048)
    
    -- THE DARK SILICON BLOCK (Universal Utilities available to every plugin)
    reaper.gmem_write(base_mem + 98, n.gain_in or n.in_gain or 0.0)   -- Input Trim (dB)
    reaper.gmem_write(base_mem + 99, n.pan or 0.0)                    -- Pan (-1 to 1)
    reaper.gmem_write(base_mem + 100, n.gain_out or n.out_gain or 0.0) -- Output Trim (dB)
    reaper.gmem_write(base_mem + 101, (n.mix and n.mix > 1.0) and n.mix or ((n.mix or 1.0) * 100.0)) -- Mix (0 to 100)

    -- THE POLYMORPHIC ROUTING (Module Specifics)
    if n.type == "COMPRESSOR" then
        -- Direct pass-through for the 7 authentic algorithms
        local algo_num = tonumber(n.algo) or 0
        if type(n.algo) == "string" then
            -- Legacy fallback handling just in case
            if n.algo == "FET" then algo_num = 1
            elseif n.algo == "OPTO" then algo_num = 6
            elseif n.algo == "VCA" then algo_num = 2
            end
        end
        reaper.gmem_write(base_mem + 0, algo_num)
        reaper.gmem_write(base_mem + 1, n.thresh or -18.0)
        reaper.gmem_write(base_mem + 2, n.ratio or 4.0)
        reaper.gmem_write(base_mem + 3, n.knee or 6.0)
        reaper.gmem_write(base_mem + 4, n.attack or 15.0)
        reaper.gmem_write(base_mem + 5, n.release or 150.0)
        reaper.gmem_write(base_mem + 6, n.mode_exp and 1 or 0)
        reaper.gmem_write(base_mem + 7, n.ratio_exp or 2.0)
    elseif n.type == "LFO" then
        reaper.gmem_write(base_mem + 0, 100) -- Module type marker
        reaper.gmem_write(base_mem + 1, n.rate_hz or 1.0)
        reaper.gmem_write(base_mem + 2, n.depth or 1.0)
        reaper.gmem_write(base_mem + 3, n.phase_offset or 0.0)
        reaper.gmem_write(base_mem + 4, n.smooth or 0.0)
        reaper.gmem_write(base_mem + 5, n.delay or 0.0)
        reaper.gmem_write(base_mem + 6, n.rise or 0.0)
        reaper.gmem_write(base_mem + 7, n.sync and 1 or 0)
    elseif n.type == "GAIN" then
        reaper.gmem_write(base_mem + 0, 200) -- Module type marker
        reaper.gmem_write(base_mem + 1, n.val or 0.833)
        reaper.gmem_write(base_mem + 2, n.pan or 0.5)
        local cur_db = -60.0 + ((n.val or 0.833) * 72.0)
        reaper.gmem_write(base_mem + 3, cur_db)
    end
end

-- ==========================================
-- THE DAW BRIDGES (JSFX Spawners)
-- ==========================================
local JSFX_VERSION = "// Version: v109.2"

function DSP.EnsureJSFXExists()
    local rp = reaper.GetResourcePath(); reaper.RecursiveCreateDirectory(rp .. "/Effects/OpenMacroMaker", 0)
    local function WriteFX(name, code_str)
        local path = rp .. "/Effects/OpenMacroMaker/" .. name
        local f = io.open(path, "r"); local content = f and f:read("*all") or ""; if f then f:close() end
        if not string.find(content, JSFX_VERSION, 1, true) then f = io.open(path, "w"); if f then f:write(code_str); f:close() end end
    end
    
    local hub_code = "desc:OMM Track Hub v108.5\noptions:gmem=OMM_Shared\n" .. JSFX_VERSION .. "\nin_pin:left input\nin_pin:right input\nout_pin:left output\nout_pin:right output\nslider1:0<0,128,1>-Track ID\n"
    for i=1, 16 do hub_code = hub_code .. string.format("slider%d:0<0,1,0.000001>Ch %d Out\n", i+1, i) end
    hub_code = hub_code .. [[
@init
smooth_coeff = 1.0 - exp(-1.0 / (0.015 * srate)); phases = 200; memset(300, 0, 16); memset(400, 0, 16); 
@block
while (midirecv(offset, msg1, msg2, msg3)) ( stat = msg1 & 0xF0; channel = msg1 & 0x0F; stat == 0x90 && msg3 > 0 ? ( 300[channel] += 1; 400[channel] += 1; gmem[20000 + channel] = 1.0; gmem[20016 + channel] = 400[channel]; ) : stat == 0x80 || (stat == 0x90 && msg3 == 0) ? ( 300[channel] = max(0, 300[channel] - 1); 300[channel] == 0 ? gmem[20000 + channel] = 0.0; ); midisend(offset, msg1, msg2, msg3); );
@sample
i = 0; loop(16, mode = gmem[i * 10 + 0]; base_val = gmem[i * 10 + 1]; depth_val = gmem[i * 10 + 2]; curve_off = gmem[i * 10 + 3]; lfo_off  = gmem[i * 10 + 4]; input_v  = gmem[i * 10 + 5]; active   = gmem[i * 10 + 6]; active == 1 ? ( sig = 0; mode == 0 ? ( phases[i] += (input_v - phases[i]) * smooth_coeff; sig = phases[i]; ) : mode == 1 ? ( freq = input_v; phases[i] += (freq / srate); phases[i] >= 1.0 ? phases[i] -= 1.0; phases[i] < 0.0 ? phases[i] += 1.0; idx = phases[i] * 1023; idx_int = floor(idx); frac = idx - idx_int; valA = gmem[lfo_off + idx_int]; valB = gmem[lfo_off + (idx_int + 1) % 1024]; sig = valA + (valB - valA) * frac; ) : ( sig = input_v; phases[i] = sig; ); curve_off > 0 ? ( c_idx = sig * 1023; c_idx = max(0, min(1023, c_idx)); c_idx_int = floor(c_idx); c_frac = c_idx - c_idx_int; c_valA = gmem[curve_off + c_idx_int]; c_valB = gmem[curve_off + min(1023, c_idx_int + 1)]; sig = c_valA + (c_valB - c_valA) * c_frac; ); out_val = base_val + (sig * depth_val); out_val = min(max(out_val, 0.0), 1.0); ) : ( out_val = base_val; );
]]
    for i=1, 16 do hub_code = hub_code .. string.format("    i == %d ? slider%d = out_val;\n", i-1, i+2) end
    hub_code = hub_code .. "    i += 1;\n);\nspl0=spl0; spl1=spl1;\n"
    
    WriteFX("OMM_Hybrid_Hub.jsfx", hub_code)
    
    WriteFX("OMM_Gain.jsfx", "desc:OMM Gain (Audio Utility) v108.5\noptions:gmem=OMM_Shared\n" .. JSFX_VERSION .. "\nin_pin:left input\nin_pin:right input\nout_pin:left output\nout_pin:right output\nslider1:0<0,128,1>-Node ID\n@init\nsmooth_coeff = 1.0 - exp(-1.0 / (0.005 * srate)); cur_gain = 1.0;\n@block\nnode_idx = 30000 + (slider1 * 2); target_db = gmem[node_idx]; target_amp = 10 ^ (target_db / 20); target_amp = target_db <= -59.9 ? 0.0 : target_amp;\n@sample\ncur_gain += (target_amp - cur_gain) * smooth_coeff;\nspl0 = spl0 * cur_gain; spl1 = spl1 * cur_gain;\n")
    
    WriteFX("OMM_Modulator.jsfx", "desc:OMM Modulator (Routing Utility) v108.5\noptions:gmem=OMM_Shared\n" .. JSFX_VERSION .. "\nin_pin:left input\nin_pin:right input\nout_pin:left output\nout_pin:right output\nslider1:0<0,1000,1>-Node ID\n@init\n@sample\nspl0=spl0; spl1=spl1;\n")
    
    local comp_code = "desc:OMM Compressor (Authentic Engine)\noptions:gmem=OMM_Shared\n" .. JSFX_VERSION .. "\nin_pin:left input\nin_pin:right input\nout_pin:left output\nout_pin:right output\nslider1:instance_id=0<0,100,1>-Instance ID\n" .. [[
@init
  ext_noinit = 1;
  // --- LOOK AHEAD BUFFER (For Saike Limiter) ---
  delay_max_samples = srate; 
  delay_buf_L = 0;           // Local memory pointer 0
  delay_buf_R = srate + 1;   // Local memory pointer srate+1
  delay_pos = 0;
  
  // --- ENVELOPE STATES ---
  env = 0; last_gr_db = 0; last_gr = 1.0; rel_fast = 0; rel_slow = 0;
  
  // --- METERING STATES ---
  buf_counter = 0; max_in = 0.0; gr_peak = 1.0;

@sample
  // ===============================================
  // 1. READ FROM OMM LUA IDE (GMEM)
  // ===============================================
  base_mem = 100000 + (instance_id * 2048);
  algo      = gmem[base_mem + 0];
  thresh_db = gmem[base_mem + 1];
  ratio     = max(1.0, gmem[base_mem + 2]);
  knee_db   = max(0.001, gmem[base_mem + 3]);
  att_ms    = max(0.001, gmem[base_mem + 4]);
  rel_ms    = max(0.001, gmem[base_mem + 5]);
  mix       = max(0.0, min(1.0, gmem[base_mem + 101] / 100));
  
  in_drive_lin = 10 ^ (gmem[base_mem + 98] / 20);
  trim_lin     = 10 ^ (gmem[base_mem + 100] / 20);

  // Write to delay line (Always running for Algo 5)
  delay_buf_L[delay_pos] = spl0;
  delay_buf_R[delay_pos] = spl1;

  in_L = spl0 * in_drive_lin; 
  in_R = spl1 * in_drive_lin;
  
  det_val = max(abs(in_L), abs(in_R));
  det_db = 20 * log10(max(0.00001, det_val));
  
  // ===============================================
  // 2. THE AUTHENTIC ALGORITHM SWITCH
  // ===============================================
  
  algo == 0 ? (
      // ALGO 0: REACOMP (Justin Frankel - Clean VCA Feed-Forward)
      att_c = 1.0 - exp(-1.0 / (srate * (att_ms / 1000)));
      rel_c = 1.0 - exp(-1.0 / (srate * (rel_ms / 1000)));
      
      det_val > env ? env += att_c * (det_val - env) : env += rel_c * (det_val - env);
      env_db = 20 * log10(max(0.00001, env));
      
      over = env_db - thresh_db;
      gr_db = over > 0 ? -over * (1.0 - (1.0/ratio)) : 0;
      linear_gain = 10 ^ (gr_db / 20);
      
      out_L = in_L * linear_gain; out_R = in_R * linear_gain;
  ) :
  algo == 1 ? (
      // ALGO 1: 1175 (Scott Stillwell - Feedback FET)
      att_c_us = 1.0 - exp(-1.0 / (srate * (att_ms / 1000000))); // Microseconds
      rel_c_us = 1.0 - exp(-1.0 / (srate * (rel_ms / 1000000))); // Microseconds
      
      // Feedback detection (reading the previous gain-reduced signal)
      fb_det = max(abs(in_L * last_gr), abs(in_R * last_gr));
      fb_det > env ? env += att_c_us * (fb_det - env) : env += rel_c_us * (fb_det - env);
      
      fixed_thresh = -24.0; // 1176 has fixed threshold, driven by input
      over = (20 * log10(max(0.00001, env))) - fixed_thresh;
      gr_db = over > 0 ? -over * (1.0 - (1.0/ratio)) : 0;
      
      linear_gain = 10 ^ (gr_db / 20);
      last_gr = linear_gain;
      
      out_L = in_L * linear_gain; out_R = in_R * linear_gain;
  ) :
  algo == 2 ? (
      // ALGO 2: BUS SSL (John Tukan - Parabolic Soft-Knee VCA)
      att_c = 1.0 - exp(-1.0 / (srate * (att_ms / 1000)));
      rel_c = 1.0 - exp(-1.0 / (srate * (rel_ms / 1000)));
      
      over = det_db - thresh_db;
      over < -(knee_db/2) ? target_gr_db = 0 :
      over > (knee_db/2) ? target_gr_db = over * (1.0 - (1.0/ratio)) :
      target_gr_db = ((over + knee_db/2)^2) / (2 * knee_db) * (1.0 - (1.0/ratio));
      
      target_gr_db > last_gr_db ? last_gr_db += att_c * (target_gr_db - last_gr_db) : last_gr_db += rel_c * (target_gr_db - last_gr_db);
      
      linear_gain = 10 ^ (-last_gr_db / 20);
      out_L = in_L * linear_gain; out_R = in_R * linear_gain;
  ) :
  algo == 3 ? (
      // ALGO 3: FAIRLYCHILD (John Tukan - Vari-Mu Time Constants)
      // Map IDE Attack knob (1-6) to hardware Time Constants
      att_ms == 1 ? ( a_ms = 0.2; r_ms = 300; ) :
      att_ms == 2 ? ( a_ms = 0.2; r_ms = 800; ) :
      att_ms == 3 ? ( a_ms = 0.4; r_ms = 2000; ) :
      att_ms == 4 ? ( a_ms = 0.8; r_ms = 5000; ) :
      att_ms == 5 ? ( a_ms = 0.4; r_ms = 2000; ) :
                    ( a_ms = 0.2; r_ms = 5000; );
                    
      att_c = 1.0 - exp(-1.0 / (srate * (a_ms / 1000)));
      rel_c = 1.0 - exp(-1.0 / (srate * (r_ms / 1000)));
      
      over = det_db - thresh_db;
      dyn_ratio = max(1.5, 1.0 + (max(0, over) * 0.15)); // Ratio scales with drive
      
      target_gr_db = over > 0 ? over * (1.0 - (1.0/dyn_ratio)) : 0;
      target_gr_db > last_gr_db ? last_gr_db += att_c * (target_gr_db - last_gr_db) : last_gr_db += rel_c * (target_gr_db - last_gr_db);
      
      linear_gain = 10 ^ (-last_gr_db / 20);
      out_L = in_L * linear_gain; out_R = in_R * linear_gain;
  ) :
  algo == 4 ? (
      // ALGO 4: EVENTHORIZON (Scott Stillwell - Hard/Soft Clipper)
      thresh_lin = 10 ^ (thresh_db / 20); 
      hd_blend = max(0.0, min(24.0, knee_db)) / 24.0; // Map knee to Hardness
      
      hc_L = max(-thresh_lin, min(thresh_lin, in_L)); 
      hc_R = max(-thresh_lin, min(thresh_lin, in_R));
      
      sc_L = thresh_lin * tanh(in_L / thresh_lin); 
      sc_R = thresh_lin * tanh(in_R / thresh_lin);
      
      out_L = hc_L + (sc_L - hc_L) * hd_blend; 
      out_R = hc_R + (sc_R - hc_R) * hd_blend;
      
      linear_gain = max(abs(out_L), abs(out_R)) / max(0.00001, det_val);
  ) :
  algo == 5 ? (
      // ALGO 5: PEAK LIMITER (Saike - True Look-Ahead)
      det_val > env ? env += 0.999 * (det_val - env) : env += (1.0 - exp(-1.0 / (srate * (rel_ms / 1000)))) * (det_val - env);
      env_db = 20 * log10(max(0.00001, env));
      
      over = env_db - thresh_db;
      gr_db = over > 0 ? -over : 0;
      linear_gain = 10 ^ (gr_db / 20);
      
      lookahead_samples = floor((2.0 / 1000) * srate); // 2ms lookahead
      read_pos = delay_pos - lookahead_samples;
      read_pos < 0 ? read_pos += delay_max_samples;
      
      out_L = delay_buf_L[read_pos] * in_drive_lin * linear_gain;
      out_R = delay_buf_R[read_pos] * in_drive_lin * linear_gain;
  ) :
  algo == 6 ? (
      // ALGO 6: OPTO (John Tukan - LA-2A Dual-Stage Release)
      opto_att_c = 1.0 - exp(-1.0 / (srate * (10.0 / 1000))); // Fixed 10ms
      rel_f_c = 1.0 - exp(-1.0 / (srate * (60.0 / 1000)));    // Stage 1 Fast
      rel_s_c = 1.0 - exp(-1.0 / (srate * (1500.0 / 1000)));  // Stage 2 Slow
      
      det_val > env ? (
          env += opto_att_c * (det_val - env);
      ) : (
          rel_fast = rel_fast + rel_f_c * (det_val - rel_fast);
          rel_slow = rel_slow + rel_s_c * (det_val - rel_slow);
          env = (rel_fast * 0.4) + (rel_slow * 0.6); // 40% fast, 60% slow recovery
      );
      
      over = (20 * log10(max(0.00001, env))) - (-24.0); // Fixed hardware threshold
      gr_db = over > 0 ? -over * (1.0 - (1.0/3.0)) : 0; // Fixed 3:1 Ratio
      
      linear_gain = 10 ^ (gr_db / 20);
      out_L = in_L * linear_gain; out_R = in_R * linear_gain;
  ) : (
      // Fallback
      out_L = in_L; out_R = in_R; linear_gain = 1.0;
  );

  // Increment Delay Buffer Pointer (Crucial for Algo 5)
  delay_pos += 1;
  delay_pos >= delay_max_samples ? delay_pos = 0;

  // ===============================================
  // 3. APPLY TRIM & MIX
  // ===============================================
  out_L = out_L * trim_lin; out_R = out_R * trim_lin;
  spl0 = (spl0 * (1.0 - mix)) + (out_L * mix); 
  spl1 = (spl1 * (1.0 - mix)) + (out_R * mix);

  // ===============================================
  // 4. WRITE METERS TO GMEM (So the IDE can see them)
  // ===============================================
  gmem[base_mem + 13] = linear_gain;            // Gain Reduction
  gmem[base_mem + 14] = max(gmem[base_mem + 14], abs(in_L)); // Input L
  gmem[base_mem + 15] = max(gmem[base_mem + 15], abs(in_R)); // Input R
  
  max_in = max(max_in, max(abs(in_L), abs(in_R)));
  gr_peak = min(gr_peak, linear_gain); 
  
  buf_counter += 1;
  buf_counter >= 512 ? (
      w_idx = 100000 + (instance_id * 2048); head_ptr = gmem[base_mem + 18]; head_ptr = (head_ptr + 1) % 1024; gmem[base_mem + 18] = head_ptr;
      gmem[w_idx + head_ptr] = max_in; gmem[w_idx + 1024 + head_ptr] = gr_peak;
      buf_counter = 0; max_in = 0.0; gr_peak = 1.0;
  );
]]
    WriteFX("OMM_Compressor.jsfx", comp_code)
end

function DSP.EnsureMIDIHubTrack()
    local t_c = reaper.CountTracks(0); local h_t = nil
    for i = 0, t_c - 1 do local t = reaper.GetTrack(0, i); local _, n = reaper.GetTrackName(t); if n == "OMM MIDI Hub" then h_t = t; break end end
    if not h_t then reaper.InsertTrackAtIndex(0, true); h_t = reaper.GetTrack(0, 0); reaper.GetSetMediaTrackInfo_String(h_t, "P_NAME", "OMM MIDI Hub", true); reaper.SetMediaTrackInfo_Value(h_t, "I_RECARM", 1); reaper.SetMediaTrackInfo_Value(h_t, "I_RECMONITOR", 1); reaper.SetMediaTrackInfo_Value(h_t, "I_RECINPUT", 4096) end
    local fx_idx = -1; local fx_c = reaper.TrackFX_GetCount(h_t)
    for i = 0, fx_c - 1 do local _, fn = reaper.TrackFX_GetFXName(h_t, i); if string.find(fn, "OMM Track Hub") then fx_idx = i; break end end
    if fx_idx == -1 then fx_idx = reaper.TrackFX_AddByName(h_t, "JS: OpenMacroMaker/OMM_Hybrid_Hub.jsfx", false, -1) end
    if fx_idx >= 0 then reaper.TrackFX_SetParam(h_t, fx_idx, 0, 100) end; return h_t
end

function DSP.EnsureTrackBridge(jsfx_cache, track, track_idx)
    if not track then return -1 end
    local app_time = reaper.time_precise(); local c_key = tostring(track_idx)
    if jsfx_cache[c_key] and (app_time - jsfx_cache[c_key]) < 0.5 then return -1 end
    jsfx_cache[c_key] = app_time; local fx_c, b_idx = reaper.TrackFX_GetCount(track), -1
    for i = 0, fx_c - 1 do local _, fn = reaper.TrackFX_GetFXName(track, i); if string.find(fn, "OMM Track Hub") then b_idx = i; break end end
    if b_idx == -1 then b_idx = reaper.TrackFX_AddByName(track, "JS: OpenMacroMaker/OMM_Hybrid_Hub.jsfx", false, -1) end
    if b_idx >= 0 then reaper.TrackFX_SetParam(track, b_idx, 0, track_idx) end; return b_idx
end

function DSP.EnsureGainBridge(jsfx_cache, track, node_id, n_opt)
    if not track then return -1 end
    local app_time = reaper.time_precise(); local c_key = "GAIN_" .. tostring(node_id)
    if jsfx_cache[c_key] and (app_time - jsfx_cache[c_key]) < 0.5 then return -1 end
    jsfx_cache[c_key] = app_time; local fx_c, b_idx = reaper.TrackFX_GetCount(track), -1
    for i = 0, fx_c - 1 do 
        local _, fn = reaper.TrackFX_GetFXName(track, i)
        if string.find(fn, "OMM Gain") then 
            if math.floor(reaper.TrackFX_GetParam(track, i, 0) + 0.5) == node_id then b_idx = i; break end 
        end 
    end
    if b_idx == -1 then b_idx = reaper.TrackFX_AddByName(track, "JS: OpenMacroMaker/OMM_Gain.jsfx", false, -1) end
    local slot = n_opt and n_opt.gmem_slot or node_id
    if b_idx >= 0 then reaper.TrackFX_SetParam(track, b_idx, 0, slot) end; return b_idx
end

function DSP.EnsureModulatorBridge(jsfx_cache, track, node_id)
    if not track then return -1 end
    local app_time = reaper.time_precise(); local c_key = "MOD_" .. tostring(node_id)
    if jsfx_cache[c_key] and (app_time - jsfx_cache[c_key]) < 0.5 then return -1 end
    jsfx_cache[c_key] = app_time; local fx_c, b_idx = reaper.TrackFX_GetCount(track), -1
    for i = 0, fx_c - 1 do 
        local _, fn = reaper.TrackFX_GetFXName(track, i)
        if string.find(fn, "OMM Modulator") then 
            if math.floor(reaper.TrackFX_GetParam(track, i, 0) + 0.5) == node_id then b_idx = i; break end 
        end 
    end
    if b_idx == -1 then b_idx = reaper.TrackFX_AddByName(track, "JS: OpenMacroMaker/OMM_Modulator.jsfx", false, -1) end
    if b_idx >= 0 then reaper.TrackFX_SetParam(track, b_idx, 0, node_id) end; return b_idx
end

function DSP.EnsureCompressorBridge(jsfx_cache, track, n)
    if not track or not n then return -1 end
    
    local node_id = n.id
    local app_time = reaper.time_precise()
    local c_key = "COMP_" .. tostring(node_id)
    
    if jsfx_cache[c_key] and (app_time - jsfx_cache[c_key]) < 0.5 then return -1 end
    jsfx_cache[c_key] = app_time
    
    local fx_c, b_idx = reaper.TrackFX_GetCount(track), -1
    for i = 0, fx_c - 1 do 
        local _, fn = reaper.TrackFX_GetFXName(track, i)
        if string.find(fn, "OMM") and string.find(fn, "Compressor") then 
            -- Check if this JSFX instance belongs to our memory slot
            local ok, param_val = pcall(reaper.TrackFX_GetParam, track, i, 0)
            if ok and math.floor(param_val + 0.5) == n.gmem_slot then
                b_idx = i
                break
            end
        end 
    end
    
    if b_idx == -1 then b_idx = reaper.TrackFX_AddByName(track, "JS: OpenMacroMaker/OMM_Compressor.jsfx", false, -1) end
    
    -- Send the specific module its memory Chunk ID
    if b_idx >= 0 then 
        reaper.TrackFX_SetParam(track, b_idx, 0, n.gmem_slot) 
        DSP.PushStateToMemory(n) -- Force data sync instantly so audio doesn't pop
    end
    
    return b_idx
end

return DSP