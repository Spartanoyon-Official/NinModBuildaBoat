-- =========================================================
-- NINMOD | BOAT ADMIN
-- Rayfield + Farm otimizado + Painel de Processos
-- =========================================================

-- ==================== Services ====================

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local StatsService = game:GetService("Stats")

local player = Players.LocalPlayer

-- ==================== Game Objects ====================

local stages = workspace
    :WaitForChild("BoatStages")
    :WaitForChild("NormalStages")

local goldEvent = workspace
    :WaitForChild("ClaimRiverResultsGold")

-- ==================== Configuration ====================

local MAX_STAGES = 10
local STAGE_DURATION = 0.35
local GOLD_COLLECT_RADIUS = 40

local GOD_MODE_ENABLED = true
local LOW_GRAVITY = 0

local CHARACTER_CHECK_INTERVAL = 0.05
local STAGE_CHECK_INTERVAL = 0.02
local TELEPORT_SETTLE_TIME = 0.05
local MISSING_STAGE_RETRY_TIME = 0.15

local UI_UPDATE_INTERVAL = 0.20
local PROCESS_UPDATE_INTERVAL = 0.50
local PROCESS_UPDATES_ENABLED = true
local NOTIFICATIONS_ENABLED = true

-- ==================== Internal State ====================

local originalGravity = workspace.Gravity

local farming = false
local farmLoopRunning = false
local farmGeneration = 0
local destroyingInterface = false

local suppressToggleCallback = false

local currentThemeName = "Padrão"
local currentFPS = 0
local frameCounter = 0
local frameWindowStartedAt = os.clock()

-- ==================== Interface References ====================

local FarmToggle

local MainSummaryParagraph
local MainActivityParagraph

local StatusParagraph
local StageParagraph
local DurationParagraph

local ProcessGeneralParagraph
local ProcessCountersParagraph
local ProcessPerformanceParagraph
local ProcessCacheParagraph
local ProcessEventParagraph
local ProcessErrorParagraph

local CurrentThemeParagraph
local ProcessSettingsParagraph

local lastStageUIUpdate = 0
local lastStageUISignature
local lastStatusSignature

local updateProcessPanels = function()
    -- Inicialização temporária: alguns builds do Rayfield executam callbacks
    -- durante a criação dos controles. A função real é atribuída mais abaixo.
end

-- ==================== Cache ====================

local stageCache = table.create(MAX_STAGES)

local goldPartCache = {}
local clickDetectorCache = {}

local invalidGoldParts = {}
local invalidClickDetectors = {}

-- ==================== Connections ====================

local collectibleAddedConnection
local collectibleRemovingConnection
local characterAddedConnection
local fpsConnection

-- ==================== Keywords ====================

local goldNames = {
    "gold",
    "goldnugget",
    "coin",
    "money",
    "ingot",
    "goldpiece"
}

local statueNames = {
    "gold",
    "statue",
    "treasure",
    "chest"
}

-- ==================== Process Statistics ====================

local processStats = {
    scriptStartedAt = os.clock(),
    farmStartedAt = nil,
    cycleStartedAt = nil,

    currentStage = 0,
    currentCycle = 0,

    completedStages = 0,
    completedCycles = 0,

    teleports = 0,
    collectionPasses = 0,

    touchAttempts = 0,
    clickAttempts = 0,
    rewardRequests = 0,

    respawns = 0,
    manualResets = 0,

    errors = 0,

    lastCycleTime = 0,
    totalCycleTime = 0,

    stageCacheBuilds = 0,
    collectibleCacheBuilds = 0,

    lastAction = "Inicializando o sistema.",
    lastError = "Nenhum erro registrado."
}

-- =========================================================
-- RAYFIELD
-- =========================================================

local rayfieldSuccess, Rayfield = xpcall(function()
    local source = game:HttpGet(
        "https://sirius.menu/rayfield",
        true
    )

    assert(
        type(source) == "string" and #source > 0,
        "O código do Rayfield não foi recebido."
    )

    local loader, compileError = loadstring(source)

    assert(
        loader,
        "Falha ao compilar o Rayfield: "
            .. tostring(compileError)
    )

    local library = loader()

    assert(
        library,
        "O Rayfield foi executado, mas não retornou a biblioteca."
    )

    return library
end, debug.traceback)

if not rayfieldSuccess or not Rayfield then
    warn("[NinMod] Não foi possível carregar o Rayfield.")
    warn("[NinMod] Erro: " .. tostring(Rayfield))
    return
end

-- =========================================================
-- GENERAL HELPERS
-- =========================================================

local function markAction(action)
    processStats.lastAction = tostring(action)
end

local function registerError(errorMessage)
    processStats.errors += 1
    processStats.lastError = tostring(errorMessage)
end

local function formatDuration(seconds)
    seconds = math.max(0, tonumber(seconds) or 0)

    local hours = math.floor(seconds / 3600)
    local minutes = math.floor((seconds % 3600) / 60)
    local remainingSeconds = math.floor(seconds % 60)

    if hours > 0 then
        return string.format(
            "%02dh %02dm %02ds",
            hours,
            minutes,
            remainingSeconds
        )
    end

    if minutes > 0 then
        return string.format(
            "%02dm %02ds",
            minutes,
            remainingSeconds
        )
    end

    return string.format("%.1fs", seconds)
end

local function countDictionary(dictionary)
    local count = 0

    for _ in pairs(dictionary) do
        count += 1
    end

    return count
end

local function countValidStages()
    local count = 0

    for stageNumber = 1, MAX_STAGES do
        local stagePart = stageCache[stageNumber]

        if stagePart and stagePart.Parent then
            count += 1
        end
    end

    return count
end

local function getPingText()
    local success, result = pcall(function()
        return StatsService.Network.ServerStatsItem[
            "Data Ping"
        ]:GetValueString()
    end)

    if success and result then
        return tostring(result)
    end

    return "Indisponível"
end

local function getAverageCycleTime()
    if processStats.completedCycles <= 0 then
        return 0
    end

    return processStats.totalCycleTime
        / processStats.completedCycles
end

