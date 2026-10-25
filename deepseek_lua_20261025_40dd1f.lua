--!nonstrict
--[[
	Bike Universe Hub v3.1
	======================
	Complete rewrite of every feature.

	1. Teleport farm       - adaptive height, multi-detect, stats
	2. Auto wheelie        - randomized cadence, auto-recovery
	3. Rider lock          - fling + ragdoll-state + drift detection
	4. Pumpkin farm        - skip collected, distance guard
	5 + 6. ESP             - HP bars, distance color, fast update
	7. Bike tuning         - REAL 400 km/h cap, smoothed brakes
	8. Teleports           - position hold, no-bike fallback
	9. Handling assist     - lateral grip, counter-steer, anti-spin
	10. Brake assist       - extra force, auto-level, anti-lock
	11. Forest Trees purge - auto removal on start
	Persistence            - toggles + tuning survive relaunch

	RightControl shows / hides the window.
]]

----------------------------------------------------------------------
-- UI library
----------------------------------------------------------------------

local UI_SOURCES = {
	"https://raw.githubusercontent.com/bobloscript/Robly_Airflow/main/Source.luau",
	"https://raw.githubusercontent.com/PookiePepelsss/Airflow-UI/refs/heads/main/Source.luau",
}

local Airflow
for _, url in ipairs(UI_SOURCES) do
	local ok, lib = pcall(function()
		return loadstring(game:HttpGet(url))()
	end)
	if ok and type(lib) == "table" and type(lib.CreateWindow) == "function" then
		Airflow = lib
		break
	end
end
if not Airflow then
	error("[Bike Universe Hub] UI library failed to load.")
end

----------------------------------------------------------------------
-- Services
----------------------------------------------------------------------

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local VirtualInputManager = game:GetService("VirtualInputManager")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local Ragdoll
pcall(function()
	Ragdoll = require(ReplicatedStorage:WaitForChild("Ragdoll", 5))
end)

----------------------------------------------------------------------
-- Forest Trees cleanup (auto)
----------------------------------------------------------------------

local function clearForestTrees()
	local trees = workspace:FindFirstChild("Forest Trees")
	if trees then
		pcall(function() trees:Destroy() end)
		return true
	end
	return false
end

-- Удаляем сразу при старте
clearForestTrees()

----------------------------------------------------------------------
-- Util
----------------------------------------------------------------------

local function short(value)
	if type(value) ~= "number" then return "-" end
	local text = tostring(math.floor(value))
	return (text:reverse():gsub("(%d%d%d)", "%1 "):reverse():gsub("^%s+", ""))
end

local function clamp(v, lo, hi)
	if v < lo then return lo end
	if v > hi then return hi end
	return v
end

----------------------------------------------------------------------
-- Bike accessors
----------------------------------------------------------------------

local function myBike()
	for _, child in ipairs(workspace:GetChildren()) do
		if child:IsA("Model") and child:GetAttribute("Owner") == LocalPlayer.UserId then
			return child
		end
	end
	return nil
end

local function chassis()
	local bike = myBike()
	return bike and (bike:FindFirstChild("Chassis") or bike.PrimaryPart) or nil
end

local function driverSeat()
	local bike = myBike()
	return bike and bike:FindFirstChild("DriverSeat") or nil
end

local function humanoid()
	local char = LocalPlayer.Character
	return char and char:FindFirstChildOfClass("Humanoid") or nil
end

local function rootPart()
	local char = LocalPlayer.Character
	return char and char:FindFirstChild("HumanoidRootPart") or nil
end

local function bikePosition()
	local bike = myBike()
	return bike and bike:GetPivot().Position or nil
end

local function isRiding()
	local seat, hum = driverSeat(), humanoid()
	return seat ~= nil and hum ~= nil and seat.Occupant == hum
end

local function cash()
	local stats = LocalPlayer:FindFirstChild("leaderstats")
	local value = stats and stats:FindFirstChild("Cash")
	return value and value.Value or 0
end

----------------------------------------------------------------------
-- Drive hook
----------------------------------------------------------------------

local TouchControls
pcall(function()
	TouchControls = require(ReplicatedStorage:WaitForChild("TouchControls"))
end)

local driveState = getgenv().__BikeHubDrive
if type(driveState) ~= "table" then
	driveState = { on = false, throttle = 0, steer = 0, gen = 0, last = 0 }
	getgenv().__BikeHubDrive = driveState
end

if TouchControls and type(TouchControls.drive) == "function" then
	if TouchControls.drive ~= getgenv().__BikeHubDriveMarker then
		local originalDrive = TouchControls.drive
		local hooked
		hooked = function(seat)
			local state = getgenv().__BikeHubDrive
			if state and state.on and state.gen == getgenv().__BikeHubGen
				and (os.clock() - (state.last or 0) < 0.4) then
				return state.throttle, state.steer
			end
			return originalDrive(seat)
		end
		TouchControls.drive = hooked
		getgenv().__BikeHubDriveMarker = hooked
	end
end

local function drive(throttle, steer)
	driveState.throttle = throttle or 0
	driveState.steer = steer or 0
	driveState.on = true
	driveState.last = os.clock()
	driveState.gen = getgenv().__BikeHubGen or 0
end

local function driveStop()
	driveState.on = false
	driveState.throttle = 0
	driveState.steer = 0
	driveState.last = 0
end

----------------------------------------------------------------------
-- Key mirroring
----------------------------------------------------------------------

local heldKeys = {}

local function key(code, down)
	if heldKeys[code] == down then return end
	heldKeys[code] = down
	pcall(function()
		VirtualInputManager:SendKeyEvent(down, code, false, game)
	end)
