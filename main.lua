-- ============================================================================
-- The Binding of Isaac: Repentance / Repentance+
-- Мод: Co-op Double Treasure Room Items
-- Опис: 
-- 1. У звичайних кімнатах скарбів спавнить 2 незалежні предмети замість 1.
-- 2. В альтернативних кімнатах (Downpour, Mines, Mausoleum) створює для
--    ОБОХ гравців по власній парі [1 звичайний + 1 прихований ?], серед яких
--    кожен гравець робить свій незалежний вибір!
-- ============================================================================

local Mod = RegisterMod("CoopDoubleTreasure", 1)

-- ============================================================================
-- Налаштування моду (Конфігурація)
-- ============================================================================
Mod.Config = {
    -- Режим активації:
    -- "CoopOnly"  - працює тільки коли в грі 2+ гравці (локальний кооп або онлайн).
    -- "Always"    - працює завжди (навіть у соло-грі, зручно для тестування).
    Mode = "Always",

    -- Обробка альтернативних кімнат (Alt-Path choice rooms):
    -- Якщо true: створює 2 окремі пари (по 1 відкритому і 1 прихованому ? для кожного гравця).
    -- Кожен гравець вибирає зі своєї пари, і взяття не ламає вибір іншого гравця!
    AltPathDualChoice = true,

    -- Зміщення пар на альтернативних поверхах (у пікселях):
    -- AltPairXOffset: відстань між парою Гравця 1 (ліворуч) та парою Гравця 2 (праворуч)
    -- AltPairYOffset: відстань між відкритим та прихованим предметом усередині пари
    AltPairXOffset = 80,
    AltPairYOffset = 50,

    -- Відстань зміщення між предметами у звичайній кімнаті скарбів (у пікселях)
    NormalPedestalOffset = 50,

    -- Спавнити візуальний ефект "диму" (Poof) та звук появи при створенні нових п'єдесталів
    SpawnPoofEffect = true,
}

-- Таблиця для відстеження кімнат, де вже були згенеровані предмети,
-- щоб уникнути повторного спавну при переході туди й назад.
Mod.ProcessedRooms = {}

-- ============================================================================
-- Допоміжні функції логування
-- ============================================================================
local function Log(message)
    local text = string.format("[CoopDoubleTreasure] %s", tostring(message))
    print(text)             -- Консоль розробника (клавіша `~`)
    Isaac.DebugString(text) -- Системний log.txt гри
end

-- ============================================================================
-- Підрахунок активних гравців
-- ============================================================================
local function GetActivePlayerCount()
    local game = Game()
    local total = game:GetNumPlayers()
    local count = 0

    for i = 0, total - 1 do
        local player = Isaac.GetPlayer(i)
        if player then
            count = count + 1
        end
    end

    return count
end

-- ============================================================================
-- Приховування предмета (ефект знака питання `?`)
-- ============================================================================
local function MakePedestalBlind(pedestal)
    if not pedestal then return end

    -- 1. Для рушія REPENTOGON (якщо встановлено):
    if pedestal.SetForceBlind then
        pedestal:SetForceBlind(true)
    end

    -- 2. Для ванільного API Repentance / Repentance+:
    -- Замінюємо шар 1 (графіку артефакту) у файлі 005.100_collectible на знак питання
    local sprite = pedestal:GetSprite()
    if sprite then
        sprite:ReplaceSpritesheet(1, "gfx/items/collectibles/questionmark.png")
        sprite:LoadGraphics()
        sprite:SetFrame("Idle", 0)
    end

    local data = pedestal:GetData()
    data.IsModBlindItem = true

    -- 3. Ховаємо справжній SubType від зовнішніх модів (EID тощо):
    --    Зберігаємо реальний ID і замінюємо на COLLECTIBLE_NULL (0),
    --    щоб EID не міг показати назву предмету.
    if data.RealSubType == nil then
        data.RealSubType = pedestal.SubType
        pedestal.SubType = CollectibleType.COLLECTIBLE_NULL
    end
end