local function notify(title, content, duration)
    if destroyingInterface or not NOTIFICATIONS_ENABLED then
        return
    end

    pcall(function()
        Rayfield:Notify({
            Title = title,
            Content = content,
            Duration = duration or 4,
            Image = 0
        })
    end)
end

local function setParagraph(paragraph, title, content)
    if not paragraph or destroyingInterface then
        return
    end

    pcall(function()
        paragraph:Set({
            Title = title,
            Content = content
        })
    end)
end

-- =========================================================
-- UI HELPERS
-- =========================================================

local function updateStatus(title, content, forceUpdate)
    if not StatusParagraph or destroyingInterface then
        return
    end

    local signature =
        tostring(title) .. "|" .. tostring(content)

    if not forceUpdate
        and signature == lastStatusSignature then

        return
    end

    lastStatusSignature = signature

    setParagraph(
        StatusParagraph,
        title,
        content
    )
end

local function updateStageStatus(
    stageNumber,
    content,
    forceUpdate
)
    if not StageParagraph or destroyingInterface then
        return
    end

    local title = "Estágio atual"

    if stageNumber and stageNumber > 0 then
        title = string.format(
            "Estágio atual: %d/%d",
            stageNumber,
            MAX_STAGES
        )
    end

    local signature =
        tostring(title) .. "|" .. tostring(content)

    if signature == lastStageUISignature
        and not forceUpdate then

        return
    end

    local now = os.clock()

    if not forceUpdate
        and now - lastStageUIUpdate < UI_UPDATE_INTERVAL then

        return
    end

    lastStageUIUpdate = now
    lastStageUISignature = signature

    setParagraph(
        StageParagraph,
        title,
        content or "Aguardando o farm."
    )
end

local function updateDurationStatus()
    setParagraph(
        DurationParagraph,
        "Tempo configurado",
        string.format(
            "%.2f segundo por estágio.",
            STAGE_DURATION
        )
    )
end

local function setFarmToggleSilently(value)
    if not FarmToggle or destroyingInterface then
        return
    end

    suppressToggleCallback = true

    pcall(function()
        FarmToggle:Set(value)
    end)

    suppressToggleCallback = false
end

-- =========================================================
-- CHARACTER HELPERS
-- =========================================================

local function getHumanoid(character)
    character = character or player.Character

    if not character then
        return nil
    end

    return character:FindFirstChildOfClass("Humanoid")
end

local function getHumanoidRootPart(character)
    character = character or player.Character

    if not character then
        return nil
    end

    return character:FindFirstChild("HumanoidRootPart")
end

local function characterStillValid(
    character,
    humanoid,
    humanoidRootPart
)
    return character ~= nil
        and character.Parent ~= nil
        and humanoid ~= nil
        and humanoid.Parent ~= nil
        and humanoid.Health > 0
        and humanoidRootPart ~= nil
        and humanoidRootPart.Parent ~= nil
end

local function getAliveCharacter()
    local character = player.Character

    if not character then
        return nil
    end

    local humanoid =
        character:FindFirstChildOfClass("Humanoid")

    if not humanoid or humanoid.Health <= 0 then
        return nil
    end

    local humanoidRootPart =
        character:FindFirstChild("HumanoidRootPart")

    if not humanoidRootPart then
        return nil
    end

    return character, humanoid, humanoidRootPart
end

local function isAlive(character)
    if not character then
        return false
    end

    local humanoid =
        character:FindFirstChildOfClass("Humanoid")

    return humanoid ~= nil
        and humanoid.Health > 0
end

local function isCurrentFarm(generation)
    return farming
        and generation == farmGeneration
end

local function waitForAliveCharacter(generation)
    while isCurrentFarm(generation) do
        local character, humanoid, humanoidRootPart =
            getAliveCharacter()

        if character then
            return character, humanoid, humanoidRootPart
        end

        task.wait(CHARACTER_CHECK_INTERVAL)
    end

    return nil
end

local function resetCharacter()
    local character = player.Character

    if not character then
        return false
    end

    local humanoid =
        character:FindFirstChildOfClass("Humanoid")

    if not humanoid then
        return false
    end

    processStats.manualResets += 1
    markAction("Reiniciando o personagem manualmente.")

    local success = pcall(function()
        humanoid.Health = 0
    end)

    task.wait()

    if humanoid.Parent
        and humanoid.Health > 0
        and character.Parent then

        pcall(function()
            character:BreakJoints()
        end)
    end

    if updateProcessPanels then
        updateProcessPanels(true)
    end

    return success
end

local function applyGodMode(character)
    if not GOD_MODE_ENABLED or not character then
        return
    end

    local humanoid =
        character:FindFirstChildOfClass("Humanoid")

    if not humanoid or humanoid.Health <= 0 then
        return
    end

    pcall(function()
        humanoid.MaxHealth = 1e9
        humanoid.Health = 1e9
    end)
end

local function fixSpawn()
    local character = player.Character

    if not character then
        notify(
            "Corrigir respawn",
            "O personagem ainda não está disponível.",
            4
        )

        return
    end

    local humanoid =
        character:FindFirstChildOfClass("Humanoid")

    if not humanoid then
        notify(
            "Corrigir respawn",
            "O Humanoid não foi encontrado.",
            4
        )

        return
    end

    processStats.manualResets += 1
    markAction("Executando correção de respawn.")

    workspace.Gravity = originalGravity

    pcall(function()
        humanoid.MaxHealth = 100
        humanoid.Health = 0
    end)

    task.wait()

    if humanoid.Parent
        and humanoid.Health > 0
        and character.Parent then

        pcall(function()
            character:BreakJoints()
        end)
    end

    notify(
        "Corrigir respawn",
        "O personagem foi reiniciado.",
        4
    )

    if updateProcessPanels then
        updateProcessPanels(true)
    end
end

-- =========================================================
-- STAGE CACHE
-- =========================================================

local function findStagePart(stageNumber)
    local stageName =
        "CaveStage" .. tostring(stageNumber)

    local stageModel =
        stages:FindFirstChild(stageName)

    if not stageModel then
        return nil
    end

    return stageModel:FindFirstChild("DarknessPart")
