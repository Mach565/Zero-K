--------------------------------------------------------------------------------
--------------------------------------------------------------------------------

function gadget:GetInfo()
	return {
		name      = "Decloak when damaged",
		desc      = "Decloaks units when they are damaged",
		author    = "Google Frog",
		date      = "Nov 25, 2009", -- Major rework 12 Feb 2014
		license   = "GNU GPL, v2 or later",
		layer     = 0,
		enabled   = true  --  loaded by default?
	}
end

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------

local CMD_WANT_CLOAK = Spring.Utilities.CMD.WANT_CLOAK
local CMD_CLOAK = CMD.CLOAK

local unitWantCloakCommandDesc = {
	id      = CMD_WANT_CLOAK,
	type    = CMDTYPE.ICON_MODE,
	name    = 'Cloak State',
	action  = 'wantcloak',
	tooltip	= 'Unit cloaking state',
	params 	= {0, 'Decloaked', 'Cloaked'}
}

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------

if (not gadgetHandler:IsSyncedCode()) then
  return false  --  silent removal
end

local alliedTrueTable = {allied = true}

local spAreTeamsAllied           = Spring.AreTeamsAllied
local spSetUnitCloak             = Spring.SetUnitCloak
local spGetUnitIsCloaked         = Spring.GetUnitIsCloaked
local spGetUnitRulesParam        = Spring.GetUnitRulesParam
local spSetUnitRulesParam        = Spring.SetUnitRulesParam
local spGetUnitDefID             = Spring.GetUnitDefID
local spGetUnitIsDead            = Spring.GetUnitIsDead
local spIsWeaponPureStatusEffect = Spring.Utilities.IsWeaponPureStatusEffect

local recloakUnit = {}
local recloakFrame = {}

local noFFWeaponDefs = {}
for i = 1, #WeaponDefs do
	local wd = WeaponDefs[i]
	if wd.customParams and wd.customParams.nofriendlyfire then
		noFFWeaponDefs[i] = true
	end
end

local DEFAULT_DECLOAK_TIME = 240
local PERSONAL_DECLOAK_TIME = 90
local BUILD_DECLOAK_TIME = 30

local DEFAULT_PROXIMITY_DECLOAK_TIME = 90
local PERSONAL_PROXIMITY_DECLOAK_TIME = 45

local UPDATE_FREQUENCY = 10
local CLOAK_MOVE_THRESHOLD = math.sqrt(0.2)

local currentFrame = 0

local cloakUnitDefID = {}
local commDefID = {}
for i = 1, #UnitDefs do
	local ud = UnitDefs[i]
	if ud.canCloak and not ud.customParams.dynamic_comm then
		cloakUnitDefID[i] = true
	end
	if ud.customParams.dynamic_comm then
		commDefID[i] = true
	end
end

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- Water handling

local waterUnitCount = 0
local waterUnitMap = {}
local waterUnits = {}
local waterUnitCloakBlocked = {}

local function AddWaterUnit(unitID)
	if waterUnitMap[unitID] then
		return
	end
	waterUnitCount = waterUnitCount + 1
	waterUnitMap[unitID] = waterUnitCount
	waterUnits[waterUnitCount] = unitID
end

local function RemoveWaterUnit(unitID)
	if not waterUnitMap[unitID] then
		return
	end
	if waterUnitCloakBlocked[unitID] then
		spSetUnitRulesParam(unitID, "cannotcloak", 0, alliedTrueTable)
		spSetUnitRulesParam(unitID, "shield_disabled", 0, alliedTrueTable)
		GG.UpdateUnitAttributes(unitID)
		waterUnitCloakBlocked[unitID] = false
	end
	
	waterUnits[waterUnitMap[unitID]] = waterUnits[waterUnitCount]
	waterUnitMap[waterUnits[waterUnitCount]] = waterUnitMap[unitID]
	waterUnits[waterUnitCount] = nil
	waterUnitMap[unitID] = nil
	waterUnitCount = waterUnitCount - 1
	
	waterUnitCloakBlocked[unitID] = nil
end

function gadget:UnitEnteredWater(unitID)
	AddWaterUnit(unitID)
end

function gadget:UnitLeftWater(unitID)
	RemoveWaterUnit(unitID)
end

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------

local function UnitHasPersonalCloak(unitID, unitDefID)
	unitDefID = unitDefID or spGetUnitDefID(unitID)
	if commDefID[unitDefID] and GG.Upgrades_UnitCanCloak(unitID) then
		return true
	end
	return (cloakUnitDefID[unitDefID] and true) or false
end

local function GetProximityDecloakTime(unitID, unitDefID)
	return (UnitHasPersonalCloak(unitID, unitDefID) and PERSONAL_PROXIMITY_DECLOAK_TIME) or DEFAULT_PROXIMITY_DECLOAK_TIME
end

