if getgenv().LootboundFarmStop then
    pcall(getgenv().LootboundFarmStop)
    task.wait(0.4)
end
if getgenv().LootboundFarmUI then
    pcall(function() getgenv().LootboundFarmUI.destroy() end)
    getgenv().LootboundFarmUI = nil
end
getgenv().LootboundFarmRunning = false

local uiLoader = loadstring(game:HttpGet('https://raw.githubusercontent.com/topitbopit/dollarware/main/library.lua'))
local ui = uiLoader({
    rounding = false,
    theme = 'cherry',
    smoothDragging = false,
})
ui.autoDisableToggles = true
getgenv().LootboundFarmUI = ui
getgenv().LootboundFarmRunning = false

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local LocalPlayer = Players.LocalPlayer

local EnemiesFolder = Workspace:WaitForChild("Enemies")
local CharFolder = Workspace:WaitForChild("Characters")

-- timings depend on what weapon you use, current; iron greatsword
local HOVER_ABOVE = 60
local CLICK_WAIT = 0.10
local SINGLE_HOLD = 0.5
local SINGLE_REST = 1.0
local MULTI_HOLD = 1.0
local MULTI_REST = 2.0
local MULTI_RADIUS = 45
local MULTI_MAX_TARGETS = 6

local Config = {
    Enabled = false,
    Mode = "Single Target",
    Target = "All",
    Weapon = "Best",
}

local State = {
    running = true,
    conns = {},
    currentEnemy = "none",
}

getgenv().LootboundFarmRunning = true

local function disconnectAll()
    for _, c in ipairs(State.conns) do
        pcall(function() c:Disconnect() end)
    end
    State.conns = {}
end

getgenv().LootboundFarmStop = function()
    getgenv().LootboundFarmRunning = false
    State.running = false
    Config.Enabled = false
    disconnectAll()
end

pcall(function()
    local S = rawget(_G, "STATE")
    if type(S) == "table" and S.onCleanup then
        S.onCleanup(function()
            getgenv().LootboundFarmRunning = false
            State.running = false
            disconnectAll()
        end)
    end
end)

local function getChar()
    local c = CharFolder:FindFirstChild(LocalPlayer.Name)
    if c then return c end
    return LocalPlayer.Character
end

local function getHRP()
    local c = getChar()
    if c then return c:FindFirstChild("HumanoidRootPart") end
    return nil
end

local function getHumanoid()
    local c = getChar()
    if c then return c:FindFirstChildOfClass("Humanoid") end
    return nil
end

local function listOwnedTools()
    local out = {}
    local c = getChar()
    local function scan(parent)
        if not parent then return end
        for _, t in ipairs(parent:GetChildren()) do
            if t:IsA("Tool") then
                table.insert(out, t.Name)
            end
        end
    end
    scan(c)
    pcall(function() scan(LocalPlayer:FindFirstChild("Backpack")) end)
    local seen, uniq = {}, {}
    for _, n in ipairs(out) do
        if not seen[n] then
            seen[n] = true
            table.insert(uniq, n)
        end
    end
    return uniq
end

local function getToolData(tool)
    local d = tool and tool:FindFirstChild("Data")
    if d then
        local ok, res = pcall(require, d)
        if ok and type(res) == "table" then return res end
    end
    return nil
end

local function pickBestTool()
    local c = getChar()
    if not c then return nil end
    local best, bestDmg = nil, -1
    local function consider(parent)
        if not parent then return end
        for _, t in ipairs(parent:GetChildren()) do
            if t:IsA("Tool") then
                local data = getToolData(t)
                local dmg = data and tonumber(data.Damage) or 0
                if dmg > bestDmg then
                    bestDmg = dmg
                    best = t
                end
            end
        end
    end
    consider(c)
    pcall(function() consider(LocalPlayer:FindFirstChild("Backpack")) end)
    return best
end

local function getWeaponTool()
    local c = getChar()
    if not c then return nil end
    if Config.Weapon ~= "Best" then
        local t = c:FindFirstChild(Config.Weapon)
        if t and t:IsA("Tool") then return t end
    end
    return pickBestTool()
end

local function getUseRemote(tool)
    if not tool then return nil end
    local s = tool:FindFirstChild("Server")
    if s then
        local u = s:FindFirstChild("Use")
        if u and u:IsA("RemoteEvent") then return u end
    end
    return tool:FindFirstChild("Use", true)
end