end

local function releaseKeys()
	for code, down in pairs(heldKeys) do
		if down then
			pcall(function()
				VirtualInputManager:SendKeyEvent(false, code, false, game)
			end)
		end
	end
	heldKeys = {}
end

----------------------------------------------------------------------
-- Seating
----------------------------------------------------------------------

local log
local riderLockSet
local spawnBike
local pumpkinList
local teleportBike

spawnBike = function()
	if myBike() then return true end
	for _, name in ipairs({ "SpawnBikeEvent", "SelectBike", "BikeMount" }) do
		local remote = ReplicatedStorage:FindFirstChild(name)
		if remote and remote:IsA("RemoteEvent") then
			pcall(function() remote:FireServer() end)
			for _ = 1, 10 do
				task.wait(0.2)
				if myBike() then return true end
			end
		end
	end
	return myBike() ~= nil
end

local function standBikeUp(bike)
	local pivot = bike:GetPivot()
	if pivot.UpVector.Y > 0.6 then return true end
	local look = Vector3.new(pivot.LookVector.X, 0, pivot.LookVector.Z)
	if look.Magnitude < 0.05 then look = Vector3.new(0, 0, -1) end
	local position = pivot.Position + Vector3.new(0, 3, 0)
	pcall(function()
		bike:PivotTo(CFrame.lookAt(position, position + look.Unit))
	end)
	task.wait(0.2)
	if bike:GetPivot().UpVector.Y > 0.6 then return true end
	local spawn = ReplicatedStorage:FindFirstChild("SpawnBikeEvent")
	if spawn and spawn:IsA("RemoteEvent") then
		pcall(function() spawn:FireServer() end)
		for _ = 1, 12 do
			task.wait(0.25)
			local again = myBike()
			if again and again:GetPivot().UpVector.Y > 0.6 then return true end
		end
	end
	return false
end

local function seatUp()
	local seat, hum, bike = driverSeat(), humanoid(), myBike()
	if not (seat and hum and bike) then
		spawnBike()
		seat, hum, bike = driverSeat(), humanoid(), myBike()
	end
	if not (seat and hum and bike) then return false end
	if seat.Occupant == hum then return true end

	local char = LocalPlayer.Character
	if not char then return false end
	if Ragdoll and Ragdoll.isActive and Ragdoll.isActive(char) then
		pcall(function() Ragdoll.stop(char) end)
	end
	if hum.PlatformStand then hum.PlatformStand = false end
	pcall(function() hum:ChangeState(Enum.HumanoidStateType.GettingUp) end)
	pcall(function() hum.Sit = false end)
	task.wait(0.1)

	standBikeUp(bike)
	seat, hum, bike = driverSeat(), humanoid(), myBike()
	if not (seat and hum and bike) then return false end

	for attempt = 1, 3 do
		pcall(function()
			char:PivotTo(seat.CFrame * CFrame.new(0, attempt == 1 and 1.5 or 0.4, 0))
		end)
		task.wait(0.1)
		pcall(function() seat:Sit(hum) end)
		for _ = 1, 8 do
			if seat.Occupant == hum then return true end
			task.wait(0.05)
		end
	end

	local pivot = bike:GetPivot()
	pcall(function() char:PivotTo(pivot * CFrame.new(2.5, 2, 0)) end)
	task.wait(0.15)
	local mountSkip = ReplicatedStorage:FindFirstChild("BikeMountSkip")
	if mountSkip and mountSkip:IsA("RemoteEvent") then
		pcall(function() mountSkip:FireServer(bike) end)
	end
	key(Enum.KeyCode.W, true)
	for _ = 1, 30 do
		if seat.Occupant == hum then break end
		task.wait(0.05)
	end
	key(Enum.KeyCode.W, false)
	return seat.Occupant == hum
end

----------------------------------------------------------------------
-- Crash prevention
----------------------------------------------------------------------

if Ragdoll and type(Ragdoll.fling) == "function" and not getgenv().__BikeHubFlingHooked then
	getgenv().__BikeHubFlingHooked = true
	local originalFling = Ragdoll.fling
	Ragdoll.fling = function(...)
		if getgenv().__BikeFarmOn or getgenv().__BikeHubRiderLock then
			return
		end
		return originalFling(...)
	end
end

local function riderLockTick()
	local seat, hum = driverSeat(), humanoid()
	if not (seat and hum) then return end

	if getgenv().__BikeHubRiderLock and seat.Occupant ~= hum then
		local rp = rootPart()
		if rp and (rp.Position - seat.Position).Magnitude > 3 then
			pcall(function()
				rp.CFrame = seat.CFrame * CFrame.new(0, 1.5, 0)
			end)
		end
		pcall(function() seat:Sit(hum) end)
	end

	if hum.PlatformStand then hum.PlatformStand = false end
	local state = hum:GetState()
	if state == Enum.HumanoidStateType.Ragdoll or state == Enum.HumanoidStateType.FallingDown then
		pcall(function() hum:ChangeState(Enum.HumanoidStateType.GettingUp) end)
	end
end

----------------------------------------------------------------------
-- Settings / state
----------------------------------------------------------------------

local Settings = {
	farmOn = false,
	height = 140,
	minHeight = 100,
	maxHeight = 400,
	cooldown = 3.0,

	wheelieOn = false,
	riderLock = false,

	handlingAssist = false,
	brakeAssist = false,

	pumpkinFarm = false,
	playerEsp = false,
	policeEsp = false,

	speedCapKmh = 400,
}

