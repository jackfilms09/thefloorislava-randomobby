local Players = game:GetService("Players") -- used for getting survivors and teleporting each round
local ReplicatedStorage = game:GetService("ReplicatedStorage") -- holds the RemoteEvent that broadcasts round state
local Workspace = game:GetService("Workspace") -- world container that platforms, lava, and spawn exist inside
local Debris = game:GetService("Debris") -- available for timed cleanup though pooling avoids most use

math.randomseed(tick()*99999) -- ensures randomized platform patterns each round

-- RemoteEvent communicating server -> client UI
local EVT = Instance.new("RemoteEvent") -- Creates the RemoteEevnt
EVT.Name = "FloorLava_Event" 
EVT.Parent = ReplicatedStorage -- Location from which client would fetch

--Folder Creator funcction for the Game to use
local function ensureFolder(parent,name)
	local f = parent:FindFirstChild(name) -- reuses folder across rounds to preserve pool contents
	if f then return f end
	f = Instance.new("Folder") -- makes it so it is created only once
	f.Name = name
	f.Parent = parent
	return f
end

local Templates = ensureFolder(Workspace,"PlatformTemplates") -- static blueprint models
local Pool      = ensureFolder(Workspace,"PlatformPool") -- hidden reusable models
local Active    = ensureFolder(Workspace,"ActivePlatforms") -- currently visible platforms

-- Spawn platform (initial node for platform graph)

local SpawnPlatform = Workspace:FindFirstChild("SpawnPlatform")
if not SpawnPlatform then
	SpawnPlatform = Instance.new("Part") -- defines the starting point for all teleports and first wave
	SpawnPlatform.Name = "SpawnPlatform"
	SpawnPlatform.Anchored = true -- ensures stability so graph grows predictably
	SpawnPlatform.Size = Vector3.new(50,3,50) -- large enough to avoid overcrowded spawns
	SpawnPlatform.Position = Vector3.new(0,5,0) -- raised above the baseline lava start height
	SpawnPlatform.Color = Color3.fromRGB(180,180,180)
	SpawnPlatform.Parent = Workspace
end

-- Lava (rises linearly over round time)

local Lava = Workspace:FindFirstChild("Lava")
if not Lava then
	Lava = Instance.new("Part") -- the elimination hazard controlled by interpolation over time
	Lava.Name = "Lava"
	Lava.Anchored = true -- movement controlled solely by server, no physics
	Lava.CanCollide = false -- prevents players from standing; touch is kill signal
	Lava.Size = Vector3.new(600,5,600) -- covers whole generation area so all platforms eventually get overtaken
	Lava.Position = Vector3.new(0,-40,0) -- starting baseline far below spawn
	Lava.Material = Enum.Material.Neon -- high visibility for hazard awareness
	Lava.Color = Color3.fromRGB(255,80,0)
	Lava.Parent = Workspace
end

Lava.Touched:Connect(function(hit) -- handles elimination event-driven instead of polling
	local h = hit.Parent:FindFirstChildOfClass("Humanoid")
	if h then h.Health = 0 end -- ensures immediate hazard response
end)

-- Platform templates (blueprints for pooling)

local function makeTemplate(size)
	local p = Instance.new("Part") -- base component that determines actual jump size
	p.Size = size
	p.Anchored = true -- template doesn't move; only clones do

	local m = Instance.new("Model") -- grouped so scaling and repositioning happens cleanly
	p.Parent = m
	m.PrimaryPart = p -- allows uniform CFrame assignment
	m.Parent = Templates
	return m
end

-- populate template library only once
if #Templates:GetChildren() == 0 then
	makeTemplate(Vector3.new(12,1,12))
	makeTemplate(Vector3.new(14,1,6))
	makeTemplate(Vector3.new(8,1,14))
	makeTemplate(Vector3.new(6,1,6))
end

-- Config controlling pacing + difficulty

