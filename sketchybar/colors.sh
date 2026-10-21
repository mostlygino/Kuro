#!/bin/zsh

# Palette is deliberately hue-free as of 2026-09-07. Everything used to be Nord,
# which is a cool blue-grey scheme, so the pills read as tinted blue against a
# near-black desktop and the Now Playing label was outright cyan. These are
# neutral greys off the Apple system palette instead: the only colour on the bar
# is whatever album art happens to be spinning.

# The bar draws nothing; these dress the two brackets. Slightly translucent so
# the desktop reads through the pills, which is the point of clearing the middle.
export PILL_COLOR=0xd91c1c1e
# 30pt in the 34pt bar band (y 8..38). The 28pt media disc has to fit inside the
# pill; at PILL_HEIGHT=26 it bulged past the fill and broke the silhouette.
# Changing this moves AeroSpace's outer.top, which measures from the pill's
# visible bottom edge, not the screen edge.
export PILL_HEIGHT=34
export PILL_RADIUS=17

# The bar is a 66pt band, but only 34pt of it is ever used at once. It is a tall
# transparent container so the Now Playing pill can be dropped below the MacBook
# notch while the side pills stay in the screen corners, which is the one thing
# moving the bar itself could never do.
#
# Items are centred in the band, so every one of them carries PILL_Y to pull it
# back up to the top. Band y 6..72, centre y 39, minus 8 puts a 34pt pill at
# y 14..48. It was 14 (y 8..42) until 2026-10-14; dropped 6pt so windows whose
# title bar ends up at the very top stay grabbable below topguard's strip.
# Changing either of these moves every pill on the bar, and aerospace.toml
# outer.top has to move with it.
#
# 66 is sized for the deepest notch inset rather than measured, because bar
# height is one global property and `menubar_reveal.sh` has to restore it from a
# constant.
export BAR_HEIGHT=66
export PILL_Y=8
export SHADOW_COLOR=0x80000000

export BAR_COLOR=0xff1c1c1e
export BORDER_COLOR=0x59ffffff
# Where every hover card rests under its badge. hoverwatch animates each card
# in from 4pt above this and needs the resting value to land on, so it is one
# constant here rather than a literal per card.
export CARD_Y_OFFSET=-20
export TEXT_COLOR=0xfff5f5f7
export MUTED_COLOR=0xff8e8e93
export TRANSPARENT=0x00000000

# The visible workspace is an inverted chip: solid light fill, dark text. It was
# a 18%-white wash (0x2effffff) behind light text until 2026-09-07, which at chip
# size read as a smudge rather than a selection. Inverting is unambiguous at a
# glance and needs no border.
export ACTIVE_FILL=0xfff5f5f7
export ACTIVE_TEXT=0xff1c1c1e
# A workspace with nothing on it is a quieter digit than one with windows, so
# the row says at a glance where your work is without adding a single mark.
export WORKSPACE_EMPTY_COLOR=0xff48484a
# The visible workspace's chip at rest, and how small it starts from when it
# grows in on a switch.
export CHIP_HEIGHT=25
export CHIP_FROM=9

# The agent chip (sketchybarrc): TestFlight's blue and its propeller, so a
# hidden agent space reads as the test bench it is, not as one more workspace.
export AGENT_BLUE=0xff1a8cff
export AGENT_TINT=0x2e1a8cff
export AGENT_ICON="󰈐"  # nf-md-fan, as the character: \U escapes fail outside a UTF-8 locale
# The focused app's own icon, before its name. macOS hands SketchyBar a 32pt
# image for `app.<bundle id>`; half of that sits at the pill's text height.
export APP_ICON_SCALE=0.5
# The app's padding_left on its pill: 1, like every item, when the last chip
# before it is a bare digit, and 7 when that chip is the focused one. A digit
# glyph leaves 13.5pt of air before the icon; the filled circle, 7pt wider than
# the digit it holds, left 6, the same as between two chips, so the app read as
# one more workspace. 7 gives the circle 11pt, which looks the same distance
# away as the digit's 13.5: a solid shape needs less air than a glyph does.
# plugins/aerospace_sync.sh glides between the two with the chip.
export APP_GAP=1
export APP_GAP_AFTER_CHIP=7

