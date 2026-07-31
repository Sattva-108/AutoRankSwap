---------------------------------------------------------------------------
-- Auto Rank Swap — Standalone Addon (no ElvUI dependency)
-- Monitors 2-min server debuffs on spells and auto-swaps action bar
-- buttons and macros to the next available lower rank.
---------------------------------------------------------------------------

local ADDON_NAME, ARS = ...

---------------------------------------------------------------------------
-- Local helpers (replacing ElvUI utilities)
---------------------------------------------------------------------------
local function wipe(t)
	for k in pairs(t) do t[k] = nil end
	return t
end

local function CopyTable(t)
	if not t then return nil end
	local copy = {}
	for k, v in pairs(t) do
		if type(v) == "table" then
			copy[k] = CopyTable(v)
		else
			copy[k] = v
		end
	end
	return copy
end

---------------------------------------------------------------------------
-- Constants
---------------------------------------------------------------------------
local CD_MONITOR_DEBUG = false
local SERVER_DEBUFF_MIN = 115
local SERVER_DEBUFF_MAX = 125
local WATCH_DELAY = 0.5
local MAX_SLOTS = 120 -- 10 standard bars × 12 slots

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------
ARS.cdWatching = {}
ARS.cdServerDebuffs = {}  -- persisted in SavedVariables
ARS.spellBookCache = {}   -- [spellName] = { { rank, rankNum, bookIndex }, ... }
ARS.pendingSwaps = {}     -- persisted in SavedVariables [actionSlot] = { ... }
ARS.pendingRestores = {}  -- volatile, not persisted
ARS.ignoredBars = {}      -- persisted in SavedVariables
ARS.ignoredSpells = {}    -- persisted in SavedVariables
ARS.ignoreBarMode = false -- visual mode for /cdignore
ARS.tempIgnoredBars = {}  -- volatile, used during config mode

-- Minimap icon and LDB provider
local ldbObject
local ARSDB
local highlightFrames = {}
local configDialogFrame

---------------------------------------------------------------------------
-- Debug
---------------------------------------------------------------------------
local function DebugPrint(...)
	if CD_MONITOR_DEBUG then
		print("|cFF00CCFF[ARS Debug]|r", ...)
	end
end

