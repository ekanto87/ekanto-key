--[[
    EKANTO
    Universal Local Panel (client-side ScreenGui)

    SECTIONS
      1. Services
      2. Theme / Constants
      3. Config & Runtime State
      4. Utilities
      5. Config IO (writefile / readfile, autosave)
      6. Physics / Cheat Systems
           AntiHit, Invisibility, AntiTrip, Fly, Speed, Aura, Ghost Rig
      7. Character Lifecycle, Main Loop, Cleanup
      8. UI Framework (Toast, Tooltip, Slider, Toggle, Keybind, Button)
      9. Main Panel (tabs, minimize "E", hotkeys)
     10. Verification Gate (key = "2009")
     11. Boot
]]

-- ============================================================
-- 1. SERVICES
-- ============================================================
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local TextService = game:GetService("TextService")

while not Players.LocalPlayer do
	task.wait()
end
local LocalPlayer = Players.LocalPlayer

-- ============================================================
-- 2. THEME / CONSTANTS
-- ============================================================
local REQUIRED_KEY = "2009"
local GUI_NAME = "EkantoCyberPanel"
local CONFIG_FILE = "EkantoConfig.json"
local LOADED_MESSAGE = "EKANTO loaded successfully. Press RightControl to hide, M to minimize."

local Theme = {
	Black = Color3.fromRGB(0, 0, 0),
	White = Color3.fromRGB(255, 255, 255),
	Cyan = Color3.fromRGB(0, 240, 255),
	Green = Color3.fromRGB(57, 255, 130),
	Red = Color3.fromRGB(255, 59, 48), -- #FF3B30
	Track = Color3.fromRGB(45, 45, 45),
	Off = Color3.fromRGB(150, 150, 150),
	HoverGrey = Color3.fromRGB(60, 60, 60),
	Font = Enum.Font.Code, -- the only font used anywhere in the UI
}

local PANEL_SIZE = UDim2.fromOffset(460, 380)
local MINI_SIZE = UDim2.fromOffset(52, 52)
local MINI_DELTA = UDim2.fromOffset(
	(MINI_SIZE.X.Offset - PANEL_SIZE.X.Offset) / 2,
	(MINI_SIZE.Y.Offset - PANEL_SIZE.Y.Offset) / 2
)

local SPEED_MIN = 16
local SPEED_MAX = 250
local FLY_MIN = 10
local FLY_MAX = 300
local FLY_SMOOTHING = 14

local AURA_RADIUS = 20
local AURA_PUSH = 300
local AURA_LIFT = 120
local AURA_COOLDOWN = 0.25
local AURA_INTERVAL = 0.05

local GHOST_OFFSET = 50 -- studs the real body sits below the local clone

local TOOLTIP_MAX_W = 240
local TOAST_TEXT_W = 274

-- ============================================================
-- 3. CONFIG & RUNTIME STATE
-- ============================================================
local DEFAULT_CONFIG = {
	speed = SPEED_MIN,
	flySpeed = 50,
	hybrid = false,
	antiHit = false,
	invisible = false,
	fly = false,
	aura = false,
	keys = { window = "RightControl", fly = "F", aura = "G" },
}

local function deepCopy(t)
	local out = {}
	for k, v in pairs(t) do
		out[k] = type(v) == "table" and deepCopy(v) or v
	end
	return out
end

local Cfg = deepCopy(DEFAULT_CONFIG)

local Runtime = {
	alive = true,
	mode = "idle", -- "idle" | "boost" | "fly"
	capture = nil, -- active keybind capture
	minimized = false,
}

-- Ghost rig state (declared early so helpers can see it)
local Ghost = { clone = nil, cloneHum = nil, cloneHrp = nil, moveDir = nil, lastCF = nil }

-- Floating "E" state (module level so cleanup can reach it)
local MiniState = { frame = nil, bag = nil }

local connections = {}
local animatedGradients = {}
local ScreenGui

local function track(conn)
	table.insert(connections, conn)
	return conn
end

-- ============================================================
-- 4. UTILITIES
-- ============================================================
local TEXT_CLASSES = { TextLabel = true, TextButton = true, TextBox = true }

-- Every text object is forced to flat Code font, no stroke, solid white (props may override color)
local function create(className, props, parent)
	local inst = Instance.new(className)
	if TEXT_CLASSES[className] then
		inst.Font = Theme.Font
		inst.TextStrokeTransparency = 1
		inst.TextColor3 = Theme.White
	end
	for k, v in pairs(props or {}) do
		inst[k] = v
	end
	if parent then
		inst.Parent = parent
	end
	return inst
end

-- The player's real character
local function getRealParts()
	local char = LocalPlayer.Character
	if not char then
		return nil, nil, nil
	end
	return char, char:FindFirstChildOfClass("Humanoid"), char:FindFirstChild("HumanoidRootPart")
end

-- The "active" body: the local ghost clone while Invisible Mode is on, otherwise the real one
local function getCharacterParts()
	if Ghost.clone and Ghost.clone.Parent and Ghost.cloneHum and Ghost.cloneHrp then
		return Ghost.clone, Ghost.cloneHum, Ghost.cloneHrp
	end
	return getRealParts()
end

local function keyFromName(name)
	local ok, key = pcall(function()
		return Enum.KeyCode[name]
	end)
	if ok then
		return key
	end
	return nil
end

local function neonGradient()
	return ColorSequence.new({
		ColorSequenceKeypoint.new(0, Theme.Cyan),
		ColorSequenceKeypoint.new(0.5, Theme.Green),
		ColorSequenceKeypoint.new(1, Theme.Cyan),
	})
end

local function addCorner(parent, radius)
	return create("UICorner", { CornerRadius = UDim.new(0, radius or 8) }, parent)
end

-- Border-mode stroke (Contextual mode would outline button TEXT and blur it)
local function addFlatStroke(parent, color, thickness)
	return create("UIStroke", {
		Color = color,
		Thickness = thickness or 1,
		Transparency = 0,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	}, parent)
end

-- Thin animated gradient window border (frame border only, no glow layers)
local function addGradientBorder(parent, thickness)
	local stroke = create("UIStroke", {
		Color = Theme.White,
		Thickness = thickness or 1.5,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	}, parent)
	table.insert(animatedGradients, create("UIGradient", { Color = neonGradient() }, stroke))
	return stroke
end

local function getGuiParent()
	local target = nil
	pcall(function()
		if typeof(gethui) == "function" then
			target = gethui()
		end
	end)
	if not target then
		pcall(function()
			local core = game:GetService("CoreGui")
			local test = Instance.new("Folder")
			test.Parent = core
			test:Destroy()
			target = core
		end)
	end
	if not target then
		target = LocalPlayer:WaitForChild("PlayerGui")
	end
	return target
end

-- Measures wrapped text so frames can be sized to fit it exactly
local function measureText(text, size, maxWidth)
	local ok, bounds = pcall(function()
		return TextService:GetTextSize(text, size, Theme.Font, Vector2.new(maxWidth, 10000))
	end)
	if ok and typeof(bounds) == "Vector2" then
		return math.ceil(bounds.X) + 2, math.ceil(bounds.Y) + 2
	end
	-- Fallback estimate if TextService is unavailable
	local charsPerLine = math.max(1, math.floor(maxWidth / (size * 0.6)))
	local lines = math.max(1, math.ceil(#text / charsPerLine))
	return maxWidth, lines * (size + 2)
end

-- Drag helper: handle drags target; onClick fires if the pointer barely moved.
-- If bag is given, connections go into it (so they can be disconnected individually).
local function makeDraggable(handle, target, onClick, bag)
	local function hold(conn)
		if bag then
			table.insert(bag, conn)
		else
			track(conn)
		end
		return conn
	end

	local dragging = false
	local moved = false
	local dragStart, startPos

	hold(handle.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			moved = false
			dragStart = input.Position
			startPos = target.Position
			local endedConn
			endedConn = input.Changed:Connect(function()
				if input.UserInputState == Enum.UserInputState.End then
					dragging = false
					if endedConn then
						endedConn:Disconnect()
					end
					if not moved and onClick then
						pcall(onClick)
					end
				end
			end)
		end
	end))

	hold(UserInputService.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			pcall(function()
				local delta = input.Position - dragStart
				if delta.Magnitude > 4 then
					moved = true
				end
				if moved then
					target.Position = UDim2.new(
						startPos.X.Scale,
						startPos.X.Offset + delta.X,
						startPos.Y.Scale,
						startPos.Y.Offset + delta.Y
					)
				end
			end)
		end
	end))
end

-- ============================================================
-- 5. CONFIG IO (writefile / readfile, all pcall-wrapped, autosave)
-- ============================================================
local function saveConfig()
	local ok = pcall(function()
		writefile(CONFIG_FILE, HttpService:JSONEncode(Cfg))
	end)
	return ok
end

