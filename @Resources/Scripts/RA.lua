-- RA.lua — parses the RetroAchievements API, groups unlocks by game
-- and renders "game header + completion bar + row of badges".
-- Extras: mastered styling, rich presence, site rank, today-glow.
-- Badges are fetched through a single serial download queue.

local groups = {}          -- array of { id, title, console, done, total, points, played, last }
local detail = {}          -- gameId -> { achs, locked, done, total, playtime }
local pending = {}         -- measure slot -> gameId currently being fetched
local retries = {}         -- gameId -> failed detail fetches (capped)
local offsets = {}         -- gameId -> scroll position within its row
local showLocked = false   -- false = unlocked history, true = still to earn
local sortKeys = { 'date', 'points', 'game' }
local sortLabels = { date = 'RECENT', points = 'POINTS', game = 'GAME' }
local sortIndex = 1
local sortAsc = false
local apiError = false
local months = { 'Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec' }

-- badge pipeline state
local iconCache = {}       -- url -> verified local file path
local urlSlots = {}        -- url -> { {g,k}, ... } (rebuilt every Render)
local dlQueue = {}
local dlBusy = {}          -- download slot -> url in flight
local DL_SLOTS = 6         -- must match the MeasureIconDL* count in the ini

local BADGES_PER_ROW = 12  -- badge meter slots per game in the ini
local TITLE_MAX = 34       -- truncate long game titles

function Initialize()
	maxGames  = math.min(tonumber(SKIN:GetVariable('MaxGames', '3')) or 3, 4)
	skinWidth = tonumber(SKIN:GetVariable('SkinWidth', '540')) or 540
	imageHost = SKIN:GetVariable('ImageHost', 'https://media.retroachievements.org')
	userName  = SKIN:GetVariable('UserName', '')
	apiKey    = SKIN:GetVariable('APIKey', '')
	textColor = SKIN:GetVariable('TextColor', '255,255,255')
	dimColor  = SKIN:GetVariable('DimColor', '150,150,150')
	accent    = SKIN:GetVariable('AccentColor', '250,126,0')
	gold      = SKIN:GetVariable('GoldColor', '255,201,84')
end