export VPN_UP_COLOR=0xff32d74b
export VPN_DOWN_COLOR=0xff8e8e93

# Avenir Next: geometric humanist sans, the closest thing on a stock Mac to
# Spotify's Circular. Demi Bold rather than Bold because Avenir's Bold is heavy
# at UI sizes, and 14.5pt because its x-height is small and the bar has the room. One family,
# one size, no italic anywhere.
export BAR_FONT="Avenir Next"
export BAR_FONT_WEIGHT="Demi Bold"
export BAR_FONT_SIZE=14.5

# Now Playing is the one live element, so it carries the bright weight and the
# clock steps back to muted grey. Hierarchy by value, not by hue.
#
# The title and the artist are two separate SketchyBar slots on one item (icon
# and label), because a label has one colour and no rich text. MEDIA_COLOR is the
# title, MEDIA_ARTIST_COLOR the artist, which is the same grey the clock wears.
export MEDIA_COLOR=0xfff5f5f7
export MEDIA_PAUSED_COLOR=0x998e8e93
export MEDIA_ARTIST_COLOR=0xff8e8e93
export MEDIA_ARTIST_PAUSED_COLOR=0x668e8e93

# The `~` between title and artist, added 2026-09-07. Same grey as the artist but
# at lower alpha, because a separator is punctuation: it has to be findable
# without competing with either of the two things it separates. Matching the
# artist exactly would read as a third word.
export MEDIA_SEP_COLOR=0x998e8e93
export MEDIA_SEP_PAUSED_COLOR=0x558e8e93

# Read by both sketchybarrc (label.max_chars) and mediawatch (composeLabel), so
# the watcher never hands over a string SketchyBar will silently clip.
#
# Only a ceiling now. Since 2026-09-29 mediawatch measures the title and artist
# in the bar's own font and fits them to the real room, from the end of the
# workspace pill to the notch (or the badges on a screen without one), and
# re-fits when the workspace pill changes width; see assets/mediafit.swift. A
# character count could never promise a width: it was 50, sized for 13pt text
# before the bar grew, and long titles ran into the notch. This is what
# SketchyBar is told to draw at most, so it only has to be comfortably above
# anything that fits.
export MEDIA_LABEL_MAX=90

# Seconds a pause may last before the media pill settles into silence: a
# music note in a capsule of its own. Playing again opens it back up.
# Read by mediawatch at launch; see pauseHideAfter in mediawatch.swift for why
# it is not zero.
export MEDIA_PAUSE_HIDE_AFTER=30

# The cover is rendered at 48px for a 24pt disc (2x, for the Retina panel), so
# it shows at 0.5: on the 2x screen that is pixel for pixel, on a 1x screen a
# clean halving. It was 24px at 1.0 while both screens were 1x, and a 24px cover
# on the Retina panel was the one soft thing on the bar.
#
# Paused matches playing on purpose: shrinking the paused disc meant scaling it
# again. Pause is legible from the stopped spin, the dimmed text and the cover
# draining to grey. To change the disc size, change discPointSize in
# mediawatch.swift, not this.
# Outer text padding on the first and last member of every pill. With the shared
# bracket padding of -6 this lands the same 16pt inset at both ends of all three
# pills, so they are uniform by construction rather than tuned per pill.
#
# 16 is dictated by the left pill: the active workspace chip is a filled circle
# in a 15pt corner radius and needs more clearance from that arc than text does.
# Raising this widens every pill's ends together, which is the point.
export PILL_TEXT_PAD=10

# The one gap between neighbouring things on the bar: pill to pill, badge to
# badge, and the last badge to the clock pill. Measured as clear desktop between
# what is actually drawn, not between item boxes, because the shield symbol sits
# inside its 16pt box with a margin and the other two marks run to the edge.
export ITEM_GAP=16