local function loadConfig()
	local ok, raw = pcall(function()
		if isfile and not isfile(CONFIG_FILE) then
			return nil
		end
		return readfile(CONFIG_FILE)
	end)
	if not ok or type(raw) ~= "string" then
		return false
	end
	local ok2, data = pcall(function()
		return HttpService:JSONDecode(raw)
	end)
	if not ok2 or type(data) ~= "table" then
		return false
	end

	if type(data.speed) == "number" then
		Cfg.speed = math.clamp(math.floor(data.speed + 0.5), SPEED_MIN, SPEED_MAX)
	end
	if type(data.flySpeed) == "number" then
		Cfg.flySpeed = math.clamp(math.floor(data.flySpeed + 0.5), FLY_MIN, FLY_MAX)
	end
	for _, k in ipairs({ "hybrid", "antiHit", "invisible", "fly", "aura" }) do
		if type(data[k]) == "boolean" then
			Cfg[k] = data[k]
		end
	end
	if type(data.keys) == "table" then
		for action, name in pairs(data.keys) do
			if Cfg.keys[action] ~= nil and type(name) == "string" and name ~= "M" and keyFromName(name) then
				Cfg.keys[action] = name
			end
		end
	end
	return true
end

local function resetConfig()
	local fresh = deepCopy(DEFAULT_CONFIG)
	for k, v in pairs(fresh) do
		Cfg[k] = v
	end
end

-- Debounced autosave: any slider, toggle or keybind change is written ~0.6s later
local saveToken = 0
local function scheduleSave()
	saveToken += 1
	local mine = saveToken
	task.delay(0.6, function()
		if mine == saveToken and Runtime.alive then
			pcall(saveConfig)
		end
	end)
end

-- ============================================================
-- 6. PHYSICS / CHEAT SYSTEMS
-- ============================================================

-- ---------- 6a. Anti-Hit ----------
local originalCanTouch = setmetatable({}, { __mode = "k" })
local descendantConn = nil

local AntiHit = {}

function AntiHit.setPart(part, disable)
	pcall(function()
		if disable then
			if originalCanTouch[part] == nil then
				originalCanTouch[part] = part.CanTouch
			end
			part.CanTouch = false
		else
			local orig = originalCanTouch[part]
			if orig ~= nil then
				part.CanTouch = orig
				originalCanTouch[part] = nil
			end
		end
	end)
end

function AntiHit.applyToCharacter(char)
	if not char then
		return
	end
	for _, d in ipairs(char:GetDescendants()) do
		if d:IsA("BasePart") then
			AntiHit.setPart(d, true)
		end
	end
end

function AntiHit.restore()
	for part, _ in pairs(originalCanTouch) do
		AntiHit.setPart(part, false)
	end
end

function AntiHit.step(hum)
	if Cfg.antiHit and hum.Health > 0 and hum.Health < hum.MaxHealth then
		hum.Health = hum.MaxHealth
	end
end

-- ---------- 6b. Invisibility + name tag hiding ----------
local originalVisual = setmetatable({}, { __mode = "k" })
local originalDisplay = setmetatable({}, { __mode = "k" })

local Invis = {}

function Invis.hide(inst)
	pcall(function()
		if inst:IsA("BasePart") then
			if originalVisual[inst] == nil then
				originalVisual[inst] = {
					t = inst.Transparency,
					l = inst.LocalTransparencyModifier,
					q = inst.CanQuery,
				}
			end
			inst.Transparency = 1
			inst.LocalTransparencyModifier = 1
			inst.CanQuery = false
		elseif inst:IsA("Decal") then
			if originalVisual[inst] == nil then
				originalVisual[inst] = { t = inst.Transparency }
			end
			inst.Transparency = 1
		end
	end)
end

function Invis.setNameTag(hum, hidden)
	pcall(function()
		if hidden then
			if originalDisplay[hum] == nil then
				originalDisplay[hum] = hum.DisplayDistanceType
			end
			hum.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
		else
			local orig = originalDisplay[hum]
			if orig ~= nil then
				hum.DisplayDistanceType = orig
				originalDisplay[hum] = nil
			end
		end
	end)
end

function Invis.applyToCharacter(char)
	if not char then
		return
	end
	for _, d in ipairs(char:GetDescendants()) do
		Invis.hide(d)
	end
	local hum = char:FindFirstChildOfClass("Humanoid")
	if hum then
		Invis.setNameTag(hum, true)
	end
end

function Invis.restore()
	for inst, data in pairs(originalVisual) do
		pcall(function()
			if inst:IsA("BasePart") then
				inst.Transparency = data.t
				inst.LocalTransparencyModifier = data.l or 0
				if data.q ~= nil then
					inst.CanQuery = data.q
				end
			elseif inst:IsA("Decal") then
				inst.Transparency = data.t
			end
		end)
		originalVisual[inst] = nil
	end
	for hum, _ in pairs(originalDisplay) do
		Invis.setNameTag(hum, false)
	end
end

function Invis.step()
	-- The camera can reset LocalTransparencyModifier, so re-assert it
	if Cfg.invisible then
		for inst, _ in pairs(originalVisual) do
			if inst and inst.Parent and inst:IsA("BasePart") then
				inst.LocalTransparencyModifier = 1
			end
		end
	end
end

local function hookCharacter(char)
	if descendantConn then
		descendantConn:Disconnect()
		descendantConn = nil
	end
	if not char then
		return
	end
	pcall(function()
		if Cfg.antiHit then
			AntiHit.applyToCharacter(char)
		end
		if Cfg.invisible then
			Invis.applyToCharacter(char)
			Ghost.enable(char)
		end
		descendantConn = char.DescendantAdded:Connect(function(d)
			pcall(function()
				if Cfg.antiHit and d:IsA("BasePart") then
					AntiHit.setPart(d, true)
				end
				if Cfg.invisible then
					Invis.hide(d)
				end
			end)
		end)
	end)
end

-- ---------- 6c. Anti-Trip / upright lock (AlignOrientation) ----------
local AntiTrip = { humanoid = nil, att = nil, align = nil, lastFlatLook = Vector3.new(0, 0, -1) }

local blockedStates = {}
for _, name in ipairs({ "Ragdoll", "FallingDown", "Tripping" }) do
	local ok, item = pcall(function()
		return Enum.HumanoidStateType[name]
	end)
	if ok and item then
		table.insert(blockedStates, item)
	end
end

local function setBlockedStates(hum, enabled)
	for _, state in ipairs(blockedStates) do
		pcall(function()
			hum:SetStateEnabled(state, enabled)
		end)
	end
end

function AntiTrip.destroyAligner()
	if AntiTrip.align then
		pcall(function()
			AntiTrip.align:Destroy()
		end)
		AntiTrip.align = nil
	end
	if AntiTrip.att then
		pcall(function()
			AntiTrip.att:Destroy()
		end)
		AntiTrip.att = nil
	end
end

function AntiTrip.ensureAligner(hrp)
	if AntiTrip.att and AntiTrip.align and AntiTrip.att.Parent == hrp and AntiTrip.align.Parent == hrp then
		return
	end
	AntiTrip.destroyAligner()
	AntiTrip.att = create("Attachment", { Name = "EkantoUprightAtt" }, hrp)
	AntiTrip.align = create("AlignOrientation", {
		Name = "EkantoUpright",
		Mode = Enum.OrientationAlignmentMode.OneAttachment,
		Attachment0 = AntiTrip.att,
		RigidityEnabled = true,
		MaxTorque = math.huge,
		Responsiveness = 200,
		ReactionTorqueEnabled = false,
		CFrame = hrp.CFrame.Rotation,
	}, hrp)
end

-- Once, on entering "boost"
function AntiTrip.engage(hum)
	if AntiTrip.humanoid ~= hum then
		if AntiTrip.humanoid then
			setBlockedStates(AntiTrip.humanoid, true)
		end
		AntiTrip.humanoid = hum
		setBlockedStates(hum, false)
	end
end

-- Once, on leaving "boost"
function AntiTrip.release()
	if AntiTrip.humanoid then
		setBlockedStates(AntiTrip.humanoid, true)
		AntiTrip.humanoid = nil
	end
	AntiTrip.destroyAligner()
end

function AntiTrip.reset()
	AntiTrip.humanoid = nil
	AntiTrip.destroyAligner()
end

function AntiTrip.step(hrp, hum, moving, moveDir, dt)
	-- Kick the humanoid out of any blocked state that still slipped in
	local current = hum:GetState()
	for _, state in ipairs(blockedStates) do
		if current == state then
			hum:ChangeState(Enum.HumanoidStateType.GettingUp)
			break
		end
	end
	if hum.PlatformStand then
		hum.PlatformStand = false
	end

	AntiTrip.ensureAligner(hrp)

	local look = hrp.CFrame.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	if flat.Magnitude < 0.1 then
		flat = AntiTrip.lastFlatLook
	else
		flat = flat.Unit
	end

	if moving and hum.AutoRotate then
		local dirFlat = Vector3.new(moveDir.X, 0, moveDir.Z)
		if dirFlat.Magnitude > 0.01 then
			dirFlat = dirFlat.Unit
			local mix = flat:Lerp(dirFlat, math.clamp(dt * 14, 0, 1))
			if mix.Magnitude < 0.05 then
				mix = dirFlat
			end
			flat = mix.Unit
		end
	end

	AntiTrip.lastFlatLook = flat
	AntiTrip.align.CFrame = CFrame.lookAt(Vector3.zero, flat)
	AntiTrip.align.Enabled = true

	local av = hrp.AssemblyAngularVelocity
	if moving then
		hrp.AssemblyAngularVelocity = Vector3.zero
	else
		hrp.AssemblyAngularVelocity = Vector3.new(0, av.Y, 0)
	end
end

-- ---------- 6d. Fly (LinearVelocity + AlignOrientation, Attachment0) ----------
-- The local character's root part is already network-owned by this client, so constraints
-- parented to it simulate locally and replicate. No SetNetworkOwner call is needed.
local Fly = { att = nil, lv = nil, ao = nil, current = Vector3.zero }