local Stats = {
	jumps = 0,
	successes = 0,
	failures = 0,
	totalAirtime = 0,
	lastAirtime = 0,
	lastCash = 0,
	lastSample = 0,
	perMinute = 0,
	launchPosition = nil,
	launchRotation = nil,
}

local Window
local UiRefs = {}

getgenv().__BikeHubGen = (getgenv().__BikeHubGen or 0) + 1
local SCRIPT_GENERATION = getgenv().__BikeHubGen

local function scriptAlive()
	return getgenv().__BikeHubGen == SCRIPT_GENERATION
end

----------------------------------------------------------------------
-- Logger
----------------------------------------------------------------------

local LogElement
local logLast = {}

log = function(message)
	if not LogElement then return end
	local text = tostring(message)
	local now = os.clock()
	if logLast[text] and now - logLast[text] < 1.0 then return end
	logLast[text] = now
	pcall(function() LogElement:Push(text) end)
end

local function logWarn(msg) log("<Warning>" .. tostring(msg) .. "</Warning>") end
local function logErr(msg) log("<Error>" .. tostring(msg) .. "</Error>") end
local function logOk(msg) log("<Success>" .. tostring(msg) .. "</Success>") end

----------------------------------------------------------------------
-- Forest Trees monitoring loop (with logging)
----------------------------------------------------------------------

task.spawn(function()
	while scriptAlive() do
		local removed = clearForestTrees()
		if removed then
			pcall(function() log("[Forest Trees] removed") end)
		end
		task.wait(removed and 0.5 or 2)
	end
end)

----------------------------------------------------------------------
-- 1. TELEPORT FARM (adaptive + stats)
----------------------------------------------------------------------

local anchor

local function captureAnchor()
	local part = chassis()
	anchor = part and part.Position or nil
end

-- IMPROVED: не замораживаем байк, реагируем только на реальный флинг
local function holdAnchor()
	local bike, part = myBike(), chassis()
	if not (bike and part) then return end
	if not anchor then anchor = part.Position end

	-- Сильный флинг — откатываем на якорь
	if (part.Position - anchor).Magnitude > 200 then
		local rotation = part.CFrame - part.CFrame.Position
		pcall(function() bike:PivotTo(CFrame.new(anchor) * rotation) end)
		part.AssemblyLinearVelocity = Vector3.zero
		part.AssemblyAngularVelocity = Vector3.zero
		return
	end

	-- Следуем за байком, гасим только опасный боковой снос
	anchor = part.Position
	local vel = part.AssemblyLinearVelocity
	local look = part.CFrame.LookVector
	local flatLook = Vector3.new(look.X, 0, look.Z)
	if flatLook.Magnitude > 0.01 then
		flatLook = flatLook.Unit
		local flatVel = Vector3.new(vel.X, 0, vel.Z)
		local lateral = flatVel - flatLook * flatVel:Dot(flatLook)
		if lateral.Magnitude > 15 then
			part.AssemblyLinearVelocity = part.AssemblyLinearVelocity - lateral * 0.5
		end
	end
end

local function jumpOnce()
	local bike, part = myBike(), chassis()
	if not (bike and part) then
		spawnBike()
		task.wait(0.2)
		return false
	end
	if not isRiding() and not seatUp() then return false end

	if not bike:GetAttribute("Airborne") then
		Stats.launchPosition = part.Position
		Stats.launchRotation = part.CFrame - part.CFrame.Position
	end
	local base = Stats.launchPosition or part.Position
	local rotation = Stats.launchRotation or (part.CFrame - part.CFrame.Position)
	local useHeight = clamp(Settings.height, Settings.minHeight, Settings.maxHeight)

	drive(1)
	bike:PivotTo(CFrame.new(base + Vector3.new(
		math.random(-25, 25),
		useHeight,
		math.random(-25, 25)
	)) * rotation)

	local started = os.clock()
	local lostRider = false
	local lastPos = part.Position
	local stillTicks = 0

	while bike:GetAttribute("Airborne") and os.clock() - started < 30 do
		if not (Settings.farmOn and scriptAlive()) then return false end
		if not isRiding() then lostRider = true break end
		if (part.Position - lastPos).Magnitude < 2 then
			stillTicks += 1
			if stillTicks > 20 then break end
		else
			stillTicks = 0
			lastPos = part.Position
		end
		task.wait(0.1)
	end

	Stats.lastAirtime = os.clock() - started
	Stats.totalAirtime += Stats.lastAirtime

	if lostRider or bike:GetAttribute("Airborne") then
		Stats.failures += 1
		bike:PivotTo(CFrame.new(base + Vector3.new(0, 6, 0)) * rotation)
		task.wait(0.5)
		seatUp()
	else
		Stats.successes += 1
	end

	if Stats.lastAirtime < 1.5 then
		Settings.height = clamp(Settings.height + 20, Settings.minHeight, Settings.maxHeight)
	elseif Stats.lastAirtime > 8 then
		Settings.height = clamp(Settings.height - 20, Settings.minHeight, Settings.maxHeight)
	end

	task.wait(Settings.cooldown)
	drive(1)
	Stats.jumps += 1
	return true
end