local function listEnemyTypes()
    local seen, out = {}, {"All"}
    for _, e in ipairs(EnemiesFolder:GetChildren()) do
        if e:IsA("Model") and not seen[e.Name] then
            seen[e.Name] = true
            table.insert(out, e.Name)
        end
    end
    table.sort(out)
    for i, v in ipairs(out) do
        if v == "All" then
            table.remove(out, i)
            break
        end
    end
    table.insert(out, 1, "All")
    return out
end

local function isAlive(model)
    local h = model and model:FindFirstChildOfClass("Humanoid")
    local hrp = model and model:FindFirstChild("HumanoidRootPart")
    return h and hrp and h.Health > 0
end

local function findTarget(myPos)
    local best, bestDist = nil, math.huge
    for _, e in ipairs(EnemiesFolder:GetChildren()) do
        if e:IsA("Model") then
            if Config.Target ~= "All" and e.Name ~= Config.Target then continue end
            local h = e:FindFirstChildOfClass("Humanoid")
            local er = e:FindFirstChild("HumanoidRootPart")
            if h and er and h.Health > 0 then
                local hrpNow = getHRP()
                local from = myPos or (hrpNow and hrpNow.Position)
                local d = from and (from - er.Position).Magnitude or 0
                if d < bestDist then
                    bestDist = d
                    best = e
                end
            end
        end
    end
    return best
end