function Fly.destroyInstances()
	for _, k in ipairs({ "lv", "ao", "att" }) do
		local inst = Fly[k]
		if inst then
			pcall(function()
				inst:Destroy()
			end)
			Fly[k] = nil
		end
	end
end

function Fly.ensure(hrp)
	if Fly.att and Fly.lv and Fly.ao and Fly.att.Parent == hrp and Fly.lv.Parent == hrp and Fly.ao.Parent == hrp then
		return
	end
	Fly.destroyInstances()
	Fly.current = Vector3.zero
	Fly.att = create("Attachment", { Name = "EkantoFlyAtt" }, hrp)
	Fly.lv = create("LinearVelocity", {
		Name = "EkantoFlyVelocity",
		Attachment0 = Fly.att,
		RelativeTo = Enum.ActuatorRelativeTo.World,
		VelocityConstraintMode = Enum.VelocityConstraintMode.Vector,
		MaxForce = math.huge,
		VectorVelocity = Vector3.zero,
	}, hrp)
	Fly.ao = create("AlignOrientation", {
		Name = "EkantoFlyOrient",
		Mode = Enum.OrientationAlignmentMode.OneAttachment,
		Attachment0 = Fly.att,
		RigidityEnabled = true,
		MaxTorque = math.huge,
		Responsiveness = 200,
		ReactionTorqueEnabled = false,
		CFrame = hrp.CFrame.Rotation,
	}, hrp)
end

function Fly.enable(hrp, hum)
	Fly.ensure(hrp)
	hum.PlatformStand = true
end

function Fly.step(hrp, hum, dt)
	local cam = workspace.CurrentCamera
	if not cam then
		return
	end
	Fly.ensure(hrp)
	hum.PlatformStand = true

	local target = Vector3.zero
	if not UserInputService:GetFocusedTextBox() then
		local look = cam.CFrame.LookVector
		local right = cam.CFrame.RightVector
		local dir = Vector3.zero
		local up = Vector3.new(0, 1, 0)

		if UserInputService:IsKeyDown(Enum.KeyCode.W) then dir += look end
		if UserInputService:IsKeyDown(Enum.KeyCode.S) then dir -= look end
		if UserInputService:IsKeyDown(Enum.KeyCode.D) then dir += right end
		if UserInputService:IsKeyDown(Enum.KeyCode.A) then dir -= right end
		if UserInputService:IsKeyDown(Enum.KeyCode.Space) or UserInputService:IsKeyDown(Enum.KeyCode.E) then
			dir += up
		end
		-- LeftShift / Q are read here only as "descend" (never as a UI toggle)
		if UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) or UserInputService:IsKeyDown(Enum.KeyCode.Q) then
			dir -= up
		end

		if dir.Magnitude > 0.01 then
			target = dir.Unit * Cfg.flySpeed
		end
	end

	-- Exponential smoothing: converges exactly to the slider speed
	local alpha = 1 - math.exp(-FLY_SMOOTHING * dt)
	Fly.current = Fly.current:Lerp(target, alpha)
	if target.Magnitude < 0.01 and Fly.current.Magnitude < 0.5 then
		Fly.current = Vector3.zero -- friction lock: hold position, zero drift
	end
	Fly.lv.VectorVelocity = Fly.current

	local camLook = cam.CFrame.LookVector
	local flat = Vector3.new(camLook.X, 0, camLook.Z)
	if flat.Magnitude > 0.05 then
		Fly.ao.CFrame = CFrame.lookAt(Vector3.zero, flat.Unit)
	end
	hrp.AssemblyAngularVelocity = Vector3.zero
end

-- Once, on leaving "fly": remove forces, then lerp horizontal momentum to zero
function Fly.disable()
	local carry = Fly.current
	Fly.destroyInstances()
	Fly.current = Vector3.zero

	local _, hum, hrp = getCharacterParts()
	if hum then
		hum.PlatformStand = false
		if hum.Health > 0 then
			hum:ChangeState(Enum.HumanoidStateType.Freefall)
		end
	end
	if hrp and carry.Magnitude > 0.5 then
		task.spawn(function()
			pcall(function()
				local steps = 8
				for i = 1, steps do
					if not Runtime.alive or Runtime.mode ~= "idle" or not hrp.Parent then
						return
					end
					local horizontal = Vector3.new(carry.X, 0, carry.Z) * (1 - i / steps)
					local v = hrp.AssemblyLinearVelocity
					-- Keep downward Y (gravity), drop upward Y so there is no floating
					hrp.AssemblyLinearVelocity = Vector3.new(horizontal.X, math.min(v.Y, 0), horizontal.Z)
					RunService.Heartbeat:Wait()
				end
			end)
		end)
	end
end

function Fly.reset()
	Fly.destroyInstances()
	Fly.current = Vector3.zero
end

-- ---------- 6e. WalkSpeed boost (AssemblyLinearVelocity push + anti-trip) ----------
local Speed = { hybridSaved = nil }

function Speed.applyHybrid(hum, on)
	if on then
		if Speed.hybridSaved == nil then
			Speed.hybridSaved = hum.WalkSpeed
		end
		if hum.WalkSpeed ~= Cfg.speed then
			hum.WalkSpeed = Cfg.speed
		end
	elseif Speed.hybridSaved ~= nil then
		hum.WalkSpeed = Speed.hybridSaved
		Speed.hybridSaved = nil
	end
end

function Speed.step(hrp, hum, dt)
	-- While ghosted, input comes from the real humanoid (the clone is driven by it)
	local moveDir = Ghost.moveDir or hum.MoveDirection
	local moving = moveDir.Magnitude > 0

	if moving then
		local dir = moveDir.Unit -- already camera-relative
		local current = hrp.AssemblyLinearVelocity
		hrp.AssemblyLinearVelocity = Vector3.new(dir.X * Cfg.speed, current.Y, dir.Z * Cfg.speed)
	end

	Speed.applyHybrid(hum, Cfg.hybrid)
	AntiTrip.step(hrp, hum, moving, moveDir, dt)
end

function Speed.exit()
	local _, hum = getCharacterParts()
	if hum then
		pcall(Speed.applyHybrid, hum, false)
	end
	Speed.hybridSaved = nil
	AntiTrip.release()
end

-- ---------- 6f. Fling Aura (NPC / dummy only, throttled background thread) ----------
local Aura = { token = 0, cooldowns = setmetatable({}, { __mode = "k" }) }

local function findHumanoidModel(part)
	local node = part
	while node and node ~= workspace do
		if node:IsA("Model") and node:FindFirstChildOfClass("Humanoid") then
			return node
		end
		node = node.Parent
	end
	return nil
end

function Aura.scan()
	local char, hum, hrp = getCharacterParts()
	if not (char and hum and hrp) or hum.Health <= 0 then
		return
	end

	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { char, LocalPlayer.Character }

	local parts = workspace:GetPartBoundsInRadius(hrp.Position, AURA_RADIUS, params)
	local handled = {}
	local now = os.clock()

	for _, part in ipairs(parts) do
		pcall(function()
			local model = findHumanoidModel(part)
			if not model or handled[model] then
				return
			end
			handled[model] = true

			-- Real players are never touched
			if Players:GetPlayerFromCharacter(model) ~= nil then
				return
			end

			local targetHum = model:FindFirstChildOfClass("Humanoid")
			local root = model:FindFirstChild("HumanoidRootPart")
			if not targetHum or not root or targetHum.Health <= 0 or root.Anchored then
				return
			end

			local last = Aura.cooldowns[model]
			if last and now - last < AURA_COOLDOWN then
				return
			end
			Aura.cooldowns[model] = now

			local offset = root.Position - hrp.Position
			local flat = Vector3.new(offset.X, 0, offset.Z)
			if flat.Magnitude < 0.1 then
				local look = hrp.CFrame.LookVector
				flat = Vector3.new(look.X, 0, look.Z)
			end
			flat = flat.Unit

			root.AssemblyLinearVelocity = flat * AURA_PUSH + Vector3.new(0, AURA_LIFT, 0)
			root.AssemblyAngularVelocity = Vector3.new(
				math.random(-40, 40),
				math.random(-40, 40),
				math.random(-40, 40)
			)
		end)
	end
end

function Aura.stop()
	Aura.token += 1
	table.clear(Aura.cooldowns)
end

function Aura.start()
	Aura.token += 1
	local myToken = Aura.token
	task.spawn(function()
		while Runtime.alive and Cfg.aura and Aura.token == myToken do
			pcall(Aura.scan)
			task.wait(AURA_INTERVAL)
		end
	end)
end

-- ---------- 6g. Ghost Rig (hitbox offset + local clone) ----------
-- While Invisible Mode is on, the real character is anchored GHOST_OFFSET studs below
-- an invisible local clone. The clone is what you steer (and the camera follows it), so
-- anything that targets or damages your real body cannot reach you on the surface.
-- Limits: the clone is client-only, and other players see your real body go underground.
local originalCollide = setmetatable({}, { __mode = "k" })

local function resetModes()
	-- Tear down movement systems on the CURRENT active body before it changes
	pcall(Speed.exit)
	pcall(Fly.reset)
	pcall(function()
		local _, hum = getCharacterParts()
		if hum then
			hum.PlatformStand = false
		end
	end)
	Runtime.mode = "idle"
end