local function GetActionDecloakTime(unitID, unitDefID)
	return (UnitHasPersonalCloak(unitID, unitDefID) and PERSONAL_DECLOAK_TIME) or DEFAULT_DECLOAK_TIME
end

local function PokeDecloakUnit(unitID, unitDefID)
	if not recloakUnit[unitID] then
		spSetUnitRulesParam(unitID, "cannotcloak", 1, alliedTrueTable)
		spSetUnitCloak(unitID, 0)
	end
	recloakUnit[unitID] = GetActionDecloakTime(unitID, unitDefID)
end

local function GetCloakedAllowed(unitID)
	if not recloakFrame[unitID] and not recloakUnit[unitID] then
		return true
	end
	if (recloakFrame[unitID] or 0) > currentFrame then
		return false
	end
	return (recloakUnit[unitID] or 0) <= 0
end

GG.UnitHasPersonalCloak = UnitHasPersonalCloak
GG.PokeDecloakUnit      = PokeDecloakUnit
GG.GetCloakedAllowed    = GetCloakedAllowed

function gadget:UnitDamaged(unitID, unitDefID, unitTeam, damage, paralyzer, weaponID, attackerID, attackerDefID, attackerTeam)
	if  (damage > 0 or spIsWeaponPureStatusEffect(weaponID)) and
		not (attackerTeam and
		weaponID and
		noFFWeaponDefs[weaponID] and
		attackerID ~= unitID and
		spAreTeamsAllied(unitTeam, attackerTeam)) then
		PokeDecloakUnit(unitID, unitDefID)
	end
end

local function CheckWaterBlockCloak(unitID, pos)
	local radius = Spring.GetUnitRadius(unitID)
	if radius + pos < 0 then
		if not waterUnitCloakBlocked[unitID] then
			PokeDecloakUnit(unitID)
			spSetUnitRulesParam(unitID, "cannotcloak", 1, alliedTrueTable)
			spSetUnitRulesParam(unitID, "shield_disabled", 1, alliedTrueTable)
			waterUnitCloakBlocked[unitID] = true
			GG.UpdateUnitAttributes(unitID)
		end
		return true
	end
	return false
end

function gadget:GameFrame(n)
	currentFrame = n
	if n%UPDATE_FREQUENCY == 2 then
		for unitID, frames in pairs(recloakUnit) do
			if frames <= UPDATE_FREQUENCY then
				if not ((spGetUnitRulesParam(unitID,"on_fire") == 1) or (spGetUnitRulesParam(unitID,"disarmed") == 1) or waterUnitCloakBlocked[unitID]) then
					local wantCloakState = spGetUnitRulesParam(unitID, "wantcloak")
					local areaCloaked = spGetUnitRulesParam(unitID, "areacloaked")
					spSetUnitRulesParam(unitID, "cannotcloak", 0, alliedTrueTable)
					if wantCloakState == 1 or areaCloaked == 1 then
						spSetUnitCloak(unitID, 1)
					end
					recloakUnit[unitID] = nil
				end
			else
				recloakUnit[unitID] = frames - UPDATE_FREQUENCY
			end
		end
		
		local i = 1
		while i <= waterUnitCount do
			local unitID = waterUnits[i]
			if Spring.ValidUnitID(unitID) then
				local pos = select(5, Spring.GetUnitPosition(unitID, true))
				if pos < 0 then
					if (not CheckWaterBlockCloak(unitID, pos)) and waterUnitCloakBlocked[unitID] then
						spSetUnitRulesParam(unitID, "cannotcloak", 0, alliedTrueTable)
						spSetUnitRulesParam(unitID, "shield_disabled", 0, alliedTrueTable)
						GG.UpdateUnitAttributes(unitID)
						waterUnitCloakBlocked[unitID] = false
					end
				else
					if waterUnitCloakBlocked[unitID] then
						spSetUnitRulesParam(unitID, "cannotcloak", 0, alliedTrueTable)
						spSetUnitRulesParam(unitID, "shield_disabled", 0, alliedTrueTable)
						GG.UpdateUnitAttributes(unitID)
						waterUnitCloakBlocked[unitID] = false
					end
				end
				i = i + 1
			else
				RemoveWaterUnit(unitID)
			end
		end
	end
end