end

local function buildStageCache()
    table.clear(stageCache)

    for stageNumber = 1, MAX_STAGES do
        stageCache[stageNumber] =
            findStagePart(stageNumber)
    end

    processStats.stageCacheBuilds += 1
    markAction("Cache dos estágios atualizado.")
end

local function getStagePart(stageNumber)
    local cachedPart = stageCache[stageNumber]

    if cachedPart
        and cachedPart.Parent
        and cachedPart:IsDescendantOf(stages) then

        return cachedPart
    end

    local refreshedPart =
        findStagePart(stageNumber)

    stageCache[stageNumber] = refreshedPart

    return refreshedPart
end

-- =========================================================
-- COLLECTIBLE CACHE
-- =========================================================

local function nameContainsKeyword(name, keywords)
    local normalizedName =
        string.lower(tostring(name))

    for index = 1, #keywords do
        if string.find(
            normalizedName,
            keywords[index],
            1,
            true
        ) then
            return true
        end
    end

    return false
end

local function isGoldPart(object)
    if not object:IsA("BasePart") then
        return false
    end

    if nameContainsKeyword(
        object.Name,
        goldNames
    ) then
        return true
    end

    local parent = object.Parent

    if parent and parent ~= workspace then
        return nameContainsKeyword(
            parent.Name,
            goldNames
        )
    end

    return false
end

local function isGoldClickDetector(object)
    if not object:IsA("ClickDetector") then
        return false
    end

    local parent = object.Parent

    if not parent or not parent:IsA("BasePart") then
        return false
    end

    return nameContainsKeyword(
        parent.Name,
        statueNames
    )
end

local function registerCollectible(object)
    if object:IsA("BasePart") then
        if isGoldPart(object) then
            goldPartCache[object] = true
        end

        return
    end

    if object:IsA("ClickDetector")
        and isGoldClickDetector(object) then

        clickDetectorCache[object] = true
    end
end

local function unregisterCollectible(object)
    goldPartCache[object] = nil
    clickDetectorCache[object] = nil
end

local function buildCollectibleCache()
    table.clear(goldPartCache)
    table.clear(clickDetectorCache)

    local descendants = workspace:GetDescendants()

    for index = 1, #descendants do
        registerCollectible(descendants[index])
    end

    processStats.collectibleCacheBuilds += 1
    markAction("Cache dos coletáveis atualizado.")
end

-- =========================================================
-- GOLD COLLECTION
-- =========================================================

local function collectGoldNearby(
    character,
    humanoid,
    humanoidRootPart
)
    if not characterStillValid(
        character,
        humanoid,
        humanoidRootPart
    ) then
        return
    end

    processStats.collectionPasses += 1
    markAction("Verificando coletáveis próximos.")

    local rootPosition =
        humanoidRootPart.Position

    local radiusSquared =
        GOLD_COLLECT_RADIUS * GOLD_COLLECT_RADIUS

    table.clear(invalidGoldParts)
    table.clear(invalidClickDetectors)

    for part in pairs(goldPartCache) do
        if not part.Parent
            or not part:IsDescendantOf(workspace) then

            invalidGoldParts[
                #invalidGoldParts + 1
            ] = part
        else
            local difference =
                part.Position - rootPosition

            if difference:Dot(difference)
                <= radiusSquared then

                processStats.touchAttempts += 1

                pcall(function()
                    firetouchinterest(
                        humanoidRootPart,
                        part,
                        0
                    )

                    firetouchinterest(
                        humanoidRootPart,
                        part,
                        1
                    )
                end)
            end
        end
    end

    for detector in pairs(clickDetectorCache) do
        local parent = detector.Parent

        if not parent
            or not parent:IsA("BasePart")
            or not detector:IsDescendantOf(workspace) then

            invalidClickDetectors[
                #invalidClickDetectors + 1
            ] = detector
        else
            local difference =
                parent.Position - rootPosition

            if difference:Dot(difference)
                <= radiusSquared then

                processStats.clickAttempts += 1

                pcall(function()
                    fireclickdetector(
                        detector,
                        50
                    )
                end)
            end
        end
    end

    for index = 1, #invalidGoldParts do
        goldPartCache[
            invalidGoldParts[index]
        ] = nil
    end

    for index = 1, #invalidClickDetectors do
        clickDetectorCache[
            invalidClickDetectors[index]
        ] = nil
    end
end

-- =========================================================
-- WAIT HELPERS
-- =========================================================

local function waitStageDuration(
    generation,
    character,
    humanoid,
    humanoidRootPart
)
    local finishTime =
        os.clock() + STAGE_DURATION

    while isCurrentFarm(generation) do
        if os.clock() >= finishTime then
            return characterStillValid(
                character,
                humanoid,
                humanoidRootPart
            )
        end

        if not characterStillValid(
            character,
            humanoid,
            humanoidRootPart
        ) then
            return false
        end

        task.wait(STAGE_CHECK_INTERVAL)
    end

    return false
end

local function waitForRespawn(generation)
    while isCurrentFarm(generation) do
        local character, humanoid, humanoidRootPart =
            getAliveCharacter()

        if characterStillValid(
            character,
            humanoid,
            humanoidRootPart
        ) then
            return character, humanoid, humanoidRootPart
        end

        task.wait(CHARACTER_CHECK_INTERVAL)
    end

    return nil
end

-- =========================================================
-- FARM LOOP
-- =========================================================

