-- RA.lua — parses the RetroAchievements API response, sorts it and
-- fills the card grid in RetroAchievements.ini.
-- Game icons are fetched through a single serial download queue
-- (one request at a time, each unique icon downloaded at most once
-- per session) to avoid hammering RA's CDN with bursts.

local achievements = {}
local sortKeys = { 'date', 'points', 'game' }
local sortIndex = 1
local sortAsc = false
local apiError = false
local months = { 'Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec' }

-- icon pipeline state
local iconCache = {}   -- url -> verified local file path
local urlCards = {}    -- url -> { card indexes } (rebuilt every Render)
local dlQueue = {}     -- urls waiting to download
local dlCurrent = nil  -- url currently in flight

-- temporary: dump raw profile response for debugging
function ProbeDone()
	local raw = SKIN:GetMeasure('MeasureProbe'):GetStringValue() or ''
	local f = io.open(SKIN:GetVariable('@') .. 'probe.txt', 'w')
	if f then f:write(raw) f:close() end
end

function Initialize()
	maxItems  = tonumber(SKIN:GetVariable('MaxItems', '6')) or 6
	imageHost = SKIN:GetVariable('ImageHost', 'https://media.retroachievements.org')
	accent    = SKIN:GetVariable('AccentColor', '250,126,0')
	dim       = SKIN:GetVariable('DimColor', '150,150,150')
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

