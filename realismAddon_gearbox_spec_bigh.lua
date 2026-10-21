-- Big-H Edition: per vehicle shift policy
--
-- Each vehicle can be given a fixed transmission mode that overrides the player's global "gear shift" game setting:
--   0 = player setting (default, nothing is overridden, behaves like the plain mod)
--   1 = automatic
--   2 = manual without clutch (realismAddon physics active, see checkIsManual in overrides)
--   3 = manual with clutch
-- The policy is stored per vehicle in the savegame, sent to joining clients and synchronized on change.
-- GIANTS re-applies the player's global setting to the vehicle every time somebody enters it (VehicleSettings ->
-- Motorized.onVehicleSettingChanged, also on the server), so we listen to the same event and put our policy back.

realismAddon_gearbox_spec_bigh = {}

realismAddon_gearbox_spec_bigh.SPEC_NAME = g_currentModName .. ".realismAddon_gearbox_spec_bigh"

realismAddon_gearbox_spec_bigh.POLICY_PLAYER = 0
realismAddon_gearbox_spec_bigh.POLICY_AUTO = 1
realismAddon_gearbox_spec_bigh.POLICY_MANUAL = 2
realismAddon_gearbox_spec_bigh.POLICY_MANUAL_CLUTCH = 3
realismAddon_gearbox_spec_bigh.POLICY_MAX = 3

realismAddon_gearbox_spec_bigh.HUD_DURATION = 5000 -- ms the profile text stays on screen after entering or switching

local function clampPolicy(policy)
	policy = tonumber(policy) or realismAddon_gearbox_spec_bigh.POLICY_PLAYER
	return math.max(0, math.min(realismAddon_gearbox_spec_bigh.POLICY_MAX, math.floor(policy)))
end

function realismAddon_gearbox_spec_bigh.prerequisitesPresent(specializations)
	return true
end

function realismAddon_gearbox_spec_bigh.registerEventListeners(vehicleType)
	SpecializationUtil.registerEventListener(vehicleType, "onLoad", realismAddon_gearbox_spec_bigh)
	SpecializationUtil.registerEventListener(vehicleType, "onPostLoad", realismAddon_gearbox_spec_bigh)
	SpecializationUtil.registerEventListener(vehicleType, "onUpdate", realismAddon_gearbox_spec_bigh)
	SpecializationUtil.registerEventListener(vehicleType, "onReadStream", realismAddon_gearbox_spec_bigh)
	SpecializationUtil.registerEventListener(vehicleType, "onWriteStream", realismAddon_gearbox_spec_bigh)
	SpecializationUtil.registerEventListener(vehicleType, "onDraw", realismAddon_gearbox_spec_bigh)
	-- the following events only exist on vehicle types that have the corresponding specialization, unknown events are ignored
	SpecializationUtil.registerEventListener(vehicleType, "onEnterVehicle", realismAddon_gearbox_spec_bigh)
	SpecializationUtil.registerEventListener(vehicleType, "onLeaveVehicle", realismAddon_gearbox_spec_bigh)
	SpecializationUtil.registerEventListener(vehicleType, "onVehicleSettingChanged", realismAddon_gearbox_spec_bigh)
	SpecializationUtil.registerEventListener(vehicleType, "onAIJobFinished", realismAddon_gearbox_spec_bigh)
end

function realismAddon_gearbox_spec_bigh.registerFunctions(vehicleType)
	SpecializationUtil.registerFunction(vehicleType, "bighGetShiftPolicy", realismAddon_gearbox_spec_bigh.bighGetShiftPolicy)
	SpecializationUtil.registerFunction(vehicleType, "bighSetShiftPolicy", realismAddon_gearbox_spec_bigh.bighSetShiftPolicy)
	SpecializationUtil.registerFunction(vehicleType, "bighApplyShiftPolicy", realismAddon_gearbox_spec_bigh.bighApplyShiftPolicy)
	SpecializationUtil.registerFunction(vehicleType, "bighOnEngineStalled", realismAddon_gearbox_spec_bigh.bighOnEngineStalled)
end

function realismAddon_gearbox_spec_bigh.registerOverwrittenFunctions(vehicleType)
	SpecializationUtil.registerOverwrittenFunction(vehicleType, "getCanMotorRun", realismAddon_gearbox_spec_bigh.getCanMotorRun)