local function farmLoop(generation)
    while isCurrentFarm(generation) do
        processStats.currentCycle += 1
        processStats.currentStage = 0
        processStats.cycleStartedAt = os.clock()

        markAction(
            "Iniciando ciclo "
            .. tostring(processStats.currentCycle)
            .. "."
        )

        local character, humanoid, humanoidRootPart =
            waitForAliveCharacter(generation)

        if not character then
            break
        end

        applyGodMode(character)

        for stageNumber = 1, MAX_STAGES do
            if not isCurrentFarm(generation) then
                break
            end

            processStats.currentStage = stageNumber

            local stageCompleted = false

            repeat
                if not isCurrentFarm(generation) then
                    break
                end

                if not characterStillValid(
                    character,
                    humanoid,
                    humanoidRootPart
                ) then
                    markAction(
                        "Aguardando o personagem renascer."
                    )

                    updateStageStatus(
                        stageNumber,
                        "Aguardando o personagem renascer."
                    )

                    character,
                    humanoid,
                    humanoidRootPart =
                        waitForAliveCharacter(generation)

                    if not character then
                        break
                    end

                    applyGodMode(character)
                end

                local darknessPart =
                    getStagePart(stageNumber)

                if not darknessPart then
                    markAction(
                        "Aguardando DarknessPart do estágio "
                        .. tostring(stageNumber)
                        .. "."
                    )

                    updateStageStatus(
                        stageNumber,
                        "DarknessPart não encontrada."
                    )

                    task.wait(
                        MISSING_STAGE_RETRY_TIME
                    )

                    continue
                end

                markAction(
                    "Movendo para o estágio "
                    .. tostring(stageNumber)
                    .. "."
                )

                updateStageStatus(
                    stageNumber,
                    string.format(
                        "Movendo para o estágio %d de %d.",
                        stageNumber,
                        MAX_STAGES
                    )
                )

                local teleportSuccess =
                    pcall(function()
                        humanoidRootPart.CFrame =
                            darknessPart.CFrame
                    end)

                if not teleportSuccess then
                    registerError(
                        "Falha ao mover para o estágio "
                        .. tostring(stageNumber)
                        .. "."
                    )

                    task.wait(0.08)
                    continue
                end

                processStats.teleports += 1

                task.wait(TELEPORT_SETTLE_TIME)

                if characterStillValid(
                    character,
                    humanoid,
                    humanoidRootPart
                ) then
                    collectGoldNearby(
                        character,
                        humanoid,
                        humanoidRootPart
                    )
                end

                stageCompleted =
                    waitStageDuration(
                        generation,
                        character,
                        humanoid,
                        humanoidRootPart
                    )
            until stageCompleted
                or not isCurrentFarm(generation)

            if isCurrentFarm(generation)
                and stageCompleted
                and characterStillValid(
                    character,
                    humanoid,
                    humanoidRootPart
                ) then

                processStats.completedStages += 1
                processStats.rewardRequests += 1

                markAction(
                    "Solicitando recompensa do estágio "
                    .. tostring(stageNumber)
                    .. "."
                )

                updateStageStatus(
                    stageNumber,
                    "Estágio concluído. Solicitando recompensa."
                )

                pcall(function()
                    goldEvent:FireServer()
                end)
            end
        end

        if isCurrentFarm(generation) then
            if processStats.cycleStartedAt then
                processStats.lastCycleTime =
                    os.clock()
                    - processStats.cycleStartedAt

                processStats.totalCycleTime +=
                    processStats.lastCycleTime

                processStats.completedCycles += 1
            end

            processStats.currentStage = 0

            markAction(
                "Ciclo concluído. Reiniciando personagem."
            )

            updateStageStatus(
                nil,
                "Ciclo concluído. Reiniciando o personagem.",
                true
            )

            if humanoid
                and humanoid.Parent
                and humanoid.Health > 0 then

                pcall(function()
                    humanoid.Health = 0
                end)
            end

            character,
            humanoid,
            humanoidRootPart =
                waitForRespawn(generation)

            if character then
                applyGodMode(character)
            end
        end
    end
end

-- =========================================================
-- FARM CONTROL
-- =========================================================

local function stopFarmSafe(resetAfterStopping)
    local wasRunning =
        farming or farmLoopRunning

    farming = false
    farmGeneration += 1

    processStats.currentStage = 0
    processStats.farmStartedAt = nil
    processStats.cycleStartedAt = nil

    workspace.Gravity = originalGravity

    markAction("Farm desligado.")

    updateStatus(
        "Status: farm desligado",
        "O farm está parado e a gravidade foi restaurada.",
        true
    )

    updateStageStatus(
        nil,
        "Aguardando o farm ser iniciado.",
        true
    )

    if resetAfterStopping then
        resetCharacter()
    end

    if wasRunning and not destroyingInterface then
        notify(
            "AFK Gold Farm",
            "Farm desligado com segurança.",
            4
        )
    end

    if updateProcessPanels then
        updateProcessPanels(true)
    end
end

local function startFarmSafe()
    if farming then
        return
    end

    if farmLoopRunning then
        notify(
            "AFK Gold Farm",
            "O ciclo anterior ainda está encerrando.",
            4
        )

        setFarmToggleSilently(false)
        return
    end

    farming = true
    farmLoopRunning = true
    farmGeneration += 1

    processStats.farmStartedAt = os.clock()
    processStats.currentStage = 0

    local currentGeneration =
        farmGeneration

    workspace.Gravity = LOW_GRAVITY

    markAction("Farm iniciado.")

    updateStatus(
        "Status: farm ativo",
        string.format(
            "Executando %d estágios com %.2f segundo por estágio.",
            MAX_STAGES,
            STAGE_DURATION
        ),
        true
    )

    updateStageStatus(
        1,
        "Preparando o primeiro estágio.",
        true
    )

    notify(
        "AFK Gold Farm",
        "Farm rápido ativado.",
        4
    )

    if updateProcessPanels then
        updateProcessPanels(true)
    end

    task.spawn(function()
        local farmSuccess, farmError =
            xpcall(function()
                farmLoop(currentGeneration)
            end, debug.traceback)

        farmLoopRunning = false

        if currentGeneration ~= farmGeneration then
            return
        end

        if not farmSuccess then
            farming = false
            workspace.Gravity = originalGravity

            registerError(farmError)
            markAction("Loop encerrado por erro.")

            setFarmToggleSilently(false)

            updateStatus(
                "Status: erro no farm",
                "O loop foi interrompido. Verifique Processos.",
                true
            )

            updateStageStatus(
                nil,
                "Erro encontrado durante a execução.",
                true
            )

            warn(
                "[NinMod | FarmLoop]\n"
                .. tostring(farmError)
            )

            notify(
                "Erro no farm",
                "O loop foi interrompido por um erro.",
                6
            )

            if updateProcessPanels then
                updateProcessPanels(true)
            end
        end
    end)