# The cover's frames are drawn at 2x (discPixelScale in mediawatch.swift), so
# they show at half. The dot, the podcast bars and the icons have their own.
export MEDIA_DISC_SCALE=0.5
export MEDIA_DISC_PAUSED_SCALE=0.5

# Worn only while the native menu bar is revealed, driven by
# plugins/menubar_reveal.sh. Low alpha so the bar's blur_radius has something to
# frost, which is what makes the real menu bar text readable on top of it.
export HOVER_BAR_COLOR=0x401c1c1e
export HOVER_BLUR=30

# Hover cards. One set of slot widths for all of them, because a card that is a
# different width per badge makes the whole row jump as the pointer travels
# along it. Sized for the widest line any of them carries, which is the battery's
# "Condition  ~  78 cycles" on the left and a v4 address on the right.
#
# The widths do the aligning, not the item width: `label.align` aligns text
# inside the label's own box, and that box is only as wide as the text unless it
# is told otherwise, so widening the item just pads the row from the outside and
# leaves the two columns touching in the middle.
export CARD_CONTEXT_WIDTH=176
export CARD_VALUE_WIDTH=104
export CARD_FONT_SIZE=12.0
export CARD_ROW_HEIGHT=26
export CARD_TEXT_PAD=12

# What the app label says on a display with no windows, and how quietly. The
# muted grey at 60%, below even an unfocused app name.
export EMPTY_LABEL="void"
export EMPTY_COLOR=0x998e8e93

# What the clock card's calendar row opens. Calendar.app by default; point it
# at a web calendar in local.sh if that is where your week lives.
export CLOCK_CLICK="/usr/bin/open -a Calendar"
# The calendar row's "Open", in the focus blue the keys page uses for a way in.
export CLOCK_ACCENT=0xff64d2ff

# Which badges the bar has. Strangers get the ones that need nothing of theirs;
# the ones that read another app (Vitals, OrbStack) only when that app is here,
# and the Claude usage badge, which reads Claude Code's login, only when asked.
# Left to right on the bar, whatever order they are named in.
KURO_BADGES="caffeinate tailscale wifi battery"
[[ -d /Applications/Vitals.app ]] && KURO_BADGES="vitals $KURO_BADGES"
[[ -d /Applications/OrbStack.app ]] && KURO_BADGES="orbstack $KURO_BADGES"
export KURO_BADGES
export MENUBAR_REVEAL_WIDTH=0

# The Kuro app's settings, ~/.config/kuro/settings: `key=value` lines it writes.
# Read, not sourced: only these keys, only values of their own shape, so the file
# can never run anything. Then local.sh below, the hand-written shell, which wins.
#
#   badges=orbstack caffeinate vitals claude tailscale wifi battery
#   menubar_reveal_width=0                 points, 0 for no opening
#   clock_url=https://calendar.example     what the clock card's Open opens
kuro_settings() {
  local file="${XDG_CONFIG_HOME:-$HOME/.config}/kuro/settings" line key value
  [[ -r "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == [a-z_]*=* ]] || continue
    key="${line%%=*}" value="${line#*=}"
    case "$key" in
      badges)
        [[ "$value" =~ '^[a-z ]*$' ]] && export KURO_BADGES="$value" ;;
      menubar_reveal_width)
        [[ "$value" =~ '^[0-9]{1,4}$' ]] && export MENUBAR_REVEAL_WIDTH="$value" ;;
      clock_url)
        [[ "$value" =~ '^https://[A-Za-z0-9._~:/?#=&%+-]+$' ]] && export CLOCK_CLICK="/usr/bin/open '$value'" ;;
    esac
  done < "$file"
}
kuro_settings

# Per-machine overrides, not in git: copy local.sh.example to local.sh. Last, so
# anything above can be overridden there.
[[ -r "${CONFIG_DIR:-$HOME/.config/sketchybar}/local.sh" ]] \
  && source "${CONFIG_DIR:-$HOME/.config/sketchybar}/local.sh"