-- Only called with enemyID if an enemy is within decloak radius.
function gadget:AllowUnitCloak(unitID, enemyID)
	if enemyID then
		local transID = Spring.GetUnitTransporter(unitID)
		if transID then
			-- For some reason enemyID indicates that the unit is being transported.
			return spGetUnitIsCloaked(transID)
		end
		recloakFrame[unitID] = currentFrame + GetProximityDecloakTime(unitID)
		return false
	end
	
	if recloakFrame[unitID] then
		if recloakFrame[unitID] > currentFrame then
			return false
		end
		recloakFrame[unitID] = nil
	end
	
	local stunnedOrInbuild = Spring.GetUnitIsStunned(unitID)
	if stunnedOrInbuild then
		return false
	end
	
	local unitDefID = unitID and Spring.GetUnitDefID(unitID)
	local ud = unitDefID and UnitDefs[unitDefID]
	if not ud then
		return false
	end
	
	local areaCloaked = (Spring.GetUnitRulesParam(unitID, "areacloaked") == 1)
	if areaCloaked then
		return GG.AreaCloakFinishedCharging(unitID)
	else -- Not area cloaked
		local speed = select(4, Spring.GetUnitVelocity(unitID))
		local moving = speed and speed > CLOAK_MOVE_THRESHOLD
		local cost = moving and ud.cloakCostMoving or ud.cloakCost
		
		if not Spring.UseUnitResource(unitID, "e", cost/2) then -- SlowUpdate happens twice a second.
			return false
		end
	end
	
	return true
end

function gadget:AllowUnitDecloak(unitID, objectID, weaponID)
	local _,_,inbuild = Spring.GetUnitIsStunned(unitID)
	if inbuild then
		recloakFrame[unitID] = math.max(recloakFrame[unitID] or 0, currentFrame + BUILD_DECLOAK_TIME)
		return true
	end
	recloakFrame[unitID] = currentFrame + GetActionDecloakTime(unitID)
	return true
end

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------

local function WouldCloakIfIdle(unitID)
	local wantCloakState = spGetUnitRulesParam(unitID, "wantcloak")
	if wantCloakState == 1 then
		return true
	end
	local areaCloaked = (Spring.GetUnitRulesParam(unitID, "areacloaked") == 1)
	return areaCloaked
end

local function SetWantedCloaked(unitID, state)
	if (not unitID) or spGetUnitIsDead(unitID) then
		return
	end
	
	local wantCloakState = spGetUnitRulesParam(unitID, "wantcloak")
	local cmdDescID = Spring.FindUnitCmdDesc(unitID, CMD_WANT_CLOAK)
	if (cmdDescID) then
		Spring.EditUnitCmdDesc(unitID, cmdDescID, { params = {state, 'Decloaked', 'Cloaked'}})
	end
	
	if state == 1 and wantCloakState ~= 1 then
		local cannotCloak = spGetUnitRulesParam(unitID, "cannotcloak")
		local areaCloaked = spGetUnitRulesParam(unitID, "areacloaked")
		if cannotCloak ~= 1 and areaCloaked ~= 1 then
			spSetUnitCloak(unitID, 1)
		end
		spSetUnitRulesParam(unitID, "wantcloak", 1, alliedTrueTable)
	elseif state == 0 and wantCloakState == 1 then
		local areaCloaked = spGetUnitRulesParam(unitID, "areacloaked")
		if areaCloaked ~= 1 then
			spSetUnitCloak(unitID, 0)
		end
		spSetUnitRulesParam(unitID, "wantcloak", 0, alliedTrueTable)
	end
end

GG.SetWantedCloaked = SetWantedCloaked
GG.WouldCloakIfIdle = WouldCloakIfIdle

function gadget:AllowCommand_GetWantedCommand()
	return {[CMD_CLOAK] = true, [CMD_WANT_CLOAK] = true}
end

function gadget:AllowCommand_GetWantedUnitDefID()
	return true
end

function gadget:AllowCommand(unitID, unitDefID, teamID, cmdID, cmdParams, cmdOptions)
	if cmdID == CMD_WANT_CLOAK then
		if UnitHasPersonalCloak(unitID, unitDefID) then
			SetWantedCloaked(unitID,cmdParams[1])
		end
		return false
	elseif cmdID == CMD_CLOAK then
		return false
	end
	return true
end

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------

function gadget:UnitCreated(unitID, unitDefID)
	local ud = UnitDefs[unitDefID]
	if UnitHasPersonalCloak(unitID, unitDefID) then
		local cloakDescID = Spring.FindUnitCmdDesc(unitID, CMD_CLOAK)
		if cloakDescID then
			Spring.InsertUnitCmdDesc(unitID, unitWantCloakCommandDesc)
			Spring.RemoveUnitCmdDesc(unitID, cloakDescID)
			spSetUnitRulesParam(unitID, "wantcloak", 0, alliedTrueTable)
			if ud.customParams.initcloaked then
				SetWantedCloaked(unitID, 1)
			end
			return
		end
	elseif ud.customParams.dynamic_comm then
		local cloakDescID = Spring.FindUnitCmdDesc(unitID, CMD_CLOAK)
		if cloakDescID then
			Spring.RemoveUnitCmdDesc(unitID, cloakDescID)
		end
	end
end

function gadget:Initialize()
	for _, unitID in ipairs(Spring.GetAllUnits()) do
		local unitDefID = spGetUnitDefID(unitID)
		gadget:UnitCreated(unitID, unitDefID)
		local pos = select(2, Spring.GetUnitPosition(unitID))
		if pos <= 0 then
			gadget:UnitEnteredWater(unitID)
		end
	end
end