end

-- =========================================================
-- INITIAL CACHE BUILD
-- =========================================================

buildStageCache()
buildCollectibleCache()

-- =========================================================
-- RAYFIELD WINDOW
-- =========================================================

local windowSuccess, Window = xpcall(function()
    return Rayfield:CreateWindow({
        Name = "NinMod | Boat Admin",
        Icon = 0,

        LoadingTitle = "NinMod",
        LoadingSubtitle = "Boat Admin",

        ShowText = "NinMod",
        Theme = "Default",

        ToggleUIKeybind = "G",

        DisableRayfieldPrompts = true,
        DisableBuildWarnings = false,

        ConfigurationSaving = {
            Enabled = false,
            FolderName = "NinMod",
            FileName = "BoatAdmin"
        },

        Discord = {
            Enabled = false,
            Invite = "",
            RememberJoins = false
        },

        KeySystem = false
    })
end, debug.traceback)

if not windowSuccess or not Window then
    warn("[NinMod] A janela do Rayfield não foi criada.")
    warn("[NinMod] Erro: " .. tostring(Window))
    return
end

-- Evita que a falha de um único elemento interrompa a criação
-- das abas e deixe a janela aberta, porém sem botões.
local function wrapRayfieldTab(tab, tabName)
    return setmetatable({}, {
        __index = function(_, methodName)
            local member = tab[methodName]

            if type(member) ~= "function" then
                return member
            end

            return function(_, ...)
                local arguments = table.pack(...)

                local success, result = xpcall(function()
                    return member(
                        tab,
                        table.unpack(arguments, 1, arguments.n)
                    )
                end, debug.traceback)

                if not success then
                    registerError(
                        string.format(
                            "Falha ao criar elemento em %s (%s): %s",
                            tostring(tabName),
                            tostring(methodName),
                            tostring(result)
                        )
                    )

                    warn(
                        "[NinMod | Rayfield | "
                            .. tostring(tabName)
                            .. "] "
                            .. tostring(result)
                    )

                    return nil
                end

                return result
            end
        end
    })
end

local function createTabSafe(tabName)
    local success, tab = xpcall(function()
        -- Ícone 0 evita incompatibilidade entre listas de ícones
        -- de builds diferentes do Rayfield.
        return Window:CreateTab(tabName, 0)
    end, debug.traceback)

    if not success or not tab then
        warn(
            "[NinMod] Falha ao criar a aba "
                .. tostring(tabName)
                .. ": "
                .. tostring(tab)
        )

        return nil
    end

    return wrapRayfieldTab(tab, tabName)
end

-- =========================================================
-- HOME TAB
-- =========================================================

local HomeTab = createTabSafe("Principal")

if not HomeTab then
    return
end

HomeTab:CreateSection("Resumo do sistema")

MainSummaryParagraph = HomeTab:CreateParagraph({
    Title = "NinMod iniciado",
    Content = "Carregando informações do sistema."
})

MainActivityParagraph = HomeTab:CreateParagraph({
    Title = "Atividade atual",
    Content = processStats.lastAction
})

HomeTab:CreateSection("Ações rápidas")

HomeTab:CreateButton({
    Name = "Iniciar farm",

    Callback = function()
        if farming then
            notify(
                "Farm",
                "O farm já está ativo.",
                3
            )

            return
        end

        setFarmToggleSilently(true)
        startFarmSafe()
    end
})

HomeTab:CreateButton({
    Name = "Parar farm",

    Callback = function()
        setFarmToggleSilently(false)
        stopFarmSafe(true)
    end
})

HomeTab:CreateButton({
    Name = "Atualizar informações",

    Callback = function()
        updateProcessPanels(true)

        notify(
            "Processos",
            "As informações foram atualizadas.",
            3
        )
    end
})

-- =========================================================
-- FARM TAB
-- =========================================================

local FarmTab = createTabSafe("Farm")

if not FarmTab then
    return
end

FarmTab:CreateSection("AFK Gold Farm")

StatusParagraph = FarmTab:CreateParagraph({
    Title = "Status: farm desligado",
    Content = "O farm está parado."
})

StageParagraph = FarmTab:CreateParagraph({
    Title = "Estágio atual",
    Content = "Aguardando o farm ser iniciado."
})

DurationParagraph = FarmTab:CreateParagraph({
    Title = "Tempo configurado",
    Content = string.format(
        "%.2f segundo por estágio.",
        STAGE_DURATION
    )
})

FarmToggle = FarmTab:CreateToggle({
    Name = "Ativar AFK Gold Farm",
    CurrentValue = false,
    Flag = "NinModGoldFarm",

    Callback = function(value)
        if suppressToggleCallback then
            return
        end

        if value then
            startFarmSafe()
        else
            stopFarmSafe(true)
        end
    end
})

FarmTab:CreateSlider({
    Name = "Tempo por estágio",
    Range = {0.30, 5},
    Increment = 0.05,
    Suffix = " s",
    CurrentValue = STAGE_DURATION,
    Flag = "NinModStageDuration",

    Callback = function(value)
        STAGE_DURATION = math.clamp(
            tonumber(value) or 0.35,
            0.30,
            5
        )

        updateDurationStatus()

        markAction(
            string.format(
                "Tempo por estágio alterado para %.2fs.",
                STAGE_DURATION
            )
        )

        if farming then
            updateStatus(
                "Status: farm ativo",
                string.format(
                    "Executando %d estágios com %.2f segundo por estágio.",
                    MAX_STAGES,
                    STAGE_DURATION
                ),
                true
            )
        end

        updateProcessPanels(true)
    end
})

FarmTab:CreateParagraph({
    Title = "Velocidade recomendada",
    Content = "Use entre 0,35 e 0,50 segundo para preservar a estabilidade."
})

FarmTab:CreateButton({
    Name = "Parar farm com segurança",

    Callback = function()
        setFarmToggleSilently(false)
        stopFarmSafe(true)
    end
})

-- =========================================================
-- PROCESSES TAB
-- =========================================================