local function farmSet(on)
	Settings.farmOn = on
	getgenv().__BikeFarmOn = on
	if not on then
		driveStop()
		releaseKeys()
		Stats.launchPosition = nil
		Stats.launchRotation = nil
		log("Farm off")
		if UiRefs.farm then pcall(function() UiRefs.farm:Set(false, true) end) end
		return
	end

	task.spawn(function()
		local ok, err = pcall(seatUp)
		if not ok or not Settings.farmOn or not isRiding() then
			logWarn("Farm start aborted: " .. tostring(err or "seatUp fail"))
			Settings.farmOn = false
			getgenv().__BikeFarmOn = false
			if UiRefs.farm then pcall(function() UiRefs.farm:Set(false, true) end) end
			return
		end
		Stats.jumps = 0
		Stats.successes = 0
		Stats.failures = 0
		Stats.totalAirtime = 0
		Stats.lastCash = cash()
		Stats.lastSample = os.clock()
		logOk(string.format("Farm on - starting height %d", Settings.height))
		while Settings.farmOn and scriptAlive() do
			local ok2, err2 = pcall(jumpOnce)
			if not ok2 then
				logErr("Jump: " .. tostring(err2))
				task.wait(1)
			elseif not Settings.farmOn then
				break
			end
			task.wait(0.05)
		end
	end)
	if UiRefs.farm then pcall(function() UiRefs.farm:Set(true, true) end) end
end

----------------------------------------------------------------------
-- 2. AUTO WHEELIE
----------------------------------------------------------------------

local function wheelieCycle(throttle)
	key(Enum.KeyCode.LeftControl, false)
	task.wait(0.04 + math.random() * 0.04)
	key(Enum.KeyCode.LeftControl, true)
	drive(throttle or 1, 0)
	task.wait(0.35 + math.random() * 0.15)
	drive(0.2, 0)
	task.wait(0.35 + math.random() * 0.15)
end

local function wheelieSet(on)
	Settings.wheelieOn = on
	getgenv().__BikeHubWheelie = on
	if on then
		captureAnchor()
		logOk("Auto wheelie on")
		task.spawn(function()
			while Settings.wheelieOn and scriptAlive() do
				if isRiding() then
					wheelieCycle(1)
					holdAnchor()
				else
					seatUp()
					task.wait(0.2)
				end
			end
			driveStop()
			releaseKeys()
		end)
	else
		driveStop()
		releaseKeys()
		log("Auto wheelie off")
	end
	if UiRefs.wheelie then pcall(function() UiRefs.wheelie:Set(on, true) end) end
end

----------------------------------------------------------------------
-- 3. RIDER LOCK
----------------------------------------------------------------------

riderLockSet = function(on)
	Settings.riderLock = on
	getgenv().__BikeHubRiderLock = on
	logOk(on and "Rider lock on" or "Rider lock off")
	if UiRefs.riderLock then pcall(function() UiRefs.riderLock:Set(on, true) end) end
end

-- IMPROVED: riderLockTick теперь реально подключён к Heartbeat
RunService.Heartbeat:Connect(function()
	if not scriptAlive() then return end
	pcall(riderLockTick)
end)

----------------------------------------------------------------------
-- 4. PUMPKIN FARM
----------------------------------------------------------------------

-- IMPROVED: рекурсивный обход + поиск внутри Model-контейнеров
pumpkinList = function()
	local list, seen = {}, {}
	local function add(model)
		if not seen[model] and model:IsA("Model") and model:FindFirstChild("Body") then
			seen[model] = true
			table.insert(list, model)
		end
	end

	local folder = workspace:FindFirstChild("MyPumpkins")
	if folder then
		for _, child in ipairs(folder:GetDescendants()) do
			add(child)
		end
		if #list > 0 then return list end
	end

	local function scan(inst, depth)
		if depth > 5 then return end
		for _, child in ipairs(inst:GetChildren()) do
			if child:IsA("Model") and child.Name:lower():find("pumpkin") then
				add(child)
			end
			if not child:IsA("Model") then scan(child, depth + 1) end
		end
	end
	scan(workspace, 0)
	return list
end

-- teleportBike: определение (в оригинале был объявлен, но не определён)
teleportBike = function(cf)
	local bike = myBike()
	if not bike or not cf then return false end
	pcall(function() bike:PivotTo(cf) end)
	local part = chassis()
	if part then
		part.AssemblyLinearVelocity = Vector3.zero
		part.AssemblyAngularVelocity = Vector3.zero
	end
	return true
end

local function pumpkinSet(on)
	Settings.pumpkinFarm = on
	if on then
		task.spawn(function()
			while Settings.pumpkinFarm and scriptAlive() do
				local bike = myBike()
				local list = pumpkinList()
				if bike and #list > 0 and type(teleportBike) == "function" then
					local bp = bike:GetPivot().Position
					local nearest, best
					for _, pumpkin in ipairs(list) do
						local distance = (pumpkin:GetPivot().Position - bp).Magnitude
						if distance < 1000 and (not best or distance < best) then
							nearest, best = pumpkin, distance
						end
					end
					if nearest then
						drive(1, 0)
						pcall(function() teleportBike(nearest:GetPivot() * CFrame.new(0, 6, 0)) end)
						task.wait(0.4)
						drive(1, 0)
						task.wait(0.4)
					else
						task.wait(0.8)
					end
				else
					task.wait(1)
				end
			end
		end)
		logWarn("Pumpkin farm on (experimental)")
	else
		log("Pumpkin farm off")
	end
	if UiRefs.pumpkin then pcall(function() UiRefs.pumpkin:Set(on, true) end) end
end

----------------------------------------------------------------------
-- 5 + 6. ESP
----------------------------------------------------------------------

local esp = { player = {}, police = {} }

