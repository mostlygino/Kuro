-- Kuro's look in Hyprland, the way AeroSpace and JankyBorders set it on the
-- Mac: 40 pt round every edge (the top measured from the bar's pills, which
-- windows already keep clear of), 16 between two windows, and the window in
-- focus marked in Kuro's white.
--
-- Installed as ~/.config/hypr/kuro.lua by linux/omarchy/install.sh and loaded
-- after looknfeel.lua, so it wins; `install.sh --off` takes it out again.
--
-- The ring is a glow from the window's shadow rather than a border: under a
-- virtual GPU without corner arcs Hyprland draws borders square, and the
-- shadow follows the rounding.
hl.config({
  general = {
    gaps_in = 8,
    gaps_out = 40,
  },
  decoration = {
    shadow = {
      enabled = true,
      range = 6,
      render_power = 3,
      color = "rgba(f5f5f7d9)",
      color_inactive = "rgba(00000059)",
    },
  },
})