function Ghost.enable(char)
	if Ghost.clone or not char then
		return
	end
	local hum = char:FindFirstChildOfClass("Humanoid")
	local hrp = char:FindFirstChild("HumanoidRootPart")
	if not hum or not hrp or hum.Health <= 0 then
		return
	end

	resetModes()

	pcall(function()
		char.Archivable = true
	end)
	local clone = nil
	pcall(function()
		clone = char:Clone()
	end)
	if not clone then
		return
	end
	clone.Name = "EkantoGhost"

	-- Make the clone inert, invisible and unqueryable
	for _, d in ipairs(clone:GetDescendants()) do
		pcall(function()
			if d:IsA("LuaSourceContainer") then
				d:Destroy()
			elseif d:IsA("BasePart") then
				d.Transparency = 1
				d.CanQuery = false
				d.CanTouch = false
			elseif d:IsA("Decal") then
				d.Transparency = 1
			end
		end)
	end

	local cloneHum = clone:FindFirstChildOfClass("Humanoid")
	local cloneHrp = clone:FindFirstChild("HumanoidRootPart")
	if not cloneHum or not cloneHrp then
		pcall(function()
			clone:Destroy()
		end)
		return
	end
	cloneHum.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None

	-- Real body: stop colliding, anchor, then drop it under the clone
	for _, d in ipairs(char:GetDescendants()) do
		if d:IsA("BasePart") then
			if originalCollide[d] == nil then
				originalCollide[d] = d.CanCollide
			end
			d.CanCollide = false
		end
	end

	clone.Parent = workspace
	pcall(function()
		clone:PivotTo(char:GetPivot())
	end)

	Ghost.clone = clone
	Ghost.cloneHum = cloneHum
	Ghost.cloneHrp = cloneHrp
	Ghost.lastCF = cloneHrp.CFrame
	Ghost.moveDir = Vector3.zero

	hrp.Anchored = true
	char:PivotTo(cloneHrp.CFrame + Vector3.new(0, -GHOST_OFFSET, 0))

	local cam = workspace.CurrentCamera
	if cam then
		cam.CameraSubject = cloneHum
	end
end

-- Per-frame: mirror real input onto the clone, keep the real body parked under it
function Ghost.step(realChar, realHum, realHrp)
	local clone = Ghost.clone
	if not clone then
		Ghost.moveDir = nil
		return
	end
	if not clone.Parent or not Ghost.cloneHrp or not Ghost.cloneHrp.Parent then
		Ghost.disable()
		return
	end

	local cHum, cHrp = Ghost.cloneHum, Ghost.cloneHrp

	Ghost.moveDir = realHum.MoveDirection
	cHum:Move(Ghost.moveDir, false)

	local jump = realHum.Jump
	if not jump and not UserInputService:GetFocusedTextBox() then
		jump = UserInputService:IsKeyDown(Enum.KeyCode.Space)
	end
	if realHum.Jump then
		realHum.Jump = false
	end
	cHum.Jump = jump and true or false

	Ghost.lastCF = cHrp.CFrame
	realChar:PivotTo(cHrp.CFrame + Vector3.new(0, -GHOST_OFFSET, 0))

	local cam = workspace.CurrentCamera
	if cam and cam.CameraSubject ~= cHum then
		cam.CameraSubject = cHum
	end
end

-- Drop the clone WITHOUT touching the old character (used on respawn)
function Ghost.dropClone()
	local c = Ghost.clone
	Ghost.clone, Ghost.cloneHum, Ghost.cloneHrp = nil, nil, nil
	Ghost.moveDir, Ghost.lastCF = nil, nil
	if c then
		pcall(function()
			c:Destroy()
		end)
	end
	table.clear(originalCollide)
end

-- Restore the real body at the clone's position, give the camera back
function Ghost.disable()
	if not Ghost.clone then
		return
	end
	resetModes()

	local clone = Ghost.clone
	local lastCF = Ghost.lastCF
	Ghost.clone, Ghost.cloneHum, Ghost.cloneHrp = nil, nil, nil
	Ghost.moveDir, Ghost.lastCF = nil, nil
	pcall(function()
		clone:Destroy()
	end)

	pcall(function()
		local char, hum, hrp = getRealParts()
		for part, orig in pairs(originalCollide) do
			pcall(function()
				part.CanCollide = orig
			end)
		end
		table.clear(originalCollide)
		if char and hrp then
			hrp.Anchored = false
			if lastCF then
				char:PivotTo(lastCF)
			end
			hrp.AssemblyLinearVelocity = Vector3.zero
			hrp.AssemblyAngularVelocity = Vector3.zero
		end
		local cam = workspace.CurrentCamera
		if cam and hum then
			cam.CameraSubject = hum
		end
	end)
end

-- ---------- 6h. Feature setters (used by UI, hotkeys and config) ----------
local Features = {}

function Features.antiHit(on)
	Cfg.antiHit = on
	pcall(function()
		if on then
			AntiHit.applyToCharacter(LocalPlayer.Character)
		else
			AntiHit.restore()
		end
	end)
end

function Features.invisible(on)
	Cfg.invisible = on
	pcall(function()
		if on then
			local char = LocalPlayer.Character
			Invis.applyToCharacter(char)
			Ghost.enable(char)
		else
			Ghost.disable()
			Invis.restore()
		end
	end)
end

function Features.fly(on)
	Cfg.fly = on -- mode transitions are handled by the main loop
end

function Features.hybrid(on)
	Cfg.hybrid = on
end

function Features.aura(on)
	Cfg.aura = on
	if on then
		Aura.start()
	else
		Aura.stop()
	end
end

-- ============================================================
-- 7. CHARACTER LIFECYCLE, MAIN LOOP, CLEANUP
-- ============================================================
local function transition(from, to)
	if from == "fly" then
		Fly.disable()
	elseif from == "boost" then
		Speed.exit()
	end

	if to == "fly" then
		local _, hum, hrp = getCharacterParts()
		if hum and hrp then
			Fly.enable(hrp, hum)
		end
	elseif to == "boost" then
		local _, hum = getCharacterParts()
		if hum then
			AntiTrip.engage(hum)
		end
	end
end

local function onHeartbeat(dt)
	if not Runtime.alive then
		return
	end
	pcall(function()
		local rChar, rHum, rHrp = getRealParts()
		if not (rChar and rHum and rHrp) then
			return
		end

		Ghost.step(rChar, rHum, rHrp)

		-- Active body: the clone while ghosted, otherwise the real character
		local char, hum, hrp = getCharacterParts()
		if not (char and hum and hrp) then
			return
		end

		local alive = hum.Health > 0
		local desired = "idle"
		if Cfg.fly and alive then
			desired = "fly"
		elseif Cfg.speed > SPEED_MIN and alive and hum.SeatPart == nil then
			desired = "boost"
		end

		-- Enter/exit logic runs once per transition, never every frame
		if desired ~= Runtime.mode then
			local from = Runtime.mode
			Runtime.mode = desired
			transition(from, desired)
		end

		if desired == "fly" then
			Fly.step(hrp, hum, dt)
		elseif desired == "boost" then
			Speed.step(hrp, hum, dt)
		end

		AntiHit.step(rHum)
		Invis.step()
	end)
end

local function onCharacterAdded(char)
	-- Fresh character: drop the old ghost, clear weak tables and stale references, re-hook
	Ghost.dropClone()
	table.clear(originalCanTouch)
	table.clear(originalVisual)
	table.clear(originalDisplay)
	Runtime.mode = "idle"
	AntiTrip.reset()
	Fly.reset()
	Speed.hybridSaved = nil

	task.spawn(function()
		pcall(function()
			char:WaitForChild("HumanoidRootPart", 10)
			char:WaitForChild("Humanoid", 10)
			task.wait(0.1)
			hookCharacter(char)
		end)
	end)
end

local function fullCleanup()
	if not Runtime.alive then
		return
	end
	local lastMode = Runtime.mode
	Runtime.alive = false

	for _, c in ipairs(connections) do
		pcall(function()
			c:Disconnect()
		end)
	end
	table.clear(connections)

	if MiniState.bag then
		for _, c in ipairs(MiniState.bag) do
			pcall(function()
				c:Disconnect()
			end)
		end
		MiniState.bag = nil
	end

	if descendantConn then
		pcall(function()
			descendantConn:Disconnect()
		end)
		descendantConn = nil
	end

	pcall(Aura.stop)
	if lastMode == "fly" then
		pcall(Fly.disable)
	else
		pcall(Fly.destroyInstances)
	end
	pcall(Speed.exit)
	pcall(Ghost.disable) -- clone destroyed, real body unanchored, camera restored
	Runtime.mode = "idle"
	pcall(AntiHit.restore) -- CanTouch back to native values
	pcall(Invis.restore) -- transparency, CanQuery and name tag back to native values

	Cfg.fly = false
	Cfg.aura = false
	Cfg.antiHit = false
	Cfg.invisible = false
end

-- ============================================================
-- 8. UI FRAMEWORK
-- ============================================================
local UI = { sliders = {}, toggles = {}, keyButtons = {} }

-- ---------- Toast notifications (bottom-right, auto-sized, wrapped) ----------
local Toast = { layer = nil, counter = 0 }