-- called by MeasureRecent's FinishAction
function Parse()
	local raw = SKIN:GetMeasure('MeasureRecent'):GetStringValue() or ''
	achievements = {}
	apiError = false

	if raw:match('[Ii]nvalid') or raw:match('"[Ee]rrors?"') or raw:match('[Uu]nauthori[sz]ed') then
		apiError = true
	else
		-- response is a flat JSON array of flat objects, so %b{} splits records
		for obj in raw:gmatch('%b{}') do
			local a = {
				title    = unescape(obj:match('"Title"%s*:%s*"(.-)"') or ''),
				desc     = unescape(obj:match('"Description"%s*:%s*"(.-)"') or ''),
				game     = unescape(obj:match('"GameTitle"%s*:%s*"(.-)"') or ''),
				console  = unescape(obj:match('"ConsoleName"%s*:%s*"(.-)"') or ''),
				icon     = unescape(obj:match('"GameIcon"%s*:%s*"(.-)"') or ''),
				date     = obj:match('"Date"%s*:%s*"(.-)"') or '',
				points   = tonumber(obj:match('"Points"%s*:%s*(%d+)') or '0') or 0,
				gameId   = obj:match('"GameID"%s*:%s*(%d+)'),
				hardcore = obj:match('"HardcoreMode"%s*:%s*(%d+)') == '1',
			}
			if a.title ~= '' then achievements[#achievements + 1] = a end
		end
	end

	SortAndRender()
end

-- called by MeasureProfile's FinishAction
function ProfileDone()
	local pts = SKIN:GetMeasure('MeasureProfilePoints'):GetStringValue() or ''
	if pts ~= '' then
		SKIN:Bang('!SetOption', 'MeterPoints', 'Text', comma(pts) .. ' PTS')
		SKIN:Bang('!UpdateMeter', 'MeterPoints')
		SKIN:Bang('!Redraw')
	end
end

-- "Order by" value clicked: cycle date -> points -> game
function CycleSort()
	sortIndex = (sortIndex % #sortKeys) + 1
	sortAsc = (sortKeys[sortIndex] == 'game')  -- alphabetical starts ascending
	SortAndRender()
end

-- direction marker clicked: flip asc/desc
function ToggleDir()
	sortAsc = not sortAsc
	SortAndRender()
end

function SortAndRender()
	local key = sortKeys[sortIndex]
	table.sort(achievements, function(x, y)
		local a, b = x[key], y[key]
		if a == b then return x.date > y.date end
		if sortAsc then return a < b else return a > b end
	end)
	Render()
end

-- ================= icon download queue =================

local function showIcon(i, path)
	SKIN:Bang('!SetOption', 'MeterIcon' .. i, 'ImageName', path)
	SKIN:Bang('!ShowMeter', 'MeterIcon' .. i)
	SKIN:Bang('!UpdateMeter', 'MeterIcon' .. i)
end

local function startNext()
	if dlCurrent then return end  -- already busy
	local url = table.remove(dlQueue, 1)
	while url and iconCache[url] do url = table.remove(dlQueue, 1) end
	if not url then return end
	dlCurrent = url
	SKIN:Bang('!SetOption', 'MeasureIconDL', 'Url', url)
	SKIN:Bang('!SetOption', 'MeasureIconDL', 'DownloadFile', url:match('([^/]+)$') or 'icon.png')
	SKIN:Bang('!CommandMeasure', 'MeasureIconDL', 'Update')
end

-- FinishAction of MeasureIconDL
function IconDone()
	local url = dlCurrent
	dlCurrent = nil
	if url then
		local path = SKIN:GetMeasure('MeasureIconDL'):GetStringValue() or ''
		if path ~= '' and fileSize(path) > 0 then
			iconCache[url] = path
			-- assign to every card currently showing this game
			for _, i in ipairs(urlCards[url] or {}) do
				showIcon(i, path)
			end
			SKIN:Bang('!Redraw')
		end
	end
	startNext()
end

-- OnDownloadErrorAction / OnConnectErrorAction of MeasureIconDL
function IconFail()
	dlCurrent = nil  -- leave affected cards blank; retried on next data refresh
	startNext()
end

-- ================= rendering =================

function Render()
	urlCards = {}
	dlQueue = {}

	for i = 1, maxItems do
		local a = achievements[i]
		if a then
			local mode = a.hardcore and '' or ' · SC'
			SKIN:Bang('!SetOption', 'MeterGame' .. i, 'Text', a.game)
			SKIN:Bang('!SetOption', 'MeterMeta' .. i, 'Text',
				string.format('%d pts · %s%s', a.points, fmtDate(a.date), mode))

			-- tooltip: achievement details on hover
			SKIN:Bang('!SetOption', 'MeterGame' .. i, 'ToolTipTitle', a.title)
			SKIN:Bang('!SetOption', 'MeterGame' .. i, 'ToolTipText',
				(a.desc ~= '' and a.desc or a.game) .. ' (' .. a.console .. ')')

			-- click-through to the game page
			local action = a.gameId
				and ('["https://retroachievements.org/game/' .. a.gameId .. '"]') or ''
			SKIN:Bang('!SetOption', 'MeterGame' .. i, 'LeftMouseUpAction', action)
			SKIN:Bang('!SetOption', 'MeterIcon' .. i, 'LeftMouseUpAction', action)

			-- icon: cached -> show now; unknown -> blank + queue download
			if a.icon ~= '' then
				local url = imageHost .. a.icon
				if not urlCards[url] then
					urlCards[url] = {}
					if not iconCache[url] then dlQueue[#dlQueue + 1] = url end
				end
				urlCards[url][#urlCards[url] + 1] = i
				if iconCache[url] then
					showIcon(i, iconCache[url])
				else
					SKIN:Bang('!SetOption', 'MeterIcon' .. i, 'ImageName', '')
					SKIN:Bang('!HideMeter', 'MeterIcon' .. i)
				end
			else
				SKIN:Bang('!SetOption', 'MeterIcon' .. i, 'ImageName', '')
				SKIN:Bang('!HideMeter', 'MeterIcon' .. i)
			end

			SKIN:Bang('!ShowMeter', 'MeterGame' .. i)
			SKIN:Bang('!ShowMeter', 'MeterMeta' .. i)
		else
			SKIN:Bang('!SetOption', 'MeterGame' .. i, 'Text', '')
			SKIN:Bang('!SetOption', 'MeterMeta' .. i, 'Text', '')
			SKIN:Bang('!SetOption', 'MeterIcon' .. i, 'ImageName', '')
			SKIN:Bang('!HideMeter', 'MeterIcon' .. i)
			SKIN:Bang('!HideMeter', 'MeterGame' .. i)
			SKIN:Bang('!HideMeter', 'MeterMeta' .. i)
		end
	end

	-- "Order by" control
	SKIN:Bang('!SetOption', 'MeterOrderValue', 'Text', sortKeys[sortIndex]:upper())
	SKIN:Bang('!SetOption', 'MeterOrderDir', 'Text', sortAsc and '^' or 'v')

	if #achievements == 0 then
		SKIN:Bang('!SetOption', 'MeterStatus', 'Text',
			apiError and 'API error - check username / key (EDIT)'
			         or  'No achievements in this window')
		SKIN:Bang('!ShowMeter', 'MeterStatus')
	else
		SKIN:Bang('!HideMeter', 'MeterStatus')
	end

	SKIN:Bang('!UpdateMeter', '*')
	SKIN:Bang('!Redraw')

	startNext()
end