local ProcessesTab = createTabSafe("Processos")

if not ProcessesTab then
    return
end

ProcessesTab:CreateSection("Execução atual")

ProcessGeneralParagraph =
    ProcessesTab:CreateParagraph({
        Title = "Estado geral",
        Content = "Carregando estado."
    })

ProcessCountersParagraph =
    ProcessesTab:CreateParagraph({
        Title = "Contadores",
        Content = "Carregando contadores."
    })

ProcessesTab:CreateSection("Desempenho")

ProcessPerformanceParagraph =
    ProcessesTab:CreateParagraph({
        Title = "Desempenho",
        Content = "Calculando desempenho."
    })

ProcessesTab:CreateSection("Caches")

ProcessCacheParagraph =
    ProcessesTab:CreateParagraph({
        Title = "Estado dos caches",
        Content = "Verificando caches."
    })

ProcessesTab:CreateSection("Diagnóstico")

ProcessEventParagraph =
    ProcessesTab:CreateParagraph({
        Title = "Último processo",
        Content = processStats.lastAction
    })

ProcessErrorParagraph =
    ProcessesTab:CreateParagraph({
        Title = "Último erro",
        Content = processStats.lastError
    })

ProcessesTab:CreateSection("Controle do monitor")

ProcessSettingsParagraph =
    ProcessesTab:CreateParagraph({
        Title = "Monitor de processos",
        Content = "Atualização automática ativa."
    })

ProcessesTab:CreateToggle({
    Name = "Atualização automática",
    CurrentValue = PROCESS_UPDATES_ENABLED,
    Flag = "NinModProcessUpdates",

    Callback = function(value)
        PROCESS_UPDATES_ENABLED = value

        markAction(
            value
                and "Monitor automático ativado."
                or "Monitor automático pausado."
        )

        setParagraph(
            ProcessSettingsParagraph,
            "Monitor de processos",
            value
                and string.format(
                    "Atualização automática a cada %.2fs.",
                    PROCESS_UPDATE_INTERVAL
                )
                or "Atualização automática pausada."
        )

        updateProcessPanels(true)
    end
})

ProcessesTab:CreateSlider({
    Name = "Intervalo do monitor",
    Range = {0.25, 2},
    Increment = 0.25,
    Suffix = " s",
    CurrentValue = PROCESS_UPDATE_INTERVAL,
    Flag = "NinModProcessInterval",

    Callback = function(value)
        PROCESS_UPDATE_INTERVAL = math.clamp(
            tonumber(value) or 0.5,
            0.25,
            2
        )

        setParagraph(
            ProcessSettingsParagraph,
            "Monitor de processos",
            string.format(
                "Atualização automática a cada %.2fs.",
                PROCESS_UPDATE_INTERVAL
            )
        )
    end
})

ProcessesTab:CreateButton({
    Name = "Atualizar agora",

    Callback = function()
        updateProcessPanels(true)

        notify(
            "Processos",
            "Diagnóstico atualizado.",
            3
        )
    end
})

ProcessesTab:CreateButton({
    Name = "Zerar contadores",

    Callback = function()
        local scriptStartedAt =
            processStats.scriptStartedAt

        local farmStartedAt =
            processStats.farmStartedAt

        processStats.currentStage = 0
        processStats.currentCycle = 0

        processStats.completedStages = 0
        processStats.completedCycles = 0

        processStats.teleports = 0
        processStats.collectionPasses = 0

        processStats.touchAttempts = 0
        processStats.clickAttempts = 0
        processStats.rewardRequests = 0

        processStats.respawns = 0
        processStats.manualResets = 0

        processStats.errors = 0

        processStats.lastCycleTime = 0
        processStats.totalCycleTime = 0

        processStats.stageCacheBuilds = 0
        processStats.collectibleCacheBuilds = 0

        processStats.scriptStartedAt =
            scriptStartedAt

        processStats.farmStartedAt =
            farmStartedAt

        processStats.lastAction =
            "Contadores zerados."

        processStats.lastError =
            "Nenhum erro registrado."

        updateProcessPanels(true)

        notify(
            "Processos",
            "Os contadores foram zerados.",
            3
        )
    end
})

ProcessesTab:CreateButton({
    Name = "Reconstruir todos os caches",

    Callback = function()
        buildStageCache()
        buildCollectibleCache()

        updateProcessPanels(true)

        notify(
            "Caches",
            "Todos os caches foram reconstruídos.",
            4
        )
    end
})

-- =========================================================
-- CHARACTER TAB
-- =========================================================

local CharacterTab = createTabSafe("Personagem")

if not CharacterTab then
    return
end

CharacterTab:CreateSection("Recuperação")

CharacterTab:CreateButton({
    Name = "Corrigir respawn",

    Callback = function()
        fixSpawn()
    end
})

CharacterTab:CreateButton({
    Name = "Reiniciar personagem",

    Callback = function()
        local success = resetCharacter()

        if success then
            notify(
                "Personagem",
                "O personagem foi reiniciado.",
                4
            )
        else
            notify(
                "Personagem",
                "Não foi possível reiniciar o personagem.",
                4
            )
        end
    end
})

CharacterTab:CreateButton({
    Name = "Restaurar gravidade",

    Callback = function()
        workspace.Gravity = originalGravity
        markAction("Gravidade original restaurada.")

        notify(
            "Gravidade",
            "A gravidade original foi restaurada.",
            4
        )

        updateProcessPanels(true)
    end
})

CharacterTab:CreateSection("Configurações")

CharacterTab:CreateToggle({
    Name = "God Mode durante o farm",
    CurrentValue = GOD_MODE_ENABLED,
    Flag = "NinModGodMode",

    Callback = function(value)
        GOD_MODE_ENABLED = value

        if value and farming then
            applyGodMode(player.Character)
        end

        markAction(
            value
                and "God Mode ativado."
                or "God Mode desativado."
        )

        notify(
            "God Mode",
            value
                and "God Mode ativado."
                or "God Mode desativado.",
            3
        )

        updateProcessPanels(true)
    end
})

-- =========================================================
-- SETTINGS TAB
-- =========================================================

