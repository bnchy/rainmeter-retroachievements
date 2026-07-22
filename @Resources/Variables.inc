[Variables]

; -- RetroAchievements credentials --------------------------------
; UserName = your RA username
; APIKey   = Web API Key from https://retroachievements.org/settings
;            (or click the lines on the widget to type them in)
UserName=Benchy
APIKey=PVXUTIJQLTybYjuYrXEdRFvChTH86gXN

; -- Behaviour ----------------------------------------------------
; Nothing here is date-limited: games are fetched by count (the N most
; recently played) and each game's badge row shows its N newest
; unlocks out of its complete history.
; MaxGames: game groups shown (1-4); card height adjusts automatically
MaxGames=3
; ImageHost: where RA serves badge/game art from
ImageHost=https://media.retroachievements.org
; UpdateRate: API poll interval measured in SKIN TICKS, not seconds.
; The skin ticks every 500ms (see Update= in the ini), so:
;   1200 ticks = 10 min   |   600 = 5 min   |   3600 = 30 min
UpdateRate=1200

; -- Style (matched to Mond) --------------------------------------
TextColor=255,255,255
DimColor=150,150,150
AccentColor=250,126,0
; used for mastered games (title + completion bar)
GoldColor=255,201,84
; glass card background (R,G,B,Alpha - lower alpha = more see-through)
BgColor=25,25,30,190
BgStroke=255,255,255,25
BgRadius=16
BgHeight=190
BodyFont=Quicksand
HeaderFont=Anurati
SkinWidth=540
