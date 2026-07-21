[Variables]

; -- RetroAchievements credentials --------------------------------
; UserName = your RA username
; APIKey   = Web API Key from https://retroachievements.org/settings
;            (or click the lines on the widget to type them in)
UserName=Benchy
APIKey=PVXUTIJQLTybYjuYrXEdRFvChTH86gXN

; -- Behaviour ----------------------------------------------------
; RecentMinutes: how far back to fetch achievements (43200 = 30 days)
RecentMinutes=43200
; MaxItems: number of achievement cards shown (grid of 3 per row)
MaxItems=8
; ImageHost: where RA serves badge/game art from
ImageHost=https://media.retroachievements.org
; UpdateRate: seconds between API refreshes (600 = 10 min)
UpdateRate=600

; -- Style (matched to Mond) --------------------------------------
TextColor=255,255,255
DimColor=150,150,150
AccentColor=250,126,0
; glass card background (R,G,B,Alpha - lower alpha = more see-through)
BgColor=25,25,30,190
BgStroke=255,255,255,25
BgRadius=16
BgHeight=190
BodyFont=Quicksand
HeaderFont=Anurati
SkinWidth=740