end

function realismAddon_gearbox_spec_bigh:onLoad(savegame)
	self.spec_realismAddon_gearbox_bigh = {}
	local spec = self.spec_realismAddon_gearbox_bigh

	spec.shiftPolicy = realismAddon_gearbox_spec_bigh.POLICY_PLAYER
	-- last gear shift mode the controlling player's game setting put on this vehicle, restored when the policy goes back to 0
	spec.playerGearShiftMode = nil
	spec.hudVisibleUntil = 0
	spec.hudOverrideText = nil -- shown instead of the profile text, e.g. "not possible without gears"
	-- set after the engine stalled (server only): blocks the automatic motor start until the clutch is pressed or neutral is selected
	spec.stallRestartBlocked = false

	-- savegame value, server only. Clients receive it via onReadStream.
	-- same raw access as the other specs of this mod (key = vehicles.vehicle(x).<modName>.realismAddon_gearbox_spec_bigh)
	if self.isServer and savegame ~= nil and not savegame.resetVehicles and savegame.xmlFile ~= nil and savegame.xmlFile.handle ~= nil and savegame.key ~= nil then
		local saved = getXMLInt(savegame.xmlFile.handle, savegame.key .. "." .. realismAddon_gearbox_spec_bigh.SPEC_NAME .. "#shiftPolicy")
		if saved ~= nil then
			spec.shiftPolicy = clampPolicy(saved)
		end
	end
end

function realismAddon_gearbox_spec_bigh:onPostLoad(savegame)
	-- motor is fully set up now
	self:bighApplyShiftPolicy()
end

-- the engine was stalled by the Big-H stall logic (overrides.lua, server only).
-- GIANTS' "automatic motor start" would restart the engine in the very next tick, so we block the start
-- until the driver presses the clutch or shifts to neutral, like the neutral safety switch of a real tractor.
function realismAddon_gearbox_spec_bigh:bighOnEngineStalled()
	local spec = self.spec_realismAddon_gearbox_bigh
	if spec ~= nil and self.isServer then
		spec.stallRestartBlocked = true
	end
end

-- asked by Motorized before the automatic motor start
function realismAddon_gearbox_spec_bigh:getCanMotorRun(superFunc)
	local spec = self.spec_realismAddon_gearbox_bigh
	if spec ~= nil and spec.stallRestartBlocked then
		return false
	end
	return superFunc(self)
end

function realismAddon_gearbox_spec_bigh:onUpdate(dt)
	local spec = self.spec_realismAddon_gearbox_bigh
	if spec == nil or not spec.stallRestartBlocked then
		return
	end

	local motor = self.spec_motorized ~= nil and self.spec_motorized.motor or nil
	if motor == nil then
		spec.stallRestartBlocked = false
		return
	end

	-- release the block as soon as the clutch is pressed, neutral is selected, the engine is starting/running again anyway
	-- or the vehicle is no longer on a policy that can stall at all
	local motorRunning = self.getMotorState ~= nil and MotorState ~= nil and self:getMotorState() ~= MotorState.OFF
	local policyCanStall = spec.shiftPolicy == realismAddon_gearbox_spec_bigh.POLICY_MANUAL or spec.shiftPolicy == realismAddon_gearbox_spec_bigh.POLICY_MANUAL_CLUTCH
	if motor.manualClutchValue > 0.1 or motor:getIsInNeutral() or motorRunning or not policyCanStall then
		spec.stallRestartBlocked = false
	end
end

-- called by Vehicle:saveToXMLFile for every specialization
function realismAddon_gearbox_spec_bigh:saveToXMLFile(xmlFile, key, usedModNames)
	local spec = self.spec_realismAddon_gearbox_bigh
	if spec == nil or xmlFile == nil or xmlFile.handle == nil then
		return
	end

	-- only store a set policy, keeps the savegame clean
	if spec.shiftPolicy ~= realismAddon_gearbox_spec_bigh.POLICY_PLAYER then
		setXMLInt(xmlFile.handle, key .. "#shiftPolicy", spec.shiftPolicy)
	end
end