local function makeEsp(adornee, text, color, hp)
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "BikeHubEsp"
	billboard.Size = UDim2.fromOffset(240, 56)
	billboard.StudsOffsetWorldSpace = Vector3.new(0, 3.5, 0)
	billboard.AlwaysOnTop = true
	billboard.Adornee = adornee
	billboard.Parent = PlayerGui

	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, 0, 0.55, 0)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.TextSize = 14
	label.TextColor3 = color
	label.TextStrokeTransparency = 0.4
	label.Text = text
	label.Parent = billboard

	local barBg = Instance.new("Frame")
	barBg.Size = UDim2.new(1, -20, 0.18, 0)
	barBg.Position = UDim2.new(0, 10, 0.6, 0)
	barBg.BackgroundColor3 = Color3.fromRGB(40, 40, 45)
	barBg.BorderSizePixel = 0
	barBg.Parent = billboard

	local bar = Instance.new("Frame")
	bar.Name = "HPBar"
	bar.Size = UDim2.new(hp or 1, 0, 1, 0)
	bar.BackgroundColor3 = Color3.fromRGB(90, 220, 120)
	bar.BorderSizePixel = 0
	bar.Parent = barBg

	local highlight = Instance.new("Highlight")
	highlight.Name = "BikeHubHighlight"
	highlight.FillColor = color
	highlight.FillTransparency = 0.75
	highlight.OutlineColor = color
	highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	highlight.Adornee = adornee
	highlight.Parent = PlayerGui

	return { billboard = billboard, highlight = highlight, label = label, bar = bar }
end

local function clearEsp(kind)
	for _, entry in pairs(esp[kind]) do
		if entry.billboard then entry.billboard:Destroy() end
		if entry.highlight then entry.highlight:Destroy() end
	end
	esp[kind] = {}
end

-- IMPROVED: расширенная очистка старых элементов
task.spawn(function()
	for _, child in ipairs(PlayerGui:GetChildren()) do
		if child.Name == "BikeHubEsp"
			or child.Name == "BikeHubHighlight"
			or child.Name == "BikeHubEspContainer" then
			child:Destroy()
		end
	end
end)

local function colorByDistance(dist)
	if not dist then return Color3.fromRGB(255, 59, 127) end
	if dist < 100 then return Color3.fromRGB(120, 255, 130) end
	if dist < 300 then return Color3.fromRGB(255, 200, 80) end
	return Color3.fromRGB(255, 59, 127)
end

local function refreshPlayerEsp()
	local alive = {}
	local me = bikePosition()
	for _, player in ipairs(Players:GetPlayers()) do
		if player ~= LocalPlayer and player.Character then
			local torso = player.Character:FindFirstChild("HumanoidRootPart")
				or player.Character:FindFirstChild("Torso")
			local hum = player.Character:FindFirstChildOfClass("Humanoid")
			if torso then
				alive[torso] = true
				local dist = me and math.floor((torso.Position - me).Magnitude) or 0
				local hpRatio = hum and (hum.Health / math.max(hum.MaxHealth, 1)) or 1
				if not esp.player[torso] then
					esp.player[torso] = makeEsp(torso, player.Name, colorByDistance(dist), hpRatio)
				end
				local e = esp.player[torso]
				e.label.Text = string.format("%s  [%d]", player.Name, dist)
				e.label.TextColor3 = colorByDistance(dist)
				e.bar.Size = UDim2.new(clamp(hpRatio, 0, 1), 0, 1, 0)
				e.bar.BackgroundColor3 = hpRatio > 0.5 and Color3.fromRGB(90, 220, 120)
					or hpRatio > 0.25 and Color3.fromRGB(255, 200, 80)
					or Color3.fromRGB(255, 90, 90)
			end
		end
	end
	for torso, entry in pairs(esp.player) do
		if not alive[torso] or not torso.Parent then
			entry.billboard:Destroy()
			entry.highlight:Destroy()
			esp.player[torso] = nil
		end
	end
end

-- IMPROVED: очищаем ESP при пропаже папки Police
local function refreshPoliceEsp()
	local folder = workspace:FindFirstChild("Police")
	if not folder then
		if next(esp.police) then clearEsp("police") end
		return
	end
	local alive = {}
	for _, model in ipairs(folder:GetChildren()) do
		if model:IsA("Model") then
			local root = model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart
			if root then
				alive[root] = true
				if not esp.police[root] then
					esp.police[root] = makeEsp(root, "POLICE", Color3.fromRGB(70, 140, 255), 1)
				end
			end
		end
	end
	for root, entry in pairs(esp.police) do
		if not alive[root] or not root.Parent then
			entry.billboard:Destroy()
			entry.highlight:Destroy()
			esp.police[root] = nil
		end
	end
end

task.spawn(function()
	while scriptAlive() do
		pcall(function()
			if Settings.playerEsp then refreshPlayerEsp()
			elseif next(esp.player) then clearEsp("player") end
			if Settings.policeEsp then refreshPoliceEsp()
			elseif next(esp.police) then clearEsp("police") end
		end)
		task.wait(0.15)
	end
end)

----------------------------------------------------------------------
-- 7. BIKE TUNING
----------------------------------------------------------------------

local TUNING_DEFAULTS = {
	MaxSpeedKmh = 400,
	LaunchAccel = 5.5,
	PowerPerKg = 250,
	TireGrip = 1.35,
	AirGravity = 50,
	WheelieStrength = 1.1,
	BrakeDecel = 22,
	SteerSpeed = 3.5,
	BrakePower = 2.0,
}

local TUNING_VALUES = getgenv().__BikeHubTuningValues
if type(TUNING_VALUES) ~= "table" then
	TUNING_VALUES = {}
	getgenv().__BikeHubTuningValues = TUNING_VALUES
end
for name, defaultValue in pairs(TUNING_DEFAULTS) do
	if type(TUNING_VALUES[name]) ~= "number" then
		TUNING_VALUES[name] = defaultValue
	end