function Toast.init(gui)
	Toast.layer = create("Frame", {
		Name = "Toasts",
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -16, 1, -16),
		Size = UDim2.fromOffset(300, 320),
		BackgroundTransparency = 1,
		Active = false,
		ZIndex = 90,
	}, gui)
	create("UIListLayout", {
		SortOrder = Enum.SortOrder.LayoutOrder,
		VerticalAlignment = Enum.VerticalAlignment.Bottom,
		HorizontalAlignment = Enum.HorizontalAlignment.Right,
		Padding = UDim.new(0, 6),
	}, Toast.layer)
end

function Toast.show(text, accent, duration)
	if not Toast.layer or not Runtime.alive then
		return
	end
	task.spawn(function()
		pcall(function()
			Toast.counter += 1
			local _, textH = measureText(text, 14, TOAST_TEXT_W)
			local frame = create("Frame", {
				LayoutOrder = Toast.counter,
				Size = UDim2.fromOffset(TOAST_TEXT_W + 16, textH + 14),
				BackgroundColor3 = Theme.Black,
				BackgroundTransparency = 1,
				BorderSizePixel = 0,
				ZIndex = 91,
			}, Toast.layer)
			addCorner(frame, 6)
			local stroke = create("UIStroke", {
				Color = accent or Theme.Cyan,
				Thickness = 1,
				Transparency = 1,
				ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
			}, frame)
			local label = create("TextLabel", {
				Size = UDim2.new(1, -16, 1, 0),
				Position = UDim2.fromOffset(8, 0),
				BackgroundTransparency = 1,
				Text = text,
				TextTransparency = 1,
				TextSize = 14,
				TextWrapped = true,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextYAlignment = Enum.TextYAlignment.Center,
				ZIndex = 92,
			}, frame)

			local tin = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
			TweenService:Create(frame, tin, { BackgroundTransparency = 0.05 }):Play()
			TweenService:Create(stroke, tin, { Transparency = 0 }):Play()
			TweenService:Create(label, tin, { TextTransparency = 0 }):Play()

			task.wait(duration or 2)
			if not frame.Parent then
				return
			end
			local tout = TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
			TweenService:Create(frame, tout, { BackgroundTransparency = 1 }):Play()
			TweenService:Create(stroke, tout, { Transparency = 1 }):Play()
			TweenService:Create(label, tout, { TextTransparency = 1 }):Play()
			task.wait(0.3)
			frame:Destroy()
		end)
	end)
end

-- ---------- Tooltips (wrapped, left-aligned, sized from measured text) ----------
local Tooltip = { frame = nil, label = nil, size = Vector2.new(0, 0) }

function Tooltip.init(gui)
	Tooltip.frame = create("Frame", {
		Name = "Tooltip",
		Visible = false,
		Size = UDim2.fromOffset(120, 30),
		BackgroundColor3 = Theme.Black,
		BorderSizePixel = 0,
		Active = false,
		ZIndex = 100,
	}, gui)
	addCorner(Tooltip.frame, 6)
	addFlatStroke(Tooltip.frame, Theme.White, 1)
	Tooltip.label = create("TextLabel", {
		Position = UDim2.fromOffset(8, 5),
		Size = UDim2.fromOffset(100, 20),
		BackgroundTransparency = 1,
		Text = "",
		TextSize = 12,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		ZIndex = 101,
	}, Tooltip.frame)
end

function Tooltip.set(text)
	local w, h = measureText(text, 12, TOOLTIP_MAX_W)
	Tooltip.label.Text = text
	Tooltip.label.Size = UDim2.fromOffset(w, h)
	Tooltip.frame.Size = UDim2.fromOffset(w + 16, h + 10)
	Tooltip.size = Vector2.new(w + 16, h + 10)
end

function Tooltip.move()
	pcall(function()
		local m = UserInputService:GetMouseLocation()
		local cam = workspace.CurrentCamera
		local vp = cam and cam.ViewportSize or Vector2.new(1920, 1080)
		local x = math.min(m.X + 14, vp.X - Tooltip.size.X - 8)
		local y = math.min(m.Y + 16, vp.Y - Tooltip.size.Y - 8)
		Tooltip.frame.Position = UDim2.fromOffset(math.max(x, 4), math.max(y, 4))
	end)
end

function Tooltip.hide()
	if Tooltip.frame then
		Tooltip.frame.Visible = false
	end
end

function Tooltip.attach(obj, text)
	track(obj.MouseEnter:Connect(function()
		if Tooltip.frame then
			Tooltip.set(text)
			Tooltip.frame.Visible = true
			Tooltip.move()
		end
	end))
	track(obj.MouseMoved:Connect(Tooltip.move))
	track(obj.MouseLeave:Connect(Tooltip.hide))
end

-- ---------- Shared card ----------
local function createCard(page, name, height, accent)
	page.order += 1
	local card = create("Frame", {
		Name = name .. "Card",
		LayoutOrder = page.order,
		Size = UDim2.new(1, -10, 0, height),
		BackgroundColor3 = Theme.Black,
		BorderSizePixel = 0,
	}, page.frame)
	addCorner(card, 8)
	create("UIStroke", {
		Color = accent,
		Thickness = 1.5,
		Transparency = 0.2,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	}, card)
	return card
end

-- ---------- Slider factory ----------
-- spec: key, name, desc, tip, min, max, value, accent, onChange(value)
local function createSlider(page, spec)
	local card = createCard(page, spec.name, 68, spec.accent)

	create("TextLabel", {
		Position = UDim2.new(0, 12, 0, 6),
		Size = UDim2.new(0.65, 0, 0, 18),
		BackgroundTransparency = 1,
		Text = spec.name,
		TextSize = 14,
		TextXAlignment = Enum.TextXAlignment.Left,
	}, card)

	create("TextLabel", {
		Position = UDim2.new(0, 12, 0, 26),
		Size = UDim2.new(1, -24, 0, 14),
		BackgroundTransparency = 1,
		Text = spec.desc,
		TextSize = 11,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
	}, card)

	local valueLabel = create("TextLabel", {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -12, 0, 6),
		Size = UDim2.new(0, 70, 0, 18),
		BackgroundTransparency = 1,
		Text = tostring(spec.value),
		TextSize = 16,
		TextXAlignment = Enum.TextXAlignment.Right,
	}, card)

	local sliderTrack = create("Frame", {
		Name = "Track",
		Position = UDim2.new(0, 14, 0, 53),
		Size = UDim2.new(1, -28, 0, 6),
		BackgroundColor3 = Theme.Track,
		BorderSizePixel = 0,
	}, card)
	addCorner(sliderTrack, 3)

	local fill = create("Frame", {
		Name = "Fill",
		Size = UDim2.new(0, 0, 1, 0),
		BackgroundColor3 = Theme.White,
		BorderSizePixel = 0,
	}, sliderTrack)
	addCorner(fill, 3)
	create("UIGradient", { Color = ColorSequence.new(Theme.Cyan, Theme.Green) }, fill)

	local knob = create("Frame", {
		Name = "Knob",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0, 0, 0.5, 0),
		Size = UDim2.new(0, 16, 0, 16),
		BackgroundColor3 = Theme.White,
		BorderSizePixel = 0,
		ZIndex = 3,
	}, sliderTrack)
	addCorner(knob, 8)
	create("UIStroke", {
		Color = Theme.Green,
		Thickness = 2,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	}, knob)

	local hit = create("TextButton", {
		Name = "Hit",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 0, 0.5, 0),
		Size = UDim2.new(1, 0, 0, 26),
		BackgroundTransparency = 1,
		Text = "",
		AutoButtonColor = false,
		ZIndex = 4,
	}, sliderTrack)

	local value = spec.value
	local knobInfo = TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

	local function render(animate)
		local alpha = (value - spec.min) / (spec.max - spec.min)
		if animate then
			TweenService:Create(fill, knobInfo, { Size = UDim2.new(alpha, 0, 1, 0) }):Play()
			TweenService:Create(knob, knobInfo, { Position = UDim2.new(alpha, 0, 0.5, 0) }):Play()
		else
			fill.Size = UDim2.new(alpha, 0, 1, 0)
			knob.Position = UDim2.new(alpha, 0, 0.5, 0)
		end
		valueLabel.Text = tostring(value)
	end
	render(false)

	local function setFromX(x)
		local w = sliderTrack.AbsoluteSize.X
		if w <= 0 then
			return
		end
		local alpha = math.clamp((x - sliderTrack.AbsolutePosition.X) / w, 0, 1)
		value = math.floor(spec.min + (spec.max - spec.min) * alpha + 0.5)
		render(true)
		pcall(spec.onChange, value)
	end

	local sliding = false
	track(hit.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			sliding = true
			setFromX(input.Position.X)
		end
	end))
	track(UserInputService.InputChanged:Connect(function(input)
		if sliding and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			setFromX(input.Position.X)
		end
	end))
	track(UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			sliding = false
		end
	end))

	Tooltip.attach(card, spec.tip)

	local obj = {}
	function obj.Set(v)
		value = math.clamp(math.floor(v + 0.5), spec.min, spec.max)
		render(false)
		pcall(spec.onChange, value)
	end
	UI.sliders[spec.key] = obj
	return obj
end