-- initial sync on join
function realismAddon_gearbox_spec_bigh:onWriteStream(streamId, connection)
	local spec = self.spec_realismAddon_gearbox_bigh
	streamWriteUIntN(streamId, clampPolicy(spec.shiftPolicy), 2)
end

function realismAddon_gearbox_spec_bigh:onReadStream(streamId, connection)
	local spec = self.spec_realismAddon_gearbox_bigh
	spec.shiftPolicy = clampPolicy(streamReadUIntN(streamId, 2))
	self:bighApplyShiftPolicy()
end

function realismAddon_gearbox_spec_bigh:bighGetShiftPolicy()
	local spec = self.spec_realismAddon_gearbox_bigh
	if spec == nil then
		return realismAddon_gearbox_spec_bigh.POLICY_PLAYER
	end
	return spec.shiftPolicy
end

-- set the policy. Called from the input callbacks (client) and from the event (server and other clients)
function realismAddon_gearbox_spec_bigh:bighSetShiftPolicy(policy, noEventSend)
	local spec = self.spec_realismAddon_gearbox_bigh
	if spec == nil then
		return
	end
	policy = clampPolicy(policy)

	-- a driver's request (not an incoming event): manual profiles need a gearbox with gears.
	-- CVT / vario vehicles without gear sets are always automatic for GIANTS, so tell the driver instead of pretending
	if not noEventSend and not realismAddon_gearbox_spec_bigh.getHasGears(self) and policy ~= realismAddon_gearbox_spec_bigh.POLICY_PLAYER and policy ~= realismAddon_gearbox_spec_bigh.POLICY_AUTO then
		if self.isClient then
			spec.hudOverrideText = realismAddon_gearbox_spec_bigh.getText("RAGB_BIGH_POLICY_NO_GEARS", "Transmission profile: not possible, no gears")
			spec.hudVisibleUntil = g_time + realismAddon_gearbox_spec_bigh.HUD_DURATION
		end
		return
	end
	spec.hudOverrideText = nil

	RAGB_BigH_ShiftPolicyEvent.sendEvent(self, policy, noEventSend)

	if spec.shiftPolicy ~= policy then
		spec.shiftPolicy = policy
		self:bighApplyShiftPolicy()
	end

	if self.isClient then
		spec.hudVisibleUntil = g_time + realismAddon_gearbox_spec_bigh.HUD_DURATION
	end
end

-- map the policy to the motor's gear shift mode. Runs on server and clients, no network traffic.
function realismAddon_gearbox_spec_bigh:bighApplyShiftPolicy()
	local spec = self.spec_realismAddon_gearbox_bigh
	local specMotorized = self.spec_motorized
	local motor = specMotorized ~= nil and specMotorized.motor or nil
	if spec == nil or motor == nil then
		return
	end

	-- while an AI worker drives GIANTS forces automatic, don't fight that. We re-apply in onAIJobFinished.
	if self.getIsAIActive ~= nil and self:getIsAIActive() then
		return
	end

	local policy = spec.shiftPolicy
	local wantedMode = nil

	-- a stall block only makes sense while the vehicle can stall (policy 2/3), never keep the engine off in automatic / player setting
	if policy ~= realismAddon_gearbox_spec_bigh.POLICY_MANUAL and policy ~= realismAddon_gearbox_spec_bigh.POLICY_MANUAL_CLUTCH then
		spec.stallRestartBlocked = false
	end

	if policy == realismAddon_gearbox_spec_bigh.POLICY_AUTO then
		wantedMode = VehicleMotor.SHIFT_MODE_AUTOMATIC
	elseif policy == realismAddon_gearbox_spec_bigh.POLICY_MANUAL then
		wantedMode = VehicleMotor.SHIFT_MODE_MANUAL
	elseif policy == realismAddon_gearbox_spec_bigh.POLICY_MANUAL_CLUTCH then
		wantedMode = VehicleMotor.SHIFT_MODE_MANUAL_CLUTCH
	else
		-- player setting: give back what the player's game setting put on this vehicle
		wantedMode = spec.playerGearShiftMode or specMotorized.gearShiftMode
	end

	-- vehicles without gears (CVT, cars) can only be automatic. A manual policy on such a vehicle (e.g. from an old savegame)
	-- is corrected to automatic so the HUD never claims "manual" on a vehicle that cannot be manual
	if not realismAddon_gearbox_spec_bigh.getHasGears(self) and (policy == realismAddon_gearbox_spec_bigh.POLICY_MANUAL or policy == realismAddon_gearbox_spec_bigh.POLICY_MANUAL_CLUTCH) then
		spec.shiftPolicy = realismAddon_gearbox_spec_bigh.POLICY_AUTO
		policy = spec.shiftPolicy
		wantedMode = VehicleMotor.SHIFT_MODE_AUTOMATIC
	end

	if wantedMode ~= nil and motor.gearShiftMode ~= wantedMode then
		-- the mod overwrites VehicleMotor.setGearShiftMode so the mode is kept as is (no powershift downgrade)
		motor:setGearShiftMode(wantedMode)

		-- the inputs spec caches the manual state and registers its action events from it
		if self.spec_realismAddon_gearbox_inputs ~= nil then
			self.spec_realismAddon_gearbox_inputs.allManualActive = realismAddon_gearbox_overrides.checkIsManual(motor)
		end
		if self.isClient and self.requestActionEventUpdate ~= nil then
			self:requestActionEventUpdate()
		end
	end