local SettingsTab = createTabSafe("Configurações")

if not SettingsTab then
    return
end

SettingsTab:CreateSection("Aparência")

CurrentThemeParagraph =
    SettingsTab:CreateParagraph({
        Title = "Tema atual",
        Content = currentThemeName
    })

local themeIdentifiers = {
    ["Padrão"] = "Default",
    ["Âmbar"] = "AmberGlow",
    ["Ametista"] = "Amethyst",
    ["Bloom"] = "Bloom",
    ["Azul-escuro"] = "DarkBlue",
    ["Verde"] = "Green",
    ["Claro"] = "Light",
    ["Oceano"] = "Ocean",
    ["Serenidade"] = "Serenity"
}

SettingsTab:CreateDropdown({
    Name = "Tema da janela",

    Options = {
        "Padrão",
        "Âmbar",
        "Ametista",
        "Bloom",
        "Azul-escuro",
        "Verde",
        "Claro",
        "Oceano",
        "Serenidade"
    },

    CurrentOption = {
        "Padrão"
    },

    MultipleOptions = false,
    Flag = "NinModTheme",

    Callback = function(options)
        local selectedTheme

        if type(options) == "table" then
            selectedTheme = options[1]
        else
            selectedTheme = options
        end

        selectedTheme =
            selectedTheme or "Padrão"

        local identifier =
            themeIdentifiers[selectedTheme]
            or "Default"

        local success, errorMessage =
            pcall(function()
                Window.ModifyTheme(identifier)
            end)

        if not success then
            success, errorMessage =
                pcall(function()
                    Window:ModifyTheme(identifier)
                end)
        end

        if success then
            currentThemeName = selectedTheme

            setParagraph(
                CurrentThemeParagraph,
                "Tema atual",
                currentThemeName
            )

            markAction(
                "Tema alterado para "
                .. currentThemeName
                .. "."
            )

            notify(
                "Tema alterado",
                "Tema aplicado: "
                .. currentThemeName,
                3
            )
        else
            registerError(
                "Falha ao aplicar tema: "
                .. tostring(errorMessage)
            )

            notify(
                "Tema",
                "Não foi possível aplicar o tema.",
                4
            )
        end

        updateProcessPanels(true)
    end
})

SettingsTab:CreateButton({
    Name = "Restaurar tema padrão",

    Callback = function()
        local success = pcall(function()
            Window.ModifyTheme("Default")
        end)

        if not success then
            success = pcall(function()
                Window:ModifyTheme("Default")
            end)
        end

        if success then
            currentThemeName = "Padrão"

            setParagraph(
                CurrentThemeParagraph,
                "Tema atual",
                currentThemeName
            )

            markAction("Tema padrão restaurado.")

            notify(
                "Tema",
                "Tema padrão restaurado.",
                3
            )
        end

        updateProcessPanels(true)
    end
})

SettingsTab:CreateSection("Interface")

SettingsTab:CreateToggle({
    Name = "Exibir notificações",
    CurrentValue = NOTIFICATIONS_ENABLED,
    Flag = "NinModNotifications",

    Callback = function(value)
        NOTIFICATIONS_ENABLED = value

        markAction(
            value
                and "Notificações ativadas."
                or "Notificações desativadas."
        )

        updateProcessPanels(true)
    end
})

SettingsTab:CreateParagraph({
    Title = "Abrir ou ocultar",
    Content = "Pressione G no computador. No celular, use o botão NinMod."
})

SettingsTab:CreateParagraph({
    Title = "Versão",
    Content = "NinMod Boat Admin — Rayfield 1.3 Process"
})

SettingsTab:CreateSection("Manutenção")

SettingsTab:CreateButton({
    Name = "Atualizar cache dos estágios",

    Callback = function()
        buildStageCache()
        updateProcessPanels(true)

        notify(
            "Cache atualizado",
            "Os estágios foram localizados novamente.",
            4
        )
    end
})

SettingsTab:CreateButton({
    Name = "Atualizar cache dos coletáveis",

    Callback = function()
        buildCollectibleCache()
        updateProcessPanels(true)

        notify(
            "Cache atualizado",
            "Os coletáveis foram localizados novamente.",
            4
        )
    end
})

SettingsTab:CreateButton({
    Name = "Testar notificação",

    Callback = function()
        Rayfield:Notify({
            Title = "NinMod",
            Content = "A interface está funcionando.",
            Duration = 4,
            Image = 0
        })
    end
})

SettingsTab:CreateButton({
    Name = "Destruir interface",

    Callback = function()
        destroyingInterface = true

        stopFarmSafe(false)
        workspace.Gravity = originalGravity

        if collectibleAddedConnection then
            collectibleAddedConnection:Disconnect()
            collectibleAddedConnection = nil
        end

        if collectibleRemovingConnection then
            collectibleRemovingConnection:Disconnect()
            collectibleRemovingConnection = nil
        end

        if characterAddedConnection then
            characterAddedConnection:Disconnect()
            characterAddedConnection = nil
        end

        if fpsConnection then
            fpsConnection:Disconnect()
            fpsConnection = nil
        end

        table.clear(stageCache)
        table.clear(goldPartCache)
        table.clear(clickDetectorCache)

        table.clear(invalidGoldParts)
        table.clear(invalidClickDetectors)

        pcall(function()
            Rayfield:Destroy()
        end)
    end
})

-- =========================================================
-- PROCESS PANEL UPDATER
-- =========================================================