-- ---------- Toggle factory ----------
-- spec: key, name, desc, tip, accent, callback(on, silent)
local function createToggle(page, spec)
	local card = createCard(page, spec.name, 48, spec.accent)

	create("TextLabel", {
		Position = UDim2.new(0, 12, 0, 7),
		Size = UDim2.new(1, -90, 0, 18),
		BackgroundTransparency = 1,
		Text = spec.name,
		TextSize = 14,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
	}, card)

	create("TextLabel", {
		Position = UDim2.new(0, 12, 0, 27),
		Size = UDim2.new(1, -90, 0, 14),
		BackgroundTransparency = 1,
		Text = spec.desc,
		TextSize = 11,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
	}, card)

	local switch = create("TextButton", {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -12, 0.5, 0),
		Size = UDim2.new(0, 48, 0, 24),
		BackgroundColor3 = Theme.Track,
		Text = "",
		AutoButtonColor = false,
	}, card)
	addCorner(switch, 12)
	local swStroke = addFlatStroke(switch, Theme.Off, 1.5)

	local sKnob = create("Frame", {
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 4, 0.5, 0),
		Size = UDim2.new(0, 16, 0, 16),
		BackgroundColor3 = Theme.Off,
		BorderSizePixel = 0,
	}, switch)
	addCorner(sKnob, 8)

	local on = false
	local info = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

	local function render()
		if on then
			TweenService:Create(sKnob, info, { Position = UDim2.new(1, -20, 0.5, 0), BackgroundColor3 = Theme.Green }):Play()
			TweenService:Create(switch, info, { BackgroundColor3 = Color3.fromRGB(0, 70, 35) }):Play()
			TweenService:Create(swStroke, info, { Color = Theme.Green }):Play()
		else
			TweenService:Create(sKnob, info, { Position = UDim2.new(0, 4, 0.5, 0), BackgroundColor3 = Theme.Off }):Play()
			TweenService:Create(switch, info, { BackgroundColor3 = Theme.Track }):Play()
			TweenService:Create(swStroke, info, { Color = Theme.Off }):Play()
		end
	end

	local obj = {}
	function obj.Set(v, silent)
		on = v and true or false
		render()
		pcall(spec.callback, on, silent)
	end
	function obj.Toggle()
		obj.Set(not on, false)
	end
	function obj.Get()
		return on
	end

	track(switch.MouseButton1Click:Connect(obj.Toggle))
	Tooltip.attach(card, spec.tip)

	UI.toggles[spec.key] = obj
	return obj
end

-- ---------- Keybind capture ----------
local function cancelCapture()
	local cap = Runtime.capture
	if cap then
		pcall(function()
			cap.button.Text = Cfg.keys[cap.action]
		end)
		Runtime.capture = nil
	end
end

local function createKeybind(page, action, label, tip)
	local card = createCard(page, action .. "Key", 40, Theme.Off)

	create("TextLabel", {
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 12, 0.5, 0),
		Size = UDim2.new(1, -140, 0, 18),
		BackgroundTransparency = 1,
		Text = label,
		TextSize = 14,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
	}, card)

	local btn = create("TextButton", {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -10, 0.5, 0),
		Size = UDim2.new(0, 110, 0, 26),
		BackgroundColor3 = Theme.Black,
		Text = Cfg.keys[action],
		TextSize = 14,
		AutoButtonColor = false,
	}, card)
	addCorner(btn, 4)
	addFlatStroke(btn, Theme.White, 1)

	track(btn.MouseButton1Click:Connect(function()
		cancelCapture()
		Runtime.capture = { action = action, button = btn }
		btn.Text = "press key..."
	end))

	Tooltip.attach(card, tip)
	UI.keyButtons[action] = btn
end

-- ---------- Plain button ----------
local function createButton(page, text, accent, tip, callback)
	local card = createCard(page, text, 40, accent)
	local btn = create("TextButton", {
		Size = UDim2.new(1, 0, 1, 0),
		BackgroundTransparency = 1,
		Text = text,
		TextSize = 16,
		AutoButtonColor = false,
	}, card)
	track(btn.MouseEnter:Connect(function()
		TweenService:Create(card, TweenInfo.new(0.12), { BackgroundColor3 = Color3.fromRGB(30, 30, 30) }):Play()
	end))
	track(btn.MouseLeave:Connect(function()
		TweenService:Create(card, TweenInfo.new(0.12), { BackgroundColor3 = Theme.Black }):Play()
	end))
	track(btn.MouseButton1Click:Connect(function()
		pcall(callback)
	end))
	Tooltip.attach(card, tip)
end

-- ============================================================
-- 9. MAIN PANEL
-- ============================================================
local Main
local mainShown = true

local function featureCallback(label, fn)
	return function(on, silent)
		fn(on)
		scheduleSave()
		if not silent then
			Toast.show(label .. (on and " enabled" or " disabled"), on and Theme.Green or Theme.Off)
		end
	end
end

local function applyConfigToUI()
	UI.sliders.speed.Set(Cfg.speed)
	UI.sliders.flySpeed.Set(Cfg.flySpeed)
	for _, k in ipairs({ "hybrid", "antiHit", "invisible", "fly", "aura" }) do
		UI.toggles[k].Set(Cfg[k], true)
	end
	for action, btn in pairs(UI.keyButtons) do
		btn.Text = Cfg.keys[action]
	end
end