-- nearby enemies around an anchor, nearest-first
local function findCluster(anchorPos, radius, maxN)
    local list = {}
    for _, e in ipairs(EnemiesFolder:GetChildren()) do
        if e:IsA("Model") then
            if Config.Target ~= "All" and e.Name ~= Config.Target then continue end
            local h = e:FindFirstChildOfClass("Humanoid")
            local er = e:FindFirstChild("HumanoidRootPart")
            if h and er and h.Health > 0 then
                local d = (anchorPos - er.Position).Magnitude
                if d <= radius then
                    table.insert(list, { m = e, d = d })
                end
            end
        end
    end
    table.sort(list, function(a, b) return a.d < b.d end)
    local out = {}
    for i = 1, math.min(#list, maxN) do
        table.insert(out, list[i].m)
    end
    return out
end

-- physics freeze while enabled
local hbConn = RunService.Heartbeat:Connect(function()
    if not State.running or not Config.Enabled then return end
    local c = getChar()
    local hrp = getHRP()
    if c and hrp then
        for _, p in ipairs(c:GetDescendants()) do
            if p:IsA("BasePart") then p.CanCollide = false end
        end
        hrp.CanCollide = false
        hrp.AssemblyLinearVelocity = Vector3.zero
        hrp.AssemblyAngularVelocity = Vector3.zero
    end
end)
table.insert(State.conns, hbConn)

local function hoverAbove(hrp, ePos)
    local hoverPos = ePos + Vector3.new(0, HOVER_ABOVE, 0)
    local cf = CFrame.new(hoverPos, ePos)
    hrp.CFrame = cf
    return cf
end

local function strikePos(ePos)
    return CFrame.new(ePos + Vector3.new(0, 1, 2), ePos)
end

-- single target function
local function runSingle(hrp, use, target)
    local eHRP = target:FindFirstChild("HumanoidRootPart")
    if not eHRP then return end
    hoverAbove(hrp, eHRP.Position)
    use:FireServer("MouseButton1", false, eHRP.CFrame)
    task.wait(CLICK_WAIT)
    if not isAlive(target) then return end
    hrp.CFrame = strikePos(eHRP.Position)
    task.wait(SINGLE_HOLD)
    use:FireServer("MouseButton1", true, eHRP.CFrame)
    if isAlive(target) then
        hoverAbove(hrp, eHRP.Position)
    else
        hoverAbove(hrp, eHRP.Position)
    end
    task.wait(SINGLE_REST)
end

-- multi cleave function
local function runCleave(hrp, use, anchor)
    local anchorHRP = anchor:FindFirstChild("HumanoidRootPart")
    if not anchorHRP then return end
    local anchorPos = anchorHRP.Position
    hoverAbove(hrp, anchorPos)
    use:FireServer("MouseButton1", false, anchorHRP.CFrame)
    task.wait(CLICK_WAIT)
    local pack = findCluster(anchorPos, MULTI_RADIUS, MULTI_MAX_TARGETS)
    if #pack == 0 then
        if isAlive(anchor) then hoverAbove(hrp, anchorHRP.Position) end
        task.wait(MULTI_REST)
        return
    end
    local per = MULTI_HOLD / math.max(#pack, 1)
    for _, e in ipairs(pack) do
        if not State.running or not Config.Enabled then break end
        local er = e:FindFirstChild("HumanoidRootPart")
        if er and isAlive(e) then
            hrp.CFrame = strikePos(er.Position)
            task.wait(per)
        end
    end
    use:FireServer("MouseButton1", true, anchorHRP.CFrame)
    if isAlive(anchor) then
        hoverAbove(hrp, anchorHRP.Position)
    else
        local next = findTarget(hrp.Position)
        if next then
            local ner = next:FindFirstChild("HumanoidRootPart")
            if ner then hoverAbove(hrp, ner.Position) end
        end
    end
    task.wait(MULTI_REST)
end

-- "dollarware" bro.
local targetList = listEnemyTypes()
local targetIdx = 1
local weaponList = {"Best"}
for _, n in ipairs(listOwnedTools()) do table.insert(weaponList, n) end
local weaponIdx = 1

local window = ui.newWindow({
    text = "Lootbound | Farm",
    resize = true,
    size = Vector2.new(550, 376),
})

local menu = window:addMenu({ text = "Farm" })

local mainSec = menu:addSection({ text = "Auto Farm", side = "left" })
local statusSec = menu:addSection({ text = "Status", side = "right" })

local farmToggle = mainSec:addToggle({ text = "Auto Farm", state = false })
farmToggle:bindToEvent("onToggle", function(on)
    Config.Enabled = on
    ui.notify({
        title = "Farm",
        message = on and "Auto-Farm ON" or "Auto-Farm OFF",
        duration = 2,
    })
end)

local modeToggle = mainSec:addToggle({ text = "Multi Cleave", state = false })
modeToggle:bindToEvent("onToggle", function(on)
    Config.Mode = on and "Multi Cleave" or "Single Target"
    ui.notify({ title = "Mode", message = Config.Mode, duration = 2 })
end)

local targetLabel = mainSec:addLabel({ text = "Target: All" })
mainSec:addButton({ text = "Next Target", style = "large" }, function()
    targetIdx = (targetIdx % #targetList) + 1
    Config.Target = targetList[targetIdx]
    targetLabel:setText("Target: " .. Config.Target)
end)

local weaponLabel = mainSec:addLabel({ text = "Weapon: Best" })
mainSec:addButton({ text = "Next Weapon", style = "large" }, function()
    weaponIdx = (weaponIdx % #weaponList) + 1
    Config.Weapon = weaponList[weaponIdx]
    weaponLabel:setText("Weapon: " .. Config.Weapon)
end)

mainSec:addButton({ text = "Refresh Lists", style = "large" }, function()
    targetList = listEnemyTypes()
    targetIdx = 1
    Config.Target = targetList[1]
    targetLabel:setText("Target: " .. Config.Target)
    weaponList = {"Best"}
    for _, n in ipairs(listOwnedTools()) do table.insert(weaponList, n) end
    weaponIdx = 1
    Config.Weapon = "Best"
    weaponLabel:setText("Weapon: Best")
    ui.notify({ title = "Farm", message = "Lists refreshed", duration = 2 })
end)

local statusLabel = statusSec:addLabel({ text = "Idle" })
statusSec:addButton({ text = "Stop Farm", style = "large" }, function()
    Config.Enabled = false
    if farmToggle:getState() then farmToggle:disable() end
    ui.notify({ title = "Farm", message = "Stopped", duration = 2 })
end)

-- started after UI so the status label exists
task.spawn(function()
    local lastStatus = 0
    while State.running and getgenv().LootboundFarmRunning do
        if not Config.Enabled then
            State.currentEnemy = "none"
            task.wait(0.25)
            continue
        end
        local hrp = getHRP()
        local hum = getHumanoid()
        if not hrp or not hum or hum.Health <= 0 then
            task.wait(0.5)
            continue
        end
        local tool = getWeaponTool()
        local use = getUseRemote(tool)
        if not use then
            task.wait(0.5)
            continue
        end
        local target = findTarget(hrp.Position)
        if not target then
            State.currentEnemy = "none"
            task.wait(0.5)
            continue
        end
        State.currentEnemy = target.Name
        local ok, err = pcall(function()
            if Config.Mode == "Multi Cleave" then
                runCleave(hrp, use, target)
            else
                runSingle(hrp, use, target)
            end
        end)
        if not ok then
            warn("[Farm] cycle error: " .. tostring(err))
            task.wait(0.5)
        end
        if os.clock() - lastStatus > 1 then
            lastStatus = os.clock()
            pcall(function()
                statusLabel:setText((Config.Enabled and "Farming: " or "Idle: ") .. State.currentEnemy .. " [" .. Config.Mode .. "]")
            end)
        end
    end
end)

ui.notify({ title = "Lootbound", message = "Farm loaded. Toggle Auto Farm.", duration = 3 })
