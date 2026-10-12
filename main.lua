-- ============================================================================
-- The Binding of Isaac: Repentance / Repentance+
-- Мод: Co-op Double Treasure Room Items
-- Опис: у кімнаті скарбів Гравець 2 отримує власну копію того, що згенерувала гра:
--   * звичайна кімната (1 предмет)       -> ще 1 незалежний предмет;
--   * More Options / альтернативний поверх -> ще одна окрема група вибору
--     (на альт. поверсі один предмет у ній прихований під "?").
-- Ряд гри (Гравець 1) зсувається вгору, ряд-копія (Гравець 2) з'являється знизу.
-- ============================================================================

local Mod = RegisterMod("CoopDoubleTreasure", 1)

-- ============================================================================
-- Налаштування моду (Конфігурація)
-- ============================================================================
Mod.Config = {
    -- Режим активації:
    -- "CoopOnly"  - працює тільки коли в грі 2+ гравці (локальний кооп або онлайн).
    -- "Always"    - працює завжди (навіть у соло-грі, зручно для тестування).
    Mode = "CoopOnly",

    -- На скільки пікселів ряд Гравця 1 зсувається вгору, а ряд Гравця 2 - вниз
    -- від початкової позиції предметів (40 = одна клітинка).
    RowOffset = 40,
}

-- ============================================================================
-- Допоміжні функції логування
-- ============================================================================
local function Log(message)
    local text = string.format("[CoopDoubleTreasure] %s", tostring(message))
    print(text)             -- Консоль розробника (клавіша `~`)
    Isaac.DebugString(text) -- Системний log.txt гри
end

-- ============================================================================
-- Підрахунок гравців-людей
-- ============================================================================
-- Ісав і душа Т.Забутого - окремі EntityPlayer, але це той самий гравець.
local SECOND_HALVES = {
    [PlayerType.PLAYER_ESAU] = true,
    [PlayerType.PLAYER_THESOUL_B] = true,
}

local function CountPlayers()
    local count = 0
    for i = 0, Game():GetNumPlayers() - 1 do
        local player = Isaac.GetPlayer(i)
        -- Parent є у Солом'яника (Strawman) та подібних помічників
        if not player.Parent and not SECOND_HALVES[player:GetPlayerType()] then
            count = count + 1
        end
    end
    return count
end

-- ============================================================================
-- Маркер оброблених кімнат
-- ============================================================================
-- Перша копія завжди спавниться з InitSeed = MarkerSeed(кімнати). За ним мод
-- упізнає вже оброблену кімнату (не дублює повторно після Continue / Glowing
-- Hourglass) і знаходить прихований предмет, щоб повернути йому "?".
-- ponytail: гра сама зберігає InitSeed разом з кімнатою, тому SaveData не потрібен
local function MarkerSeed(room)
    return room:GetSpawnSeed() ~ 0x5EED
end

local function IsAltPathFloor()
    local stageType = Game():GetLevel():GetStageType()
    return stageType == StageType.STAGETYPE_REPENTANCE or stageType == StageType.STAGETYPE_REPENTANCE_B
end

-- ============================================================================
-- Приховування предмета (знак питання `?`)
-- ============================================================================
-- Ванільний API не вміє робити предмет "сліпим", тому міняємо лише картинку.
-- Справжній SubType лишається - предмет нормально підбирається.
-- ponytail: гра скидає спрайт при кожному вході в кімнату, тому OnNewRoom ховає його знову
local function MakePedestalBlind(pedestal)
    if pedestal.SetForceBlind then -- REPENTOGON
        pedestal:SetForceBlind(true)
    end
    local sprite = pedestal:GetSprite()
    sprite:ReplaceSpritesheet(1, "gfx/items/collectibles/questionmark.png")
    sprite:LoadGraphics()
end

function Mod:OnGameStarted(isContinued)
    Log(string.format("Гру запущено! (Продовження: %s, Гравців: %d, Режим: %s)",
        tostring(isContinued), CountPlayers(), Mod.Config.Mode))
end
Mod:AddCallback(ModCallbacks.MC_POST_GAME_STARTED, Mod.OnGameStarted)

-- ============================================================================
-- Головна логіка: вхід у кімнату скарбів
-- ============================================================================
function Mod:OnNewRoom()
    local game = Game()
    local room = game:GetRoom()
    if room:GetType() ~= RoomType.ROOM_TREASURE then return end

    local items = Isaac.FindByType(EntityType.ENTITY_PICKUP, PickupVariant.PICKUP_COLLECTIBLE)
    local marker = MarkerSeed(room)

    -- Кімнату вже оброблено: лише повертаємо "?" прихованому предмету
    for _, ent in ipairs(items) do
        if ent.InitSeed == marker then
            local pickup = ent:ToPickup()
            -- Після підбирання гра скидає OptionsPickupIndex у 0 - тоді ховати вже нічого
            if pickup.SubType ~= 0 and pickup.OptionsPickupIndex ~= 0 and IsAltPathFloor() then
                MakePedestalBlind(pickup)
            end
            return
        end
    end

    if not room:IsFirstVisit() or #items == 0 then return end
    if Mod.Config.Mode == "CoopOnly" and CountPlayers() < 2 then return end

    -- Якщо гра дала групу вибору - копія теж буде групою, але з новим індексом
    local isChoice, newIndex = false, 1
    for _, ent in ipairs(items) do
        local index = ent:ToPickup().OptionsPickupIndex
        if index > 0 then isChoice = true end
        newIndex = math.max(newIndex, index + 1)
    end
    local makeBlind = isChoice and IsAltPathFloor()

    local itemPool = game:GetItemPool()
    local pool = itemPool:GetPoolForRoom(RoomType.ROOM_TREASURE, marker)
    if pool < 0 then pool = ItemPoolType.POOL_TREASURE end

    local rng = RNG()
    rng:SetSeed(marker, 35)

    for i, ent in ipairs(items) do
        local original = ent:ToPickup()
        local pos = original.Position
        original.Position = room:FindFreePickupSpawnPosition(pos - Vector(0, Mod.Config.RowOffset), 0, true)
        local copyPos = room:FindFreePickupSpawnPosition(pos + Vector(0, Mod.Config.RowOffset), 0, true)

        local seed = (i == 1) and marker or rng:Next()
        local id = itemPool:GetCollectible(pool, true, seed)
        local copy = game:Spawn(EntityType.ENTITY_PICKUP, PickupVariant.PICKUP_COLLECTIBLE,
            copyPos, Vector(0, 0), nil, id, seed):ToPickup()
        copy.OptionsPickupIndex = isChoice and newIndex or 0
        copy.Price = original.Price -- Devil's Crown / Т.Кіпер: копія не має бути безкоштовною

        if i == 1 and makeBlind then
            MakePedestalBlind(copy)
        end
    end

    Log(string.format("Кімната скарбів: додано %d предмет(и) для Гравця 2 (вибір: %s, прихований: %s)",
        #items, tostring(isChoice), tostring(makeBlind)))
end
Mod:AddCallback(ModCallbacks.MC_POST_NEW_ROOM, Mod.OnNewRoom)

Log("Мод CoopDoubleTreasure успішно завантажено!")