---------------------------------------------------------------------------
-- SavedVariables helpers
---------------------------------------------------------------------------
local function SaveDB()
	if not ARSDB then return end
	ARSDB.pendingSwaps = ARS.pendingSwaps
	ARSDB.cdServerDebuffs = ARS.cdServerDebuffs

	ARSDB.ignoredBars = ARSDB.ignoredBars or {}
	local bars = {}
	for barNum in pairs(ARS.ignoredBars) do
		tinsert(bars, barNum)
	end
	wipe(ARSDB.ignoredBars)
	for _, barNum in ipairs(bars) do
		ARSDB.ignoredBars[#ARSDB.ignoredBars + 1] = barNum
	end

	ARSDB.ignoredSpells = ARSDB.ignoredSpells or {}
	local spells = {}
	for spellName in pairs(ARS.ignoredSpells) do
		if type(spellName) == "string" then
			tinsert(spells, spellName)
		end
	end
	wipe(ARSDB.ignoredSpells)
	for _, spellName in ipairs(spells) do
		ARSDB.ignoredSpells[#ARSDB.ignoredSpells + 1] = spellName
	end
end

local function LoadDB()
	AutoRankSwapDB = AutoRankSwapDB or {}
	ARSDB = AutoRankSwapDB

	-- Initialize persistent state tables
	ARSDB.pendingSwaps = ARSDB.pendingSwaps or {}
	ARSDB.cdServerDebuffs = ARSDB.cdServerDebuffs or {}
	ARSDB.ignoredBars = ARSDB.ignoredBars or {}
	ARSDB.ignoredSpells = ARSDB.ignoredSpells or {}

	-- Point ARS state directly at the DB tables (persists across /reload)
	ARS.pendingSwaps = ARSDB.pendingSwaps
	ARS.cdServerDebuffs = ARSDB.cdServerDebuffs
	ARS.ignoredBars = {}
	if ARSDB.ignoredBars then
		for _, v in pairs(ARSDB.ignoredBars) do
			ARS.ignoredBars[v] = true
		end
	end
	ARS.ignoredSpells = {}
	for _, spellName in ipairs(ARSDB.ignoredSpells or {}) do
		if type(spellName) == "string" then
			ARS.ignoredSpells[spellName] = true
		end
	end
end

-- Map bar number → slot range, dynamically checking Dominos, ElvUI, Bartender, or Default Blizzard button states
local function IsSlotInIgnoredBar(slot)
	if not slot or not next(ARS.ignoredBars) then return false end

	for barNum in pairs(ARS.ignoredBars) do
		-- 1. Direct Dominos button action inspection
		local domFrame = _G["DominosFrame" .. barNum] or (Dominos and Dominos.Frame and Dominos.Frame:Get(barNum))
		if domFrame and domFrame.buttons then
			for _, btn in ipairs(domFrame.buttons) do
				if btn then
					local btnSlot = btn:GetAttribute("action") or btn:GetAttribute("action--base") or btn._state_action or btn.action
					if btnSlot and tonumber(btnSlot) == slot then
						return true
					end
				end
			end
		end

		-- 2. Direct ElvUI button action inspection
		for i = 1, 12 do
			local btn = _G["ElvUI_Bar" .. barNum .. "Button" .. i]
			if btn then
				local btnSlot = btn:GetAttribute("action") or btn._state_action or btn.action
				if btnSlot and tonumber(btnSlot) == slot then
					return true
				end
			end
		end

		-- 3. Direct Bartender4 button action inspection
		for i = 1, 12 do
			local btn = _G[format("BT4Button%d", (barNum - 1) * 12 + i)]
			if btn then
				local btnSlot = btn:GetAttribute("action") or btn._state_action or btn.action
				if btnSlot and tonumber(btnSlot) == slot then
					return true
				end
			end
		end

		-- 4. Standard WotLK / Blizzard Page-to-Slot Mapping (Bars 1..10 -> Slots 1..120):
		local pageMap = {
			[1]  = {1, 12},    -- Main Action Bar
			[2]  = {13, 24},   -- Action Page 2 / Bonus Bar
			[3]  = {25, 36},   -- MultiBarRight
			[4]  = {37, 48},   -- MultiBarLeft
			[5]  = {49, 60},   -- MultiBarBottomRight
			[6]  = {61, 72},   -- MultiBarBottomLeft
			[7]  = {73, 84},   -- Action Page 7
			[8]  = {85, 96},   -- Action Page 8
			[9]  = {97, 108},  -- Action Page 9
			[10] = {109, 120}, -- Action Page 10
		}
		local range = pageMap[barNum]
		if range then
			if slot >= range[1] and slot <= range[2] then
				return true
			end
		else
			local lo = (barNum - 1) * 12 + 1
			local hi = barNum * 12
			if slot >= lo and slot <= hi then
				return true
			end
		end
	end
	return false
end

-- Check if a spell matches any blacklisted full or partial spell name
local function IsSpellIgnored(spellName)
	if type(spellName) ~= "string" or not next(ARS.ignoredSpells) then return false end
	local lowerSpell = spellName:lower()
	for pattern in pairs(ARS.ignoredSpells) do
		if type(pattern) == "string" and lowerSpell:find(pattern:lower(), 1, true) then
			return true
		end
	end
	return false
end

---------------------------------------------------------------------------
-- Spell Book Scanner
---------------------------------------------------------------------------
local function ParseSpellRank(rankVal)
	if not rankVal then return 0 end
	if type(rankVal) == "number" then return rankVal end
	if rankVal == "" then return 0 end
	local rank = tonumber(tostring(rankVal):match("(%d+)"))
	return rank or 0
end

local function BuildSpellBookCache()
	wipe(ARS.spellBookCache)

	for tab = 1, GetNumSpellTabs() do
		local _, _, offset, numSpells = GetSpellTabInfo(tab)
		for i = 1, numSpells do
			local bookIndex = offset + i
			local spellName, rank = GetSpellName(bookIndex, BOOKTYPE_SPELL)
			if spellName then
				if not ARS.spellBookCache[spellName] then
					ARS.spellBookCache[spellName] = {}
				end
				tinsert(ARS.spellBookCache[spellName], {
					rank = rank or "",
					rankNum = ParseSpellRank(rank),
					bookIndex = bookIndex,
				})
			end
		end
	end

	-- Sort each spell's ranks descending (highest rank first)
	for spellName, ranks in pairs(ARS.spellBookCache) do
		sort(ranks, function(a, b) return a.rankNum > b.rankNum end)
	end

	-- Debug: show cached spells with multiple ranks
	local multiRank = 0
	for spellName, ranks in pairs(ARS.spellBookCache) do
		if #ranks > 1 then
			multiRank = multiRank + 1
			local ranksStr = ""
			for _, data in ipairs(ranks) do
				ranksStr = ranksStr .. data.rankNum .. "(" .. data.bookIndex .. ") "
			end
			DebugPrint("SpellBook: " .. spellName .. " ranks: " .. ranksStr)
		end
	end
	DebugPrint("SpellBook cache built: " .. multiRank .. " spells with multiple ranks")

	-- Scan action slots and show what's on them
	DebugPrint("=== Action Slot Scan ===")
	for slot = 1, MAX_SLOTS do
		local actionType, id = GetActionInfo(slot)
		if actionType == "spell" and id and id > 0 then
			local name, rank = GetSpellName(id, BOOKTYPE_SPELL)
			if name then
				DebugPrint("Slot " .. slot .. ": SPELL " .. tostring(name) .. " " .. tostring(rank) .. " bookIndex=" .. id)
			end
		elseif actionType == "macro" and id and id > 0 then
			local macroName = GetMacroInfo(id)
			local macroSpell = GetMacroSpell(id)
			DebugPrint("Slot " .. slot .. ": MACRO " .. tostring(macroName) .. " spell=" .. tostring(macroSpell))
		end
	end
	DebugPrint("=== End Action Slot Scan ===")
end

-- Find the bookIndex for a specific spell + rank
local function FindSpellBookIndex(spellName, rank)
	local ranks = ARS.spellBookCache[spellName]
	if not ranks then return nil end
	local targetRank = ParseSpellRank(rank)

	-- Fallback: Если ранг не указан (часто в макросах), берем самый высокий доступный
	if targetRank == 0 and #ranks > 0 then
		DebugPrint("FindSpellBookIndex: No rank specified for " .. spellName .. ", assuming highest rank.")
		return ranks[1].bookIndex
	end

	for _, data in ipairs(ranks) do
		if data.rankNum == targetRank then
			return data.bookIndex
		end
	end
	return nil
end

-- Find the next lower rank of a spell. Returns bookIndex, rankStr or nil if no lower rank
local function FindLowerRank(spellName, currentRankStr)
	local ranks = ARS.spellBookCache[spellName]
	if not ranks or #ranks == 0 then
		DebugPrint("FindLowerRank: " .. spellName .. " NOT in spellbook cache")
		return nil, nil
	end

	local currentRank = ParseSpellRank(currentRankStr)
	local now = GetTime()
	DebugPrint("FindLowerRank: " .. spellName .. " currentRank=" .. currentRank .. " availableRanks=" .. #ranks)

	for _, data in ipairs(ranks) do
		DebugPrint("  -> rank=" .. data.rankNum .. " bookIndex=" .. data.bookIndex)
		if data.rankNum < currentRank then
			-- Check if this specific lower rank is ALSO currently debuffed!
			local debuffKey = spellName .. ":" .. tostring(data.rank)
			local debuff = ARS.cdServerDebuffs[debuffKey]
			local isDebuffed = false

			if debuff then
				local remaining = (debuff.expiry or 0) - now
				if remaining > 0 then
					isDebuffed = true
				end
			end

			if not isDebuffed then
				DebugPrint("FindLowerRank: FOUND available lower rank " .. data.rankNum .. " bookIndex=" .. data.bookIndex)
				return data.bookIndex, data.rank
			else
				DebugPrint("FindLowerRank: SKIPPING rank " .. data.rankNum .. " (currently debuffed)")
			end
		end
	end
	DebugPrint("FindLowerRank: NO available lower rank found than " .. currentRank)
	return nil, nil
end

---------------------------------------------------------------------------
-- Action Slot Scanner (standard WoW API — no ElvUI dependency)
---------------------------------------------------------------------------

-- Find all action slots that have a specific spell name
-- Iterates standard action slots 1–120 (works with Default UI, ElvUI, Bartender)
local function FindActionSlotsWithSpell(spellName)
	local slots = {}

	for slot = 1, MAX_SLOTS do
		if not IsSlotInIgnoredBar(slot) then
			local actionType, id = GetActionInfo(slot)
			if actionType == "spell" and id and id > 0 then
				local name, rank = GetSpellName(id, BOOKTYPE_SPELL)
				if name == spellName then
					DebugPrint("FindSlots: slot=" .. slot .. " name=" .. tostring(name) .. " rank=" .. tostring(rank))
					tinsert(slots, { slot = slot, spellBookIndex = id, rank = rank or 0 })
				end
			elseif actionType == "macro" and id and id > 0 then
				local name, icon, text = GetMacroInfo(id)
				local macroSpell = GetMacroSpell(id)
				if (text and text:find(spellName, 1, true)) or (macroSpell == spellName) then
					DebugPrint("FindSlots: slot=" .. slot .. " MACRO match=" .. spellName)
					tinsert(slots, { slot = slot, isMacro = true })
				end
			end
		else
			DebugPrint("FindSlots: SKIPPING ignored slot " .. slot)
		end
	end
	DebugPrint("FindSlots: found " .. #slots .. " slots for " .. spellName)
	return slots
end

---------------------------------------------------------------------------
-- Swap Logic
---------------------------------------------------------------------------
local function PerformSwap(actionSlot, newBookIndex)
	DebugPrint("PerformSwap: slot=" .. actionSlot .. " newBookIndex=" .. newBookIndex)

	if InCombatLockdown() then
		DebugPrint("PerformSwap: IN COMBAT, queuing")
		ARS.pendingSwaps[actionSlot] = ARS.pendingSwaps[actionSlot] or {}
		ARS.pendingSwaps[actionSlot].newBookIndex = newBookIndex
		return false
	end

	-- Store what's currently on the slot ONLY if not already stored (preserve original)
	if not ARS.pendingSwaps[actionSlot] or not ARS.pendingSwaps[actionSlot].originalSpell then
		local actionType, id = GetActionInfo(actionSlot)
		DebugPrint("PerformSwap: current on slot: type=" .. tostring(actionType) .. " id=" .. tostring(id))
		if actionType == "spell" and id and id > 0 then
			local name, rank = GetSpellName(id, BOOKTYPE_SPELL)
			DebugPrint("PerformSwap: saving original: " .. tostring(name) .. " " .. tostring(rank))
			ARS.pendingSwaps[actionSlot] = ARS.pendingSwaps[actionSlot] or {}
			ARS.pendingSwaps[actionSlot].originalSpell = name
			ARS.pendingSwaps[actionSlot].originalRank = rank or ""
			ARS.pendingSwaps[actionSlot].originalBookIndex = id
		end
	else
		DebugPrint("PerformSwap: preserving existing original: " .. tostring(ARS.pendingSwaps[actionSlot].originalSpell) .. " " .. tostring(ARS.pendingSwaps[actionSlot].originalRank))
	end

	-- Pick up current action and discard it
	PickupAction(actionSlot)
	local cursorType = GetCursorInfo()
	DebugPrint("PerformSwap: after PickupAction, cursor=" .. tostring(cursorType))
	ClearCursor()

	-- Place the new spell
	PickupSpell(newBookIndex, BOOKTYPE_SPELL)
	cursorType = GetCursorInfo()
	DebugPrint("PerformSwap: after PickupSpell, cursor=" .. tostring(cursorType))
	if cursorType == "spell" then
		PlaceAction(actionSlot)
		ClearCursor()
		ARS.pendingSwaps[actionSlot].newBookIndex = nil
		SaveDB()
		DebugPrint("PerformSwap: SUCCESS - placed on slot " .. actionSlot)
		return true
	else
		ClearCursor()
		DebugPrint("PerformSwap: FAILED - no spell on cursor")
		return false
	end
end

local function PerformRestore(actionSlot)
	local swap = ARS.pendingSwaps[actionSlot]
	if not swap or not swap.originalSpell then
		DebugPrint("PerformRestore: slot=" .. actionSlot .. " NO SWAP DATA")
		return false
	end
	DebugPrint("PerformRestore: slot=" .. actionSlot .. " restoring " .. tostring(swap.originalSpell) .. " " .. tostring(swap.originalRank))

	if InCombatLockdown() then
		DebugPrint("PerformRestore: IN COMBAT, queuing")
		ARS.pendingRestores[actionSlot] = CopyTable(swap)
		return false
	end

	-- Find the original spell in spellbook (may have new bookIndex)
	local bookIndex = FindSpellBookIndex(swap.originalSpell, swap.originalRank)
	DebugPrint("PerformRestore: bookIndex=" .. tostring(bookIndex))
	if not bookIndex then
		DebugPrint("PerformRestore: FAILED - cannot find in spellbook")
		return false
	end

	-- Pick up current action and discard it
	PickupAction(actionSlot)
	local cursorType = GetCursorInfo()
	DebugPrint("PerformRestore: after PickupAction, cursor=" .. tostring(cursorType))
	ClearCursor()

	-- Place the original spell back
	PickupSpell(bookIndex, BOOKTYPE_SPELL)
	cursorType = GetCursorInfo()
	DebugPrint("PerformRestore: after PickupSpell, cursor=" .. tostring(cursorType))
	if cursorType == "spell" then
		PlaceAction(actionSlot)
		ClearCursor()
		ARS.pendingSwaps[actionSlot] = nil
		SaveDB()
		DebugPrint("PerformRestore: SUCCESS - restored on slot " .. actionSlot)
		return true
	else
		ClearCursor()
		DebugPrint("PerformRestore: FAILED - no spell on cursor")
		return false
	end
end

---------------------------------------------------------------------------
-- Macro Swap Logic
---------------------------------------------------------------------------
local function FindMacroSlot(spellName)
	for slot = 1, MAX_SLOTS do
		if not IsSlotInIgnoredBar(slot) then
			local actionType, id = GetActionInfo(slot)
			if actionType == "macro" and id and id > 0 then
				local name, icon, text = GetMacroInfo(id)
				local macroSpell = GetMacroSpell(id)
				if (text and text:find(spellName, 1, true)) or (macroSpell == spellName) then
					DebugPrint("FindMacroSlot: slot=" .. slot .. " id=" .. id .. " text match for " .. spellName)
					return slot, id
				end
			end
		end
	end
	DebugPrint("FindMacroSlot: no unignored macro found for " .. spellName)
	return nil, nil
end

local function PerformMacroSwap(spellName, lowerRankStr)
	local slot, macroID = FindMacroSlot(spellName)
	if not slot then
		DebugPrint("PerformMacroSwap: no macro found for " .. spellName)
		return false
	end

	if InCombatLockdown() then
		DebugPrint("PerformMacroSwap: IN COMBAT, queuing")
		ARS.pendingSwaps[slot] = ARS.pendingSwaps[slot] or {}
		ARS.pendingSwaps[slot].isMacro = true
		ARS.pendingSwaps[slot].spellName = spellName
		ARS.pendingSwaps[slot].lowerRankStr = lowerRankStr
		return false
	end

	-- Get current macro text
	local name, icon, text = GetMacroInfo(macroID)
	if not text then
		DebugPrint("PerformMacroSwap: no macro text for slot " .. slot)
		return false
	end
	DebugPrint("PerformMacroSwap: macro name=" .. tostring(name) .. " text=" .. tostring(text))

	-- Store original text if not already stored
	if not ARS.pendingSwaps[slot] or not ARS.pendingSwaps[slot].originalMacroText then
		ARS.pendingSwaps[slot] = ARS.pendingSwaps[slot] or {}
		ARS.pendingSwaps[slot].isMacro = true
		ARS.pendingSwaps[slot].originalMacroText = text
		ARS.pendingSwaps[slot].originalSpell = spellName
		ARS.pendingSwaps[slot].slot = slot
		ARS.pendingSwaps[slot].macroID = macroID
		DebugPrint("PerformMacroSwap: saved original macro text")
	else
		DebugPrint("PerformMacroSwap: preserving existing original macro text")
	end

	-- Replace spell name with spell name + rank in macro text
	-- ALWAYS use the pristine original text to prevent (Rank 5)(Rank 6) stacking
	local baseText = ARS.pendingSwaps[slot].originalMacroText or text
	local safeSpellName = spellName:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
	local newText = gsub(baseText, safeSpellName, spellName .. "(" .. lowerRankStr .. ")")

	-- Fallback для случаев, когда регистр букв в макросе отличается (например, Земной Шок вместо Земной шок)
	if newText == baseText then
		local lowerBase = baseText:lower()
		local lowerSpell = spellName:lower()
		local startIdx, endIdx = lowerBase:find(lowerSpell, 1, true)
		if startIdx and endIdx then
			local matchedText = baseText:sub(startIdx, endIdx)
			safeSpellName = matchedText:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
			newText = gsub(baseText, safeSpellName, spellName .. "(" .. lowerRankStr .. ")")
		end
	end

	DebugPrint("PerformMacroSwap: old=" .. tostring(text))
	DebugPrint("PerformMacroSwap: base=" .. tostring(baseText))
	DebugPrint("PerformMacroSwap: new=" .. tostring(newText))

	if newText ~= text then
		EditMacro(macroID, nil, nil, newText)
		ARS.pendingSwaps[slot].lowerRankStr = nil
		ARS.pendingSwaps[slot].spellName = nil
		SaveDB()
		DebugPrint("PerformMacroSwap: SUCCESS - edited macro on slot " .. slot)
		print(format("|cFF00CCFF[CD Monitor]|r Macro on slot #%d: |cFFFFFFFF%s|r -> |cFFFFFFFF%s(%s)|r", slot, spellName, spellName, lowerRankStr))
		return true
	else
		DebugPrint("PerformMacroSwap: FAILED - spell name not found in macro text")
		return false
	end
end

local function PerformMacroRestore(slot)
	local swap = ARS.pendingSwaps[slot]
	if not swap or not swap.isMacro or not swap.originalMacroText then
		DebugPrint("PerformMacroRestore: slot=" .. slot .. " NO MACRO DATA")
		return false
	end

	if InCombatLockdown() then
		DebugPrint("PerformMacroRestore: IN COMBAT, queuing")
		ARS.pendingRestores[slot] = CopyTable(swap)
		return false
	end

	local macroID = swap.macroID
	if not macroID then
		local actionType, id = GetActionInfo(slot)
		if actionType == "macro" then
			macroID = id
		end
	end

	if not macroID then
		DebugPrint("PerformMacroRestore: no macroID for slot " .. slot)
		return false
	end

	DebugPrint("PerformMacroRestore: restoring macro text: " .. tostring(swap.originalMacroText))
	EditMacro(macroID, nil, nil, swap.originalMacroText)
	ARS.pendingSwaps[slot] = nil
	SaveDB()
	DebugPrint("PerformMacroRestore: SUCCESS - restored macro on slot " .. slot)
	return true
end

---------------------------------------------------------------------------
-- Pending Swap/Restore Processors
---------------------------------------------------------------------------
local function ProcessPendingSwaps()
	if InCombatLockdown() then return end
	local changed = false
	for slot, data in pairs(ARS.pendingSwaps) do
		if data.isMacro then
			if data.lowerRankStr and data.spellName then
				DebugPrint("ProcessPendingSwaps: applying queued macro swap slot=" .. slot)
				local ok = PerformMacroSwap(data.spellName, data.lowerRankStr)
				if ok then
					changed = true
					DebugPrint("ProcessPendingSwaps: macro SUCCESS slot=" .. slot)
				end
			end
			if not data.lowerRankStr and not data.spellName and not data.originalMacroText then
				ARS.pendingSwaps[slot] = nil
				changed = true
			end
		elseif data.newBookIndex then
			DebugPrint("ProcessPendingSwaps: applying queued swap slot=" .. slot)
			local ok = PerformSwap(slot, data.newBookIndex)
			if ok then
				changed = true
				DebugPrint("ProcessPendingSwaps: SUCCESS slot=" .. slot)
			else
				DebugPrint("ProcessPendingSwaps: FAILED slot=" .. slot)
			end
		end
	end
	if changed then
		SaveDB()
	end
end

local function ProcessPendingRestores()
	if InCombatLockdown() then return end
	for slot, data in pairs(ARS.pendingRestores) do
		local ok
		if data.isMacro then
			ok = PerformMacroRestore(slot)
		else
			ok = PerformRestore(slot)
		end
		if ok then
			DebugPrint("ProcessPendingRestores: SUCCESS slot=" .. slot)
		end
	end
	wipe(ARS.pendingRestores)
end

---------------------------------------------------------------------------
-- Popup system
---------------------------------------------------------------------------
local POPUP_FADE_IN = 0.3
local POPUP_HOLD = 2.0
local POPUP_FADE_OUT = 0.7
local POPUP_TOTAL = POPUP_FADE_IN + POPUP_HOLD + POPUP_FADE_OUT

local popupFrame
local popupText
local popupIcon
local popupSpellIcon
local popupElapsed = 0
local popupActive = false

local function Popup_Show(spellName, text, textColor, iconTexture)
	if not popupFrame then return end
	popupText:SetText(text)
	popupText:SetTextColor(textColor.r, textColor.g, textColor.b)
	if iconTexture then
		popupSpellIcon:SetTexture(iconTexture)
		popupSpellIcon:Show()
		popupIcon:Show()
	else
		popupSpellIcon:Hide()
		popupIcon:Hide()
	end
	popupFrame:SetAlpha(0)
	popupFrame:Show()
	popupActive = true
	popupElapsed = 0
end

local function Popup_OnUpdate(self, elapsed)
	if not popupActive then return end
	popupElapsed = popupElapsed + elapsed
	local t = popupElapsed
	local alpha = 0
	if t < POPUP_FADE_IN then
		alpha = t / POPUP_FADE_IN
	elseif t < POPUP_FADE_IN + POPUP_HOLD then
		alpha = 1
	elseif t < POPUP_TOTAL then
		alpha = 1 - (t - POPUP_FADE_IN - POPUP_HOLD) / POPUP_FADE_OUT
	else
		self:Hide()
		popupActive = false
		return
	end
	self:SetAlpha(alpha)
end

local function CreatePopupFrame()
	popupFrame = CreateFrame("Frame", "AutoRankSwap_Popup", UIParent)
	popupFrame:SetFrameStrata("FULLSCREEN_DIALOG")
	popupFrame:SetWidth(320)
	popupFrame:SetHeight(70)
	popupFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 200)
	popupFrame:SetBackdrop({
		bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
		edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
		tile = true, tileSize = 32, edgeSize = 32,
		insets = {left = 11, right = 12, top = 12, bottom = 11}
	})
	popupFrame:SetAlpha(0)
	popupFrame:Hide()
	popupFrame:SetScript("OnUpdate", Popup_OnUpdate)

	popupSpellIcon = popupFrame:CreateTexture(nil, "ARTWORK")
	popupSpellIcon:SetWidth(48)
	popupSpellIcon:SetHeight(48)
	popupSpellIcon:SetPoint("LEFT", popupFrame, "LEFT", 18, 0)
	popupSpellIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

	popupIcon = popupFrame:CreateTexture(nil, "OVERLAY")
	popupIcon:SetWidth(50)
	popupIcon:SetHeight(50)
	popupIcon:SetPoint("CENTER", popupSpellIcon, "CENTER", 0, 0)
	popupIcon:SetTexture(0, 0, 0, 0.5)

	popupText = popupFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
	popupText:SetPoint("LEFT", popupSpellIcon, "RIGHT", 12, 0)
	popupText:SetPoint("RIGHT", popupFrame, "RIGHT", -15, 0)
	popupText:SetJustifyH("CENTER")
	popupText:SetText("")
end

---------------------------------------------------------------------------
-- CD Tracker UI (3.3.5 Compatible)
---------------------------------------------------------------------------
local ICON_SIZE = 60
local ICON_SPACING = 4
local trackerAnchorFrame
local trackerIcons = {}

local function SaveTrackerAnchor()
	if not AutoRankSwapDB then AutoRankSwapDB = {} end
	local point, _, relativePoint, xOfs, yOfs = trackerAnchorFrame:GetPoint()
	AutoRankSwapDB.trackerAnchor = { point = point, relativePoint = relativePoint, x = xOfs, y = yOfs }
end

local function ARS_UpdateTrackerUI()
	if not trackerAnchorFrame then return end
	local index = 1
	local now = GetTime()

	local sortedDebuffs = {}
	for debuffKey, data in pairs(ARS.cdServerDebuffs) do
		local remaining = (data.expiry or 0) - now
		if remaining > 0 then
			tinsert(sortedDebuffs, data)
		end
	end
	table.sort(sortedDebuffs, function(a, b) return (a.expiry or 0) < (b.expiry or 0) end)

	for _, data in ipairs(sortedDebuffs) do
		local icon = trackerIcons[index]
		if not icon then
			icon = CreateFrame("Frame", nil, trackerAnchorFrame)
			icon:SetSize(ICON_SIZE, ICON_SIZE)
			icon:SetPoint("LEFT", trackerAnchorFrame, "LEFT", (index - 1) * (ICON_SIZE + ICON_SPACING), 0)

			icon.texture = icon:CreateTexture(nil, "BACKGROUND")
			icon.texture:SetAllPoints()
			icon.texture:SetTexCoord(0.08, 0.92, 0.08, 0.92)

			icon.cd = CreateFrame("Cooldown", nil, icon, "CooldownFrameTemplate")
			icon.cd:SetAllPoints()

			icon.rankText = icon:CreateFontString(nil, "OVERLAY", "SystemFont_Outline_Small")
			icon.rankText:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", 2, -2)
			icon.rankText:SetTextColor(1, 1, 1)

			trackerIcons[index] = icon
		end

		icon.texture:SetTexture(data.texture)
		local rankNum = data.rank and tostring(data.rank):match("%d+") or ""
		icon.rankText:SetText(rankNum)

		icon.cd:SetCooldown(data.expiry - data.duration, data.duration)
		icon:Show()
		index = index + 1
	end

	for i = index, #trackerIcons do
		trackerIcons[i]:Hide()
	end

	if index > 1 then
		trackerAnchorFrame:SetWidth((index - 1) * (ICON_SIZE + ICON_SPACING) - ICON_SPACING)
	else
		trackerAnchorFrame:SetWidth(ICON_SIZE)
	end
end

local function ARS_ToggleTrackerUnlock(enable)
	if not trackerAnchorFrame then return end
	if enable ~= nil then
		trackerAnchorFrame.isUnlocked = enable
	else
		trackerAnchorFrame.isUnlocked = not trackerAnchorFrame.isUnlocked
	end

	if trackerAnchorFrame.isUnlocked then
		trackerAnchorFrame.bg:Show()
		trackerAnchorFrame.text:Show()
		print("|cFF00CCFF[CD Monitor]|r Tracker UI UNLOCKED. Drag the green box to move.")
	else
		trackerAnchorFrame.bg:Hide()
		trackerAnchorFrame.text:Hide()
		print("|cFF00CCFF[CD Monitor]|r Tracker UI LOCKED.")
	end
end

local function ARS_CreateTrackerUI()
	trackerAnchorFrame = CreateFrame("Frame", "ARS_CDTrackerAnchor", UIParent)
	trackerAnchorFrame:SetSize(ICON_SIZE, ICON_SIZE)

	if AutoRankSwapDB and AutoRankSwapDB.trackerAnchor then
		local p = AutoRankSwapDB.trackerAnchor
		trackerAnchorFrame:SetPoint(p.point, UIParent, p.relativePoint or p.point, p.x, p.y)
	else
		trackerAnchorFrame:SetPoint('BOTTOM', UIParent, 0, 128)
	end

	trackerAnchorFrame:SetMovable(true)
	trackerAnchorFrame:EnableMouse(true)
	trackerAnchorFrame:RegisterForDrag("LeftButton")
	trackerAnchorFrame:SetScript("OnDragStart", function(self)
		if self.isUnlocked then
			self:StartMoving()
		end
	end)
	trackerAnchorFrame:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		SaveTrackerAnchor()
	end)

	trackerAnchorFrame.bg = trackerAnchorFrame:CreateTexture(nil, "BACKGROUND")
	trackerAnchorFrame.bg:SetAllPoints()
	trackerAnchorFrame.bg:SetTexture(0, 1, 0, 0.4)
	trackerAnchorFrame.bg:Hide()

	trackerAnchorFrame.text = trackerAnchorFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	trackerAnchorFrame.text:SetPoint("BOTTOM", trackerAnchorFrame, "TOP", 0, 4)
	trackerAnchorFrame.text:SetText("Иконки КД")
	trackerAnchorFrame.text:Hide()
end

---------------------------------------------------------------------------
-- Core: Detection + Auto-Rank-Swap
---------------------------------------------------------------------------
local function ProcessWatching()
	local now = GetTime()
	for spellName, data in pairs(ARS.cdWatching) do
		if now - data[1] >= WATCH_DELAY then
			local castRank = data[3]

			-- Fallback to highest rank if empty (macro casts usually don't send rank to API)
			if not castRank or castRank == "" then
				local ranks = ARS.spellBookCache[spellName]
				if ranks and ranks[1] then
					castRank = ranks[1].rank
					DebugPrint("ProcessWatching: Rank was empty, assuming highest rank: " .. castRank)
				end
			end

			local bookIndex = FindSpellBookIndex(spellName, castRank)
			local start, duration = 0, 0

			if bookIndex then
				start, duration = GetSpellCooldown(bookIndex, BOOKTYPE_SPELL)
			end
			start = start or 0
			duration = duration or 0

			if duration >= SERVER_DEBUFF_MIN and duration <= SERVER_DEBUFF_MAX then
				if IsSpellIgnored(spellName) then
					DebugPrint("ProcessWatching: " .. spellName .. " is in ignore list. Skipping.")
				else
					local debuffKey = spellName .. ":" .. tostring(castRank)

					if not ARS.cdServerDebuffs[debuffKey] then
						DebugPrint("ProcessWatching: " .. spellName .. " Rank " .. tostring(castRank) .. " duration=" .. duration)
						ARS.cdServerDebuffs[debuffKey] = {expiry = now + duration, duration = duration, texture = data[4], rank = castRank, spellName = spellName}
						SaveDB()
						ARS_UpdateTrackerUI()
						Popup_Show(spellName, "DISABLED", {r=1, g=0.2, b=0.2}, data[4])
						PlaySoundFile("Sound\\Interface\\Error.wav", "Master")
						print(format("|cFFFF0000[CD Alert]|r |cFFFFFFFF%s|r Rank %s was DISABLED for 2 minutes by server!", spellName, tostring(castRank)))

						-- Auto-rank-swap: only swap slots with the AFFECTED rank
						local castRankNum = ParseSpellRank(castRank)
						DebugPrint("ProcessWatching: castRank=" .. tostring(castRank) .. " castRankNum=" .. castRankNum)
						local slots = FindActionSlotsWithSpell(spellName)
						for _, slotInfo in ipairs(slots) do
							if slotInfo.isMacro then
								-- Macro: always swap when any rank is debuffed
								local ranks = ARS.spellBookCache[spellName]
								if ranks and #ranks > 1 then
									local lowerBookIndex, lowerRank = FindLowerRank(spellName, castRank)
									if lowerRank then
										DebugPrint("ProcessWatching: MACRO swap " .. castRank .. " -> " .. lowerRank)
										PerformMacroSwap(spellName, lowerRank)
									else
										DebugPrint("ProcessWatching: MACRO no lower rank available for " .. castRank)
									end
								end
							else
								-- Direct spell slot: only swap if rank matches
								local slotRankNum = ParseSpellRank(slotInfo.rank)
								DebugPrint("ProcessWatching: slot=" .. slotInfo.slot .. " slotRank=" .. slotRankNum .. " castRank=" .. castRankNum)
								if slotRankNum == castRankNum then
									local lowerBookIndex, lowerRank = FindLowerRank(spellName, slotInfo.rank)
									if lowerBookIndex then
										local ok = PerformSwap(slotInfo.slot, lowerBookIndex)
										if ok then
											print(format("|cFF00CCFF[CD Monitor]|r Swapped |cFFFFFFFF%s %s|r -> |cFFFFFFFF%s %s|r on slot #%d", spellName, slotInfo.rank, spellName, lowerRank, slotInfo.slot))
										end
									else
										print(format("|cFFFF0000[CD Monitor]|r |cFFFFFFFF%s %s|r has no lower rank to swap to!", spellName, slotInfo.rank))
									end
								else
									DebugPrint("ProcessWatching: slot=" .. slotInfo.slot .. " SKIPPED (rank " .. slotRankNum .. " != " .. castRankNum .. ")")
								end
							end
						end
					end
				end
			end
			ARS.cdWatching[spellName] = nil
		end
	end
end

local function CheckDebuffExpiry()
	local now = GetTime()
	local changed = false
	for debuffKey, data in pairs(ARS.cdServerDebuffs) do
		local remaining = (data.expiry or 0) - now
		if remaining <= 0 then
			local spellName = data.spellName

			-- Remove this debuff
			ARS.cdServerDebuffs[debuffKey] = nil
			changed = true

			-- Check if a higher rank is already available
			local expiredRankNum = ParseSpellRank(data.rank)
			local higherRankAvailable = false
			local ranks = ARS.spellBookCache[spellName]

			if ranks then
				for _, rData in ipairs(ranks) do
					if rData.rankNum > expiredRankNum then
						local hKey = spellName .. ":" .. rData.rank
						if not ARS.cdServerDebuffs[hKey] then
							higherRankAvailable = true
							break
						end
					end
				end
			end

			-- Only show the alert if no higher rank is currently available
			if not higherRankAvailable then
				Popup_Show(spellName, "ENABLED", {r=0.2, g=1, b=0.2}, data.texture)
				PlaySoundFile("Sound\\Interface\\MagicClick.wav", "Master")
				print(format("|cFF00FF00[CD Alert]|r |cFFFFFFFF%s|r Rank %s is ENABLED again!", spellName, tostring(data.rank)))
			end

			-- Restore original spell on all affected slots
			for slot, swap in pairs(ARS.pendingSwaps) do
				if swap.originalSpell == spellName and (swap.isMacro or swap.originalRank == data.rank) then
					DebugPrint("CheckDebuffExpiry: restoring slot=" .. slot .. " isMacro=" .. tostring(swap.isMacro))
					local ok
					if swap.isMacro then
						ok = PerformMacroRestore(slot)
					else
						ok = PerformRestore(slot)
					end
					if ok then
						print(format("|cFF00CCFF[CD Monitor]|r Restored |cFFFFFFFF%s|r on slot #%d", spellName, slot))
					end
				end
			end
		end
	end
	if changed then
		SaveDB()
		ARS_UpdateTrackerUI()
	end
end

---------------------------------------------------------------------------
-- OnUpdate & Event Handlers
---------------------------------------------------------------------------
local function CDMonitor_OnUpdate(self, elapsed)
	ProcessWatching()
	CheckDebuffExpiry()

	if not next(ARS.cdWatching) and not next(ARS.cdServerDebuffs) and not popupActive then
		self:SetScript("OnUpdate", nil)
	end
end

local function EnsureOnUpdate()
	if cdMonitorFrame and not cdMonitorFrame:GetScript("OnUpdate") then
		cdMonitorFrame:SetScript("OnUpdate", CDMonitor_OnUpdate)
	end
end

---------------------------------------------------------------------------
-- Post-combat validation: restore any macros that got stuck
---------------------------------------------------------------------------
local function ValidateMacroRestores()
	for slot = 1, MAX_SLOTS do
		local actionType, id = GetActionInfo(slot)
		if actionType == "macro" and id and id > 0 then
			local name, icon, text = GetMacroInfo(id)
			if text then
				local macroSpell = GetMacroSpell(id)
				if macroSpell then
					-- Check if ANY rank of this spell has an active debuff
					local hasActiveDebuff = false
					for _, d in pairs(ARS.cdServerDebuffs) do
						if d.spellName == macroSpell then
							local rem = (d.expiry or 0) - GetTime()
							if rem > 0 then
								hasActiveDebuff = true
								break
							end
						end
					end

					if not hasActiveDebuff then
						-- No active debuff - check if macro still has rank suffix
						local safeSpellName = macroSpell:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
						local rankPattern = safeSpellName .. "%((.-)%)"
						local foundRank = text:match(rankPattern)
						if foundRank then
							-- Try to restore from stored original text
							local swap = ARS.pendingSwaps[slot]
							local restore = ARS.pendingRestores[slot]
							local originalText = (swap and swap.originalMacroText) or (restore and restore.originalMacroText)
							if originalText then
								EditMacro(id, nil, nil, originalText)
								ARS.pendingSwaps[slot] = nil
								ARS.pendingRestores[slot] = nil
								print(format("|cFF00CCFF[CD Monitor]|r Post-combat: fixed macro on slot #%d (restored original)", slot))
							else
								-- No stored text: remove the entire (Rank N) pattern
								local safeFoundRank = foundRank:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
								local patternToRemove = safeSpellName .. "%(" .. safeFoundRank .. "%)"
								local fixedText = gsub(text, patternToRemove, macroSpell)
								if fixedText ~= text then
									EditMacro(id, nil, nil, fixedText)
									print(format("|cFF00CCFF[CD Monitor]|r Post-combat: fixed macro on slot #%d (removed rank suffix)", slot))
								end
							end
						end
					end
				end
			end
		end
	end
end

local function CDMonitor_OnEvent(self, event, unit, spell, rank)
	if event == "UNIT_SPELLCAST_SUCCEEDED" and unit == "player" then
		local spellFullName = rank and (spell .. "(" .. rank .. ")") or spell
		local texture = GetSpellTexture(spellFullName)
		ARS.cdWatching[spell] = {GetTime(), spell, rank, texture}
		EnsureOnUpdate()
	elseif event == "PLAYER_ENTERING_WORLD" then
		wipe(ARS.cdWatching)
		BuildSpellBookCache()

		-- Cleanup stuck debuffs (happens when client restarts and GetTime() resets to 0)
		local now = GetTime()
		local changed = false
		for k, v in pairs(ARS.cdServerDebuffs) do
			local remaining = (v.expiry or 0) - now
			if remaining < 0 or remaining > 300 then
				DebugPrint("Startup Audit: Cleared stuck debuff for " .. tostring(k))
				ARS.cdServerDebuffs[k] = nil
				changed = true
			end
		end
		if changed then
			SaveDB()
			ARS_UpdateTrackerUI()
		end

		-- Startup audit: clean up any stale state from before /reload or logout
		CheckDebuffExpiry()
		ValidateMacroRestores()
		EnsureOnUpdate()
	elseif event == "PLAYER_REGEN_ENABLED" then
		ProcessPendingSwaps()
		ProcessPendingRestores()
		ValidateMacroRestores()
	elseif event == "LEARNED_SPELL_IN_TAB" then
		BuildSpellBookCache()
	end
end

---------------------------------------------------------------------------
-- Manual scan: check all action slots for server debuffs
---------------------------------------------------------------------------
local function ManualScan()
	DebugPrint("Manual scan: checking all action slots for server debuffs")
	for slot = 1, MAX_SLOTS do
		if not IsSlotInIgnoredBar(slot) then
			local actionType, id = GetActionInfo(slot)
			if actionType == "spell" and id and id > 0 then
				local start, duration = GetSpellCooldown(id, BOOKTYPE_SPELL)
				start = start or 0
				duration = duration or 0
				if duration >= SERVER_DEBUFF_MIN and duration <= SERVER_DEBUFF_MAX then
					local name, rank = GetSpellName(id, BOOKTYPE_SPELL)
					local texture = GetSpellTexture(id, BOOKTYPE_SPELL)
					if name and not IsSpellIgnored(name) then
						local debuffKey = name .. ":" .. tostring(rank)
						if not ARS.cdServerDebuffs[debuffKey] then
							ARS.cdServerDebuffs[debuffKey] = {expiry = GetTime() + duration, duration = duration, texture = texture, rank = rank, spellName = name}
							SaveDB()
							ARS_UpdateTrackerUI()
							Popup_Show(name, "DISABLED", {r=1, g=0.2, b=0.2}, texture)
							PlaySoundFile("Sound\\Interface\\Error.wav", "Master")
							print(format("|cFFFF0000[CD Alert]|r |cFFFFFFFF%s|r Rank %s was DISABLED for 2 minutes by server!", name, tostring(rank)))
						end
					end
				end
			elseif actionType == "macro" and id and id > 0 then
				local macroSpell = GetMacroSpell(id)
				if macroSpell then
					-- For macros, we can't easily get cooldown from the action slot directly
					-- The macro's spell cooldown is tracked through ProcessWatching on cast
				end
			end
		end
	end
	EnsureOnUpdate()
	DebugPrint("Scan complete")
end

---------------------------------------------------------------------------
-- Ignore Bar Highlight System
---------------------------------------------------------------------------
-- Forward declarations
local ARS_ExitIgnoreBarMode

-- Helper to update highlight color dynamically (Red = Ignored, Green = Monitored)
local function ARS_UpdateHighlightFrameVisual(frame)
	local barNum = frame.barNum
	local isIgnored = ARS.tempIgnoredBars[barNum]

	if isIgnored then
		-- RED visual for Ignored Bars
		frame.bg:SetTexture(1, 0, 0, 0.35)
		frame.bg:Show()
		frame.border:SetTexture(1, 0, 0, 0.9)
		frame.border:Show()
	else
		-- GREEN visual for Monitored Bars
		frame.bg:SetTexture(0, 1, 0, 0.2)
		frame.bg:Show()
		frame.border:SetTexture(0, 1, 0, 0.8)
		frame.border:Show()
	end
end

-- Helper: Get list of active visual button frames for a given bar number
local function GetBarButtons(barNum)
	local buttons = {}

	-- 1. Dominos support (DominosFrame1..10 -> .buttons table)
	local domFrame = _G["DominosFrame" .. barNum] or (Dominos and Dominos.Frame and Dominos.Frame:Get(barNum))
	if domFrame and domFrame.buttons then
		for _, btn in ipairs(domFrame.buttons) do
			if btn and btn:IsShown() and btn:IsVisible() then
				tinsert(buttons, btn)
			end
		end
		if #buttons > 0 then return buttons end
	end

	-- 2. Bartender4 support (Bar 1 = BT4Button1..12, Bar 2 = BT4Button13..24, etc.)
	if _G["BT4Bar" .. barNum] then
		local startIdx = (barNum - 1) * 12 + 1
		for i = 0, 11 do
			local btn = _G["BT4Button" .. (startIdx + i)]
			if btn and btn:IsShown() and btn:IsVisible() then
				tinsert(buttons, btn)
			end
		end
		if #buttons > 0 then return buttons end
	end

	-- 3. ElvUI support (ElvUI_Bar1Button1..12)
	if _G["ElvUI_Bar" .. barNum] then
		for i = 1, 12 do
			local btn = _G["ElvUI_Bar" .. barNum .. "Button" .. i]
			if btn and btn:IsShown() and btn:IsVisible() then
				tinsert(buttons, btn)
			end
		end
		if #buttons > 0 then return buttons end
	end

	-- 4. Default Blizzard UI support (3.3.5a)
	local blizzPrefixes = {
		[1] = "ActionButton",
		[2] = "BonusActionButton", -- Dominos uses BonusActionButton for Bar 2!
		[3] = "MultiBarRightButton",
		[4] = "MultiBarLeftButton",
		[5] = "MultiBarBottomRightButton",
		[6] = "MultiBarBottomLeftButton",
	}
	local prefix = blizzPrefixes[barNum]
	if prefix then
		for i = 1, 12 do
			local btn = _G[prefix .. i]
			if btn and btn:IsShown() and btn:IsVisible() then
				tinsert(buttons, btn)
			end
		end
	end

	return buttons
end

local function ARS_ToggleBarIgnore(barNum)
	if ARS.ignoredBars[barNum] then
		ARS.ignoredBars[barNum] = nil
		print(format("|cFF00CCFF[CD Monitor]|r Bar %d: now MONITORED", barNum))
	else
		ARS.ignoredBars[barNum] = true
		print(format("|cFF00CCFF[CD Monitor]|r Bar %d: now IGNORED (will not auto-swap)", barNum))
	end
	SaveDB()
end

local function ARS_CreateHighlightFrames()
	-- Destroy existing highlight frames
	for i = 1, #highlightFrames do
		local f = highlightFrames[i]
		f:SetScript("OnEnter", nil)
		f:SetScript("OnLeave", nil)
		f:SetScript("OnMouseDown", nil)
		f:SetScript("OnKeyDown", nil)
		f:SetParent(nil)
		f:Hide()
	end
	wipe(highlightFrames)

	for barNum = 1, 10 do
		local buttons = GetBarButtons(barNum)
		if #buttons > 0 then
			-- Calculate exact bounding box across all active buttons on screen
			local left, right, top, bottom
			for _, btn in ipairs(buttons) do
				local l, b, w, h = btn:GetRect()
				if l and b and w and h then
					local r, t = l + w, b + h
					left = left and math.min(left, l) or l
					right = right and math.max(right, r) or r
					bottom = bottom and math.min(bottom, b) or b
					top = top and math.max(top, t) or t
				end
			end

			if left and right and top and bottom then
				local frame = CreateFrame("Frame", nil, UIParent)
				frame:SetFrameStrata("DIALOG")
				frame:SetFrameLevel(100)
				frame:EnableMouse(true)
				frame.barNum = barNum

				-- Position precisely over the buttons area on screen
				frame:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", left - 3, bottom - 3)
				frame:SetWidth((right - left) + 6)
				frame:SetHeight((top - bottom) + 6)

				-- Background overlay texture
				frame.bg = frame:CreateTexture(nil, "BACKGROUND")
				frame.bg:SetAllPoints()

				-- Border texture
				frame.border = frame:CreateTexture(nil, "BORDER")
				frame.border:SetAllPoints()
				frame.border:SetBlendMode("ADD")

				-- Initial Visual State (Red for Ignored, Green for Monitored)
				ARS_UpdateHighlightFrameVisual(frame)

				-- OnEnter: show tooltip
				frame:SetScript("OnEnter", function(self)
					if not ARS.ignoreBarMode then return end

					GameTooltip:SetOwner(self, "ANCHOR_TOP")
					GameTooltip:ClearLines()

					local isIgnored = ARS.tempIgnoredBars[self.barNum]
					if isIgnored then
						GameTooltip:AddLine("|cFFFFFF00Bar " .. self.barNum .. "|r |cFFFF3333(Currently Ignored)|r", 1, 1, 0)
						GameTooltip:AddLine("|cFF00FF00Left-Click to Monitor (Enable Auto-Swap)|r", 0, 1, 0)
					else
						GameTooltip:AddLine("|cFFFFFF00Bar " .. self.barNum .. "|r |cFF33FF33(Currently Monitored)|r", 1, 1, 0)
						GameTooltip:AddLine("|cFFFF3333Left-Click to Ignore (Disable Auto-Swap)|r", 1, 0.2, 0.2)
					end
					GameTooltip:Show()
				end)

				-- OnLeave
				frame:SetScript("OnLeave", function(self)
					GameTooltip:Hide()
				end)

				-- OnMouseDown: Left = Toggle State, Right = Cancel & Exit
				frame:SetScript("OnMouseDown", function(self, button)
					if not ARS.ignoreBarMode then return end
					if button == "LeftButton" then
						-- Toggle temp state
						if ARS.tempIgnoredBars[self.barNum] then
							ARS.tempIgnoredBars[self.barNum] = nil
						else
							ARS.tempIgnoredBars[self.barNum] = true
						end

						-- Update color immediately
						ARS_UpdateHighlightFrameVisual(self)

						-- Refresh Tooltip
						if self:HasScript("OnEnter") then
							self:GetScript("OnEnter")(self)
						end
					elseif button == "RightButton" then
						ARS_CancelAndExitIgnoreBarMode()
					end
				end)

				-- OnKeyDown: ESC = Cancel
				frame:SetScript("OnKeyDown", function(self, key)
					if key == "ESCAPE" then
						ARS_CancelAndExitIgnoreBarMode()
					end
				end)

				frame:Show()
				tinsert(highlightFrames, frame)
			end
		end
	end
end

---------------------------------------------------------------------------
-- Config Dialog Frame (Save / Cancel Popup)
---------------------------------------------------------------------------
local function CreateConfigDialogFrame()
	if configDialogFrame then return end

	local f = CreateFrame("Frame", "AutoRankSwap_ConfigDialog", UIParent)
	f:SetFrameStrata("DIALOG")
	f:SetToplevel(true)
	f:EnableMouse(true)
	f:SetClampedToScreen(true)
	f:SetWidth(380)
	f:SetHeight(110)
	f:SetBackdrop({
		bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
		edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
		tile = true, tileSize = 32, edgeSize = 32,
		insets = {left = 11, right = 12, top = 12, bottom = 11}
	})
	f:SetPoint("TOP", UIParent, "TOP", 0, -50)
	f:Hide()

	local header = f:CreateTexture(nil, "ARTWORK")
	header:SetTexture("Interface\\DialogFrame\\UI-DialogBox-Header")
	header:SetWidth(280)
	header:SetHeight(64)
	header:SetPoint("TOP", 0, 12)

	local title = f:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	title:SetPoint("TOP", header, "TOP", 0, -14)
	title:SetText("Auto Rank Swap - Bar Config")

	local desc = f:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	desc:SetPoint("TOPLEFT", 18, -32)
	desc:SetPoint("BOTTOMRIGHT", -18, 42)
	desc:SetJustifyH("CENTER")
	desc:SetJustifyV("TOP")
	desc:SetText("Click bars to toggle: |cFFFF3333Red = Ignored|r | |cFF33FF33Green = Monitored|r\nDrag the green CD Tracker box to move it.")

	-- Save Button
	local saveBtn = CreateFrame("Button", nil, f, "OptionsButtonTemplate")
	saveBtn:SetText("Save")
	saveBtn:SetWidth(100)
	saveBtn:SetPoint("BOTTOMLEFT", 40, 14)
	saveBtn:SetScript("OnClick", function()
		ARS_SaveAndExitIgnoreBarMode()
	end)

	-- Cancel Button
	local cancelBtn = CreateFrame("Button", nil, f, "OptionsButtonTemplate")
	cancelBtn:SetText("Cancel")
	cancelBtn:SetWidth(100)
	cancelBtn:SetPoint("BOTTOMRIGHT", -40, 14)
	cancelBtn:SetScript("OnClick", function()
		ARS_CancelAndExitIgnoreBarMode()
	end)

	configDialogFrame = f
end

local function ARS_EnterIgnoreBarMode()
	if ARS.ignoreBarMode then return end
	ARS.ignoreBarMode = true

	-- Copy current saved ignoredBars into tempIgnoredBars
	wipe(ARS.tempIgnoredBars)
	for barNum in pairs(ARS.ignoredBars) do
		ARS.tempIgnoredBars[barNum] = true
	end

	-- Show Save/Cancel Config Dialog
	CreateConfigDialogFrame()
	configDialogFrame:Show()

	-- Create Highlight Frames (All bars show RED or GREEN automatically)
	ARS_CreateHighlightFrames()

	-- Automatically unlock and show the CD Tracker anchor for moving
	if trackerAnchorFrame then
		trackerAnchorFrame.isUnlocked = true
		trackerAnchorFrame.bg:Show()
		trackerAnchorFrame.text:Show()
	end

	print("|cFF00CCFF[CD Monitor]|r |cFFFFFFFFConfig Mode|r: Click bars to toggle (Red = Ignored, Green = Monitored). Click Save or Cancel when done.")
end

function ARS_SaveAndExitIgnoreBarMode()
	if not ARS.ignoreBarMode then return end

	-- Apply temp changes to permanent ARS.ignoredBars
	wipe(ARS.ignoredBars)
	for barNum in pairs(ARS.tempIgnoredBars) do
		ARS.ignoredBars[barNum] = true
	end
	SaveDB()

	ARS_ExitIgnoreBarMode()
	print("|cFF00CCFF[CD Monitor]|r Bar ignore settings |cFF00FF00SAVED|r.")
end

function ARS_CancelAndExitIgnoreBarMode()
	if not ARS.ignoreBarMode then return end

	-- Discard temp changes
	wipe(ARS.tempIgnoredBars)

	ARS_ExitIgnoreBarMode()
	print("|cFF00CCFF[CD Monitor]|r Bar ignore changes |cFFFF5555CANCELLED|r.")
end

ARS_ExitIgnoreBarMode = function()
	if not ARS.ignoreBarMode then return end
	ARS.ignoreBarMode = false

	-- Hide Tooltip and Config Dialog
	GameTooltip:Hide()
	if configDialogFrame then configDialogFrame:Hide() end

	-- Automatically lock and hide the CD Tracker anchor
	if trackerAnchorFrame then
		trackerAnchorFrame.isUnlocked = false
		trackerAnchorFrame.bg:Hide()
		trackerAnchorFrame.text:Hide()
	end

	-- Cleanup Highlight Frames
	for i = 1, #highlightFrames do
		local f = highlightFrames[i]
		f:SetScript("OnEnter", nil)
		f:SetScript("OnLeave", nil)
		f:SetScript("OnMouseDown", nil)
		f:SetScript("OnKeyDown", nil)
		f:SetParent(nil)
		f:Hide()
	end
	wipe(highlightFrames)
end

---------------------------------------------------------------------------
-- Minimap Icon & LibDataBroker Integration
---------------------------------------------------------------------------
local function CreateMinimapIcon()
	local LDB = LibStub and LibStub("LibDataBroker-1.1", true)
	local LDBIcon = LibStub and LibStub("LibDBIcon-1.0", true)

	if not LDB then return end

	-- Register LDB Launcher Object
	ldbObject = LDB:NewDataObject("AutoRankSwap", {
		type = "launcher",
		label = "Auto Rank Swap",
		icon = "Interface\\Icons\\INV_Misc_PocketWatch_01",
		OnClick = function(self, button)
			if button == "LeftButton" then
				if ARS.ignoreBarMode then
					ARS_SaveAndExitIgnoreBarMode()
				else
					ARS_EnterIgnoreBarMode()
				end
			elseif button == "RightButton" then
				if ARS.ignoreBarMode then
					ARS_CancelAndExitIgnoreBarMode()
				else
					ARS_ToggleTrackerUnlock()
				end
			end
		end,
		OnTooltipShow = function(tooltip)
			if not tooltip or not tooltip.AddLine then return end
			tooltip:AddLine("|cFF00CCFFAuto Rank Swap|r |cFFFFFFFF(ARS)|r")
			tooltip:AddLine(" ")
			if ARS.ignoreBarMode then
				tooltip:AddLine("|cFFFFFFFFLeft-Click:|r |cFF00FF00Save & Exit Config|r")
				tooltip:AddLine("|cFFFFFFFFRight-Click:|r |cFFFF3333Cancel & Exit Config|r")
			else
				tooltip:AddLine("|cFFFFFFFFLeft-Click:|r |cFF00FF00Bar Ignore Mode & Move Tracker|r")
				tooltip:AddLine("|cFFFFFFFFRight-Click:|r |cFFFFFF00Toggle CD Tracker UI|r")
			end
		end,
	})

	if LDBIcon then
		ARSDB.minimap = ARSDB.minimap or { hide = false }
		LDBIcon:Register("AutoRankSwap", ldbObject, ARSDB.minimap)
	end
end

---------------------------------------------------------------------------
-- Initialization
---------------------------------------------------------------------------
local function Initialize(self)
	-- Initialize SavedVariables (per-character)
	LoadDB()

	-- Create Minimap Icon
	CreateMinimapIcon()

	ARS_CreateTrackerUI()
	ARS_UpdateTrackerUI()

	SLASH_ARSU1 = "/cdui"
	SlashCmdList["ARSU"] = ARS_ToggleTrackerUnlock

	DebugPrint("Auto Rank Swap initializing...")

	CreatePopupFrame()
	BuildSpellBookCache()

	cdMonitorFrame = CreateFrame("Frame", "AutoRankSwapFrame", UIParent)
	cdMonitorFrame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
	cdMonitorFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
	cdMonitorFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
	cdMonitorFrame:RegisterEvent("LEARNED_SPELL_IN_TAB")
	cdMonitorFrame:SetScript("OnEvent", CDMonitor_OnEvent)

	-- /cdscan — manual scan of all action slots
	SLASH_AUTORANKSWAP1 = "/cdscan"
	SlashCmdList["AUTORANKSWAP"] = ManualScan

	-- /cdignore <bar#> — toggle ignore for a specific bar
	-- /cdignore <spell name> — toggle ignore for a spell name or partial match
	-- /cdignore list — show ignored bars and spells
	-- /cdignore clear — clear all ignored bars and spells
	SLASH_ARSI1 = "/cdignore"
	SlashCmdList["ARSI"] = function(msg)
		msg = strtrim(msg or "")
		if msg == "" then
			ARS_EnterIgnoreBarMode()
			return
		end

		if msg == "help" then
			print("|cFF00CCFF[CD Monitor]|r Usage:")
			print("|cFF00CCFF[CD Monitor]|r  /cdignore                          - Enter visual bar ignore mode")
			print("|cFF00CCFF[CD Monitor]|r  /cdignore <bar#>                   - Toggle bar ignore")
			print("|cFF00CCFF[CD Monitor]|r  /cdignore <spell name>             - Toggle spell ignore")
			print("|cFF00CCFF[CD Monitor]|r  /cdignore list                     - Show ignored bars and spells")
			print("|cFF00CCFF[CD Monitor]|r  /cdignore clear                    - Clear all ignore entries")
			return
		end

		if msg == "list" then
			local ignoredBars = {}
			for barNum in pairs(ARS.ignoredBars) do
				tinsert(ignoredBars, tostring(barNum))
			end
			local ignoredSpells = {}
			for spellName in pairs(ARS.ignoredSpells) do
				tinsert(ignoredSpells, spellName)
			end

			print("|cFF00CCFF[CD Monitor]|r Ignored Bars: " .. (#ignoredBars > 0 and table.concat(ignoredBars, ", ") or "None"))
			print("|cFF00CCFF[CD Monitor]|r Ignored Spells: " .. (#ignoredSpells > 0 and table.concat(ignoredSpells, ", ") or "None"))
			return
		end

		if msg == "clear" then
			wipe(ARS.ignoredBars)
			wipe(ARS.ignoredSpells)
			SaveDB()
			print("|cFF00CCFF[CD Monitor]|r All bars and spells cleared from ignore list")
			return
		end

		local barNum = tonumber(msg)
		if barNum then
			if ARS.ignoredBars[barNum] then
				ARS.ignoredBars[barNum] = nil
				print(format("|cFF00CCFF[CD Monitor]|r Bar %d: now MONITORED", barNum))
			else
				ARS.ignoredBars[barNum] = true
				print(format("|cFF00CCFF[CD Monitor]|r Bar %d: now IGNORED (will not auto-swap)", barNum))
			end
		else
			if ARS.ignoredSpells[msg] then
				ARS.ignoredSpells[msg] = nil
				print(format("|cFF00CCFF[CD Monitor]|r Spell matching '%s': now MONITORED", msg))
			else
				ARS.ignoredSpells[msg] = true
				print(format("|cFF00CCFF[CD Monitor]|r Spell matching '%s': now IGNORED (will not alert or auto-swap)", msg))
			end
		end
		SaveDB()
	end

	DebugPrint("Ready. Use /cdscan, /cdignore")
end

---------------------------------------------------------------------------
-- Bootstrap
---------------------------------------------------------------------------
local loader = CreateFrame("Frame")
loader:RegisterEvent("PLAYER_LOGIN")
loader:SetScript("OnEvent", function(self, event, ...)
	self:UnregisterEvent(event)
	Initialize(self)
end)