local PitBull4 = _G.PitBull4
local PitBull4_Aura = PitBull4:GetModule("Aura")
local PitBull4_AuraDuration = PitBull4_Aura:NewModule("AuraDuration", "AceEvent-3.0")

local bit_band = bit.band

local spells = PitBull4.Spells.spell_durations
local dr_spells = PitBull4.Spells.dr_spells

local new, del do
	local pool = {}

	local auto_table__mt = {
		__index = function(t, k)
			t[k] = new()
			return t[k]
		end,
	}

	function new()
		local t = next(pool)
		if t then
			pool[t] = nil
		else
			t = setmetatable({}, auto_table__mt)
		end
		return t
	end

	function del(t)
		for k,v in next, t do
			if type(v) == "table" then
				del(v)
			end
			t[k] = nil
		end
		pool[t] = true
		return nil
	end
end

local function get(t, ...)
	for i=1, select("#", ...) do
		local key = select(i, ...)
		t = rawget(t, key)
		if t == nil then
			return nil
		end
	end
	return t
end

local auras = new()
PitBull4_AuraDuration.auras = auras

local diminished_returns = new()
PitBull4_AuraDuration.diminished_returns = diminished_returns

-- DR is 15 seconds, but the server only checks every 5 seconds, so it can reset any time between 15 and 20 seconds.
local DR_RESET_TIME = 18

-- Categories that have DR in PvE
local dr_pve_categories = {
	stun = true,
	-- blind = true,
	cheapshot = true,
	-- kidneyshot - true,
}

-- This uses the logic provided by Shadowed in DRData-1.0 (it's his fault if it doesn't work right!)
-- DR is applied when the debuff fades
local function add_dr(dst_guid, spell_id, is_player)
	local cat = dr_spells[spell_id]
	if not cat then return end
	if not is_player and not dr_pve_categories[cat] then return end

	local entry = diminished_returns[dst_guid][cat]
	entry[1] = GetTime() + DR_RESET_TIME
	local diminished = get(entry, 2) or 1
	if diminished == 1 then
		entry[2] = 0.5
	elseif diminished == 0.5 then
		entry[2] = 0.25
	else
		entry[2] = 0
	end
end

-- DR reset time is checked when the debuff is gained
local function get_dr(dst_guid, spell_id, is_player)
	local cat = dr_spells[spell_id]
	if cat and (is_player or dr_pve_categories[cat]) then
		local entry = diminished_returns[dst_guid][cat]
		if get(entry, 1) and entry[1] <= GetTime() then
			wipe(entry)
		end
		return get(entry, 2) or 1
	end
	return 1
end

local is_player = bit.bor(COMBATLOG_OBJECT_TYPE_PLAYER, COMBATLOG_OBJECT_CONTROL_PLAYER)
local is_group = bit.bor(COMBATLOG_OBJECT_AFFILIATION_MINE, COMBATLOG_OBJECT_AFFILIATION_PARTY, COMBATLOG_OBJECT_AFFILIATION_RAID)

local event_list = {
	SPELL_AURA_APPLIED = true,
	SPELL_AURA_APPLIED_DOSE = true,
	SPELL_AURA_REFRESH = true,
	SPELL_AURA_REMOVED = true,
}

local player_guid = UnitGUID("player")

local frame = CreateFrame("Frame")
frame:SetScript("OnEvent", function(self)
	local _, event, _, src_guid, _, src_flags, _, dst_guid, _, dst_flags, _, spell_id = CombatLogGetCurrentEventInfo()

	if dst_guid == player_guid then
		return
	end

	if event == "UNIT_DIED" then
		if get(auras, dst_guid) then
			auras[dst_guid] = del(auras[dst_guid])
		end
		if get(diminished_returns, dst_guid) then
			diminished_returns[dst_guid] = del(diminished_returns[dst_guid])
		end
		return
	end

	if event_list[event] and spells[spell_id] then -- and bit_band(src_flags, is_group) > 0
		if event == "SPELL_AURA_REMOVED" or event == "SPELL_AURA_REFRESH" then
			add_dr(dst_guid, spell_id, bit_band(dst_flags, is_player) > 0)
		end

		if event == "SPELL_AURA_APPLIED" or event == "SPELL_AURA_REFRESH" or event == "SPELL_AURA_APPLIED_DOSE" then
			local duration = spells[spell_id] * get_dr(dst_guid, spell_id)
			local expiration = GetTime() + duration
			local entry = auras[dst_guid][spell_id][src_guid]
			entry[1] = duration
			entry[2] = expiration
		elseif event == "SPELL_AURA_REMOVED" then
			auras[dst_guid][spell_id][src_guid] = del(auras[dst_guid][spell_id][src_guid])
		end
	end
end)

function PitBull4_AuraDuration:OnEnable()
	self:RegisterEvent("PLAYER_ENTERING_WORLD")
	frame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
end

function PitBull4_AuraDuration:OnDisable()
	frame:UnregisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
	self:PLAYER_ENTERING_WORLD()
end

function PitBull4_AuraDuration:PLAYER_ENTERING_WORLD()
	-- tidy up
	local purge = not IsInGroup()
	for guid in next, auras do
		if purge or guid:sub(1, 6) ~= "Player" then
			auras[guid] = del(auras[guid])
		end
	end
	for guid in next, diminished_returns do
		diminished_returns[guid] = del(diminished_returns[guid])
	end
end

local tmp = {}
function PitBull4_Aura:GetDuration(src_guid, dst_guid, spell_id, aura_list, aura_index)
	if spells[spell_id] then
		if src_guid then
			local entry = get(auras, dst_guid, spell_id, src_guid)
			if entry then
				if entry[2] > GetTime() then
					return entry[1], entry[2]
				end
				auras[dst_guid][spell_id][src_guid] = del(entry)
			end
		else
			-- The aura has no caster, assign it one of the expirations we have
			local casters = get(auras, dst_guid, spell_id)
			if casters then
				wipe(tmp)
				local t = GetTime()
				-- Build an indexed table of the caster guids and sort by expiration
				for guid, entry in next, casters do
					if entry[2] > t then
						tmp[#tmp+1] = guid
					else
						auras[dst_guid][spell_id][guid] = del(entry)
					end
				end
				sort(tmp, function(a, b) return casters[a][2] > casters[b][2] end)

				-- Find which instance of the aura is being updated
				local index = 0
				for i=1, #aura_list do
					if aura_list[i].spell_id == spell_id or i == aura_index then -- (the data hasn't been updated yet so always count our aura)
						index = index + 1
					end
					if i == aura_index then break	end
				end

				-- Pick the caster to go with the aura
				if index >= 1 and index <= #tmp then
					local guid = tmp[index]
					return casters[guid][1], casters[guid][2]
				end
			end
		end
	end
	return 0, 0
end