updateProcessPanels = function(forceUpdate)
    if destroyingInterface then
        return
    end

    if not PROCESS_UPDATES_ENABLED
        and not forceUpdate then

        return
    end

    local now = os.clock()

    local scriptUptime =
        now - processStats.scriptStartedAt

    local farmUptime = 0

    if farming and processStats.farmStartedAt then
        farmUptime =
            now - processStats.farmStartedAt
    end

    local farmState =
        farming and "ATIVO" or "DESLIGADO"

    local loopState =
        farmLoopRunning and "Executando" or "Parado"

    local currentStageText =
        processStats.currentStage > 0
            and string.format(
                "%d/%d",
                processStats.currentStage,
                MAX_STAGES
            )
            or "Nenhum"

    setParagraph(
        MainSummaryParagraph,
        "NinMod | " .. farmState,
        string.format(
            "Ciclo: %d\n"
                .. "Estágio: %s\n"
                .. "Farm ativo por: %s\n"
                .. "FPS: %d | Ping: %s",
            processStats.currentCycle,
            currentStageText,
            formatDuration(farmUptime),
            currentFPS,
            getPingText()
        )
    )

    setParagraph(
        MainActivityParagraph,
        "Atividade atual",
        processStats.lastAction
    )

    setParagraph(
        ProcessGeneralParagraph,
        "Estado geral",
        string.format(
            "Farm: %s\n"
                .. "Loop: %s\n"
                .. "Ciclo atual: %d\n"
                .. "Estágio atual: %s\n"
                .. "Tempo do script: %s\n"
                .. "Tempo do farm: %s",
            farmState,
            loopState,
            processStats.currentCycle,
            currentStageText,
            formatDuration(scriptUptime),
            formatDuration(farmUptime)
        )
    )

    setParagraph(
        ProcessCountersParagraph,
        "Contadores",
        string.format(
            "Estágios concluídos: %d\n"
                .. "Ciclos concluídos: %d\n"
                .. "Teleportes: %d\n"
                .. "Passagens de coleta: %d\n"
                .. "Tentativas de toque: %d\n"
                .. "Tentativas de clique: %d\n"
                .. "Solicitações de recompensa: %d\n"
                .. "Respawns detectados: %d\n"
                .. "Reinícios manuais: %d",
            processStats.completedStages,
            processStats.completedCycles,
            processStats.teleports,
            processStats.collectionPasses,
            processStats.touchAttempts,
            processStats.clickAttempts,
            processStats.rewardRequests,
            processStats.respawns,
            processStats.manualResets
        )
    )

    setParagraph(
        ProcessPerformanceParagraph,
        "Desempenho",
        string.format(
            "FPS: %d\n"
                .. "Ping: %s\n"
                .. "Tempo por estágio: %.2fs\n"
                .. "Último ciclo: %s\n"
                .. "Média dos ciclos: %s\n"
                .. "Monitor: %.2fs",
            currentFPS,
            getPingText(),
            STAGE_DURATION,
            formatDuration(
                processStats.lastCycleTime
            ),
            formatDuration(
                getAverageCycleTime()
            ),
            PROCESS_UPDATE_INTERVAL
        )
    )

    setParagraph(
        ProcessCacheParagraph,
        "Estado dos caches",
        string.format(
            "Estágios encontrados: %d/%d\n"
                .. "Partes de ouro: %d\n"
                .. "Detectores de clique: %d\n"
                .. "Atualizações dos estágios: %d\n"
                .. "Atualizações dos coletáveis: %d",
            countValidStages(),
            MAX_STAGES,
            countDictionary(goldPartCache),
            countDictionary(clickDetectorCache),
            processStats.stageCacheBuilds,
            processStats.collectibleCacheBuilds
        )
    )

    setParagraph(
        ProcessEventParagraph,
        "Último processo",
        processStats.lastAction
    )

    setParagraph(
        ProcessErrorParagraph,
        "Último erro | Total: "
            .. tostring(processStats.errors),
        processStats.lastError
    )
end

-- =========================================================
-- FPS MONITOR
-- =========================================================

fpsConnection =
    RunService.RenderStepped:Connect(function()
        frameCounter += 1

        local now = os.clock()
        local elapsed =
            now - frameWindowStartedAt

        if elapsed >= 1 then
            currentFPS = math.floor(
                frameCounter / elapsed + 0.5
            )

            frameCounter = 0
            frameWindowStartedAt = now
        end
    end)

-- =========================================================
-- PROCESS MONITOR LOOP
-- =========================================================

task.spawn(function()
    while not destroyingInterface do
        if PROCESS_UPDATES_ENABLED then
            updateProcessPanels(false)
        end

        task.wait(PROCESS_UPDATE_INTERVAL)
    end
end)

-- =========================================================
-- WORKSPACE CONNECTIONS
-- =========================================================

collectibleAddedConnection =
    workspace.DescendantAdded:Connect(
        function(object)
            registerCollectible(object)

            if object.Name == "DarknessPart" then
                local parent = object.Parent

                if parent then
                    local stageNumber =
                        tonumber(
                            string.match(
                                parent.Name,
                                "^CaveStage(%d+)$"
                            )
                        )

                    if stageNumber
                        and stageNumber >= 1
                        and stageNumber <= MAX_STAGES then

                        stageCache[stageNumber] = object
                    end
                end
            end
        end
    )

collectibleRemovingConnection =
    workspace.DescendantRemoving:Connect(
        function(object)
            unregisterCollectible(object)

            for stageNumber = 1, MAX_STAGES do
                if stageCache[stageNumber] == object then
                    stageCache[stageNumber] = nil
                    break
                end
            end
        end
    )

-- =========================================================
-- CHARACTER RESPAWN
-- =========================================================

characterAddedConnection =
    player.CharacterAdded:Connect(
        function(character)
            processStats.respawns += 1

            markAction(
                "Novo personagem detectado."
            )

            if updateProcessPanels then
                updateProcessPanels(true)
            end

            if not farming then
                return
            end

            local generation =
                farmGeneration

            task.spawn(function()
                local humanoid =
                    character:WaitForChild(
                        "Humanoid",
                        10
                    )

                local humanoidRootPart =
                    character:WaitForChild(
                        "HumanoidRootPart",
                        10
                    )

                if not isCurrentFarm(generation) then
                    return
                end

                if humanoid and humanoidRootPart then
                    workspace.Gravity = LOW_GRAVITY
                    applyGodMode(character)
                end
            end)
        end
    )

-- =========================================================
-- INITIALIZATION
-- =========================================================

updateDurationStatus()
updateProcessPanels(true)

markAction("Interface Rayfield carregada com todos os controles.")
updateProcessPanels(true)

notify(
    "NinMod carregado",
    "Painel e controles do Rayfield ativados.",
    5
)