-- ============================================================================
-- Відновлення прихованого SubType при підбиранні
-- (запускається кожен кадр для кожного pickup у кімнаті)
-- ============================================================================
function Mod:OnPickupUpdate(pickup)
    if pickup.Variant ~= PickupVariant.PICKUP_COLLECTIBLE then return end

    local data = pickup:GetData()
    if not data.IsModBlindItem then return end
    if data.RealSubType == nil then return end

    -- Якщо гравець торкнувся п'єдесталу — відновлюємо справжній предмет
    -- (прапорець Touched стає true за 1 кадр до того, як гравець підбере предмет)
    if pickup.Touched then
        pickup.SubType = data.RealSubType
        data.RealSubType = nil
        data.IsModBlindItem = nil
        Log(string.format("Blind pedestal touched — відновлено SubType: %d", pickup.SubType))
    end
end
Mod:AddCallback(ModCallbacks.MC_POST_PICKUP_UPDATE, Mod.OnPickupUpdate)

-- ============================================================================
-- Скидання кешу кімнат
-- ============================================================================
function Mod:OnGameStarted(isContinued)
    Mod.ProcessedRooms = {}
    local playerCount = GetActivePlayerCount()
    Log(string.format("Гру запущено! (Продовження: %s, Гравців: %d, Режим: %s)",
        tostring(isContinued), playerCount, Mod.Config.Mode))
end
Mod:AddCallback(ModCallbacks.MC_POST_GAME_STARTED, Mod.OnGameStarted)

function Mod:OnNewLevel()
    Mod.ProcessedRooms = {}
end
Mod:AddCallback(ModCallbacks.MC_POST_NEW_LEVEL, Mod.OnNewLevel)

