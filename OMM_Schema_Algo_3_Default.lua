-- OMM_Schema_Algo_3_Default.lua
-- MODULE: Fairchild 670 | THEME: Default
-- Protocol Zero: Claymorphism Radio Buttons

return {
  grid_cols = 12,
  grid_rows = 6,
  seed_hex = 0xFF6B35, -- Tangerine
  module_type = "COMPRESSOR",
  components = {
    { id = "bg_panel", type = "BackPanel", x = 0, y = 0, w = 480, h = 180, color_token = "Base" },
    { id = "algo_drop", type = "Dropdown", x = 20, y = 10, w = 150, h = 24, label = "COMP TYPE", color_token = "Accent_A", param_key = "algo", default_val = 3,
      norm_to_real = function(n, node) 
          return math.floor(tonumber(n) or 3)
      end,
      real_to_norm = function(r, node)
          return tonumber(r) or 3
      end
    },
    { id = "vfd_scr", type = "VFDScreen", x = 180, y = 10, w = 80, h = 24, label = "GR", color_token = "Teal" },
    { id = "th", type = "InlineDrag", x = 20, y = 50, w = 60, h = 20, label = "TH", color_token = "Teal", param_key = "thresh", default_val = -18.0 },
    { id = "rt_comp", type = "InlineDrag", x = 90, y = 50, w = 60, h = 20, label = "RATIO", color_token = "Teal", param_key = "ratio", default_val = 4.0 },
    {
      id = "tc_radio", 
      type = "RadioStrip",
      x = 30, y = 100, 
      steps = 6, 
      axis = "H",
      btn_w = 32,
      btn_h = 24, 
      wrap_at = 6, 
      labels = {"1", "2", "3", "4", "5", "6"},
      color_token = "Tangerine",
      param_key = "attack", 
      default_val = 0.0,
      norm_to_real = function(n, node)
          return math.floor(n * 5.0 + 0.5) + 1
      end,
      real_to_norm = function(r, node)
          return ((tonumber(r) or 1) - 1) / 5.0
      end
    },
    { id = "kn_rel", type = "AuraKnob", x = 240, y = 100, radius = 20, label = "RELEASE", color_token = "Teal", param_key = "release", default_val = 150.0, is_disabled = function(node) return true end }
  }
}
