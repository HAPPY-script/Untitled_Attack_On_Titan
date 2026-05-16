local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local Entities = workspace:WaitForChild("Entities")
local TITANS_FOLDER = Entities:WaitForChild("Titans")
local REFILLS_FOLDER = workspace:WaitForChild("Refills")
local damageRemote = ReplicatedStorage:WaitForChild("DamageEvent")

local damageEnabled = false
local damageThread = nil

local LUNGE_SPEED = 400
local FOLLOW_DISTANCE = 400
local SCAN_INTERVAL = 0.12

local ORBIT_RADIUS = 100
local ORBIT_SPEED = 10

local DAMAGE_DELAY = 0.05

local enabled = false
local movementToken = 0
local mode = "Idle"
local currentTarget = nil

local lungeConn = nil
local followConn = nil
local scanThread = nil

local function getCharacter()
	return player.Character or player.CharacterAdded:Wait()
end

local function getHRP()
	return getCharacter():WaitForChild("HumanoidRootPart")
end

local function getEntityFolders()
	local folders = { TITANS_FOLDER }
	local humanoids = Entities:FindFirstChild("Humanoids")
	if humanoids then
		table.insert(folders, humanoids)
	end
	return folders
end

local function forEachTargetModel(fn)
	for _, folder in ipairs(getEntityFolders()) do
		for _, obj in ipairs(folder:GetChildren()) do
			if obj:IsA("Model") then
				fn(obj)
			end
		end
	end
end

local function getTargetInfo(model)
	if not model or not model.Parent then
		return
	end

	local humanoid = model:FindFirstChildOfClass("Humanoid") or model:FindFirstChildWhichIsA("Humanoid", true)
	local nape = model:FindFirstChild("NapeHitbox", true)

	if not humanoid or not nape or not nape:IsA("BasePart") then
		return
	end

	if humanoid.Health <= 0 then
		return
	end

	return humanoid, nape
end

local function setDamageEnabled(state)
	damageEnabled = state

	if damageThread then
		task.cancel(damageThread)
		damageThread = nil
	end

	if not state then
		return
	end

	damageThread = task.spawn(function()
		while damageEnabled and enabled do
			local hrp = getHRP()

			forEachTargetModel(function(model)
				local humanoid, nape = getTargetInfo(model)
				if humanoid and nape then
					local dist = (nape.Position - hrp.Position).Magnitude
					if dist <= ORBIT_RADIUS + 50 then
						damageRemote:FireServer(nil, humanoid, "&@&*&@&", model)
					end
				end
			end)

			task.wait(DAMAGE_DELAY)
		end
	end)
end

local function stopMovement()
	movementToken += 1

	if lungeConn then
		lungeConn:Disconnect()
		lungeConn = nil
	end

	if followConn then
		followConn:Disconnect()
		followConn = nil
	end

	setDamageEnabled(false)
	mode = "Idle"
end

local function findNearestTarget()
	local hrp = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	if not hrp then
		return nil
	end

	local nearestModel = nil
	local nearestDist = math.huge

	forEachTargetModel(function(model)
		local humanoid, nape = getTargetInfo(model)
		if humanoid and nape then
			local dist = (nape.Position - hrp.Position).Magnitude
			if dist < nearestDist then
				nearestDist = dist
				nearestModel = model
			end
		end
	end)

	return nearestModel, nearestDist
end

local function findNearestRefill()
	local hrp = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	if not hrp then
		return nil
	end

	local nearest
	local nearestDist = math.huge

	for _, refill in ipairs(REFILLS_FOLDER:GetChildren()) do
		if refill:IsA("Model") and refill.Name == "RefillTank" then
			local main = refill:FindFirstChild("Main", true)
			if main and main:IsA("BasePart") then
				local dist = (main.Position - hrp.Position).Magnitude
				if dist < nearestDist then
					nearestDist = dist
					nearest = main
				end
			end
		end
	end

	return nearest
end

local function startFollow(targetModel)
	stopMovement()

	currentTarget = targetModel
	mode = "Follow"

	local token = movementToken
	local angle = 0

	setDamageEnabled(true)

	followConn = RunService.Heartbeat:Connect(function(dt)
		if not enabled or token ~= movementToken then
			return
		end

		local humanoid, nape = getTargetInfo(targetModel)
		if not humanoid or not nape then
			stopMovement()
			currentTarget = nil
			return
		end

		local hrp = getHRP()
		hrp.AssemblyLinearVelocity = Vector3.zero

		angle += ORBIT_SPEED * dt

		local center = nape.Position
		local x = math.cos(angle) * ORBIT_RADIUS
		local z = math.sin(angle) * ORBIT_RADIUS

		local pos = center + Vector3.new(x, 0, z)
		local nextAngle = angle + 0.05
		local nextPos = center + Vector3.new(
			math.cos(nextAngle) * ORBIT_RADIUS,
			0,
			math.sin(nextAngle) * ORBIT_RADIUS
		)

		hrp.CFrame = CFrame.lookAt(pos, nextPos)
	end)
