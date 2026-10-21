#!/usr/bin/env python3
"""Builds docs/highlights.png, the three tiles at the top of the README, from
the sheets the other scripts make: states.png, marks.png and keys.png.

    python3 docs/make_highlights.py    (after make_states.py and make_keys.py)
"""
from PIL import Image, ImageDraw, ImageFont, ImageFilter
FONT="/System/Library/Fonts/SFNS.ttf"
def font(size, weight="Regular"):
    f=ImageFont.truetype(FONT,size)
    try: f.set_variation_by_name(weight)
    except Exception: pass
    return f
BG=(8,8,9); TILE=(8,8,9); EDGE=(58,58,62); TITLE=(245,245,247); NOTE=(150,150,156)
states=Image.open("docs/states.png").convert("RGB")
marks=Image.open("docs/marks.png").convert("RGB")
keys=Image.open("docs/keys.png").convert("RGB")
# The keyboard in keys.png, from its CSS: 16.49 units of 63.6 px wide plus the
# border, centred in 1280, 44 px down, drawn at 2x. Its corners are rounded, so
# it is pasted through a mask of the same radius and the page behind it drops.
BOARD, BOARD_RADIUS = (229, 88, 2331, 860), 53
# The part of each sheet that tells its story.
crops=[
  ("Every state, drawn", "off and error included, not just greyed",
   states.crop((360, 330, 1560, 720))),
  ("Knows what is playing", "a record, live bars, a mark per service",
   marks.crop((360, 60, 1418, 320))),
  ("Keys that explain themselves", "generated from the config, lit as you hold",
   keys.crop(BOARD)),
]
TW, TH, PAD, S = 1200, 780, 56, 2
W = PAD + len(crops)*(TW+PAD)
H = TH + 2*PAD
out = Image.new("RGB",(W,H),BG); d=ImageDraw.Draw(out)
for i,(title,note,img) in enumerate(crops):
    x=PAD+i*(TW+PAD); y=PAD
    d.rounded_rectangle((x,y,x+TW,y+TH),radius=44,fill=TILE,outline=EDGE,width=2)
    d.text((x+56,y+52),title,font=font(52,"Semibold"),fill=TITLE)
    d.text((x+56,y+124),note,font=font(34),fill=NOTE)
    room=(TW-96, TH-240)
    k=min(room[0]/img.width, room[1]/img.height)
    im=img.resize((int(img.width*k),int(img.height*k)),Image.LANCZOS)
    mask=Image.new("L",im.size,255)
    if img.size==(BOARD[2]-BOARD[0], BOARD[3]-BOARD[1]):
        mask=Image.new("L",im.size,0)
        ImageDraw.Draw(mask).rounded_rectangle((0,0,im.width-1,im.height-1),radius=int(BOARD_RADIUS*k),fill=255)
    elif i==1:
        # The service row runs on past Vimeo; fade it out rather than cut it.
        fade=int(im.width*0.14)
        for c in range(fade):
            ImageDraw.Draw(mask).line((im.width-fade+c,0,im.width-fade+c,im.height),fill=int(255*(1-(c+1)/fade)))
    out.paste(im,(x+(TW-im.width)//2, y+200+(room[1]-im.height)//2),mask)
out.save("docs/highlights.png",optimize=True)
print(out.size, states.size, marks.size, keys.size)