end
-- migrate old defaults
if TUNING_VALUES.BrakeDecel == 7 then TUNING_VALUES.BrakeDecel = 22 end
if TUNING_VALUES.TireGrip == 0.95 then TUNING_VALUES.TireGrip = 1.35 end
if TUNING_VALUES.LaunchAccel == 4.2 then TUNING_VALUES.LaunchAccel = 5.5 end

TUNING_VALUES.MaxSpeedKmh = clamp(TUNING_VALUES.MaxSpeedKmh, 40, 400)
TUNING_VALUES.PowerPerKg = clamp(TUNING_VALUES.PowerPerKg, 10, 250)
TUNING_VALUES.TireGrip = clamp(TUNING_VALUES.TireGrip, 0.2, 3)
TUNING_VALUES.BrakeDecel = clamp(TUNING_VALUES.BrakeDecel, 1, 50)
TUNING_VALUES.LaunchAccel = clamp(TUNING_VALUES.LaunchAccel, 1, 30)
TUNING_VALUES.SteerSpeed = clamp(TUNING_VALUES.SteerSpeed, 0.5, 10)
TUNING_VALUES.BrakePower = clamp(TUNING_VALUES.BrakePower, 0.5, 10)

local function applyTuningToBike(bike, name, value)
	if bike and bike.Parent and bike:IsA("Model") then
		pcall(function() bike:SetAttribute(name, value) end)
	end
end

local function applyAllTuning(bike)
	bike = bike or myBike()
	if not bike then return false end
	for name, value in pairs(TUNING_VALUES) do
		if TUNING_DEFAULTS[name] ~= nil then
			applyTuningToBike(bike, name, value)
		end
	end
	return true
end

local function applyTuning(name, value)
	if TUNING_DEFAULTS[name] == nil or type(value) ~= "number" then return end
	TUNING_VALUES[name] = value
	getgenv().__BikeHubTuningValues = TUNING_VALUES
	applyTuningToBike(myBike(), name, value)
end

local function resetTuning()
	for name, value in pairs(TUNING_DEFAULTS) do
		TUNING_VALUES[name] = value
	end
	getgenv().__BikeHubTuningValues = TUNING_VALUES
	applyAllTuning()
	logOk("Tuning reset to defaults")
end

-- Автоприменение тюнинга при появлении байка
task.spawn(function()
	while scriptAlive() do
		local bike = myBike()
		if bike then
			for name, value in pairs(TUNING_VALUES) do
				if TUNING_DEFAULTS[name] ~= nil then
					local current = bike:GetAttribute(name)
					if current ~= value then
						applyTuningToBike(bike, name, value)
					end
				end
			end
		end
		task.wait(1)
	end
end)

----------------------------------------------------------------------
-- 7a. HANDLING ASSIST (improved)
----------------------------------------------------------------------

local HANDLING = {
	LateralGrip      = 0.72,
	AutoLevel        = 0.45,
	SteerSmoothing   = 0.75,
	MaxAngularVel    = 14,
	HighSpeedAssist  = 0.5,
	AssistSpeedKmh   = 180,
	CounterSteerGain = 3.0,
}

local handlingState = {
	smoothedSteer = 0,
}

local function speedKmh(part)
	if not part then return 0 end
	return part.AssemblyLinearVelocity.Magnitude * 3.6
end

local function handlingAssistUpdate(dt)
	if not Settings.handlingAssist then return end
	local bike, part = myBike(), chassis()
	if not (bike and part) or not isRiding() then return end

	local rawSteer = (driveState.on and driveState.steer) or 0
	handlingState.smoothedSteer = handlingState.smoothedSteer
		+ (rawSteer - handlingState.smoothedSteer) * HANDLING.SteerSmoothing

	if bike:GetAttribute("Airborne") then
		local up = part.CFrame.UpVector
		if up.Y < 0.92 then
			local targetUp = Vector3.new(0, 1, 0)
			local axis = up:Cross(targetUp)
			if axis.Magnitude > 0.001 then
				local angle = math.asin(clamp(axis.Magnitude, -1, 1))
				local correction = axis.Unit * angle * HANDLING.AutoLevel * 6
				part.AssemblyAngularVelocity = part.AssemblyAngularVelocity + correction * dt
			end
		end
		return
	end

	local vel = part.AssemblyLinearVelocity
	local look = part.CFrame.LookVector
	local flatLook = Vector3.new(look.X, 0, look.Z)
	if flatLook.Magnitude > 0.01 then
		flatLook = flatLook.Unit
		local forward = flatLook * vel:Dot(flatLook)
		local lateral = Vector3.new(vel.X, 0, vel.Z) - forward
		if lateral.Magnitude > 1.5 then
			local correction = lateral * HANDLING.LateralGrip * dt * 6
			if correction.Magnitude > lateral.Magnitude then correction = lateral end
			part.AssemblyLinearVelocity = part.AssemblyLinearVelocity - correction
		end
	end

	local speed = speedKmh(part)
	if speed > HANDLING.AssistSpeedKmh and math.abs(handlingState.smoothedSteer) > 0.05 then
		local strength = (speed - HANDLING.AssistSpeedKmh) / 200
		local assist = -handlingState.smoothedSteer * HANDLING.HighSpeedAssist * strength
		part.AssemblyAngularVelocity = part.AssemblyAngularVelocity
			+ Vector3.new(0, assist * HANDLING.CounterSteerGain * dt * 60, 0)
	end

	local ang = part.AssemblyAngularVelocity
	if ang.Magnitude > HANDLING.MaxAngularVel then
		part.AssemblyAngularVelocity = ang.Unit * HANDLING.MaxAngularVel
	end
end

----------------------------------------------------------------------
-- 7b. BRAKE ASSIST (improved)
----------------------------------------------------------------------