local function buildMain()
	Main = create("Frame", {
		Name = "Main",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.5, 0),
		Size = PANEL_SIZE,
		BackgroundColor3 = Theme.Black,
		BorderSizePixel = 0,
		Active = true,
	}, ScreenGui)
	addCorner(Main, 10)
	addGradientBorder(Main, 1.5)

	local scale = create("UIScale", { Scale = 0.9 }, Main)
	TweenService:Create(scale, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()

	-- Body holds everything that hides while minimized
	local body = create("Frame", {
		Name = "Body",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
	}, Main)

	-- ---------- Header (title only + window buttons) ----------
	local header = create("Frame", {
		Name = "Header",
		Size = UDim2.new(1, 0, 0, 48),
		BackgroundTransparency = 1,
		Active = true,
	}, body)

	create("TextLabel", {
		Name = "Title",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 16, 0.5, 0),
		Size = UDim2.new(1, -110, 0, 28),
		BackgroundTransparency = 1,
		Text = "EKANTO",
		TextSize = 24,
		TextXAlignment = Enum.TextXAlignment.Left,
	}, header)

	local function makeHeaderButton(name, text, xOffset, hoverColor)
		local btn = create("TextButton", {
			Name = name,
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, xOffset, 0.5, 0),
			Size = UDim2.new(0, 28, 0, 28),
			BackgroundColor3 = Theme.Black,
			Text = text,
			TextSize = 18,
			TextXAlignment = Enum.TextXAlignment.Center,
			TextYAlignment = Enum.TextYAlignment.Center,
			AutoButtonColor = false,
			ZIndex = 5,
		}, header)
		addCorner(btn, 4)
		addFlatStroke(btn, Theme.Off, 1)
		track(btn.MouseEnter:Connect(function()
			TweenService:Create(btn, TweenInfo.new(0.15), { BackgroundColor3 = hoverColor }):Play()
		end))
		track(btn.MouseLeave:Connect(function()
			TweenService:Create(btn, TweenInfo.new(0.15), { BackgroundColor3 = Theme.Black }):Play()
		end))
		return btn
	end

	-- Plain "X": the Code font has no "✕" glyph, which is why that button used to render blank
	local closeBtn = makeHeaderButton("Close", "X", -12, Theme.Red) -- hover: flat red #FF3B30
	local minBtn = makeHeaderButton("Minimize", "-", -46, Theme.HoverGrey) -- hover: flat dark grey

	track(closeBtn.MouseButton1Click:Connect(function()
		pcall(saveConfig) -- final save before cleanup resets the live flags
		pcall(function()
			ScreenGui:Destroy()
		end)
	end))

	local divider = create("Frame", {
		Name = "Divider",
		Position = UDim2.new(0, 14, 0, 48),
		Size = UDim2.new(1, -28, 0, 2),
		BackgroundColor3 = Theme.White,
		BorderSizePixel = 0,
	}, body)
	table.insert(animatedGradients, create("UIGradient", { Color = neonGradient() }, divider))

	makeDraggable(header, Main, nil)

	-- ---------- Tabs (flat terminal buttons) ----------
	local tabBar = create("Frame", {
		Name = "Tabs",
		Position = UDim2.new(0, 12, 0, 56),
		Size = UDim2.new(1, -24, 0, 28),
		BackgroundTransparency = 1,
	}, body)
	create("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		Padding = UDim.new(0, 6),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, tabBar)

	local tabs = {}
	local tabOrder = 0

	local function selectTab(name)
		for n, t in pairs(tabs) do
			local active = (n == name)
			t.page.frame.Visible = active
			t.button.TextColor3 = active and Theme.Green or Theme.White
			t.stroke.Color = active and Theme.Green or Theme.Off
		end
	end

	local function createTab(name)
		tabOrder += 1
		local button = create("TextButton", {
			Name = name .. "Tab",
			LayoutOrder = tabOrder,
			Size = UDim2.new(0.25, -5, 1, 0),
			BackgroundColor3 = Theme.Black,
			BorderSizePixel = 0,
			Text = name,
			TextSize = 14,
			AutoButtonColor = false,
		}, tabBar)
		addCorner(button, 4)
		local stroke = addFlatStroke(button, Theme.Off, 1)

		local frame = create("ScrollingFrame", {
			Name = name .. "Page",
			Position = UDim2.new(0, 12, 0, 92),
			Size = UDim2.new(1, -24, 1, -102),
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			ScrollBarThickness = 4,
			ScrollBarImageColor3 = Theme.Off,
			CanvasSize = UDim2.new(0, 0, 0, 0),
			ScrollingDirection = Enum.ScrollingDirection.Y,
			Visible = false,
		}, body)
		create("UIPadding", { PaddingLeft = UDim.new(0, 2), PaddingTop = UDim.new(0, 2) }, frame)
		local layout = create("UIListLayout", {
			Padding = UDim.new(0, 8),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}, frame)
		track(layout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
			pcall(function()
				frame.CanvasSize = UDim2.new(0, 0, 0, layout.AbsoluteContentSize.Y + 8)
			end)
		end))

		local page = { frame = frame, order = 0 }
		tabs[name] = { button = button, stroke = stroke, page = page }
		track(button.MouseButton1Click:Connect(function()
			selectTab(name)
		end))
		return page
	end

	local movePage = createTab("Movement")
	local flyPage = createTab("Flight")
	local combatPage = createTab("Combat")
	local configPage = createTab("Config")

	-- ---------- Movement ----------
	createSlider(movePage, {
		key = "speed",
		name = "WalkSpeed Changer",
		desc = "Velocity push + anti-trip • 16 - 250",
		tip = "Pushes your root part along your move direction. Ragdoll, FallingDown and Tripping are blocked and the vertical axis is locked, so you slide along walls instead of tumbling.",
		min = SPEED_MIN,
		max = SPEED_MAX,
		value = Cfg.speed,
		accent = Theme.Cyan,
		onChange = function(v)
			Cfg.speed = v
			scheduleSave()
		end,
	})
	createToggle(movePage, {
		key = "hybrid",
		name = "WalkSpeed Hybrid",
		desc = "Also sets Humanoid.WalkSpeed while boosting",
		tip = "Helps games that read WalkSpeed for animations. The original value is restored when this is off.",
		accent = Theme.Cyan,
		callback = featureCallback("WalkSpeed Hybrid", Features.hybrid),
	})

	-- ---------- Flight ----------
	createToggle(flyPage, {
		key = "fly",
		name = "Fly Hack Mode",
		desc = "WASD • Space up • LeftShift down",
		tip = "Camera-aligned flight using LinearVelocity and AlignOrientation. Space ascends, LeftShift descends, and releasing all keys hovers in place.",
		accent = Theme.Cyan,
		callback = featureCallback("Fly Hack Mode", Features.fly),
	})
	createSlider(flyPage, {
		key = "flySpeed",
		name = "Fly Speed Control",
		desc = "Flight speed, live • 10 - 300",
		tip = "Changes flight speed in real time, even mid-flight.",
		min = FLY_MIN,
		max = FLY_MAX,
		value = Cfg.flySpeed,
		accent = Theme.Green,
		onChange = function(v)
			Cfg.flySpeed = v
			scheduleSave()
		end,
	})
	createKeybind(flyPage, "fly", "Fly Toggle Key", "Click, then press a key to rebind. Esc cancels. M is reserved for minimize.")

	-- ---------- Combat ----------
	createToggle(combatPage, {
		key = "antiHit",
		name = "Anti-Hit / Damage Nullifier",
		desc = "Health lock • CanTouch off on limbs",
		tip = "Locks health to max and disables CanTouch on your character parts so touch-based hazards cannot register. Everything is restored when disabled or on close.",
		accent = Theme.Cyan,
		callback = featureCallback("Anti-Hit", Features.antiHit),
	})
	createToggle(combatPage, {
		key = "invisible",
		name = "Invisible Mode",
		desc = "Ghost rig • hidden parts • no name tag",
		tip = "Hides all parts and your name tag, then parks your real body 50 studs under a local invisible clone that you steer. Raycasts and NPC tracking aimed at your real body cannot reach you on the surface. Restored when off.",
		accent = Theme.Green,
		callback = featureCallback("Invisible Mode", Features.invisible),
	})
	createToggle(combatPage, {
		key = "aura",
		name = "Auto-Hit / Fling Aura",
		desc = "Flings NPCs/dummies within 20 studs",
		tip = "Scans every 0.05s. Only non-player Humanoid models are affected; real players are always skipped.",
		accent = Theme.Green,
		callback = featureCallback("Fling Aura", Features.aura),
	})
	createKeybind(combatPage, "aura", "Aura Toggle Key", "Click, then press a key to rebind. Esc cancels. M is reserved for minimize.")

	-- ---------- Config ----------
	createKeybind(configPage, "window", "Window Toggle Key", "Shows or hides the panel. Default is RightControl. M is reserved for minimize.")
	createButton(configPage, "Save Config", Theme.Cyan, "Writes sliders, toggles and keybinds to " .. CONFIG_FILE .. " (it also autosaves on every change).", function()
		if saveConfig() then
			Toast.show("Config saved", Theme.Green)
		else
			Toast.show("Save unavailable here", Theme.Red)
		end
	end)
	createButton(configPage, "Load Config", Theme.Green, "Reloads the saved config and applies it.", function()
		if loadConfig() then
			applyConfigToUI()
			Toast.show("Config loaded", Theme.Green)
		else
			Toast.show("No saved config found", Theme.Red)
		end
	end)
	createButton(configPage, "Reset Defaults", Theme.Red, "Restores every setting and keybind to its default.", function()
		cancelCapture()
		resetConfig()
		applyConfigToUI()
		scheduleSave()
		Toast.show("Defaults restored", Theme.Cyan)
	end)

	selectTab("Movement")

	-- ---------- Minimize: panel <-> floating "E" square ----------
	local MINI_TWEEN = TweenInfo.new(0.3, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
	local minToken = 0
	local setMinimized -- forward declaration (the "E" button calls it)

	local function fadeMini(m, visible, duration)
		pcall(function()
			local info = TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
			TweenService:Create(m, info, {
				BackgroundTransparency = visible and 0 or 1,
				TextTransparency = visible and 0 or 1,
			}):Play()
			local stroke = m:FindFirstChildOfClass("UIStroke")
			if stroke then
				TweenService:Create(stroke, info, { Transparency = visible and 0 or 1 }):Play()
			end
			local glow = m:FindFirstChild("Glow")
			if glow then
				local gs = glow:FindFirstChildOfClass("UIStroke")
				if gs then
					TweenService:Create(gs, info, { Transparency = visible and 0.6 or 1 }):Play()
				end
			end
		end)
	end

	local function createMini(pos)
		local m = create("TextButton", {
			Name = "EkantoMini",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = pos,
			Size = MINI_SIZE,
			BackgroundColor3 = Theme.Black,
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Text = "E",
			TextSize = 28,
			TextTransparency = 1,
			AutoButtonColor = false,
			ZIndex = 50,
		}, ScreenGui)
		addCorner(m, 8)
		local stroke = addFlatStroke(m, Theme.Cyan, 2)
		stroke.Transparency = 1

		-- Soft cyan halo ring behind the square (frame-level glow, not text)
		local glow = create("Frame", {
			Name = "Glow",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.new(1, 10, 1, 10),
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Active = false,
			ZIndex = 49,
		}, m)
		addCorner(glow, 13)
		create("UIStroke", {
			Color = Theme.Cyan,
			Thickness = 4,
			Transparency = 1,
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		}, glow)

		MiniState.frame = m
		MiniState.bag = {}
		makeDraggable(m, m, function()
			setMinimized(false)
		end, MiniState.bag)

		fadeMini(m, true, 0.2)
		return m
	end

	-- Fades the "E" out, then destroys it and disconnects its drag connections
	local function closeMini()
		local m, bag = MiniState.frame, MiniState.bag
		MiniState.frame, MiniState.bag = nil, nil
		if not m then
			return
		end
		fadeMini(m, false, 0.15)
		task.delay(0.2, function()
			if bag then
				for _, c in ipairs(bag) do
					pcall(function()
						c:Disconnect()
					end)
				end
			end
			pcall(function()
				m:Destroy()
			end)
		end)
	end

	setMinimized = function(state)
		if Runtime.minimized == state then
			return
		end
		Runtime.minimized = state
		minToken += 1
		local myToken = minToken
		Tooltip.hide()

		if state then
			body.Visible = false
			-- Top-left corner stays fixed, so the square appears where the panel was
			local pos = Main.Position + MINI_DELTA
			TweenService:Create(Main, MINI_TWEEN, { Size = MINI_SIZE, Position = pos }):Play()
			task.delay(0.3, function()
				if myToken ~= minToken or not Runtime.minimized or not Main.Parent then
					return
				end
				Main.Visible = false
				local m = createMini(pos)
				if not mainShown then
					m.Visible = false
				end
			end)
		else
			-- Expand from wherever the (possibly dragged) square currently is
			local pos = Main.Position
			if MiniState.frame then
				pos = MiniState.frame.Position
			end
			closeMini()
			Main.Position = pos
			Main.Size = MINI_SIZE
			Main.Visible = mainShown
			TweenService:Create(Main, MINI_TWEEN, { Size = PANEL_SIZE, Position = pos - MINI_DELTA }):Play()
			task.delay(0.28, function()
				if myToken == minToken and not Runtime.minimized and body.Parent then
					body.Visible = true
				end
			end)
		end
	end

	track(minBtn.MouseButton1Click:Connect(function()
		pcall(setMinimized, true)
	end))

	-- ---------- Window toggle (RightControl by default) ----------
	local toggleToken = 0
	local function setWindowVisible(visible)
		mainShown = visible
		toggleToken += 1
		local myToken = toggleToken
		Tooltip.hide()

		-- While minimized, the floating "E" is what gets hidden/shown
		if Runtime.minimized then
			if MiniState.frame then
				MiniState.frame.Visible = visible
			end
			return
		end

		if visible then
			Main.Visible = true
			scale.Scale = 0.92
			TweenService:Create(scale, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
		else
			local tw = TweenService:Create(scale, TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Scale = 0.92 })
			tw.Completed:Connect(function()
				if myToken == toggleToken and not mainShown and Main and Main.Parent then
					Main.Visible = false
				end
			end)
			tw:Play()
		end
	end

	-- ---------- Keyboard: capture, window toggle, M minimize, fly/aura hotkeys ----------
	-- LeftShift is never used as a toggle here; it is only read as "descend" inside the fly loop.
	track(UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if input.UserInputType ~= Enum.UserInputType.Keyboard then
			return
		end

		if Runtime.capture then
			if input.KeyCode == Enum.KeyCode.Escape then
				cancelCapture()
			elseif input.KeyCode == Enum.KeyCode.M then
				Toast.show("M is reserved for minimize", Theme.Red)
			elseif input.KeyCode ~= Enum.KeyCode.Unknown then
				local cap = Runtime.capture
				Runtime.capture = nil
				Cfg.keys[cap.action] = input.KeyCode.Name
				cap.button.Text = input.KeyCode.Name
				scheduleSave()
				Toast.show("Bound to " .. input.KeyCode.Name, Theme.Cyan)
			end
			return
		end

		local code = input.KeyCode
		if code == keyFromName(Cfg.keys.window) then
			pcall(function()
				if Main and Main.Parent then
					setWindowVisible(not mainShown)
				end
			end)
			return
		end

		if gameProcessed or UserInputService:GetFocusedTextBox() then
			return
		end

		if code == Enum.KeyCode.M then
			if mainShown then
				pcall(setMinimized, not Runtime.minimized)
			end
			return
		end

		if code == keyFromName(Cfg.keys.fly) then
			UI.toggles.fly.Toggle()
		elseif code == keyFromName(Cfg.keys.aura) then
			UI.toggles.aura.Toggle()
		end
	end))

	-- ---------- Runtime ----------
	track(RunService.Heartbeat:Connect(onHeartbeat))
	track(LocalPlayer.CharacterAdded:Connect(onCharacterAdded))
	task.spawn(function()
		pcall(function()
			hookCharacter(LocalPlayer.Character)
		end)
	end)

	-- Apply the saved config onto the freshly built widgets
	applyConfigToUI()

	-- Load notification
	Toast.show(LOADED_MESSAGE, Theme.Green, 4)