local CFG = {
	preRound = 4, -- countdown before waves/lava begin
	roundTime = 60, -- total time lava takes to reach final Y
	spawnTick = 0.35, -- how often a new cluster spawns
	platformLife = 30, -- how long each platform persists before collapsing
	maxActive = 45, -- avoids platform explosion that lags server
	poolSize = 65, -- number of reusable objects preloaded
	scaleMin = 0.75, -- platform size randomness min
	scaleMax = 1.35, -- size randomness max
	distMin = 8, -- minimum jump distance for new platforms
	distMax = 22, -- maximum jump distance
	lavaStartY = -40, -- baseline for rising lava
	lavaEndY = 90, -- end height where map becomes fully deadly
}

local state = {
	running = false, -- shared flag read by lava and wave systems
	pool = {}, -- reusable platform instances for fast spawn
	active = {} -- list of currently visible platforms
}

-- Random colored bonus orb spawner
local function SpawnBonusOrb()
	if not state.running then return end
	local activePlatforms = Active:GetChildren()
	if #activePlatforms == 0 then return end

	local randomPlatform = activePlatforms[math.random(1, #activePlatforms)]
	local base = randomPlatform:FindFirstChildWhichIsA("BasePart")
	if not base then return end

	local orb = Instance.new("Part")
	orb.Shape = Enum.PartType.Ball
	orb.Size = Vector3.new(3,3,3)
	orb.Color = Color3.fromRGB(math.random(50,255), math.random(50,255), math.random(50,255))
	orb.Material = Enum.Material.Neon
	orb.Anchored = true
	orb.Position = base.Position + Vector3.new(0, 6, 0)
	orb.Parent = Workspace

	orb.Touched:Connect(function(hit)
		local hum = hit.Parent:FindFirstChildOfClass("Humanoid")
		if hum then
			print("BONUS ORB COLLECTED by:", hit.Parent.Name)
			orb:Destroy()
		end
	end)

	task.delay(8, function()
		if orb and orb.Parent then orb:Destroy() end
	end)
end

-- Periodic spawner loop
task.spawn(function()
	while true do
		task.wait(12)
		if state.running then
			SpawnBonusOrb()
		end
	end
end)

-- Pooling helpers 

local function getPrimary(model)
	return model.PrimaryPart -- always access via PrimaryPart for consistent transforms
end

local function cloneToPool() -- creates new pooled platform when pool low
	local arr = Templates:GetChildren()
	local t = arr[math.random(1,#arr)]:Clone() -- pick a random blueprint to increase variety
	getPrimary(t).CFrame = CFrame.new(0,-2000,0) -- hide immediately
	t.Parent = Pool
	return t
end

local function fillPool() -- refill pool before round to avoid runtime cloning
	state.pool = {}
	for i=1,CFG.poolSize do
		table.insert(state.pool, cloneToPool()) -- preload hidden clones
	end
end

local function acquire() -- retrieves a ready-to-use platform
	if #state.pool > 0 then
		return table.remove(state.pool) -- reuse first for fastest turnaround
	end
	return cloneToPool() -- fallback if pool unexpectedly empty
end

local function release(m) -- returns a platform back to hidden pool
	getPrimary(m).CFrame = CFrame.new(0,-2000,0) -- hide from active area
	m.Parent = Pool
	table.insert(state.pool,m)
end

-- Platform generation

local function spawnPlatform(baseCF)
	if #state.active >= CFG.maxActive then return end -- cap growth for performance consistency

	local m = acquire() -- bring platform out of pool
	local p = getPrimary(m)

	local s = CFG.scaleMin + math.random()*(CFG.scaleMax-CFG.scaleMin) -- size-changes vary jumping difficulty
	p.Size = p.Size * s

	local ang = math.random()*math.pi*2 -- angle determines branching direction
	local dist = CFG.distMin + math.random()*(CFG.distMax-CFG.distMin) -- jump length variation
	local height = 6 + math.random()*12 -- vertical offset produces multi-layer parkour

	p.CFrame = baseCF + Vector3.new(math.cos(ang)*dist,height,math.sin(ang)*dist) -- place relative to parent node

	m.Parent = Active -- moves into active list visible to players
	table.insert(state.active,m)

	task.delay(CFG.platformLife,function() -- schedule collapse to enforce forward progression
		for i=#state.active,1,-1 do
			if state.active[i] == m then
				table.remove(state.active,i) -- unlink from active graph
				break
			end
		end
		release(m) -- recycle for future waves
	end)

	return p.CFrame -- returned so spawnWave can branch from it
end

local function spawnWave()
	if #state.active == 0 then -- first batch after round start
		for i=1,3 do spawnPlatform(SpawnPlatform.CFrame) end -- seed initial graph
		return
	end

	for i=1,3 do -- 3-platform burst keeps flow steady
		local m = state.active[math.random(1,#state.active)] -- pick random existing node to extend path
		if m then spawnPlatform(getPrimary(m).CFrame) end -- extend outward in semi-organic directions
	end
end

-- Lava rising (progress-based hazard increase)

local function raiseLava()
	local t0 = tick() -- round start timestamp
	while state.running do -- active only during round
		local elapsed = tick()-t0 -- time since round start
		local f = elapsed / CFG.roundTime -- normalized 0→1 progression
		if f>1 then f=1 end -- clamp end

		local y = CFG.lavaStartY + (CFG.lavaEndY-CFG.lavaStartY)*f -- compute current hazard height
		Lava.CFrame = CFrame.new(0,y,0)

		task.wait(0.2) -- reasonable update frequency
	end

	Lava.CFrame = CFrame.new(0,CFG.lavaStartY,0) -- reset hazard for next round
end

-- Teleport system (ensures synchronized round start)

local function teleport(plr)
	if not plr.Character then plr:LoadCharacter() task.wait(0.15) end -- ensure body loaded
	local c = plr.Character
	if c and c.PrimaryPart then
		c:SetPrimaryPartCFrame(SpawnPlatform.CFrame + Vector3.new(0,7,0)) -- spawn slightly above anchor
	end
end

Players.PlayerAdded:Connect(function(plr)
	plr.CharacterAdded:Connect(function()
		task.wait(0.1) -- allow character to fully load
		teleport(plr)
	end)
end)

-- Early elimination check

local function everyoneDead()
	for _,plr in ipairs(Players:GetPlayers()) do
		local h = plr.Character and plr.Character:FindFirstChildOfClass("Humanoid")
		if h and h.Health > 0 then return false end -- round continues if someone alive
	end
	return true -- no players alive → early round termination
end

-- Round lifecycle

local function runRound()
	fillPool() -- start with fresh reusable resources
	state.active = {} -- clear previous round's graph
	state.running = true -- enable spawn + lava subsystems

	for _,plr in ipairs(Players:GetPlayers()) do
		teleport(plr) -- synchronize starting position for fairness
	end

	EVT:FireAllClients("Round Starting...") -- update player UI
	task.wait(CFG.preRound)

	EVT:FireAllClients("Round Started!") -- UI shift to active state
	task.spawn(raiseLava) -- begin hazard progression asynchronously

	local t0 = tick() -- timestamp for round duration control
	while tick()-t0 < CFG.roundTime do -- main gameplay loop
		if everyoneDead() then break end -- terminate early if no survivors
		spawnWave() -- add new platforms to expand playable area
		task.wait(CFG.spawnTick)
	end

	state.running = false -- disable lava movement
	EVT:FireAllClients("Round Over") -- signal end to clients

	for _,m in ipairs(state.active) do release(m) end -- recycle all remaining nodes
	state.active = {}

	task.wait(5) -- breathing space before next cycle
end

-- Continuous automatic rounds

task.spawn(function()
	while true do
		runRound() -- execute full match
		task.wait(3) -- small interval before next round
	end
end)