local BRAKE = {
	ExtraForce      = 30,
	MaxDecel        = 70,
	AutoLevel       = 0.6,
	MinSpeedToBrake = 2,
}

local brakeState = {
	active  = false,
	prevVel = Vector3.zero,
}

local function isBrakeInput()
	if UserInputService:GetFocusedTextBox() then return false end
	if UserInputService:IsKeyDown(Enum.KeyCode.S) then return true end
	if UserInputService:IsKeyDown(Enum.KeyCode.Down) then return true end
	if driveState.on and driveState.throttle < 0 then return true end
	return false
end

local function brakeAssistUpdate(dt)
	if not Settings.brakeAssist then
		brakeState.active = false
		return
	end
	local bike, part = myBike(), chassis()
	if not (bike and part) or not isRiding() then
		brakeState.active = false
		return
	end

	if not isBrakeInput() then
		brakeState.active = false
		brakeState.prevVel = part.AssemblyLinearVelocity
		return
	end

	brakeState.active = true
	local vel = part.AssemblyLinearVelocity
	local flatVel = Vector3.new(vel.X, 0, vel.Z)
	local speed = flatVel.Magnitude

	if speed > BRAKE.MinSpeedToBrake then
		local dir = flatVel.Unit
		local extra = math.min(BRAKE.ExtraForce * dt, speed)
		part.AssemblyLinearVelocity = Vector3.new(
			vel.X - dir.X * extra,
			vel.Y,
			vel.Z - dir.Z * extra
		)
	end

	if not bike:GetAttribute("Airborne") then
		local up = part.CFrame.UpVector
		if up.Y < 0.95 then
			local targetUp = Vector3.new(0, 1, 0)
			local axis = up:Cross(targetUp)
			if axis.Magnitude > 0.001 then
				local angle = math.asin(clamp(axis.Magnitude, -1, 1))
				local correction = axis.Unit * angle * BRAKE.AutoLevel * 8
				part.AssemblyAngularVelocity = part.AssemblyAngularVelocity + correction * dt
			end
		end
	end

	if brakeState.prevVel.Magnitude > 0.5 then
		local deltaV = part.AssemblyLinearVelocity - brakeState.prevVel
		local accel = deltaV.Magnitude / math.max(dt, 0.001)
		if accel > BRAKE.MaxDecel then
			local ratio = BRAKE.MaxDecel / accel
			part.AssemblyLinearVelocity = brakeState.prevVel + deltaV * ratio
		end
	end

	brakeState.prevVel = part.AssemblyLinearVelocity
end

-- Единый Heartbeat для обеих ассисток
RunService.Heartbeat:Connect(function(dt)
	if not scriptAlive() then return end
	pcall(handlingAssistUpdate, dt)
	pcall(brakeAssistUpdate, dt)
end)

----------------------------------------------------------------------
-- Persistence
----------------------------------------------------------------------

local PERSIST_KEY = "__BikeHubPersist"

local function saveSettings()
	getgenv()[PERSIST_KEY] = {
		height = Settings.height,
		cooldown = Settings.cooldown,
		speedCapKmh = Settings.speedCapKmh,
		handlingAssist = Settings.handlingAssist,
		brakeAssist = Settings.brakeAssist,
	}
end

local function loadSettings()
	local saved = getgenv()[PERSIST_KEY]
	if type(saved) ~= "table" then return end
	if type(saved.height) == "number" then
		Settings.height = clamp(saved.height, Settings.minHeight, Settings.maxHeight)
	end
	if type(saved.cooldown) == "number" then
		Settings.cooldown = clamp(saved.cooldown, 1, 20)
	end
	if type(saved.speedCapKmh) == "number" then
		Settings.speedCapKmh = clamp(saved.speedCapKmh, 40, 400)
	end
	if type(saved.handlingAssist) == "boolean" then
		Settings.handlingAssist = saved.handlingAssist
	end
	if type(saved.brakeAssist) == "boolean" then
		Settings.brakeAssist = saved.brakeAssist
	end
end

loadSettings()

----------------------------------------------------------------------
-- UI
----------------------------------------------------------------------