end

-- ============================================================
-- 10. VERIFICATION GATE (flat terminal, key = "2009")
-- ============================================================
local function buildGate()
	local KeyFrame = create("Frame", {
		Name = "KeyFrame",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.5, 0),
		Size = UDim2.new(0, 380, 0, 244),
		BackgroundColor3 = Theme.Black,
		BorderSizePixel = 0,
	}, ScreenGui)
	addCorner(KeyFrame, 10)
	addGradientBorder(KeyFrame, 1.5)

	create("TextLabel", {
		Position = UDim2.new(0, 0, 0, 16),
		Size = UDim2.new(1, 0, 0, 30),
		BackgroundTransparency = 1,
		Text = "ACCESS TERMINAL",
		TextSize = 24,
	}, KeyFrame)

	create("TextLabel", {
		Position = UDim2.new(0, 0, 0, 50),
		Size = UDim2.new(1, 0, 0, 20),
		BackgroundTransparency = 1,
		Text = "Enter authorization key to continue",
		TextSize = 15,
	}, KeyFrame)

	local keyBox = create("TextBox", {
		Name = "KeyInput",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 86),
		Size = UDim2.new(1, -48, 0, 48),
		BackgroundColor3 = Theme.Black,
		Text = "",
		PlaceholderText = "Enter key...",
		PlaceholderColor3 = Theme.White,
		TextSize = 22,
		ClearTextOnFocus = false,
		BorderSizePixel = 0,
	}, KeyFrame)
	addCorner(keyBox, 4)
	local keyBoxStroke = addFlatStroke(keyBox, Theme.White, 1)

	local statusLabel = create("TextLabel", {
		Name = "Status",
		Position = UDim2.new(0, 0, 0, 140),
		Size = UDim2.new(1, 0, 0, 22),
		BackgroundTransparency = 1,
		Text = "",
		TextColor3 = Theme.Red,
		TextSize = 17,
	}, KeyFrame)

	local verifyBtn = create("TextButton", {
		Name = "Verify",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 170),
		Size = UDim2.new(1, -48, 0, 46),
		BackgroundColor3 = Theme.Black,
		Text = "VERIFY",
		TextSize = 20,
		AutoButtonColor = false,
		BorderSizePixel = 0,
	}, KeyFrame)
	addCorner(verifyBtn, 4)
	addFlatStroke(verifyBtn, Theme.White, 1)

	track(verifyBtn.MouseEnter:Connect(function()
		TweenService:Create(verifyBtn, TweenInfo.new(0.12), { BackgroundColor3 = Color3.fromRGB(38, 38, 38) }):Play()
	end))
	track(verifyBtn.MouseLeave:Connect(function()
		TweenService:Create(verifyBtn, TweenInfo.new(0.12), { BackgroundColor3 = Theme.Black }):Play()
	end))

	local busy = false

	-- task.wait keeps this from hanging if a tween is interrupted
	local function shakeFrame()
		local offsets = { -14, 14, -10, 10, -6, 6, -3, 3, 0 }
		for _, ox in ipairs(offsets) do
			if not KeyFrame or not KeyFrame.Parent then
				return
			end
			TweenService:Create(
				KeyFrame,
				TweenInfo.new(0.04, Enum.EasingStyle.Linear),
				{ Position = UDim2.new(0.5, ox, 0.5, 0) }
			):Play()
			task.wait(0.04)
		end
		if KeyFrame and KeyFrame.Parent then
			KeyFrame.Position = UDim2.new(0.5, 0, 0.5, 0)
		end
	end

	local function fadeOutAndDestroy(root, duration)
		local info = TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		local function fadeInstance(inst)
			pcall(function()
				if inst:IsA("GuiObject") then
					TweenService:Create(inst, info, { BackgroundTransparency = 1 }):Play()
				end
				if TEXT_CLASSES[inst.ClassName] then
					TweenService:Create(inst, info, { TextTransparency = 1 }):Play()
				end
				if inst:IsA("UIStroke") then
					TweenService:Create(inst, info, { Transparency = 1 }):Play()
				end
			end)
		end
		fadeInstance(root)
		for _, d in ipairs(root:GetDescendants()) do
			fadeInstance(d)
		end
		task.wait(duration + 0.05)
		pcall(function()
			root:Destroy()
		end)
	end

	local function attemptVerify()
		if busy or not Runtime.alive then
			return
		end
		busy = true
		local entered = tostring(keyBox.Text or ""):match("^%s*(.-)%s*$")

		if entered == REQUIRED_KEY then
			statusLabel.TextColor3 = Theme.Green
			statusLabel.Text = "Access Granted"
			task.spawn(function()
				pcall(function()
					fadeOutAndDestroy(KeyFrame, 0.5)
				end)
				pcall(buildMain)
			end)
		else
			statusLabel.TextColor3 = Theme.Red
			statusLabel.Text = "Access Denied"
			TweenService:Create(keyBoxStroke, TweenInfo.new(0.1), { Color = Theme.Red }):Play()
			task.spawn(function()
				pcall(shakeFrame)
				pcall(function()
					TweenService:Create(keyBoxStroke, TweenInfo.new(0.4), { Color = Theme.White }):Play()
				end)
				busy = false
			end)
		end
	end

	track(verifyBtn.MouseButton1Click:Connect(attemptVerify))
	track(keyBox.FocusLost:Connect(function(enterPressed)
		if enterPressed then
			attemptVerify()
		end
	end))

	-- Entry animation (ends at scale 1 so text renders at native sharpness)
	local kScale = create("UIScale", { Scale = 0.85 }, KeyFrame)
	local tw = TweenService:Create(kScale, TweenInfo.new(0.4, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 })
	tw.Completed:Connect(function()
		pcall(function()
			kScale.Scale = 1
		end)
	end)
	tw:Play()
end

-- ============================================================
-- 11. BOOT
-- ============================================================
pcall(function()
	local old = getGuiParent():FindFirstChild(GUI_NAME)
	if old then
		old:Destroy()
	end
end)

pcall(loadConfig)

ScreenGui = create("ScreenGui", {
	Name = GUI_NAME,
	ResetOnSpawn = false,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	IgnoreGuiInset = true,
	DisplayOrder = 999,
})
pcall(function()
	if syn and syn.protect_gui then
		syn.protect_gui(ScreenGui)
	end
end)
ScreenGui.Parent = getGuiParent()

track(ScreenGui.Destroying:Connect(fullCleanup))

Toast.init(ScreenGui)
Tooltip.init(ScreenGui)

-- Shared gradient-border animation
do
	local t = 0
	track(RunService.RenderStepped:Connect(function(dt)
		t += dt
		for i = #animatedGradients, 1, -1 do
			local g = animatedGradients[i]
			if g and g.Parent then
				g.Rotation = (t * 90) % 360
			else
				table.remove(animatedGradients, i)
			end
		end
	end))
end

buildGate()