-- ============================================================================
-- Головна логіка: Обробка входу в нову кімнату скарбів
-- ============================================================================
function Mod:OnNewRoom()
    local game = Game()
    local room = game:GetRoom()

    -- 1. Перевіряємо, чи це кімната скарбів
    if room:GetType() ~= RoomType.ROOM_TREASURE then
        return
    end

    -- 2. Перевіряємо, чи це перший візит
    if not room:IsFirstVisit() then
        return
    end

    -- 3. Перевіряємо унікальний індекс поточної кімнати на поверсі
    local level = game:GetLevel()
    local roomIndex = level:GetCurrentRoomIndex()
    if Mod.ProcessedRooms[roomIndex] then
        return
    end

    -- 4. Перевіряємо умову коопу / режиму
    local playerCount = GetActivePlayerCount()
    local isCoop = playerCount >= 2

    if Mod.Config.Mode == "CoopOnly" and not isCoop then
        return
    end

    -- Знаходимо всі наявні п'єдестали в кімнаті
    local entities = Isaac.FindByType(EntityType.ENTITY_PICKUP, PickupVariant.PICKUP_COLLECTIBLE, -1, false, false)
    local currentCount = #entities
    local centerPos = room:GetCenterPos()
    local itemPool = game:GetItemPool()
    local seed = room:GetSpawnSeed()

    -- ========================================================================
    -- СЦЕНАРІЙ А: Кімнати з 3 предметами (Alt-Path з артефактом "More Options")
    -- Створюємо два окремі ряди вибору (по 3 предмети для кожного гравця):
    -- Верхній ряд (Гравець 1): [Відкритий] [?] [Відкритий] (OptionsPickupIndex = 1)
    -- Нижній ряд (Гравець 2): [Відкритий] [?] [Відкритий] (OptionsPickupIndex = 2)
    -- ========================================================================
    if currentCount == 3 then
        local p1 = entities[1]:ToPickup()
        local p2 = entities[2]:ToPickup()
        local p3 = entities[3]:ToPickup()

        local topY = centerPos.Y - 55
        local botY = centerPos.Y + 55
        local xStep = 80
        local xCoords = { centerPos.X - xStep, centerPos.X, centerPos.X + xStep }

        -- 1. Переміщуємо наявні 3 предмети у верхній ряд (для Гравця 1)
        if p1 then
            p1.Position = room:FindFreePickupSpawnPosition(Vector(xCoords[1], topY), 0, true, false)
            p1.OptionsPickupIndex = 1
        end
        if p2 then
            p2.Position = room:FindFreePickupSpawnPosition(Vector(xCoords[2], topY), 0, true, false)
            p2.OptionsPickupIndex = 1
            -- Середній предмет у верхньому ряду - знак питання ?
            MakePedestalBlind(p2)
        end
        if p3 then
            p3.Position = room:FindFreePickupSpawnPosition(Vector(xCoords[3], topY), 0, true, false)
            p3.OptionsPickupIndex = 1
        end

        -- 2. Створюємо нові 3 предмети в нижньому ряду (для Гравця 2)
        -- Лівий відкритий предмет:
        local idBot1 = itemPool:GetCollectible(ItemPoolType.POOL_TREASURE, true, seed + 1)
        local posBot1 = room:FindFreePickupSpawnPosition(Vector(xCoords[1], botY), 0, true, false)
        local bot1 = game:Spawn(EntityType.ENTITY_PICKUP, PickupVariant.PICKUP_COLLECTIBLE, posBot1, Vector(0,0), nil, idBot1, seed + 1):ToPickup()
        if bot1 then bot1.OptionsPickupIndex = 2 end

        -- Середній прихований предмет (знак питання ?):
        local idBot2 = itemPool:GetCollectible(ItemPoolType.POOL_TREASURE, true, seed + 2)
        local posBot2 = room:FindFreePickupSpawnPosition(Vector(xCoords[2], botY), 0, true, false)
        local bot2 = game:Spawn(EntityType.ENTITY_PICKUP, PickupVariant.PICKUP_COLLECTIBLE, posBot2, Vector(0,0), nil, idBot2, seed + 2):ToPickup()
        if bot2 then
            bot2.OptionsPickupIndex = 2
            MakePedestalBlind(bot2)
        end

        -- Правий відкритий предмет:
        local idBot3 = itemPool:GetCollectible(ItemPoolType.POOL_TREASURE, true, seed + 3)
        local posBot3 = room:FindFreePickupSpawnPosition(Vector(xCoords[3], botY), 0, true, false)
        local bot3 = game:Spawn(EntityType.ENTITY_PICKUP, PickupVariant.PICKUP_COLLECTIBLE, posBot3, Vector(0,0), nil, idBot3, seed + 3):ToPickup()
        if bot3 then bot3.OptionsPickupIndex = 2 end

        -- Ефекти появи для нижнього ряду
        if Mod.Config.SpawnPoofEffect then
            Isaac.Spawn(EntityType.ENTITY_EFFECT, EffectVariant.POOF01, 0, posBot1, Vector(0,0), nil)
            Isaac.Spawn(EntityType.ENTITY_EFFECT, EffectVariant.POOF01, 0, posBot2, Vector(0,0), nil)
            Isaac.Spawn(EntityType.ENTITY_EFFECT, EffectVariant.POOF01, 0, posBot3, Vector(0,0), nil)
            local sfx = SFXManager()
            sfx:Play(SoundEffect.SOUND_SUMMONPOOF, 0.8, 0, false, 1.0)
        end

        Log("Alt-Path + More Options: Створено 2 ряди вибору (по 3 предмети для кожного гравця, середній - ?)")
        Mod.ProcessedRooms[roomIndex] = true
        return
    end

    -- Якщо якимось чином у кімнаті вже 4+ предметів:
    if currentCount >= 4 then
        for _, ent in ipairs(entities) do
            local p = ent:ToPickup()
            if p then p.OptionsPickupIndex = 0 end
        end
        Mod.ProcessedRooms[roomIndex] = true
        return
    end

    -- ========================================================================
    -- СЦЕНАРІЙ Б: Стандартна альтернативна кімната вибору (Alt-Path Choice Room, 2 предмети)
    -- У кімнаті згенеровано 2 предмети з механікою вибору (OptionsPickupIndex > 0)
    -- ========================================================================
    -- Alt-path choice кімнати існують лише на Downpour/Mines/Mausoleum поверхах
    -- (StageType REPENTANCE або REPENTANCE_B). "More Options" на звичайних поверхах
    -- теж дає 2 предмети з OptionsPickupIndex > 0, але це НЕ alt-path кімната.
    local stageType = level:GetStageType()
    local isAltPathFloor = (stageType == StageType.STAGETYPE_REPENTANCE or
                            stageType == StageType.STAGETYPE_REPENTANCE_B)

    local isAltChoiceRoom = isAltPathFloor and (currentCount == 2) and (
        (entities[1]:ToPickup() and entities[1]:ToPickup().OptionsPickupIndex > 0) or
        (entities[2]:ToPickup() and entities[2]:ToPickup().OptionsPickupIndex > 0)
    )

    if isAltChoiceRoom and Mod.Config.AltPathDualChoice then
        local p1A = entities[1]:ToPickup()
        local p1B = entities[2]:ToPickup()

        -- Позиції для Пари 1 (Гравець 1 - Ліва сторона кімнати):
        -- Верхній та нижній предмет ліворуч від центру
        local pos1A = room:FindFreePickupSpawnPosition(
            centerPos + Vector(-Mod.Config.AltPairXOffset, -Mod.Config.AltPairYOffset),
            0, true, false
        )
        local pos1B = room:FindFreePickupSpawnPosition(
            centerPos + Vector(-Mod.Config.AltPairXOffset, Mod.Config.AltPairYOffset),
            0, true, false
        )

        -- Переміщуємо наявну пару 1 на ліву сторону
        local p1AIsBlind = (p1A and p1A.IsBlind and p1A:IsBlind())
        local p1BIsBlind = (p1B and p1B.IsBlind and p1B:IsBlind())

        if p1A then
            p1A.Position = pos1A
            p1A.OptionsPickupIndex = 1
        end
        if p1B then
            p1B.Position = pos1B
            p1B.OptionsPickupIndex = 1
        end

        -- Гарантуємо, що в Парі 1 рівно один предмет є прихованим:
        if p1AIsBlind then
            MakePedestalBlind(p1A)
        else
            -- Якщо p1A не прихований, робимо нижній предмет p1B знаком питання
            MakePedestalBlind(p1B)
        end

        -- Позиції для Пари 2 (Гравець 2 - Права сторона кімнати):
        local pos2A = room:FindFreePickupSpawnPosition(
            centerPos + Vector(Mod.Config.AltPairXOffset, -Mod.Config.AltPairYOffset),
            0, true, false
        )
        local pos2B = room:FindFreePickupSpawnPosition(
            centerPos + Vector(Mod.Config.AltPairXOffset, Mod.Config.AltPairYOffset),
            0, true, false
        )

        -- Створюємо ПАРУ 2 для Гравця 2:
        -- 1. Новий відкритий предмет (Visible 2)
        local idVisible2 = itemPool:GetCollectible(ItemPoolType.POOL_TREASURE, true, seed + 1)
        local spawnedVisible2 = game:Spawn(
            EntityType.ENTITY_PICKUP,
            PickupVariant.PICKUP_COLLECTIBLE,
            pos2A,
            Vector(0, 0),
            nil,
            idVisible2,
            seed + 1
        ):ToPickup()

        if spawnedVisible2 then
            -- Прив'язуємо до групи вибору №2
            spawnedVisible2.OptionsPickupIndex = 2
        end

        -- 2. Новий прихований предмет (Blind 2 із знаком питання `?`)
        local idBlind2 = itemPool:GetCollectible(ItemPoolType.POOL_TREASURE, true, seed + 2)
        local spawnedBlind2 = game:Spawn(
            EntityType.ENTITY_PICKUP,
            PickupVariant.PICKUP_COLLECTIBLE,
            pos2B,
            Vector(0, 0),
            nil,
            idBlind2,
            seed + 2
        ):ToPickup()

        if spawnedBlind2 then
            -- Прив'язуємо до тієї ж групи вибору №2
            spawnedBlind2.OptionsPickupIndex = 2
            -- Робимо предмет прихованим (знак питання `?`)
            MakePedestalBlind(spawnedBlind2)
        end

        -- Ефекти появи для нової пари
        if Mod.Config.SpawnPoofEffect then
            Isaac.Spawn(EntityType.ENTITY_EFFECT, EffectVariant.POOF01, 0, pos2A, Vector(0, 0), nil)
            Isaac.Spawn(EntityType.ENTITY_EFFECT, EffectVariant.POOF01, 0, pos2B, Vector(0, 0), nil)
            local sfx = SFXManager()
            sfx:Play(SoundEffect.SOUND_SUMMONPOOF, 0.8, 0, false, 1.0)
        end

        Log("Альтернативна кімната: Створено 2 незалежні пари вибору! (Пара 1 ліворуч для Гравця 1, Пара 2 праворуч для Гравця 2)")
        Mod.ProcessedRooms[roomIndex] = true
        return
    end

    -- ========================================================================
    -- СЦЕНАРІЙ Б: Звичайна кімната скарбів (1 предмет у ванілі)
    -- ========================================================================
    if currentCount == 1 then
        local firstPedestal = entities[1]:ToPickup()

        -- Зміщуємо перший предмет ліворуч від центру
        local leftPos = room:FindFreePickupSpawnPosition(
            centerPos - Vector(Mod.Config.NormalPedestalOffset, 0),
            0, true, false
        )
        if firstPedestal then
            firstPedestal.Position = leftPos
            firstPedestal.OptionsPickupIndex = 0 -- Робимо незалежним
        end

        -- Створюємо 2-й предмет праворуч від центру
        local rightPos = room:FindFreePickupSpawnPosition(
            centerPos + Vector(Mod.Config.NormalPedestalOffset, 0),
            0, true, false
        )

        local collectibleID = itemPool:GetCollectible(ItemPoolType.POOL_TREASURE, true, seed)
        local spawnedEntity = game:Spawn(
            EntityType.ENTITY_PICKUP,
            PickupVariant.PICKUP_COLLECTIBLE,
            rightPos,
            Vector(0, 0),
            nil,
            collectibleID,
            seed
        )

        local secondPedestal = spawnedEntity:ToPickup()
        if secondPedestal then
            secondPedestal.OptionsPickupIndex = 0 -- Робимо незалежним
        end

        -- Ефект появи
        if Mod.Config.SpawnPoofEffect then
            Isaac.Spawn(EntityType.ENTITY_EFFECT, EffectVariant.POOF01, 0, rightPos, Vector(0, 0), nil)
            local sfx = SFXManager()
            sfx:Play(SoundEffect.SOUND_SUMMONPOOF, 0.8, 0, false, 1.0)
        end

        local itemConfig = Isaac.GetItemConfig():GetCollectible(collectibleID)
        local itemName = itemConfig and itemConfig.Name or ("ID " .. tostring(collectibleID))
        Log(string.format("Звичайна кімната скарбів: додано 2-й незалежний предмет '%s' (ID: %d)", itemName, collectibleID))

    -- Якщо п'єдесталів чомусь не було взагалі:
    elseif currentCount == 0 then
        for i = 1, 2 do
            local xOffset = (i == 1) and -Mod.Config.NormalPedestalOffset or Mod.Config.NormalPedestalOffset
            local spawnPos = room:FindFreePickupSpawnPosition(
                centerPos + Vector(xOffset, 0),
                0, true, false
            )
            local collectibleID = itemPool:GetCollectible(ItemPoolType.POOL_TREASURE, true, seed + i)
            local spawnedEntity = game:Spawn(
                EntityType.ENTITY_PICKUP,
                PickupVariant.PICKUP_COLLECTIBLE,
                spawnPos,
                Vector(0, 0),
                nil,
                collectibleID,
                seed + i
            )
            local newPedestal = spawnedEntity:ToPickup()
            if newPedestal then
                newPedestal.OptionsPickupIndex = 0
            end
        end
    end

    Mod.ProcessedRooms[roomIndex] = true
end
Mod:AddCallback(ModCallbacks.MC_POST_NEW_ROOM, Mod.OnNewRoom)

Log("Мод CoopDoubleTreasure успішно завантажено!")
