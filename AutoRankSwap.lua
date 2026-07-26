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
ARS.cdServerDebuffs = {}
ARS.spellBookCache = {}   -- [spellName] = { { rank, rankNum, bookIndex }, ... }
ARS.pendingSwaps = {}     -- [actionSlot] = { ... }
ARS.pendingRestores = {}  -- [actionSlot] = { ... }
ARS.ignoredBars = {}      -- [barNum] = true

local cdMonitorFrame
local ARSDB

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
local function LoadIgnoredBars()
	wipe(ARS.ignoredBars)
	if ARSDB and ARSDB.ignoredBars then
		for _, v in pairs(ARSDB.ignoredBars) do
			ARS.ignoredBars[v] = true
		end
	end
end

local function SaveIgnoredBars()
	if not ARSDB then return end
	ARSDB.ignoredBars = ARSDB.ignoredBars or {}
	wipe(ARSDB.ignoredBars)
	local i = 1
	for barNum in pairs(ARS.ignoredBars) do
		ARSDB.ignoredBars[i] = barNum
		i = i + 1
	end
end

-- Map bar number → slot range: Bar1=1-12, Bar2=13-24, ..., Bar10=109-120
local function IsSlotInIgnoredBar(slot)
	if not slot then return false end
	for barNum in pairs(ARS.ignoredBars) do
		local lo = (barNum - 1) * 12 + 1
		local hi = barNum * 12
		if slot >= lo and slot <= hi then
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
				local macroSpell = GetMacroSpell(id)
				if macroSpell == spellName then
					DebugPrint("FindSlots: slot=" .. slot .. " MACRO macroSpell=" .. tostring(macroSpell))
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
		local actionType, id = GetActionInfo(slot)
		if actionType == "macro" and id and id > 0 then
			local macroSpell = GetMacroSpell(id)
			if macroSpell == spellName then
				DebugPrint("FindMacroSlot: slot=" .. slot .. " id=" .. id .. " macroSpell=" .. tostring(macroSpell))
				return slot, id
			end
		end
	end
	DebugPrint("FindMacroSlot: no macro found for " .. spellName)
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
	local newText = gsub(baseText, spellName, spellName .. "(" .. lowerRankStr .. ")")
	DebugPrint("PerformMacroSwap: old=" .. tostring(text))
	DebugPrint("PerformMacroSwap: base=" .. tostring(baseText))
	DebugPrint("PerformMacroSwap: new=" .. tostring(newText))
	if newText ~= text then
		EditMacro(macroID, nil, nil, newText)
		ARS.pendingSwaps[slot].lowerRankStr = nil
		ARS.pendingSwaps[slot].spellName = nil
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
	DebugPrint("PerformMacroRestore: SUCCESS - restored macro on slot " .. slot)
	return true
end

---------------------------------------------------------------------------
-- Pending Swap/Restore Processors
---------------------------------------------------------------------------
local function ProcessPendingSwaps()
	if InCombatLockdown() then return end
	for slot, data in pairs(ARS.pendingSwaps) do
		if data.isMacro then
			if data.lowerRankStr and data.spellName then
				DebugPrint("ProcessPendingSwaps: applying queued macro swap slot=" .. slot)
				local ok = PerformMacroSwap(data.spellName, data.lowerRankStr)
				if ok then
					DebugPrint("ProcessPendingSwaps: macro SUCCESS slot=" .. slot)
				end
			end
			if not data.lowerRankStr and not data.spellName and not data.originalMacroText then
				ARS.pendingSwaps[slot] = nil
			end
		elseif data.newBookIndex then
			DebugPrint("ProcessPendingSwaps: applying queued swap slot=" .. slot)
			local ok = PerformSwap(slot, data.newBookIndex)
			if ok then
				DebugPrint("ProcessPendingSwaps: SUCCESS slot=" .. slot)
			else
				DebugPrint("ProcessPendingSwaps: FAILED slot=" .. slot)
			end
		end
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
-- Core: Detection + Auto-Rank-Swap
---------------------------------------------------------------------------
local function ProcessWatching()
	local now = GetTime()
	for spellName, data in pairs(ARS.cdWatching) do
		if now - data[1] >= WATCH_DELAY then
			local castRank = data[3]
			local bookIndex = FindSpellBookIndex(spellName, castRank)
			local start, duration = 0, 0

			if bookIndex then
				start, duration = GetSpellCooldown(bookIndex, BOOKTYPE_SPELL)
			end
			start = start or 0
			duration = duration or 0

			if duration >= SERVER_DEBUFF_MIN and duration <= SERVER_DEBUFF_MAX then
				local debuffKey = spellName .. ":" .. tostring(castRank)

				if not ARS.cdServerDebuffs[debuffKey] then
					DebugPrint("ProcessWatching: " .. spellName .. " Rank " .. tostring(castRank) .. " duration=" .. duration)
					ARS.cdServerDebuffs[debuffKey] = {expiry = now + duration, duration = duration, texture = data[4], rank = castRank, spellName = spellName}
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
			ARS.cdWatching[spellName] = nil
		end
	end