end

local function startLunge(targetModel)
	stopMovement()

	currentTarget = targetModel
	mode = "Lunge"

	local token = movementToken
	local hrp = getHRP()

	local humanoid, nape = getTargetInfo(targetModel)
	if not humanoid or not nape then
		currentTarget = nil
		return
	end

	local startPos = hrp.Position
	local targetPos = nape.Position
	local delta = targetPos - startPos
	local dist = delta.Magnitude
	if dist < 0.5 then
		startFollow(targetModel)
		return
	end

	local dir = delta.Unit
	local duration = dist / LUNGE_SPEED
	local elapsed = 0

	lungeConn = RunService.Heartbeat:Connect(function(dt)
		if not enabled or token ~= movementToken then
			return
		end

		local nearestModel = findNearestTarget()
		if nearestModel and nearestModel ~= currentTarget then
			startLunge(nearestModel)
			return
		end

		local humanoid2, nape2 = getTargetInfo(targetModel)
		if not humanoid2 or not nape2 then
			stopMovement()
			currentTarget = nil
			return
		end

		local nowDist = (nape2.Position - hrp.Position).Magnitude
		if nowDist <= FOLLOW_DISTANCE then
			startFollow(targetModel)
			return
		end

		elapsed += dt
		local alpha = math.clamp(elapsed / duration, 0, 1)
		local newPos = startPos + dir * (dist * alpha)

		hrp.AssemblyLinearVelocity = Vector3.zero
		hrp.CFrame = CFrame.new(newPos, nape2.Position)

		if alpha >= 1 then
			stopMovement()
		end
	end)
end

local function goToRefill()
	local refillMain = findNearestRefill()
	if not refillMain then
		return
	end

	stopMovement()
	currentTarget = nil

	local token = movementToken
	local hrp = getHRP()

	local startPos = hrp.Position
	local targetPos = refillMain.Position
	local delta = targetPos - startPos
	local dist = delta.Magnitude
	if dist < 0.5 then
		return
	end

	local dir = delta.Unit
	local duration = dist / LUNGE_SPEED
	local elapsed = 0

	lungeConn = RunService.Heartbeat:Connect(function(dt)
		if token ~= movementToken then
			return
		end

		if not refillMain.Parent then
			stopMovement()
			return
		end

		elapsed += dt
		local alpha = math.clamp(elapsed / duration, 0, 1)
		local newPos = startPos + dir * (dist * alpha)

		hrp.AssemblyLinearVelocity = Vector3.zero
		hrp.CFrame = CFrame.new(newPos)

		if alpha >= 1 then
			stopMovement()
		end
	end)
end

local function updateTarget()
	if not enabled then
		return
	end

	local targetModel, dist = findNearestTarget()
	if not targetModel then
		currentTarget = nil
		stopMovement()
		return
	end

	local humanoid, nape = getTargetInfo(targetModel)
	if not humanoid or not nape then
		currentTarget = nil
		stopMovement()
		return
	end

	if targetModel ~= currentTarget then
		currentTarget = targetModel

		if dist <= FOLLOW_DISTANCE then
			startFollow(targetModel)
		else
			startLunge(targetModel)
		end
		return
	end

	if mode == "Idle" then
		if dist <= FOLLOW_DISTANCE then
			startFollow(targetModel)
		else
			startLunge(targetModel)
		end
	elseif mode == "Lunge" and dist <= FOLLOW_DISTANCE then
		startFollow(targetModel)
	end
end

local function refreshToggleUI(toggleBtn)
	toggleBtn.Text = enabled and "AUTO KILL: ON" or "AUTO KILL: OFF"
	toggleBtn.BackgroundColor3 = enabled and Color3.fromRGB(50, 120, 70) or Color3.fromRGB(55, 55, 55)
end

local function setEnabled(state)
	enabled = state

	if not enabled then
		stopMovement()
		currentTarget = nil
		if scanThread then
			task.cancel(scanThread)
			scanThread = nil
		end
		return
	end

	stopMovement()
	currentTarget = nil

	if scanThread then
		task.cancel(scanThread)
	end

	scanThread = task.spawn(function()
		while enabled do
			updateTarget()
			task.wait(SCAN_INTERVAL)
		end
	end)