-- minimal JSON string unescaper (titles can contain \" \/ \uXXXX)
local function unescape(s)
	s = s:gsub('\\u(%x%x%x%x)', function(h)
		local c = tonumber(h, 16)
		return (c and c < 256) and string.char(c) or ''
	end)
	s = s:gsub('\\"', '"'):gsub('\\/', '/'):gsub('\\\\', '\\')
	return s
end

local function comma(n)
	local s = tostring(n):reverse():gsub('(%d%d%d)', '%1,'):reverse()
	return (s:gsub('^,', ''))
end

local function fmtDate(d)
	local m, dd = d:match('%d+%-(%d+)%-(%d+)')
	if not m then return d end
	return (months[tonumber(m)] or m) .. ' ' .. tonumber(dd)
end

local function fileSize(path)
	local f = io.open(path, 'rb')
	if not f then return 0 end
	local size = f:seek('end') or 0
	f:close()
	return size
end

-- ================= data =================

-- called by MeasureRecent's FinishAction (the recently-played list)
function Parse()
	local raw = SKIN:GetMeasure('MeasureRecent'):GetStringValue() or ''
	groups = {}
	apiError = false
	retries = {}   -- a new poll is a fresh chance for a game that failed

	if raw:match('[Ii]nvalid') or raw:match('"[Ee]rrors?"') or raw:match('[Uu]nauthori[sz]ed') then
		apiError = true
	else
		-- a flat JSON array of games, newest-played first
		for obj in raw:gmatch('%b{}') do
			local soft = tonumber(obj:match('"NumAchieved"%s*:%s*"?(%d+)') or '0') or 0
			local hard = tonumber(obj:match('"NumAchievedHardcore"%s*:%s*"?(%d+)') or '0') or 0
			local sSoft = tonumber(obj:match('"ScoreAchieved"%s*:%s*"?(%d+)') or '0') or 0
			local sHard = tonumber(obj:match('"ScoreAchievedHardcore"%s*:%s*"?(%d+)') or '0') or 0
			local g = {
				id      = obj:match('"GameID"%s*:%s*(%d+)') or '0',
				title   = unescape(obj:match('"Title"%s*:%s*"(.-)"') or ''),
				console = unescape(obj:match('"ConsoleName"%s*:%s*"(.-)"') or ''),
				played  = obj:match('"LastPlayed"%s*:%s*"(.-)"') or '',
				done    = math.max(soft, hard),
				total   = tonumber(obj:match('"NumPossibleAchievements"%s*:%s*"?(%d+)') or '0') or 0,
				points  = math.max(sSoft, sHard),
				achs    = {},
				last    = '',
			}
			if g.title ~= '' then groups[#groups + 1] = g end
		end
	end

	retries = {}   -- a fresh poll gets a fresh retry budget
	SortAndRender()
	FetchDetails()
end

-- Fetch full detail for each displayed game (complete unlock history,
-- progress counts and playtime). Cached per game for the session, so
-- re-sorting costs nothing and a refresh only fetches what's new.
function FetchDetails()
	if userName == '' then return end
	-- games already in flight, so a game is never requested twice
	local inFlight = {}
	for n = 1, 4 do
		if pending[n] then inFlight[pending[n]] = true end
	end

	for i = 1, maxGames do
		local grp = groups[i]
		if grp and not detail[grp.id] and not inFlight[grp.id]
		   and (retries[grp.id] or 0) <= 2 then
			-- Claim a free slot. A busy slot is never re-pointed: sorting
			-- moves games between positions, and retargeting a slot
			-- mid-flight makes the arriving body land on the wrong game.
			local slot
			for n = 1, 4 do
				if not pending[n] then slot = n break end
			end
			if not slot then return end

			pending[slot] = grp.id
			inFlight[grp.id] = true
			local url = 'https://retroachievements.org/API/API_GetGameInfoAndUserProgress.php?u='
				.. userName .. '&y=' .. apiKey .. '&g=' .. grp.id
			SKIN:Bang('!SetOption', 'MeasureGame' .. slot, 'Url', url)
			SKIN:Bang('!CommandMeasure', 'MeasureGame' .. slot, 'Update')
		end
	end
end

-- Error actions of MeasureGame1..4. Without this a transient timeout
-- would leave the slot marked in-flight forever and that game's row
-- would stay empty until the next poll.
function GameFail(n)
	local gameId = pending[n]
	pending[n] = nil
	if not gameId then return end
	retries[gameId] = (retries[gameId] or 0) + 1
	if retries[gameId] <= 2 then FetchDetails() end
end

-- FinishAction of MeasureGame1..4
function GameDone(n)
	local requested = pending[n]
	pending[n] = nil

	local raw = SKIN:GetMeasure('MeasureGame' .. n):GetStringValue() or ''

	-- Identify the game from the body itself rather than from the slot.
	-- The response opens with the game's own "ID", so even if a slot was
	-- reused the data can only ever be filed under the game it describes.
	local gameId = raw:match('"ID"%s*:%s*(%d+)') or requested

	-- a failed fetch must not be cached, or the row shows "none" forever
	local function failed()
		if gameId then
			retries[gameId] = (retries[gameId] or 0) + 1
			if retries[gameId] <= 2 then FetchDetails() end
		end
	end

	if raw == '' or raw:match('"[Ee]rrors?"') or not gameId then
		failed()
		return
	end

	local d = {
		achs     = {},   -- earned, newest first
		locked   = {},   -- still to earn, in game order
		last     = '',
		total    = tonumber(raw:match('"NumAchievements"%s*:%s*"?(%d+)') or '0') or 0,
		playtime = tonumber(raw:match('"UserTotalPlaytime"%s*:%s*"?(%d+)') or '0') or 0,
	}
	local soft = tonumber(raw:match('"NumAwardedToUser"%s*:%s*"?(%d+)') or '0') or 0
	local hard = tonumber(raw:match('"NumAwardedToUserHardcore"%s*:%s*"?(%d+)') or '0') or 0
	d.done = math.max(soft, hard)

	-- every earned achievement in the set, not just the recent window
	-- "Achievements" is an object keyed by id, so strip its outer
	-- braces before iterating - otherwise the wrapper itself matches
	local block = raw:match('"Achievements"%s*:%s*(%b{})')
	if not block then
		-- truncated or unbalanced body: retry instead of caching a blank
		failed()
		return
	end
	do
		for obj in block:sub(2, -2):gmatch('%b{}') do
			local hc    = obj:match('"DateEarnedHardcore"%s*:%s*"(.-)"')
			local sc    = obj:match('"DateEarned"%s*:%s*"(.-)"')
			local when  = hc or sc
			local badge = obj:match('"BadgeName"%s*:%s*"(.-)"') or ''
			local a = {
				title  = unescape(obj:match('"Title"%s*:%s*"(.-)"') or ''),
				desc   = unescape(obj:match('"Description"%s*:%s*"(.-)"') or ''),
				points = tonumber(obj:match('"Points"%s*:%s*(%d+)') or '0') or 0,
				achId  = obj:match('"ID"%s*:%s*(%d+)'),
				order  = tonumber(obj:match('"DisplayOrder"%s*:%s*(%d+)') or '0') or 0,
			}
			if when then
				a.date     = when
				a.hardcore = hc ~= nil
				a.badge    = '/Badge/' .. badge .. '.png'
				d.achs[#d.achs + 1] = a
			else
				-- RA serves a greyed-out variant for locked achievements
				a.badge  = '/Badge/' .. badge .. '_lock.png'
				a.locked = true
				d.locked[#d.locked + 1] = a
			end
		end
		table.sort(d.achs, function(x, y) return x.date > y.date end)
		table.sort(d.locked, function(x, y)
			if x.order == y.order then return x.points < y.points end
			return x.order < y.order
		end)
		if #d.achs > 0 then d.last = d.achs[1].date end
	end

	retries[gameId] = nil
	detail[gameId] = d

	-- newest unlock may now reorder the list
	for _, grp in ipairs(groups) do
		if grp.id == gameId then grp.last = d.last end
	end
	SortAndRender()
end

-- FinishAction of MeasureProfile
function ProfileDone()
	local raw = SKIN:GetMeasure('MeasureProfile'):GetStringValue() or ''

	local pts = raw:match('"TotalPoints"%s*:%s*"?(%d+)')
	if pts then
		SKIN:Bang('!SetOption', 'MeterPoints', 'Text', comma(pts) .. ' PTS')
		SKIN:Bang('!UpdateMeter', 'MeterPoints')
	end

	-- rich presence: what you're playing right now (last known status)
	local rp = raw:match('"RichPresenceMsg"%s*:%s*"(.-)"%s*,') or ''
	rp = unescape(rp)
	rp = rp:gsub('[\128-\255]', '')        -- drop emoji/unicode (ANSI-safe)
	rp = rp:gsub('%s+', ' '):gsub('^%s+', ''):gsub('%s+$', '')
	if rp ~= '' and not rp:match('^[Uu]nknown') then
		SKIN:Bang('!SetOption', 'MeterPresence', 'Text', rp)
		SKIN:Bang('!SetOption', 'MeterPresence', 'ToolTipText', rp)
	else
		SKIN:Bang('!SetOption', 'MeterPresence', 'Text', '')
	end
	SKIN:Bang('!UpdateMeter', 'MeterPresence')
	SKIN:Bang('!Redraw')
end

-- FinishAction of MeasureRank
function RankDone()
	local raw = SKIN:GetMeasure('MeasureRank'):GetStringValue() or ''
	local rank = raw:match('"Rank"%s*:%s*"?(%d+)')
	local of   = raw:match('"TotalRanked"%s*:%s*"?(%d+)')
	if rank then
		SKIN:Bang('!SetOption', 'MeterRank', 'Text', 'RANK #' .. comma(rank))
		if of then
			SKIN:Bang('!SetOption', 'MeterRank', 'ToolTipText',
				'#' .. comma(rank) .. ' of ' .. comma(of) .. ' ranked players')
		end
		SKIN:Bang('!UpdateMeter', 'MeterRank')
		SKIN:Bang('!Redraw')
	end
end

-- ================= sorting =================

function CycleSort()
	sortIndex = (sortIndex % #sortKeys) + 1
	sortAsc = (sortKeys[sortIndex] == 'game')
	SortAndRender()
end

function ToggleDir()
	sortAsc = not sortAsc
	SortAndRender()
end

function SortAndRender()
	local key = sortKeys[sortIndex]
	-- newest unlock when known, else when the game was last played
	local function recency(g)
		if g.last ~= '' then return g.last end
		return g.played
	end
	table.sort(groups, function(x, y)
		local a, b
		if key == 'date' then a, b = recency(x), recency(y)
		elseif key == 'points' then a, b = x.points, y.points
		else a, b = x.title:lower(), y.title:lower() end
		if a == b then return recency(x) > recency(y) end
		if sortAsc then return a < b else return a > b end
	end)
	Render()
	FetchDetails()   -- a re-sort can bring a new game into view
end

-- ================= scrolling / filtering =================

-- how many badges fit in one row (leaves room for the position label)
local function rowCapacity()
	return math.max(1, math.min(BADGES_PER_ROW, math.floor((skinWidth - 56) / 52)))
end

-- the list a group is currently showing
local function listFor(grp)
	local d = detail[grp.id]
	if not d then return {} end
	if showLocked then return d.locked end
	return d.achs
end

-- mouse wheel over a badge row (dir -1 = up/left, 1 = down/right)
function Scroll(g, dir)
	local grp = groups[g]
	if not grp then return end
	local list = listFor(grp)
	local cap = rowCapacity()
	local maxOff = math.max(0, #list - cap)
	local off = (offsets[grp.id] or 0) + dir * cap   -- page at a time
	if off < 0 then off = 0 end
	if off > maxOff then off = maxOff end
	offsets[grp.id] = off
	Render()
end

-- jump a row back to the start
function ScrollHome(g)
	local grp = groups[g]
	if not grp then return end
	offsets[grp.id] = 0
	Render()
end

-- Sign out. Destructive enough to deserve a confirm, and Rainmeter has
-- no dialogs, so the first click arms and the second click commits.
-- Any other interaction re-renders and disarms it.
local logoutArmed = false

function Logout()
	if not logoutArmed then
		logoutArmed = true
		SKIN:Bang('!SetOption', 'MeterLogout', 'Text', 'CONFIRM?')
		SKIN:Bang('!SetOption', 'MeterLogout', 'FontColor', accent)
		SKIN:Bang('!UpdateMeter', 'MeterLogout')
		SKIN:Bang('!Redraw')
		return
	end
	logoutArmed = false
	local vars = SKIN:GetVariable('@') .. 'Variables.inc'
	SKIN:Bang('!WriteKeyValue', 'Variables', 'UserName', '', vars)
	SKIN:Bang('!WriteKeyValue', 'Variables', 'APIKey', '', vars)
	SKIN:Bang('!Refresh')
end

-- ================= settings menu =================
-- The ellipsis dropdown. Kept in its own meter group so the rest of
-- the skin can show and hide itself without disturbing it.

local menuOpen = false

local function applyMenu()
	SKIN:Bang(menuOpen and '!ShowMeterGroup' or '!HideMeterGroup', 'Menu')
	SKIN:Bang('!SetOption', 'MeterMenuBtn', 'FontColor', menuOpen and accent or dimColor)
	SKIN:Bang('!UpdateMeter', 'MeterMenuBtn')
	SKIN:Bang('!Redraw')
end

function ToggleMenu()
	menuOpen = not menuOpen
	if not menuOpen and logoutArmed then
		-- closing the menu abandons an armed sign-out
		logoutArmed = false
		SKIN:Bang('!SetOption', 'MeterLogout', 'Text', 'LOG OUT')
		SKIN:Bang('!SetOption', 'MeterLogout', 'FontColor', dimColor)
	end
	applyMenu()
end

function CloseMenu()
	menuOpen = false
	applyMenu()
end

-- toggle between earned history and what's still locked
function ToggleFilter()
	showLocked = not showLocked
	offsets = {}   -- both views start at the beginning
	Render()
end

-- 153398 -> "42.6h", 1500 -> "25m"
local function fmtPlaytime(secs)
	if not secs or secs <= 0 then return nil end
	if secs < 3600 then return math.floor(secs / 60) .. 'm' end
	return string.format('%.1fh', secs / 3600)
end

-- ================= badge download queue =================

-- badge already on disk from an earlier session?
local function localBadge(url)
	local name = url:match('([^/]+)$')
	if not name then return nil end
	local path = SKIN:GetVariable('CURRENTPATH') .. 'DownloadFile\\' .. name
	if fileSize(path) > 0 then return path end
	return nil
end

local function showBadge(g, k, path)
	local meter = 'MeterBadge' .. g .. '_' .. k
	SKIN:Bang('!SetOption', meter, 'ImageName', path)
	SKIN:Bang('!ShowMeter', meter)
	SKIN:Bang('!UpdateMeter', meter)
end

-- fill every free download slot from the queue
local function startNext()
	for n = 1, DL_SLOTS do
		if not dlBusy[n] then
			local url = table.remove(dlQueue, 1)
			while url and iconCache[url] do url = table.remove(dlQueue, 1) end
			if not url then return end
			dlBusy[n] = url
			local m = 'MeasureIconDL' .. n
			SKIN:Bang('!EnableMeasure', m)
			SKIN:Bang('!SetOption', m, 'Url', url)
			SKIN:Bang('!SetOption', m, 'DownloadFile', url:match('([^/]+)$') or 'badge.png')
			SKIN:Bang('!CommandMeasure', m, 'Update')
		end
	end
end

-- FinishAction of MeasureIconDL<n>
function IconDone(n)
	local url = dlBusy[n]
	dlBusy[n] = nil
	if url then
		local path = SKIN:GetMeasure('MeasureIconDL' .. n):GetStringValue() or ''
		if path ~= '' and fileSize(path) > 0 then
			iconCache[url] = path
			for _, slot in ipairs(urlSlots[url] or {}) do
				showBadge(slot[1], slot[2], path)
			end
			SKIN:Bang('!Redraw')
		end
	end
	startNext()
end

-- OnDownloadErrorAction / OnConnectErrorAction of MeasureIconDL<n>
function IconFail(n)
	dlBusy[n] = nil
	startNext()
end

-- ================= rendering =================

function Render()
	urlSlots = {}
	dlQueue = {}
	local badgeFit = rowCapacity()
	local today = os.date('%Y-%m-%d')

	-- any re-render cancels a pending logout confirmation
	if logoutArmed then
		logoutArmed = false
		SKIN:Bang('!SetOption', 'MeterLogout', 'Text', 'LOG OUT')
		SKIN:Bang('!SetOption', 'MeterLogout', 'FontColor', dimColor)
	end

	SKIN:Bang('!SetOption', 'MeterFilter', 'Text', showLocked and 'LOCKED' or 'UNLOCKED')
	SKIN:Bang(showLocked and '!ShowMeter' or '!HideMeter', 'MeterLockClosed')
	SKIN:Bang(showLocked and '!HideMeter' or '!ShowMeter', 'MeterLockOpen')

	for g = 1, 4 do
		local grp = (g <= maxGames) and groups[g] or nil
		if grp then
			local d = detail[grp.id]
			-- counts come with the game list, so headers draw immediately;
			-- badges and playtime fill in when the detail call lands
			local achList = listFor(grp)
			local mastered = grp.total > 0 and grp.done >= grp.total

			-- clamp any stale scroll position, then take this row's page
			local off = offsets[grp.id] or 0
			if off > math.max(0, #achList - badgeFit) then
				off = math.max(0, #achList - badgeFit)
				offsets[grp.id] = off
			end

			-- title (white; gold when mastered)
			local t = grp.title
			if #t > TITLE_MAX then t = t:sub(1, TITLE_MAX - 3) .. '...' end
			SKIN:Bang('!SetOption', 'MeterHeadTitle' .. g, 'Text', t)
			SKIN:Bang('!SetOption', 'MeterHeadTitle' .. g, 'FontColor',
				mastered and gold or textColor)
			SKIN:Bang('!SetOption', 'MeterHeadTitle' .. g, 'ToolTipTitle', grp.title)
			SKIN:Bang('!SetOption', 'MeterHeadTitle' .. g, 'ToolTipText',
				grp.console .. '  -  played ' .. fmtDate(grp.played)
				.. (grp.last ~= '' and ('  -  last unlock ' .. fmtDate(grp.last)) or '')
				.. (mastered and '  -  MASTERED' or ''))
			SKIN:Bang('!SetOption', 'MeterHeadTitle' .. g, 'LeftMouseUpAction',
				'["https://retroachievements.org/game/' .. grp.id .. '"]')

			-- stats (dim; gold MASTERED tag when done) + playtime
			local statsText = mastered
				and ('MASTERED ' .. grp.done .. '/' .. grp.total)
				or  (grp.done .. '/' .. grp.total .. ' unlocked')
			local pt = d and fmtPlaytime(d.playtime)
			if pt then statsText = statsText .. '   -   ' .. pt end
			SKIN:Bang('!SetOption', 'MeterHeadStats' .. g, 'Text', statsText)
			SKIN:Bang('!SetOption', 'MeterHeadStats' .. g, 'FontColor',
				mastered and gold or dimColor)

			-- points (accent, right-aligned)
			SKIN:Bang('!SetOption', 'MeterHeadPts' .. g, 'Text', grp.points .. ' pts')

			-- completion bar
			local pct = (grp.total > 0) and (grp.done / grp.total) or 0
			local w = math.max(1, math.floor(pct * skinWidth + 0.5))
			local fill = (pct > 0) and (mastered and gold or accent) or '0,0,0,1'
			SKIN:Bang('!SetOption', 'MeterBar' .. g, 'Shape2',
				'Rectangle 0,0,' .. w .. ',3,1.5 | Fill Color ' .. fill .. ' | StrokeWidth 0')

			SKIN:Bang('!ShowMeter', 'MeterHeadTitle' .. g)
			SKIN:Bang('!ShowMeter', 'MeterHeadStats' .. g)
			SKIN:Bang('!ShowMeter', 'MeterHeadPts' .. g)
			SKIN:Bang('!ShowMeter', 'MeterBar' .. g)

			-- position label: "11-19 / 146", or a note when the page is empty
			local posText
			if #achList == 0 then
				posText = d and (showLocked and 'all done' or 'none') or '...'
			elseif #achList <= badgeFit then
				posText = tostring(#achList)
			else
				posText = (off + 1) .. '-' .. math.min(off + badgeFit, #achList)
					.. ' / ' .. #achList
			end
			SKIN:Bang('!SetOption', 'MeterHeadPos' .. g, 'Text', posText)
			SKIN:Bang('!SetOption', 'MeterHeadPos' .. g, 'ToolTipText',
				(#achList > badgeFit)
					and 'Scroll the row to page through - click to jump to the start'
					or  'Scroll a row to page through it')
			SKIN:Bang('!ShowMeter', 'MeterHeadPos' .. g)
			SKIN:Bang('!ShowMeter', 'MeterRowCatch' .. g)

			-- badges (newest first; accent frame on today's unlocks)
			for k = 1, BADGES_PER_ROW do
				local a = (k <= badgeFit) and achList[off + k] or nil
				local meter = 'MeterBadge' .. g .. '_' .. k
				if a and a.badge ~= '' then
					SKIN:Bang('!SetOption', meter, 'ToolTipTitle', a.title)
					if a.locked then
						SKIN:Bang('!SetOption', meter, 'ToolTipText',
							a.desc .. '  -  ' .. a.points .. ' pts  -  LOCKED')
					else
						local mode = a.hardcore and '' or '  (softcore)'
						SKIN:Bang('!SetOption', meter, 'ToolTipText',
							a.desc .. '  -  ' .. a.points .. ' pts  -  ' .. fmtDate(a.date) .. mode)
					end
					if a.achId then
						SKIN:Bang('!SetOption', meter, 'LeftMouseUpAction',
							'["https://retroachievements.org/achievement/' .. a.achId .. '"]')
					end
					SKIN:Bang('!SetOption', meter, 'MouseScrollUpAction',
						'[!CommandMeasure MeasureScript "Scroll(' .. g .. ',-1)"]')
					SKIN:Bang('!SetOption', meter, 'MouseScrollDownAction',
						'[!CommandMeasure MeasureScript "Scroll(' .. g .. ',1)"]')

					local isNew = (not a.locked) and a.date:sub(1, 10) == today
					SKIN:Bang('!SetOption', meter, 'SolidColor', isNew and accent or '0,0,0,0')
					SKIN:Bang('!SetOption', meter, 'Padding', isNew and '2,2,2,2' or '0,0,0,0')

					local url = imageHost .. a.badge
					if not iconCache[url] then iconCache[url] = localBadge(url) end
					if iconCache[url] then
						showBadge(g, k, iconCache[url])
					else
						SKIN:Bang('!SetOption', meter, 'ImageName', '')
						SKIN:Bang('!HideMeter', meter)
						if not urlSlots[url] then
							urlSlots[url] = {}
							dlQueue[#dlQueue + 1] = url
						end
						urlSlots[url][#urlSlots[url] + 1] = { g, k }
					end
				else
					SKIN:Bang('!SetOption', meter, 'ImageName', '')
					SKIN:Bang('!HideMeter', meter)
				end
			end
		else
			SKIN:Bang('!SetOption', 'MeterHeadTitle' .. g, 'Text', '')
			SKIN:Bang('!SetOption', 'MeterHeadStats' .. g, 'Text', '')
			SKIN:Bang('!SetOption', 'MeterHeadPts' .. g, 'Text', '')
			SKIN:Bang('!HideMeter', 'MeterHeadTitle' .. g)
			SKIN:Bang('!HideMeter', 'MeterHeadStats' .. g)
			SKIN:Bang('!HideMeter', 'MeterHeadPts' .. g)
			SKIN:Bang('!HideMeter', 'MeterHeadPos' .. g)
			SKIN:Bang('!HideMeter', 'MeterBar' .. g)
			SKIN:Bang('!HideMeter', 'MeterRowCatch' .. g)
			for k = 1, BADGES_PER_ROW do
				SKIN:Bang('!SetOption', 'MeterBadge' .. g .. '_' .. k, 'ImageName', '')
				SKIN:Bang('!HideMeter', 'MeterBadge' .. g .. '_' .. k)
			end
		end
	end

	-- "Order by" control
	SKIN:Bang('!SetOption', 'MeterOrderValue', 'Text', sortLabels[sortKeys[sortIndex]])
	SKIN:Bang('!SetOption', 'MeterOrderDir', 'Text', sortAsc and '^' or 'v')

	if #groups == 0 then
		SKIN:Bang('!SetOption', 'MeterStatus', 'Text',
			apiError and 'API error - check username / key (EDIT)'
			         or  'No games found')
		SKIN:Bang('!ShowMeter', 'MeterStatus')
	else
		SKIN:Bang('!HideMeter', 'MeterStatus')
	end

	SKIN:Bang('!UpdateMeter', '*')
	SKIN:Bang('!Redraw')

	startNext()
end