end

local function CheckDebuffExpiry()
	local now = GetTime()
	for debuffKey, data in pairs(ARS.cdServerDebuffs) do
		local remaining = (data.expiry or 0) - now
		if remaining <= 0 then
			local spellName = data.spellName

			-- Remove this debuff
			ARS.cdServerDebuffs[debuffKey] = nil

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
						local rankPattern = macroSpell .. "%((.-)%)"
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
								local patternToRemove = macroSpell .. "%(" .. foundRank .. "%)"
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
		local actionType, id = GetActionInfo(slot)
		if actionType == "spell" and id and id > 0 then
			local start, duration = GetSpellCooldown(id, BOOKTYPE_SPELL)
			start = start or 0
			duration = duration or 0
			if duration >= SERVER_DEBUFF_MIN and duration <= SERVER_DEBUFF_MAX then
				local name, rank = GetSpellName(id, BOOKTYPE_SPELL)
				local texture = GetSpellTexture(id, BOOKTYPE_SPELL)
				local debuffKey = name .. ":" .. tostring(rank)
				if name and not ARS.cdServerDebuffs[debuffKey] then
					ARS.cdServerDebuffs[debuffKey] = {expiry = GetTime() + duration, duration = duration, texture = texture, rank = rank, spellName = name}
					Popup_Show(name, "DISABLED", {r=1, g=0.2, b=0.2}, texture)
					PlaySoundFile("Sound\\Interface\\Error.wav", "Master")
					print(format("|cFFFF0000[CD Alert]|r |cFFFFFFFF%s|r Rank %s was DISABLED for 2 minutes by server!", name, tostring(rank)))
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
	EnsureOnUpdate()
	DebugPrint("Scan complete")
end

---------------------------------------------------------------------------
-- Initialization
---------------------------------------------------------------------------
local function Initialize(self)
	-- Initialize SavedVariables
	AutoRankSwapDB = AutoRankSwapDB or {}
	ARSDB = AutoRankSwapDB

	DebugPrint("Auto Rank Swap initializing...")

	CreatePopupFrame()
	BuildSpellBookCache()
	LoadIgnoredBars()

	cdMonitorFrame = CreateFrame("Frame", "AutoRankSwapFrame", UIParent)
	cdMonitorFrame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
	cdMonitorFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
	cdMonitorFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
	cdMonitorFrame:RegisterEvent("LEARNED_SPELL_IN_TAB")
	cdMonitorFrame:SetScript("OnEvent", CDMonitor_OnEvent)

	-- /cdscan — manual scan of all action slots
	SLASH_AUTORANKSWAP1 = "/cdscan"
	SlashCmdList["AUTORANKSWAP"] = ManualScan

	-- /cdignore <bar#> [bar#...] — toggle ignore for specific bars
	-- /cdignore list — show ignored bars
	-- /cdignore clear — clear all ignored bars
	SLASH_ARSI1 = "/cdignore"
	SlashCmdList["ARSI"] = function(msg)
		msg = strtrim(msg or "")
		if msg == "" then
			print("|cFF00CCFF[CD Monitor]|r Usage: /cdignore <bar#> [bar#...] or /cdignore list or /cdignore clear")
			return
		end

		if msg == "list" then
			local ignored = {}
			for barNum in pairs(ARS.ignoredBars) do
				tinsert(ignored, tostring(barNum))
			end
			if #ignored > 0 then
				print(format("|cFF00CCFF[CD Monitor]|r Ignored bars: %s", table.concat(ignored, ", ")))
			else
				print("|cFF00CCFF[CD Monitor]|r No bars ignored")
			end
			return
		end

		if msg == "clear" then
			wipe(ARS.ignoredBars)
			SaveIgnoredBars()
			print("|cFF00CCFF[CD Monitor]|r All bars cleared from ignore list")
			return
		end

		-- Parse bar numbers
		for numStr in msg:gmatch("%d+") do
			local barNum = tonumber(numStr)
			if barNum then
				if ARS.ignoredBars[barNum] then
					ARS.ignoredBars[barNum] = nil
					print(format("|cFF00CCFF[CD Monitor]|r Bar %d: now MONITORED", barNum))
				else
					ARS.ignoredBars[barNum] = true
					print(format("|cFF00CCFF[CD Monitor]|r Bar %d: now IGNORED (will not auto-swap)", barNum))
				end
			end
		end
		SaveIgnoredBars()
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