end

-- UI
local gui = Instance.new("ScreenGui")
gui.Name = "TitanFollowUI"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.Parent = playerGui

local frame = Instance.new("Frame")
frame.Size = UDim2.fromOffset(220, 125)
frame.Position = UDim2.new(0.5, -110, 0.5, -45)
frame.BackgroundColor3 = Color3.fromRGB(25, 25, 25)
frame.BorderSizePixel = 0
frame.Parent = gui

local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 10)
corner.Parent = frame

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -36, 0, 28)
title.Position = UDim2.fromOffset(10, 8)
title.BackgroundTransparency = 1
title.Text = "KILL ARENA"
title.TextColor3 = Color3.fromRGB(255, 255, 255)
title.TextXAlignment = Enum.TextXAlignment.Left
title.Font = Enum.Font.GothamBold
title.TextSize = 16
title.Parent = frame

local closeBtn = Instance.new("TextButton")
closeBtn.Size = UDim2.fromOffset(26, 26)
closeBtn.Position = UDim2.new(1, -32, 0, 8)
closeBtn.BackgroundColor3 = Color3.fromRGB(170, 50, 50)
closeBtn.BorderSizePixel = 0
closeBtn.Text = "X"
closeBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
closeBtn.Font = Enum.Font.GothamBold
closeBtn.TextSize = 14
closeBtn.Parent = frame

local reloadBtn = Instance.new("TextButton")
reloadBtn.Size = UDim2.new(1, -20, 0, 30)
reloadBtn.Position = UDim2.fromOffset(10, 82)
reloadBtn.BackgroundColor3 = Color3.fromRGB(70, 90, 140)
reloadBtn.BorderSizePixel = 0
reloadBtn.Text = "Reload"
reloadBtn.TextColor3 = Color3.fromRGB(255,255,255)
reloadBtn.Font = Enum.Font.GothamBold
reloadBtn.TextSize = 14
reloadBtn.Parent = frame

local reloadCorner = Instance.new("UICorner")
reloadCorner.CornerRadius = UDim.new(0, 8)
reloadCorner.Parent = reloadBtn

local closeCorner = Instance.new("UICorner")
closeCorner.CornerRadius = UDim.new(0, 6)
closeCorner.Parent = closeBtn

local toggleBtn = Instance.new("TextButton")
toggleBtn.Size = UDim2.new(1, -20, 0, 34)
toggleBtn.Position = UDim2.fromOffset(10, 42)
toggleBtn.BackgroundColor3 = Color3.fromRGB(55, 55, 55)
toggleBtn.BorderSizePixel = 0
toggleBtn.Text = "AUTO kILL: OFF"
toggleBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
toggleBtn.Font = Enum.Font.GothamBold
toggleBtn.TextSize = 14
toggleBtn.Parent = frame

local toggleCorner = Instance.new("UICorner")
toggleCorner.CornerRadius = UDim.new(0, 8)
toggleCorner.Parent = toggleBtn

-- Drag UI
do
	local UIS = game:GetService("UserInputService")

	local dragging = false
	local dragStart, startPos

	local function update(input)
		local delta = input.Position - dragStart
		frame.Position = UDim2.new(
			startPos.X.Scale,
			startPos.X.Offset + delta.X,
			startPos.Y.Scale,
			startPos.Y.Offset + delta.Y
		)
	end

	frame.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			dragStart = input.Position
			startPos = frame.Position

			input.Changed:Connect(function()
				if input.UserInputState == Enum.UserInputState.End then
					dragging = false
				end
			end)
		end
	end)

	UIS.InputChanged:Connect(function(input)
		if dragging and (
			input.UserInputType == Enum.UserInputType.MouseMovement
			or input.UserInputType == Enum.UserInputType.Touch
		) then
			update(input)
		end
	end)
end

toggleBtn.MouseButton1Click:Connect(function()
	setEnabled(not enabled)
	refreshToggleUI(toggleBtn)
end)

closeBtn.MouseButton1Click:Connect(function()
	enabled = false
	stopMovement()
	if scanThread then
		task.cancel(scanThread)
		scanThread = nil
	end
	gui:Destroy()
end)

reloadBtn.MouseButton1Click:Connect(function()
	setEnabled(false)
	refreshToggleUI(toggleBtn)
	goToRefill()
end)

player.CharacterAdded:Connect(function()
	task.wait(0.5)
	if enabled then
		updateTarget()
	end
end)