end

-- GIANTS applied the controlling player's global gear shift setting to this vehicle (runs after Motorized's listener)
function realismAddon_gearbox_spec_bigh:onVehicleSettingChanged(gameSettingId, state)
	if gameSettingId == GameSettings.SETTING.GEAR_SHIFT_MODE then
		local spec = self.spec_realismAddon_gearbox_bigh
		if spec ~= nil then
			spec.playerGearShiftMode = state
		end
		self:bighApplyShiftPolicy()
	end
end

-- GIANTS restores the player's setting after an AI job, put the policy back on top
function realismAddon_gearbox_spec_bigh:onAIJobFinished(job)
	self:bighApplyShiftPolicy()
end

function realismAddon_gearbox_spec_bigh:onEnterVehicle(isControlling)
	local spec = self.spec_realismAddon_gearbox_bigh
	-- show the current profile for a few seconds whenever the player takes control, also for "player setting"
	if spec ~= nil and self.isClient and isControlling then
		spec.hudOverrideText = nil
		spec.hudVisibleUntil = g_time + realismAddon_gearbox_spec_bigh.HUD_DURATION
	end
end

function realismAddon_gearbox_spec_bigh:onLeaveVehicle(wasEntered)
	local spec = self.spec_realismAddon_gearbox_bigh
	if spec ~= nil then
		spec.hudVisibleUntil = 0
		-- don't carry a stall block over to the next driver
		spec.stallRestartBlocked = false
	end
end

function realismAddon_gearbox_spec_bigh.getHasGears(vehicle)
	local motor = vehicle.spec_motorized ~= nil and vehicle.spec_motorized.motor or nil
	return motor ~= nil and (motor.forwardGears ~= nil or motor.backwardGears ~= nil)
end

function realismAddon_gearbox_spec_bigh.getText(name, fallback)
	local text = g_i18n:getText(name)
	if text == nil or text == "" then
		text = fallback
	end
	return text
end

function realismAddon_gearbox_spec_bigh.getPolicyText(policy)
	return realismAddon_gearbox_spec_bigh.getText("RAGB_BIGH_POLICY_" .. tostring(clampPolicy(policy)), "Policy " .. tostring(policy))
end

function realismAddon_gearbox_spec_bigh:onDraw(isActiveForInput, isActiveForInputIgnoreSelection, isSelected)
	local spec = self.spec_realismAddon_gearbox_bigh
	if spec == nil or g_time > spec.hudVisibleUntil then
		return
	end

	setTextAlignment(RenderText.ALIGN_CENTER)
	setTextBold(true)
	setTextColor(130/255, 171/255, 13/255, 1)
	renderText(0.5, 0.95, 0.018, spec.hudOverrideText or realismAddon_gearbox_spec_bigh.getPolicyText(spec.shiftPolicy))
	setTextColor(1, 1, 1, 1)
	setTextBold(false)
	setTextAlignment(RenderText.ALIGN_LEFT)
end
