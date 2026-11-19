--[[
    Prada Auto Play  (its own script, separate from Prada Hub)
    Moves around until the shot is open (0 contest) and makeable, then shoots with Auto Green.
    You pick the shot: Three, Two, Layup, Dunk or Any. Guards whoever has the ball when you do not.
    RightControl shows / hides the window. The x button unloads it.
]]

local genv = _G
pcall(function() if getgenv then genv = getgenv() or _G end end)

if genv.PradaAutoPlay and genv.PradaAutoPlay.unload then pcall(genv.PradaAutoPlay.unload) end

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local clock = os.clock
local Stats = game:GetService("Stats")

local LocalPlayer = Players.LocalPlayer
local Running = true
local connections = {}
local function track(c) connections[#connections + 1] = c return c end

-- settings ---------------------------------------------------------------------------------

-- settings ---------------------------------------------------------------------------------
local Cfg = {
    enabled = false,
    shotType = "Three",     -- Three / Two / Layup / Dunk / Any
    threeLine = 24,         -- distance from the hoop where a three starts (minus 1.5)
    layupRange = 13,
    dunkRange = 7,
    maxContest = 0,         -- shoot only when contest is at or below this percent
    closeDist = 5,          -- defender this close = 100% contest
    farDist = 14,           -- defender this far = 0% contest
    giveUp = 0,             -- seconds before shooting while covered (0 = never)
    speed = 30,
    chaseBall = true,
    holdTime = 0.55,
    hoop = "Auto",
    green = true,
    rainbow = false,
    nudge = 0,
    openSpot = true,        -- jump to a new spot when a defender gets close
    openRange = 7,
    openDistance = 14,
    defense = true,
    defSpeed = 21,
    defGap = 6.5,
}


-- game access ------------------------------------------------------------------------------
local function getCharacter()
    local chars = Workspace:FindFirstChild("Characters")
    local char = chars and chars:FindFirstChild(LocalPlayer.Name)
    if char and char:IsA("Model") then return char end
    return LocalPlayer.Character
end

local function getRoot()
    local char = getCharacter()
    return char and (char:FindFirstChild("HumanoidRootPart") or char:FindFirstChild("Torso"))
end

local function getProxy()
    local proxy = Workspace:FindFirstChild("ProxyCharacter")
    if not proxy then return nil end
    return proxy, proxy:FindFirstChild("MovementVelocity"), proxy:FindFirstChild("MovementGyro")
end

local function getState()
    local proxy = Workspace:FindFirstChild("ProxyCharacter")
    if proxy and proxy:GetAttribute("CanMove") ~= nil then return proxy end
    local char = getCharacter()
    if not char then return nil end
    if char:GetAttribute("CanMove") ~= nil or char:GetAttribute("WalkSpeed") ~= nil then return char end
    for _, child in ipairs(char:GetChildren()) do
        if child:GetAttribute("CanMove") ~= nil or child:GetAttribute("WalkSpeed") ~= nil then return child end
    end
    return nil
end

local function hasBall()
    local char = getCharacter()
    if not char then return false end
    local hrp = char:FindFirstChild("HumanoidRootPart")
    local weld = hrp and hrp:FindFirstChild("Basketball")
    if weld and weld:IsA("Motor6D") and weld.Part1 then return true end
    local holder = char:FindFirstChild("Attributes")
    local value = holder and holder:FindFirstChild("Basketball")
    if value and value:IsA("ObjectValue") and value.Value then return true end
    local state = getState()
    return state ~= nil and state:GetAttribute("Basketball") and true or false
end

local Remotes, RemoteCache = {
    shoot = { "InputService", "Shoot" },
    dribble = { "InputService", "Dribble" },
}, {}

local function resolveRemote(key)
    local cached = RemoteCache[key]
    if cached and cached.Parent then return cached end
    local node = ReplicatedStorage:FindFirstChild("Aero")
    node = node and node:FindFirstChild("AeroRemoteServices")
    for _, name in ipairs(Remotes[key]) do
        node = node and node:FindFirstChild(name)
    end
    if node and (node:IsA("RemoteEvent") or node:IsA("UnreliableRemoteEvent") or node:IsA("RemoteFunction")) then
        RemoteCache[key] = node
        return node
    end
    return nil
end

local function fireRemote(key, ...)
    local rem = resolveRemote(key)
    if not rem then return false end
    local args = { ... }
    return pcall(function()
        if rem:IsA("RemoteFunction") then rem:InvokeServer(unpack(args)) else rem:FireServer(unpack(args)) end
    end)
end

-- hoops ------------------------------------------------------------------------------------
local Hoops = { list = {}, at = -10 }
local function hoopList()
    if clock() - Hoops.at > 5 or #Hoops.list == 0 then
        local list = {}
        local folder = Workspace:FindFirstChild("Hoops")
        if folder then
            for _, model in ipairs(folder:GetChildren()) do
                local goal = model:FindFirstChild("Goal", true)
                if goal and goal:IsA("BasePart") then list[#list + 1] = goal end
            end
        end
        Hoops.list, Hoops.at = list, clock()
    end
    return Hoops.list
end

local function attackHoop(fromPos)
    local list = hoopList()
    if #list == 0 then return nil end
    local near, far, nearD, farD = nil, nil, math.huge, -1
    for _, part in ipairs(list) do
        local d = (part.Position - fromPos).Magnitude
        if d < nearD then near, nearD = part, d end
        if d > farD then far, farD = part, d end
    end
    if Cfg.hoop == "Nearest" then return near end
    if Cfg.hoop == "Farthest" then return far end
    -- Auto: the game's own Goal attribute when it points at a hoop, else the far one
    local state = getState()
    local value = state and state:GetAttribute("Goal")
    local pos = typeof(value) == "CFrame" and value.Position or (typeof(value) == "Vector3" and value or nil)
    if pos then
        local best, bestD = nil, 10
        for _, part in ipairs(list) do
            local d = (part.Position - pos).Magnitude
            if d < bestD then best, bestD = part, d end
        end
        if best then return best end
    end
    -- no Goal attribute: they defend their own hoop, so attack the one closest to the other team
    local me = getCharacter()
    local myTeam = me and me:GetAttribute("Team")
    local sum, n = Vector3.zero, 0
    local chars = Workspace:FindFirstChild("Characters")
    if chars then
        for _, m in ipairs(chars:GetChildren()) do
            if m ~= me and m:IsA("Model") then
                local r = m:FindFirstChild("HumanoidRootPart")
                local t = m:GetAttribute("Team")
                if r and (myTeam == nil or t == nil or t ~= myTeam) then sum += r.Position n += 1 end
            end
        end
    end
    if n > 0 then
        local centre, best, bestD = sum / n, nil, math.huge
        for _, part in ipairs(list) do
            local d = (part.Position - centre).Magnitude
            if d < bestD then best, bestD = part, d end
        end
        if best then return best end
    end
    return far
end

-- movement (through the game's proxy body) --------------------------------------------------
local Move = { forced = false, originalForce = nil }

local function steer(direction, speed)
    local proxy, velocity, gyro = getProxy()
    if not velocity then return end
    if not Move.originalForce then Move.originalForce = velocity.MaxForce end
    velocity.MaxForce = Vector3.new(1e6, 0, 1e6)
    velocity.Velocity = direction * (speed * 0.84)
    Move.forced = true
    if gyro and proxy then
        gyro.CFrame = CFrame.lookAt(proxy.Position, proxy.Position + Vector3.new(direction.X, 0, direction.Z))
    end
end

local function stopMoving()
    if not Move.forced then return end
    local _, velocity = getProxy()
    if velocity then
        velocity.Velocity = Vector3.zero
        if Move.originalForce then velocity.MaxForce = Move.originalForce end
    end
    Move.forced = false
end

local function faceHoop(goal)
    local proxy, _, gyro = getProxy()
    if not proxy or not gyro or not goal then return end
    local flat = Vector3.new(goal.Position.X, proxy.Position.Y, goal.Position.Z)
    if (flat - proxy.Position).Magnitude > 0.1 then gyro.CFrame = CFrame.lookAt(proxy.Position, flat) end
end

local function setGoal(goal)
    local state = getState()
    if not state or not goal then return end
    local existing = state:GetAttribute("Goal")
    local value = typeof(existing) == "Vector3" and goal.Position or CFrame.new(goal.Position)
    pcall(function() state:SetAttribute("Goal", value) end)
end

-- the closest opponent (anyone who is not you)
local function nearestOther(from)
    local me = getCharacter()
    local best, bestD = nil, math.huge
    local chars = Workspace:FindFirstChild("Characters")
    local function consider(model)
        if not model or model == me or model.Name == LocalPlayer.Name then return end
        local root = model:FindFirstChild("HumanoidRootPart")
        if root then
            local d = (root.Position - from).Magnitude
            if d < bestD then best, bestD = root, d end
        end
    end
    if chars then for _, m in ipairs(chars:GetChildren()) do if m:IsA("Model") then consider(m) end end end
    for _, plr in ipairs(Players:GetPlayers()) do if plr ~= LocalPlayer then consider(plr.Character) end end
    return best, bestD
end

local function looseBall(from)
    local folder = Workspace:FindFirstChild("Basketballs")
    local best, bestD = nil, math.huge
    if folder then
        for _, ball in ipairs(folder:GetChildren()) do
            if ball:IsA("BasePart") then
                local d = (ball.Position - from).Magnitude
                if d < bestD then best, bestD = ball, d end
            end
        end
    end
    return best, bestD
end

-- who holds the ball
local function heldBy(char)
    if not char then return false end
    local hrp = char:FindFirstChild("HumanoidRootPart")
    local weld = hrp and hrp:FindFirstChild("Basketball")
    if weld and weld:IsA("Motor6D") and weld.Part1 then return true end
    local holder = char:FindFirstChild("Attributes")
    local value = holder and holder:FindFirstChild("Basketball")
    return value ~= nil and value:IsA("ObjectValue") and value.Value ~= nil
end

local function handlerRoot()
    local me = getCharacter()
    local chars = Workspace:FindFirstChild("Characters")
    local function check(model)
        if model and model ~= me and model.Name ~= LocalPlayer.Name and heldBy(model) then
            return model:FindFirstChild("HumanoidRootPart")
        end
    end
    if chars then
        for _, m in ipairs(chars:GetChildren()) do
            if m:IsA("Model") then
                local r = check(m)
                if r then return r end
            end
        end
    end
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LocalPlayer then
            local r = check(plr.Character)
            if r then return r end
        end
    end
    return nil
end

-- shooting ---------------------------------------------------------------------------------
local Shot = { active = false, pressedAt = 0, nextAt = 0, session = nil }

local function pingSeconds()
    local ok, value = pcall(function() return Stats.Network.ServerStatsItem["Data Ping"]:GetValue() end)
    return (ok and type(value) == "number") and value / 1000 or 0.05
end

local function mouseDown(down)
    pcall(function()
        if down and mouse1press then mouse1press()
        elseif (not down) and mouse1release then mouse1release()
        else
            local c = Workspace.CurrentCamera.ViewportSize / 2
            game:GetService("VirtualInputManager"):SendMouseButtonEvent(c.X, c.Y, 0, down, game, 0)
        end
    end)
end

local function keyE(down)
    pcall(function()
        game:GetService("VirtualInputManager"):SendKeyEvent(down, Enum.KeyCode.E, false, game)
    end)
end

local function pressShoot(goal)
    setGoal(goal)
    faceHoop(goal)
    local sent = fireRemote("shoot", { Shoot = true, Input = "E" })
    if not sent then mouseDown(true) keyE(true) Shot.viaInput = true else Shot.viaInput = false end
    Shot.active, Shot.pressedAt, Shot.fallback = true, clock(), false
end

local function releaseShoot()
    fireRemote("shoot", { Shoot = false, Input = "E" })
    fireRemote("shoot", { Shoot = false })
    mouseDown(false)
    keyE(false)
end


-- the shot meter -----------------------------------------------------------------------------
local function getMeter()
    local char = getCharacter()
    if not char then return nil end
    local hrp, head = char:FindFirstChild("HumanoidRootPart"), char:FindFirstChild("Head")
    local direct = (hrp and hrp:FindFirstChild("VerticalMeter")) or (head and head:FindFirstChild("VerticalMeter"))
    if direct then return direct end
    for _, holder in ipairs({ hrp, head }) do
        if holder then
            for _, child in ipairs(holder:GetChildren()) do
                if string.find(string.lower(child.Name), "meter", 1, true) and child:FindFirstChild("FillGradient", true) then
                    return child
                end
            end
        end
    end
    return nil
end

local function meterActive()
    local meter = getMeter()
    return meter ~= nil and meter:GetAttribute("Active") == true, meter
end

local function meterMag()
    local char = getCharacter()
    if not char then return nil end
    local offset = char:GetAttribute("meterOffset")
    if typeof(offset) == "Vector2" or typeof(offset) == "Vector3" then return math.abs(offset.Y) end
    if typeof(offset) == "number" then return math.abs(offset) end
    local m = getMeter()
    local fg = m and m:FindFirstChild("FillGradient", true)
    return fg and math.abs(fg.Offset.Y) or nil
end

-- auto green: release when mag >= -perfect - 0.15 - ping - nudge (perfect = -1.5), with a time limit as a backstop
local PERFECT, HOLD_MAX = -1.5, 0.7
local function greenStep()
    local now = clock()
    local active = meterActive()
    local s = Shot.session
    if not active then
        if s and now - s.t0 > 0.08 then
            Shot.session, Shot.active = nil, false
            Shot.nextAt = math.max(Shot.nextAt, now + 0.9)
        end
        return
    end
    local mag = meterMag()
    if not s then
        s = { t0 = now, armed = false, retries = 0 }
        Shot.session = s
    end
    if s.released then
        -- keep sending the release until the meter really stops
        if now - s.relAt > 0.12 and s.retries < 12 then
            s.retries += 1
            s.relAt = now
            releaseShoot()
        end
        return
    end
    local ping = pingSeconds()
    local elapsed = now - s.t0
    local function release()
        s.released, s.relAt, s.retries = true, now, 0
        releaseShoot()
    end
    if elapsed >= HOLD_MAX - ping * 0.5 then return release() end
    if not mag then return end
    local netPing = ping
    pcall(function() netPing = LocalPlayer:GetNetworkPing() end)
    local target = (-PERFECT) - 0.15 - netPing - Cfg.nudge / 1000
    if mag < target then s.armed = true end
    if s.armed and mag >= target and elapsed >= 0.03 then release() end
end

track(RunService.Heartbeat:Connect(function()
    if not Running or not Cfg.green then return end
    local ok, err = pcall(greenStep)
    if not ok and not Cfg.greenErr then
        Cfg.greenErr = true
        warn("[Prada Auto Play] auto green: " .. tostring(err))
    end
end))

-- rainbow meter: only the colour changes, the needle and green zone behave as before
track(RunService.RenderStepped:Connect(function()
    if not Running or not Cfg.rainbow then return end
    local meter = getMeter()
    if not meter then return end
    local t = clock() * 0.35
    local keys = {}
    for i = 0, 6 do keys[#keys + 1] = ColorSequenceKeypoint.new(i / 6, Color3.fromHSV((t + i / 6) % 1, 0.85, 1)) end
    local seq = ColorSequence.new(keys)
    for _, d in ipairs(meter:GetDescendants()) do
        if d:IsA("UIGradient") then d.Color = seq end
    end
end))

-- moving to a new spot ------------------------------------------------------------------------
local function floorAt(pos)
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    local ignore = { Workspace:FindFirstChild("Characters"), Workspace:FindFirstChild("ProxyCharacter"), Workspace:FindFirstChild("Basketballs"), LocalPlayer.Character }
    local list = {}
    for _, i in ipairs(ignore) do if i then list[#list + 1] = i end end
    params.FilterDescendantsInstances = list
    return Workspace:Raycast(pos + Vector3.new(0, 6, 0), Vector3.new(0, -20, 0), params) ~= nil
end


local function jumpTo(pos)
    local proxy = getProxy()
    local hrp = getRoot()
    local part = (proxy and proxy:IsA("BasePart")) and proxy or hrp
    if not part then return end
    part.CFrame = CFrame.new(pos.X, part.Position.Y, pos.Z) * (part.CFrame - part.Position)
    part.AssemblyLinearVelocity = Vector3.zero
end

-- the brain --------------------------------------------------------------------------------
local AP = { status = "Off", gotBallAt = nil, lastDribble = 0, flip = 1, openAt = 0, shootAt = nil }

local function flat(v) return Vector3.new(v.X, 0, v.Z) end

-- the hoop the ball handler is going for: the one they run or face toward (the choice sticks)
local function attackedHoop(root, run)
    local look = flat(root.CFrame.LookVector)
    local face = run.Magnitude > 3 and run.Unit or (look.Magnitude > 0.1 and look.Unit or nil)
    if not face then return AP.defHoop end
    local best, bestScore, cur, curScore
    for _, part in ipairs(hoopList()) do
        if part.Parent then
            local d = flat(part.Position - root.Position)
            if d.Magnitude > 0.5 then
                local score = d.Unit:Dot(face) - d.Magnitude / 400
                if not bestScore or score > bestScore then best, bestScore = part, score end
                if part == AP.defHoop then cur, curScore = part, score end
            end
        end
    end
    if cur and best ~= cur and bestScore - curScore < 0.5 then best = cur end
    AP.defHoop = best or AP.defHoop
    return AP.defHoop
end

local function defend(hrp, hRoot)
    local now = clock()
    if AP.hRoot ~= hRoot then
        AP.hRoot, AP.hPos, AP.hAt, AP.hVel = hRoot, hRoot.Position, now, Vector3.zero
    elseif now - AP.hAt > 0.03 then
        local d = flat(hRoot.Position - AP.hPos) / (now - AP.hAt)
        if now - AP.hAt < 0.5 then AP.hVel = AP.hVel:Lerp(d, 0.5) end
        AP.hPos, AP.hAt = hRoot.Position, now
    end
    local run = AP.hVel
    local engine = flat(hRoot.AssemblyLinearVelocity)
    if engine.Magnitude > run.Magnitude then run = engine end
    local hoop = attackedHoop(hRoot, run)
    if not hoop then stopMoving() AP.status = "No hoop found" return end
    local toHoop = flat(hoop.Position - hRoot.Position)
    local front = toHoop.Magnitude > 0.1 and toHoop.Unit or Vector3.new(0, 0, -1)
    -- stand between them and the hoop, a little ahead of where they are going
    local spot = hRoot.Position + run * 0.3 + front * Cfg.defGap
    local rel = flat(hrp.Position - hRoot.Position)
    if rel:Dot(front) < -0.5 then
        -- behind them: circle round the nearer side instead of running through them
        local side = Vector3.new(-front.Z, 0, front.X)
        if rel:Dot(side) < 0 then side = -side end
        spot = hRoot.Position + run * 0.3 + side * 4 + front * 1.5
    end
    local to = flat(spot - hrp.Position)
    if to.Magnitude > 1.2 then
        local speed = math.min(math.clamp(run.Magnitude * 1.05 + to.Magnitude * 2.5, 8, Cfg.defSpeed), 8 + (to.Magnitude) * 8)
        steer(to.Unit, speed)
    else
        stopMoving()
    end
    -- always look at them
    local proxy, _, gyro = getProxy()
    if proxy and gyro then
        local at = flat(hRoot.Position - proxy.Position)
        if at.Magnitude > 0.1 then gyro.CFrame = CFrame.lookAt(proxy.Position, proxy.Position + at) end
    end
    AP.status = "Guarding"
end

-- shot types and contest ----------------------------------------------------------------------
local function hoopDist(pos, goal)
    return (Vector3.new(goal.Position.X, 0, goal.Position.Z) - Vector3.new(pos.X, 0, pos.Z)).Magnitude
end

local function zoneOf(dist)
    if dist <= Cfg.dunkRange then return "Dunk" end
    if dist <= Cfg.layupRange then return "Layup" end
    if dist >= Cfg.threeLine - 1.5 then return "Three" end
    return "Two"
end

local function typeOk(dist)
    local t = Cfg.shotType
    if t == "Any" then return dist > 3 end
    local z = zoneOf(dist)
    if t == "Dunk" then return z == "Dunk" end
    if t == "Layup" then return z == "Layup" or z == "Dunk" end
    return z == t
end

-- how far from the hoop to stand for the chosen shot
local function targetDist(current)
    local t = Cfg.shotType
    if t == "Three" then return Cfg.threeLine + 1 end
    if t == "Two" then return (Cfg.layupRange + Cfg.threeLine - 1.5) / 2 end
    if t == "Layup" then return math.max(Cfg.layupRange - 3, 5) end
    if t == "Dunk" then return math.max(Cfg.dunkRange - 3, 3) end
    return current
end

local function contestAt(pos)
    local other, d = nearestOther(pos)
    if not other then return 0, nil, math.huge end
    local span = math.max(Cfg.farDist - Cfg.closeDist, 1)
    return math.clamp((Cfg.farDist - d) / span, 0, 1) * 100, other, d
end

-- a spot on the ring around the hoop for the chosen shot where nobody is close
local function pickSpot(hrp, goal)
    local tgt = targetDist(hoopDist(hrp.Position, goal))
    local gp = Vector3.new(goal.Position.X, hrp.Position.Y, goal.Position.Z)
    local best, bestScore
    for i = 0, 15 do
        local a = i * math.pi / 8
        local pos = gp + Vector3.new(math.cos(a), 0, math.sin(a)) * tgt
        if floorAt(pos) then
            local _, _, defD = contestAt(pos)
            local travel = (pos - hrp.Position).Magnitude
            local score = math.min(defD, 30) - travel * 0.25
            if not bestScore or score > bestScore then best, bestScore = pos, score end
        end
    end
    return best
end

-- the jump: a spot within openDistance of you that is in the chosen zone and has a defender-free area
local function bestOpenSpot(hrp, goal)
    local origin = hrp.Position
    local _, _, curDef = contestAt(origin)
    local best, bestScore
    for i = 0, 15 do
        local a = i * math.pi / 8
        local pos = origin + Vector3.new(math.cos(a), 0, math.sin(a)) * Cfg.openDistance
        if floorAt(pos) then
            local hd = hoopDist(pos, goal)
            local _, _, defD = contestAt(pos)
            if hd >= 4 and typeOk(hd) and defD > curDef + 3 and (not bestScore or defD > bestScore) then
                best, bestScore = pos, defD
            end
        end
    end
    return best
end

local function step()
    if not Cfg.enabled then
        if AP.status ~= "Off" then AP.status = "Off" stopMoving() end
        return
    end
    local hrp = getRoot()
    local proxy = getProxy()
    if not hrp or not proxy then AP.status = "No character" stopMoving() return end
    local now = clock()

    -- a shot is being taken: stand still, face the hoop. Auto Green lets go; without it, hold then release.
    if Shot.active then
        stopMoving()
        faceHoop(attackHoop(hrp.Position))
        local held = now - Shot.pressedAt
        local char = getCharacter()
        local shooting = char and char:GetAttribute("Action") == "Shooting"
        -- nothing started: try the real input as well
        if held > 0.3 and not shooting and not meterActive() and not Shot.fallback then
            Shot.fallback = true
            mouseDown(true) keyE(true)
            Shot.viaInput = true
        end
        if Cfg.green then
            if (held > 0.5 and not shooting and not Shot.session and not meterActive()) or held >= 1.6 then
                releaseShoot()
                Shot.active, Shot.nextAt = false, now + 1.3
            end
        elseif held >= Cfg.holdTime then
            releaseShoot()
            Shot.active, Shot.nextAt = false, now + 1.3
        end
        AP.status = "Shooting"
        return
    end

    if AP.pauseUntil and now < AP.pauseUntil then stopMoving() return end

    if hasBall() then
        AP.gotBallAt = AP.gotBallAt or now
        local goal = attackHoop(hrp.Position)
        if not goal then AP.status = "No hoop found" stopMoving() return end
        local dist = hoopDist(hrp.Position, goal)
        local contest, other, od = contestAt(hrp.Position)
        local zoneOkNow = typeOk(dist)
        local state = getState()
        local canAct = not (state and state:GetAttribute("CanMove") == false)

        -- makeable: right spot for the shot, contest low enough, nothing in the way
        if zoneOkNow and canAct and now >= Shot.nextAt then
            local open = contest <= Cfg.maxContest
            local forced = Cfg.giveUp > 0 and now - AP.gotBallAt >= Cfg.giveUp
            if open or forced then
                stopMoving()
                AP.status = string.format("Shooting %s  (contest %d%%)", zoneOf(dist), contest)
                pressShoot(goal)
                AP.gotBallAt, AP.spot = nil, nil
                return
            end
        end

        -- a defender is on you: jump to a clear spot in the zone
        if Cfg.openSpot and other and od <= Cfg.openRange and now >= Shot.nextAt and now - AP.openAt > 1.5 then
            local spot = bestOpenSpot(hrp, goal)
            if spot then
                AP.openAt = now
                jumpTo(spot)
                AP.pauseUntil = now + 0.12
                AP.spot = nil
                AP.status = "Getting open"
                return
            end
        end

        -- move around until the spot is open and in range
        if not AP.spot or now - AP.spotAt > 0.45 or (AP.spot - hrp.Position).Magnitude < 2 then
            AP.spot, AP.spotAt = pickSpot(hrp, goal), now
        end
        if AP.spot then
            local to = flat(AP.spot - hrp.Position)
            if to.Magnitude > 1.5 then
                steer(to.Unit, Cfg.speed)
            else
                stopMoving()
            end
        else
            stopMoving()
        end
        AP.status = string.format("Moving to open spot  (%s, contest %d%%)", string.lower(zoneOf(dist)), contest)
        return
    end

    AP.gotBallAt, AP.spot = nil, nil

    -- they have the ball: stay in front of them
    if Cfg.defense then
        local hRoot = handlerRoot()
        if hRoot then
            defend(hrp, hRoot)
            return
        end
    end

    if Cfg.chaseBall then
        local ball, bd = looseBall(hrp.Position)
        if ball and bd < 60 and bd > 3 then
            local to = flat(ball.Position - hrp.Position)
            if to.Magnitude > 0.1 then
                steer(to.Unit, Cfg.speed)
                AP.status = "Getting the ball"
                return
            end
        end
    end
    stopMoving()
    AP.status = "Waiting for the ball"
end

track(RunService.Heartbeat:Connect(function()
    if not Running then return end
    local ok, err = pcall(step)
    if not ok and not AP.errShown then
        AP.errShown = true
        warn("[Prada Auto Play] " .. tostring(err))
    end
end))

-- window -----------------------------------------------------------------------------------
local function new(class, props, parent)
    local inst = Instance.new(class)
    for k, v in pairs(props) do inst[k] = v end
    inst.Parent = parent
    return inst
end

local function round(inst, radius)
    new("UICorner", { CornerRadius = UDim.new(0, radius) }, inst)
end

local GuiParent
do
    local ok, ui = pcall(function() return gethui and gethui() end)
    if ok and ui then GuiParent = ui
    else
        ok, ui = pcall(function() return game:GetService("CoreGui") end)
        GuiParent = (ok and ui) or LocalPlayer:WaitForChild("PlayerGui")
    end
end
local old = GuiParent:FindFirstChild("PradaAutoPlay")
if old then old:Destroy() end

local WIN_W, WIN_H, SIDE_W, TOP = 740, 410, 150, 56
local WHITE, DIM, PANEL = Color3.fromRGB(245, 245, 245), Color3.fromRGB(140, 140, 140), Color3.fromRGB(22, 22, 22)
local BLACK, OFF = Color3.fromRGB(10, 10, 10), Color3.fromRGB(50, 50, 50)

local Gui = new("ScreenGui", { Name = "PradaAutoPlay", ResetOnSpawn = false, IgnoreGuiInset = true, DisplayOrder = 9998 }, GuiParent)
local Shell = new("Frame", {
    Size = UDim2.fromOffset(WIN_W, WIN_H), Position = UDim2.new(0.5, -WIN_W / 2, 0.5, -WIN_H / 2),
    BackgroundColor3 = Color3.fromRGB(8, 8, 8), BorderSizePixel = 0, ClipsDescendants = true,
}, Gui)
round(Shell, 30)
new("UIStroke", { Color = Color3.fromRGB(40, 40, 40), Thickness = 1 }, Shell)
do
    local view = Workspace.CurrentCamera and Workspace.CurrentCamera.ViewportSize or Vector2.new(1280, 720)
    local scale = math.min(1, (view.X - 20) / WIN_W, (view.Y - 20) / WIN_H)
    if scale < 1 then new("UIScale", { Scale = scale }, Shell) end
end

local Sidebar = new("Frame", { Size = UDim2.fromOffset(SIDE_W, WIN_H - TOP - 12), Position = UDim2.fromOffset(12, TOP), BackgroundTransparency = 1 }, Shell)
new("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }, Sidebar)
local Content = new("Frame", {
    Size = UDim2.fromOffset(WIN_W - SIDE_W - 36, WIN_H - TOP - 14), Position = UDim2.fromOffset(SIDE_W + 24, TOP), BackgroundTransparency = 1,
}, Shell)

-- top bar (drag here)
local bar = new("Frame", { Size = UDim2.new(1, 0, 0, TOP), BackgroundTransparency = 1 }, Shell)
new("TextLabel", {
    Size = UDim2.fromOffset(300, TOP), Position = UDim2.fromOffset(22, 0), BackgroundTransparency = 1, Text = "PRADA AUTO PLAY",
    Font = Enum.Font.GothamBlack, TextSize = 22, TextColor3 = WHITE, TextXAlignment = Enum.TextXAlignment.Left,
}, bar)
local statusLabel = new("TextLabel", {
    Size = UDim2.new(1, -460, 0, TOP), Position = UDim2.fromOffset(330, 0), BackgroundTransparency = 1, Text = "Off",
    Font = Enum.Font.Gotham, TextSize = 12, TextColor3 = DIM, TextXAlignment = Enum.TextXAlignment.Right, TextTruncate = Enum.TextTruncate.AtEnd,
}, bar)
local function dot(x, text)
    local b = new("TextButton", {
        Size = UDim2.fromOffset(26, 26), Position = UDim2.new(1, x, 0, (TOP - 26) / 2), BackgroundColor3 = PANEL, Text = text,
        Font = Enum.Font.GothamBold, TextSize = 14, TextColor3 = WHITE, AutoButtonColor = false,
    }, bar)
    round(b, 13)
    return b
end
local closeBtn = dot(-40, "x")
local miniBtn = dot(-72, "-")
do
    local full = true
    miniBtn.MouseButton1Click:Connect(function()
        full = not full
        Sidebar.Visible, Content.Visible = full, full
        Shell.Size = full and UDim2.fromOffset(WIN_W, WIN_H) or UDim2.fromOffset(WIN_W, TOP)
    end)
end

do
    local dragging, startPos, startMouse
    bar.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging, startPos, startMouse = true, Shell.Position, input.Position
        end
    end)
    track(UserInputService.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            local d = input.Position - startMouse
            Shell.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
        end
    end))
    track(UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then dragging = false end
    end))
end

-- tabs -------------------------------------------------------------------------------------
local refreshers, tabs, Page = {}, {}, nil
local tabCount = 0

local function selectTab(name)
    for n, t in pairs(tabs) do
        t.page.Visible = n == name
        t.btn.BackgroundColor3 = n == name and WHITE or PANEL
        t.btn.TextColor3 = n == name and BLACK or WHITE
    end
end

local function addTab(name)
    tabCount += 1
    local btn = new("TextButton", {
        Size = UDim2.new(1, 0, 0, 38), BackgroundColor3 = PANEL, Text = name, Font = Enum.Font.GothamBold, TextSize = 14,
        TextColor3 = WHITE, AutoButtonColor = false, LayoutOrder = tabCount,
    }, Sidebar)
    round(btn, 14)
    local page = new("ScrollingFrame", {
        Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 3,
        AutomaticCanvasSize = Enum.AutomaticSize.Y, CanvasSize = UDim2.new(), ScrollBarImageColor3 = Color3.fromRGB(90, 90, 90),
        Visible = false,
    }, Content)
    new("UIPadding", { PaddingRight = UDim.new(0, 8), PaddingBottom = UDim.new(0, 8) }, page)
    new("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder }, page)
    tabs[name] = { btn = btn, page = page, n = 0 }
    btn.MouseButton1Click:Connect(function() selectTab(name) end)
    Page = tabs[name]
    return tabs[name]
end

local function nextOrder()
    Page.n += 1
    return Page.n
end

local function toggle(label, key)
    local row = new("TextButton", {
        Size = UDim2.new(1, 0, 0, 36), BackgroundColor3 = PANEL, Text = "", AutoButtonColor = false, LayoutOrder = nextOrder(),
    }, Page.page)
    round(row, 12)
    new("TextLabel", {
        Size = UDim2.new(1, -70, 1, 0), Position = UDim2.fromOffset(14, 0), BackgroundTransparency = 1, Text = label,
        Font = Enum.Font.GothamMedium, TextSize = 14, TextColor3 = WHITE, TextXAlignment = Enum.TextXAlignment.Left,
    }, row)
    local pill = new("Frame", { Size = UDim2.fromOffset(36, 20), Position = UDim2.new(1, -50, 0.5, -10), BackgroundColor3 = OFF }, row)
    round(pill, 10)
    local knob = new("Frame", { Size = UDim2.fromOffset(16, 16), Position = UDim2.fromOffset(2, 2), BackgroundColor3 = WHITE }, pill)
    round(knob, 8)
    row.MouseButton1Click:Connect(function() Cfg[key] = not Cfg[key] end)
    table.insert(refreshers, function()
        pill.BackgroundColor3 = Cfg[key] and WHITE or OFF
        knob.BackgroundColor3 = Cfg[key] and BLACK or WHITE
        knob.Position = Cfg[key] and UDim2.fromOffset(18, 2) or UDim2.fromOffset(2, 2)
    end)
end

local function slider(label, lo, hi, key, stepSize, fmt)
    local row = new("Frame", { Size = UDim2.new(1, 0, 0, 46), BackgroundColor3 = PANEL, LayoutOrder = nextOrder() }, Page.page)
    round(row, 12)
    new("TextLabel", {
        Size = UDim2.new(1, -80, 0, 20), Position = UDim2.fromOffset(14, 4), BackgroundTransparency = 1, Text = label,
        Font = Enum.Font.GothamMedium, TextSize = 14, TextColor3 = WHITE, TextXAlignment = Enum.TextXAlignment.Left,
    }, row)
    local valueLabel = new("TextLabel", {
        Size = UDim2.fromOffset(60, 20), Position = UDim2.new(1, -74, 0, 4), BackgroundTransparency = 1,
        Font = Enum.Font.GothamBold, TextSize = 14, TextColor3 = WHITE, TextXAlignment = Enum.TextXAlignment.Right,
    }, row)
    local rail = new("Frame", { Size = UDim2.new(1, -28, 0, 6), Position = UDim2.fromOffset(14, 33), BackgroundColor3 = OFF }, row)
    round(rail, 3)
    local fill = new("Frame", { Size = UDim2.new(0, 0, 1, 0), BackgroundColor3 = WHITE }, rail)
    round(fill, 3)
    local dragging = false
    local function setFrom(x)
        local alpha = math.clamp((x - rail.AbsolutePosition.X) / math.max(rail.AbsoluteSize.X, 1), 0, 1)
        local v = lo + (hi - lo) * alpha
        v = math.floor(v / stepSize + 0.5) * stepSize
        Cfg[key] = math.clamp(v, lo, hi)
    end
    row.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            setFrom(input.Position.X)
        end
    end)
    track(UserInputService.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            setFrom(input.Position.X)
        end
    end))
    track(UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then dragging = false end
    end))
    table.insert(refreshers, function()
        fill.Size = UDim2.new(math.clamp((Cfg[key] - lo) / (hi - lo), 0, 1), 0, 1, 0)
        valueLabel.Text = string.format(fmt, Cfg[key])
    end)
end

-- a row of buttons, one per option
local function segment(label, key, options)
    local row = new("Frame", { Size = UDim2.new(1, 0, 0, 68), BackgroundColor3 = PANEL, LayoutOrder = nextOrder() }, Page.page)
    round(row, 12)
    new("TextLabel", {
        Size = UDim2.new(1, -28, 0, 22), Position = UDim2.fromOffset(14, 4), BackgroundTransparency = 1, Text = label,
        Font = Enum.Font.GothamMedium, TextSize = 14, TextColor3 = WHITE, TextXAlignment = Enum.TextXAlignment.Left,
    }, row)
    local holder = new("Frame", { Size = UDim2.new(1, -28, 0, 30), Position = UDim2.fromOffset(14, 30), BackgroundTransparency = 1 }, row)
    new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }, holder)
    local buttons = {}
    for i, option in ipairs(options) do
        local b = new("TextButton", {
            Size = UDim2.new(1 / #options, -6 * (#options - 1) / #options, 1, 0), BackgroundColor3 = OFF, Text = option,
            Font = Enum.Font.GothamBold, TextSize = 13, TextColor3 = WHITE, AutoButtonColor = false, LayoutOrder = i,
        }, holder)
        round(b, 10)
        b.MouseButton1Click:Connect(function() Cfg[key] = option end)
        buttons[option] = b
    end
    table.insert(refreshers, function()
        for option, b in pairs(buttons) do
            b.BackgroundColor3 = Cfg[key] == option and WHITE or OFF
            b.TextColor3 = Cfg[key] == option and BLACK or WHITE
        end
    end)
end

local function button(label, callback)
    local b = new("TextButton", {
        Size = UDim2.new(1, 0, 0, 40), BackgroundColor3 = PANEL, Text = label, Font = Enum.Font.GothamBold, TextSize = 15,
        TextColor3 = WHITE, AutoButtonColor = false, LayoutOrder = nextOrder(),
    }, Page.page)
    round(b, 12)
    b.MouseButton1Click:Connect(callback)
    return b
end

-- Play
addTab("Play")
local startBtn = button("START", function() Cfg.enabled = not Cfg.enabled end)
table.insert(refreshers, function()
    startBtn.Text = Cfg.enabled and "STOP" or "START"
    startBtn.BackgroundColor3 = Cfg.enabled and WHITE or PANEL
    startBtn.TextColor3 = Cfg.enabled and BLACK or WHITE
    statusLabel.Text = AP.status
end)
segment("Shot", "shotType", { "Three", "Two", "Layup", "Dunk", "Any" })
slider("Shoot at contest up to", 0, 100, "maxContest", 5, "%d%%")
slider("Shoot covered after (0 = never)", 0, 15, "giveUp", 1, "%ds")
toggle("Auto open spot", "openSpot")

-- Shooting
addTab("Shooting")
toggle("Auto Green", "green")
slider("Release nudge", -80, 80, "nudge", 2, "%+d")
toggle("Rainbow meter", "rainbow")
slider("Hold time (no Auto Green)", 0.3, 1.0, "holdTime", 0.05, "%.2fs")
slider("Three-point line", 18, 40, "threeLine", 1, "%d")
slider("Layup range", 8, 20, "layupRange", 1, "%d")
slider("Dunk range", 3, 12, "dunkRange", 1, "%d")

-- Open
addTab("Open")
slider("Defender this close", 4, 12, "openRange", 0.5, "%.1f")
slider("Jump distance", 8, 20, "openDistance", 1, "%d")
slider("Contest 100% at", 3, 9, "closeDist", 0.5, "%.1f")
slider("Contest 0% at", 10, 24, "farDist", 1, "%d")

-- Defense
addTab("Defense")
toggle("Auto defense", "defense")
slider("Defense speed", 12, 32, "defSpeed", 1, "%d")
slider("Defense gap", 4, 10, "defGap", 0.5, "%.1f")

-- Settings
addTab("Settings")
segment("Hoop", "hoop", { "Auto", "Nearest", "Farthest" })
slider("Run speed", 16, 60, "speed", 1, "%d")
toggle("Get loose balls", "chaseBall")

local unloadRef
button("Unload", function() if unloadRef then unloadRef() end end)

selectTab("Play")

task.spawn(function()
    while Running do
        for _, f in ipairs(refreshers) do pcall(f) end
        task.wait(0.1)
    end
end)

track(UserInputService.InputBegan:Connect(function(input, processed)
    if processed then return end
    if input.KeyCode == Enum.KeyCode.RightControl then Shell.Visible = not Shell.Visible end
end))

local function unload()
    Running = false
    Cfg.enabled = false
    pcall(stopMoving)
    pcall(releaseShoot)
    for _, c in ipairs(connections) do pcall(function() c:Disconnect() end) end
    pcall(function() Gui:Destroy() end)
    genv.PradaAutoPlay = nil
end
unloadRef = unload
closeBtn.MouseButton1Click:Connect(unload)
genv.PradaAutoPlay = { unload = unload, config = Cfg }