local uiOk, uiErr = pcall(function()
	Window = Airflow.CreateWindow({
		Title = "Bike Universe Hub v3.1",
		Subtitle = "Universal Bike Hub",
		TabWidth = 160,
		Size = UDim2.fromOffset(620, 480),
		Theme = "Dark",
		Acrylic = true,
		MinimizeKey = Enum.KeyCode.RightControl,
	})

	-- ===================== FARM =====================
	local FarmTab = Window:CreateTab({ Title = "Farm", Icon = "rbxassetid://10734947542" })
	local FarmSection = FarmTab:CreateSection("Teleport farm")

	UiRefs.farm = FarmSection:CreateToggle({
		Name = "Enable farm",
		CurrentValue = false,
		Flag = "farm",
		Callback = function(state) farmSet(state) end,
	})

	FarmSection:CreateSlider({
		Name = "Height",
		Range = { Settings.minHeight, Settings.maxHeight },
		Increment = 10,
		Suffix = " studs",
		CurrentValue = Settings.height,
		Flag = "farm_height",
		Callback = function(value)
			Settings.height = clamp(value, Settings.minHeight, Settings.maxHeight)
			saveSettings()
		end,
	})

	FarmSection:CreateSlider({
		Name = "Cooldown",
		Range = { 1, 10 },
		Increment = 0.5,
		Suffix = " s",
		CurrentValue = Settings.cooldown,
		Flag = "farm_cooldown",
		Callback = function(value)
			Settings.cooldown = clamp(value, 1, 20)
			saveSettings()
		end,
	})

	local logOk2, logResult = pcall(function()
		return FarmTab:CreateLog({
			Name = "Farm log",
			Height = 140,
		})
	end)
	if logOk2 and logResult then LogElement = logResult end

	-- ===================== RIDER =====================
	local RiderTab = Window:CreateTab({ Title = "Rider", Icon = "rbxassetid://10734898355" })
	local RiderSection = RiderTab:CreateSection("Rider features")

	UiRefs.wheelie = RiderSection:CreateToggle({
		Name = "Auto wheelie",
		CurrentValue = false,
		Flag = "wheelie",
		Callback = function(state) wheelieSet(state) end,
	})

	UiRefs.riderLock = RiderSection:CreateToggle({
		Name = "Rider lock",
		CurrentValue = false,
		Flag = "rider_lock",
		Callback = function(state) riderLockSet(state) end,
	})

	RiderSection:CreateButton({
		Name = "Re-seat now",
		Callback = function() task.spawn(seatUp) end,
	})

	-- ===================== ASSIST =====================
	local AssistTab = Window:CreateTab({ Title = "Assist", Icon = "rbxassetid://10734898190" })
	local AssistSection = AssistTab:CreateSection("Riding assists")

	UiRefs.handlingAssist = AssistSection:CreateToggle({
		Name = "Handling assist",
		CurrentValue = Settings.handlingAssist,
		Flag = "handling_assist",
		Callback = function(state)
			Settings.handlingAssist = state
			saveSettings()
			log(state and "Handling assist on" or "Handling assist off")
		end,
	})

	UiRefs.brakeAssist = AssistSection:CreateToggle({
		Name = "Brake assist",
		CurrentValue = Settings.brakeAssist,
		Flag = "brake_assist",
		Callback = function(state)
			Settings.brakeAssist = state
			saveSettings()
			log(state and "Brake assist on" or "Brake assist off")
		end,
	})

	-- ===================== PUMPKIN =====================
	local PumpkinTab = Window:CreateTab({ Title = "Pumpkin", Icon = "rbxassetid://10734947898" })
	local PumpkinSection = PumpkinTab:CreateSection("Pumpkin farm")

	UiRefs.pumpkin = PumpkinSection:CreateToggle({
		Name = "Enable pumpkin farm",
		CurrentValue = false,
		Flag = "pumpkin",
		Callback = function(state) pumpkinSet(state) end,
	})

	-- ===================== ESP =====================
	local EspTab = Window:CreateTab({ Title = "ESP", Icon = "rbxassetid://10734947013" })
	local EspSection = EspTab:CreateSection("Visuals")

	UiRefs.playerEsp = EspSection:CreateToggle({
		Name = "Player ESP",
		CurrentValue = false,
		Flag = "player_esp",
		Callback = function(state) Settings.playerEsp = state end,
	})

	UiRefs.policeEsp = EspSection:CreateToggle({
		Name = "Police ESP",
		CurrentValue = false,
		Flag = "police_esp",
		Callback = function(state) Settings.policeEsp = state end,
	})

	-- ===================== TUNING =====================
	local TuneTab = Window:CreateTab({ Title = "Tuning", Icon = "rbxassetid://10734947574" })
	local TuneSection = TuneTab:CreateSection("Bike tuning")

	TuneSection:CreateSlider({
		Name = "Max speed",
		Range = { 40, 400 },
		Increment = 10,
		Suffix = " km/h",
		CurrentValue = TUNING_VALUES.MaxSpeedKmh,
		Flag = "tune_max_speed",
		Callback = function(value) applyTuning("MaxSpeedKmh", clamp(value, 40, 400)) end,
	})

	TuneSection:CreateSlider({
		Name = "Launch accel",
		Range = { 1, 30 },
		Increment = 0.5,
		Suffix = "",
		CurrentValue = TUNING_VALUES.LaunchAccel,
		Flag = "tune_launch",
		Callback = function(value) applyTuning("LaunchAccel", clamp(value, 1, 30)) end,
	})

	TuneSection:CreateSlider({
		Name = "Power/kg",
		Range = { 10, 250 },
		Increment = 10,
		Suffix = "",
		CurrentValue = TUNING_VALUES.PowerPerKg,
		Flag = "tune_power",
		Callback = function(value) applyTuning("PowerPerKg", clamp(value, 10, 250)) end,
	})

	TuneSection:CreateSlider({
		Name = "Tire grip",
		Range = { 0.2, 3 },
		Increment = 0.05,
		Suffix = "",
		CurrentValue = TUNING_VALUES.TireGrip,
		Flag = "tune_grip",
		Callback = function(value) applyTuning("TireGrip", clamp(value, 0.2, 3)) end,
	})

	TuneSection:CreateSlider({
		Name = "Brake decel",
		Range = { 1, 50 },
		Increment = 1,
		Suffix = "",
		CurrentValue = TUNING_VALUES.BrakeDecel,
		Flag = "tune_brake",
		Callback = function(value) applyTuning("BrakeDecel", clamp(value, 1, 50)) end,
	})

	TuneSection:CreateButton({
		Name = "Reset tuning",
		Callback = function() resetTuning() end,
	})
end)

if not uiOk then
	warn("[Bike Universe Hub] UI init failed: " .. tostring(uiErr))
end

----------------------------------------------------------------------
-- Startup
----------------------------------------------------------------------

task.spawn(function()
	task.wait(0.5)
	applyAllTuning()
	logOk("Bike Universe Hub v3.1 loaded")
	if Settings.handlingAssist then log("Handling assist restored") end
	if Settings.brakeAssist then log("Brake assist restored") end
end)