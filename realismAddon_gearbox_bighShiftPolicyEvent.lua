-- Big-H Edition: event to synchronize the per vehicle shift policy (client -> server -> all clients)

RAGB_BigH_ShiftPolicyEvent = {}
local RAGB_BigH_ShiftPolicyEvent_mt = Class(RAGB_BigH_ShiftPolicyEvent, Event)

InitEventClass(RAGB_BigH_ShiftPolicyEvent, "RAGB_BigH_ShiftPolicyEvent")

function RAGB_BigH_ShiftPolicyEvent.emptyNew()
	return Event.new(RAGB_BigH_ShiftPolicyEvent_mt)
end

function RAGB_BigH_ShiftPolicyEvent.new(vehicle, policy)
	local self = RAGB_BigH_ShiftPolicyEvent.emptyNew()
	self.vehicle = vehicle
	self.policy = policy
	return self
end

function RAGB_BigH_ShiftPolicyEvent:readStream(streamId, connection)
	self.vehicle = NetworkUtil.readNodeObject(streamId)
	self.policy = streamReadUIntN(streamId, 2)
	self:run(connection)
end

function RAGB_BigH_ShiftPolicyEvent:writeStream(streamId, connection)
	NetworkUtil.writeNodeObject(streamId, self.vehicle)
	streamWriteUIntN(streamId, self.policy, 2)
end

function RAGB_BigH_ShiftPolicyEvent:run(connection)
	if not connection:getIsServer() then
		g_server:broadcastEvent(self, false, connection, self.vehicle)
	end

	if self.vehicle ~= nil and self.vehicle:getIsSynchronized() and self.vehicle.bighSetShiftPolicy ~= nil then
		self.vehicle:bighSetShiftPolicy(self.policy, true)
	end
end

function RAGB_BigH_ShiftPolicyEvent.sendEvent(vehicle, policy, noEventSend)
	if noEventSend == nil or noEventSend == false then
		if g_server ~= nil then
			g_server:broadcastEvent(RAGB_BigH_ShiftPolicyEvent.new(vehicle, policy), nil, nil, vehicle)
		else
			g_client:getServerConnection():sendEvent(RAGB_BigH_ShiftPolicyEvent.new(vehicle, policy))
		end
	end
end
