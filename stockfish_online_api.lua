local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local HttpService = game:GetService("HttpService")
local TeleportService = game:GetService("TeleportService")

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

-- Anti-AFK
local VirtualUser = game:GetService("VirtualUser")
LocalPlayer.Idled:Connect(function()
    VirtualUser:CaptureController()
    VirtualUser:ClickButton2(Vector2.new(0, 0))
end)

-- After a teleport, MatchClient expects VersusScreen to already exist.
local VersusScreen
repeat
    VersusScreen = PlayerGui:FindFirstChild("VersusScreen")
    if not VersusScreen then
        task.wait(1)
    end
until VersusScreen

local MatchClient = require((PlayerGui:WaitForChild("Client"):WaitForChild("MatchClient")) :: any)
local MenuModule = require((PlayerGui:WaitForChild("menu"):WaitForChild("menu")) :: any)
local MovePiece = ReplicatedStorage:WaitForChild("Connections"):WaitForChild("MovePiece")
local EndGame = ReplicatedStorage:WaitForChild("Connections"):WaitForChild("EndGame")
local CloseMatch = ReplicatedStorage:WaitForChild("Connections"):WaitForChild("CloseMatch")

local CHESS_API_URL = "https://chess-api.com/v1"
local CHESS_API_DEPTH = 18
local CHESS_API_MAX_THINKING_MS = 100

-- chess-api.com does not publish a numeric HIGH_USAGE quota. We do not try
-- to defeat that server-side control. Instead, when it throttles us, the
-- script temporarily stops sending requests to chess-api.com and switches to
-- a second, independent Stockfish service.
local STOCKFISH_ONLINE_URL = "https://stockfish.online/api/s/v2.php"
local STOCKFISH_ONLINE_DEPTH = 15 -- current public maximum is below 16

local API_REQUEST_GAP = 3.5
local API_MAX_REQUESTS_PER_MINUTE = 20
local API_FAILURE_BACKOFF = 5.0
local API_PRIMARY_COOLDOWN = 300
local API_ACCURACY_SAMPLE_EVERY = 3
local API_CACHE_TTL = 600
local API_CACHE_MAX_ENTRIES = 300
local CONFIG_FILE = "prometheus_stockfish_config.json"
local SERVER_LIST_LIMIT = 50
local SERVER_SCAN_PAGES = 5
local SERVER_HOP_DELAY = 0.8
local GITHUB_RAW_URL = "https://raw.githubusercontent.com/altsalts75-alt/chess/main/stockfish_online_api.lua"

local executorEnv = getgenv and getgenv() or _G
local executorSyn = type(executorEnv.syn) == "table" and executorEnv.syn or nil
local requestFunction = executorEnv.request
    or executorEnv.http_request
    or (executorSyn and executorSyn.request)
local AutoPlayState = executorEnv

-- Persist API usage state/cache through teleports. This reduces repeated
-- opening-position requests and prevents a fresh script instance from
-- immediately resetting the usage limiter.
local sharedApi = executorEnv.__CHESS_API_STATE_V4
if type(sharedApi) ~= "table" then
    sharedApi = {
        RequestTimes = {},
        Cache = {},
        NextRequestAt = 0,
        PrimaryCooldownUntil = 0,
        HighUsageUntil = 0,
        RecoveryUntil = 0,
    }
    executorEnv.__CHESS_API_STATE_V4 = sharedApi
end
sharedApi.RequestTimes = type(sharedApi.RequestTimes) == "table" and sharedApi.RequestTimes or {}
sharedApi.Cache = type(sharedApi.Cache) == "table" and sharedApi.Cache or {}
sharedApi.NextRequestAt = tonumber(sharedApi.NextRequestAt) or 0
sharedApi.PrimaryCooldownUntil = tonumber(sharedApi.PrimaryCooldownUntil) or 0
sharedApi.HighUsageUntil = tonumber(sharedApi.HighUsageUntil) or 0
sharedApi.RecoveryUntil = tonumber(sharedApi.RecoveryUntil) or 0

-- Wall-clock seconds persist correctly across Roblox teleports/new script
-- executions. `os.clock()` does not provide that guarantee.
local function apiNow()
    return os.time()
end

-- Prevent a teleport-queued execution and an executor autoexec from both
-- starting the bot in the same Roblox server. Only one instance per JobId
-- may run.
local bootGuard = executorEnv.__CHESS_BOOT_GUARD
if type(bootGuard) == "table"
    and bootGuard.Active == true
    and tostring(bootGuard.JobId) == tostring(game.JobId) then
    return
end
executorEnv.__CHESS_BOOT_GUARD = {
    Active = true,
    JobId = tostring(game.JobId),
}

local previousInstance = AutoPlayState.__CHESS_AUTOPLAYER
if previousInstance then
    pcall(function()
        if previousInstance.Destroy then
            previousInstance.Destroy()
        end
    end)
end

local oldGui = PlayerGui:FindFirstChild("ChessAutoPlayerGUI")
if oldGui then
    pcall(function() oldGui:Destroy() end)
end

local oldGui2 = PlayerGui:FindFirstChild("VitalitysHubGUI")
if oldGui2 then
    pcall(function() oldGui2:Destroy() end)
end

local config = {
    AutoPlay = false,
    AutoRanked = false,
    MenuKeyCode = "RightShift",
    XScale = 0,
    XOffset = 24,
    YScale = 0.5,
    YOffset = -155,
}

local function loadConfig()
    if type(readfile) ~= "function" or type(isfile) ~= "function" then
        return
    end

    local okExists, exists = pcall(isfile, CONFIG_FILE)
    if not okExists or not exists then
        return
    end

    local okRead, raw = pcall(readfile, CONFIG_FILE)
    if not okRead or type(raw) ~= "string" then
        return
    end

    local okDecode, saved = pcall(HttpService.JSONDecode, HttpService, raw)
    if not okDecode or type(saved) ~= "table" then
        return
    end


    if type(saved.AutoPlay) == "boolean" then
        config.AutoPlay = saved.AutoPlay
    end

    if type(saved.AutoRanked) == "boolean" then
        config.AutoRanked = saved.AutoRanked
    end

    if type(saved.MenuKeyCode) == "string" then
        local enumValue = Enum.KeyCode[saved.MenuKeyCode]
        if enumValue then
            config.MenuKeyCode = saved.MenuKeyCode
        end
    end

    if type(saved.Position) == "table" then
        if type(saved.Position.XScale) == "number" then
            config.XScale = saved.Position.XScale
        end
        if type(saved.Position.XOffset) == "number" then
            config.XOffset = saved.Position.XOffset
        end
        if type(saved.Position.YScale) == "number" then
            config.YScale = saved.Position.YScale
        end
        if type(saved.Position.YOffset) == "number" then
            config.YOffset = saved.Position.YOffset
        end
    end
end

loadConfig()

-- Keep the toggle in the executor environment too. This survives a
-- teleport re-execution even when the workspace config is not yet available.
local runtimeConfig = executorEnv.__CHESS_CONFIG
if type(runtimeConfig) == "table" then
    if type(runtimeConfig.AutoPlay) == "boolean" then
        config.AutoPlay = runtimeConfig.AutoPlay
    end

    if type(runtimeConfig.AutoRanked) == "boolean" then
        config.AutoRanked = runtimeConfig.AutoRanked
    end

    if type(runtimeConfig.MenuKeyCode) == "string" then
        local enumValue = Enum.KeyCode[runtimeConfig.MenuKeyCode]
        if enumValue then
            config.MenuKeyCode = runtimeConfig.MenuKeyCode
        end
    end
end

local function saveConfig()
    local payload = {
        AutoPlay = config.AutoPlay,
        AutoRanked = config.AutoRanked,
        MenuKeyCode = config.MenuKeyCode,
        Position = {
            XScale = config.XScale,
            XOffset = config.XOffset,
            YScale = config.YScale,
            YOffset = config.YOffset,
        },
    }

    executorEnv.__CHESS_CONFIG = {
        AutoPlay = payload.AutoPlay,
        AutoRanked = payload.AutoRanked,
        MenuKeyCode = payload.MenuKeyCode,
    }

    if type(writefile) == "function" then
        pcall(writefile, CONFIG_FILE, HttpService:JSONEncode(payload))
    end
end

-- KeepIY-style teleport persistence.
-- The script is reloaded from its GitHub raw URL after a teleport.
local teleportCheck = false

local function keepiy()
    local queue = executorEnv.queue_on_teleport
        or executorEnv.queueonteleport
        or executorEnv.queue_on_tp

    if type(queue) ~= "function" and type(executorSyn) == "table" then
        queue = executorSyn.queue_on_teleport
    end

    if type(queue) ~= "function" or type(GITHUB_RAW_URL) ~= "string" then
        return false
    end

    local queuedCode = "if not game:IsLoaded() then game.Loaded:Wait() end; loadstring(game:HttpGet(" .. string.format("%q", GITHUB_RAW_URL) .. "))()"

    local ok = pcall(queue, queuedCode)
    return ok
end

local state = {
    Enabled = config.AutoPlay,
    AutoRanked = config.AutoRanked,
    MenuKeyCode = Enum.KeyCode[config.MenuKeyCode] or Enum.KeyCode.RightShift,
    Busy = false,
    Destroyed = false,
    Recommendation = nil,
    AccuracySum = 0,
    AccuracyCount = 0,
    AccuracyGeneration = 0,
    AccuracyMoveSerial = 0,
    WhiteAccuracyMoveSerial = 0,
    BlackAccuracyMoveSerial = 0,
    LastAccuracyDisplayedSerial = 0,
    CurrentGameId = nil,
    LastSnapshot = nil,
    LastBoardKey = nil,
    AutoRankedBusy = false,
    NextRankedAttempt = 0,
    PendingPlayKey = nil,
    PendingAccuracy = nil,
    LastMoveUci = nil,
    LastEngineFen = nil,
    LastEngineResult = nil,

    -- Accuracy uses the engine result from the position BEFORE a move and
    -- one analysis of the position AFTER that move. This avoids the old
    -- searchmoves double-request method and keeps the result legal for both
    -- White and Black.
    AccuracyBaselineFen = nil,
    AccuracyBaselineResult = nil,

    -- Public API protection. These are runtime-only and never saved to the
    -- user's config, so Auto Ranked ON/OFF is unaffected.
    ApiHighUsageUntil = sharedApi.PrimaryCooldownUntil,
    ApiRequestTimes = sharedApi.RequestTimes,

    -- Ranked-cycle runtime guards. These do not alter the saved AutoRanked
    -- setting; only the user's toggle/config does that.
    RankedQueuePending = false,
    RankedQueueStartedAt = 0,
    RankedMatchActive = false,
    RankedActiveMatchId = nil,
    RankedEndHandledId = nil,
    RankedPostGame = false,
    RankedTeleporting = false,
    RankedStartupReadyAt = os.clock() + 2,

    WhiteAccuracyMoves = {},
    BlackAccuracyMoves = {},
}

if state.AutoRanked then
    state.Enabled = true
end
config.AutoPlay = state.Enabled

executorEnv.__CHESS_CONFIG = {
    AutoPlay = config.AutoPlay,
    AutoRanked = config.AutoRanked,
    MenuKeyCode = config.MenuKeyCode,
}

-- Install this only after `state` exists so the callback captures the
-- correct local state value.
Players.LocalPlayer.OnTeleport:Connect(function()
    if teleportCheck then
        return
    end

    teleportCheck = true

    -- Capture the live UI state immediately before the teleport.
    config.AutoPlay = state.Enabled
    config.AutoRanked = state.AutoRanked
    config.MenuKeyCode = state.MenuKeyCode.Name

    saveConfig()
    keepiy()
end)

AutoPlayState.__CHESS_AUTOPLAYER = state

local pieceLetters = {
    Pawn = "P",
    Knight = "N",
    Bishop = "B",
    Rook = "R",
    Queen = "Q",
    King = "K",
}

local promotionNames = {
    Q = "Queen",
    R = "Rook",
    B = "Bishop",
    N = "Knight",
}

local function boardKey(board)
    if not board then
        return "none"
    end

    return table.concat({
        tostring(board.id),
        tostring(board.round),
        tostring(board.activeTeam),
    }, ":")
end

local function squareToNotation(square)
    return string.char(8 - square[1] + 97) .. tostring(square[2])
end

local function notationToSquare(notation)
    return {
        9 - (string.byte(notation, 1) - 96),
        tonumber(string.sub(notation, 2)),
    }
end

local function isPlayerTurn(board)
    if not board or not board.boardExists or board.isSpectate then
        return false
    end

    local activeTeam = board.activeTeam
    if activeTeam == nil or not board.players then
        return false
    end

    if board.players[activeTeam] ~= LocalPlayer then
        return false
    end

    if board.botInfo and board.botInfo.team == activeTeam then
        return false
    end

    return true
end

local function pieceToFen(piece)
    if not piece then
        return nil
    end

    local symbol = pieceLetters[piece.Name]
    if not symbol then
        return nil
    end

    if piece.team == true then
        return symbol
    end

    return string.lower(symbol)
end

local function boardPlacementToFen(board)
    local ranks = {}

    for rank = 8, 1, -1 do
        local row = {}
        local empty = 0

        for x = 8, 1, -1 do
            local symbol = pieceToFen(board:getPiece({ x, rank }))

            if symbol then
                if empty > 0 then
                    table.insert(row, tostring(empty))
                    empty = 0
                end
                table.insert(row, symbol)
            else
                empty = empty + 1
            end
        end

        if empty > 0 then
            table.insert(row, tostring(empty))
        end

        table.insert(ranks, table.concat(row))
    end

    return table.concat(ranks, "/")
end

local function enPassantSquare(board, lastMoveUci)
    if type(lastMoveUci) ~= "string" or #lastMoveUci < 4 then
        return "-"
    end

    local fromFile = string.byte(string.sub(lastMoveUci, 1, 1)) - 96
    local fromRank = tonumber(string.sub(lastMoveUci, 2, 2))
    local toFile = string.byte(string.sub(lastMoveUci, 3, 3)) - 96
    local toRank = tonumber(string.sub(lastMoveUci, 4, 4))

    if not fromFile or not fromRank or not toFile or not toRank then
        return "-"
    end

    if fromFile ~= toFile or math.abs(toRank - fromRank) ~= 2 then
        return "-"
    end

    -- A white double-step (e2-e4) leaves e3 available to Black.
    -- A black double-step (e7-e5) leaves e6 available to White.
    if board.activeTeam == false then
        if fromRank ~= 2 or toRank ~= 4 then
            return "-"
        end
    else
        if fromRank ~= 7 or toRank ~= 5 then
            return "-"
        end
    end

    local destination = board:getPiece({
        9 - toFile,
        toRank,
    })

    if not destination or destination.Name ~= "Pawn" or destination.team == board.activeTeam then
        return "-"
    end

    -- Only advertise an EP target when the side to move actually has a pawn
    -- capable of making that capture. This also avoids strict FEN validators
    -- rejecting an otherwise harmless "ghost" en-passant square.
    local captureRank = toRank
    local leftX = toFile - 1
    local rightX = toFile + 1

    for _, x in ipairs({ leftX, rightX }) do
        if x >= 1 and x <= 8 then
            local pawn = board:getPiece({ 9 - x, captureRank })
            if pawn
                and pawn.Name == "Pawn"
                and pawn.team == board.activeTeam then
                return squareToNotation({ 9 - toFile, (fromRank + toRank) / 2 })
            end
        end
    end

    return "-"
end

local function castlingRights(board)
    local rights = ""

    local whiteKing = board:getPiece({ 4, 1 })
    local whiteKingSide = board:getPiece({ 1, 1 })
    local whiteQueenSide = board:getPiece({ 8, 1 })

    if whiteKing and whiteKing.Name == "King" and whiteKing.team == true and whiteKing.unmoved == true then
        if whiteKingSide and whiteKingSide.Name == "Rook" and whiteKingSide.team == true and whiteKingSide.unmoved == true then
            rights = rights .. "K"
        end
        if whiteQueenSide and whiteQueenSide.Name == "Rook" and whiteQueenSide.team == true and whiteQueenSide.unmoved == true then
            rights = rights .. "Q"
        end
    end

    local blackKing = board:getPiece({ 4, 8 })
    local blackKingSide = board:getPiece({ 1, 8 })
    local blackQueenSide = board:getPiece({ 8, 8 })

    if blackKing and blackKing.Name == "King" and blackKing.team ~= true and blackKing.unmoved == true then
        if blackKingSide and blackKingSide.Name == "Rook" and blackKingSide.team ~= true and blackKingSide.unmoved == true then
            rights = rights .. "k"
        end
        if blackQueenSide and blackQueenSide.Name == "Rook" and blackQueenSide.team ~= true and blackQueenSide.unmoved == true then
            rights = rights .. "q"
        end
    end

    return rights == "" and "-" or rights
end

local function boardToFen(board, lastMoveUci)
    local boardFen = boardPlacementToFen(board)
    local side = board.activeTeam == true and "w" or "b"
    local ep = enPassantSquare(board, lastMoveUci)
    local round = tonumber(board.round) or 0
    local fullmove = math.max(1, math.floor((round + 1) / 2))

    return table.concat({
        boardFen,
        side,
        castlingRights(board),
        ep,
        "0",
        tostring(fullmove),
    }, " ")
end

local apiRequestBusy = false
local apiNextRequestAt = 0

local function pruneApiRequestTimes(now)
    local times = sharedApi.RequestTimes
    local kept = {}
    for _, t in ipairs(times) do
        if now - t < 60 then
            kept[#kept + 1] = t
        end
    end
    sharedApi.RequestTimes = kept
    state.ApiRequestTimes = kept
    return kept
end

local function isHighUsageText(value)
    return type(value) == "string"
        and string.find(string.upper(value), "HIGH_USAGE", 1, true) ~= nil
end

local function isAccuracySampleForSide(side, nextCount)
    return side == "White" and (nextCount % API_ACCURACY_SAMPLE_EVERY == 0)
        or side == "Black" and (nextCount % API_ACCURACY_SAMPLE_EVERY == 0)
end

local function apiProfile()
    return API_REQUEST_GAP, API_MAX_REQUESTS_PER_MINUTE,
        CHESS_API_DEPTH, CHESS_API_MAX_THINKING_MS
end

local function apiCacheKey(payload, depth, thinkingMs)
    return table.concat({
        tostring(payload.fen or ""),
        tostring(payload.searchmoves or ""),
        tostring(depth),
        tostring(thinkingMs),
    }, "|")
end

local function getCachedApiResult(key)
    local entry = sharedApi.Cache[key]
    if type(entry) ~= "table" then
        return nil
    end

    if tonumber(entry.expiresAt) and apiNow() >= entry.expiresAt then
        sharedApi.Cache[key] = nil
        return nil
    end

    entry.lastUsed = apiNow()
    return entry.result
end

local function storeCachedApiResult(key, result)
    sharedApi.Cache[key] = {
        result = result,
        expiresAt = apiNow() + API_CACHE_TTL,
        lastUsed = apiNow(),
    }

    local entries = {}
    for k, entry in pairs(sharedApi.Cache) do
        if type(entry) ~= "table" or apiNow() >= (tonumber(entry.expiresAt) or 0) then
            sharedApi.Cache[k] = nil
        else
            entries[#entries + 1] = {
                key = k,
                lastUsed = tonumber(entry.lastUsed) or 0,
            }
        end
    end

    while #entries > API_CACHE_MAX_ENTRIES do
        local oldestIndex = 1
        for i = 2, #entries do
            if entries[i].lastUsed < entries[oldestIndex].lastUsed then
                oldestIndex = i
            end
        end
        sharedApi.Cache[entries[oldestIndex].key] = nil
        table.remove(entries, oldestIndex)
    end
end

local function markHighUsage()
    local now = apiNow()
    sharedApi.PrimaryCooldownUntil = math.max(
        tonumber(sharedApi.PrimaryCooldownUntil) or 0,
        now + API_PRIMARY_COOLDOWN
    )
    sharedApi.HighUsageUntil = sharedApi.PrimaryCooldownUntil
    state.ApiHighUsageUntil = sharedApi.PrimaryCooldownUntil
end

local function requestStockfishOnline(payload, laneAlreadyHeld)
    if type(requestFunction) ~= "function" then
        error("No executor HTTP request function is available")
    end

    local depth = STOCKFISH_ONLINE_DEPTH
    local key = apiCacheKey(payload, depth, 0)
    local cached = getCachedApiResult(key)
    if cached then
        return cached
    end

    if not laneAlreadyHeld then
        while apiRequestBusy do
            if state.Destroyed then
                error("Script destroyed while waiting for API request")
            end
            task.wait(0.03)
        end

        apiRequestBusy = true
    end

    local ok, result = xpcall(function()
        while true do
            local tnow = apiNow()
            local times = pruneApiRequestTimes(tnow)
            local waitFor = sharedApi.NextRequestAt - tnow
            if #times < API_MAX_REQUESTS_PER_MINUTE and waitFor <= 0 then
                break
            end

            local budgetWait = #times >= API_MAX_REQUESTS_PER_MINUTE
                and math.max(0, (times[1] or tnow) + 60 - tnow)
                or 0
            local targetWait = math.max(waitFor, budgetWait)
            if targetWait > 0 then
                task.wait(math.min(targetWait, 1.0))
            else
                task.wait(0.03)
            end
        end

        local lateCached = getCachedApiResult(key)
        if lateCached then
            return lateCached
        end

        local requestNow = apiNow()
        local finalTimes = pruneApiRequestTimes(requestNow)
        if #finalTimes >= API_MAX_REQUESTS_PER_MINUTE then
            error("API_LOCAL_RATE_LIMIT")
        end

        local encodedFen = HttpService:UrlEncode(tostring(payload.fen or ""))
        local url = STOCKFISH_ONLINE_URL
            .. "?fen=" .. encodedFen
            .. "&depth=" .. tostring(depth)

        table.insert(sharedApi.RequestTimes, apiNow())
        state.ApiRequestTimes = sharedApi.RequestTimes
        sharedApi.NextRequestAt = apiNow() + API_REQUEST_GAP

        local response = requestFunction({
            Url = url,
            Method = "GET",
        })

        if not response then
            error("No response from stockfish.online")
        end

        local statusCode = tonumber(response.StatusCode or response.Status or 0) or 0
        local responseBody = response.Body or response.body or ""
        if statusCode ~= 0 and (statusCode < 200 or statusCode >= 300) then
            error("StockfishOnline HTTP " .. tostring(statusCode))
        end
        if type(responseBody) ~= "string" then
            error("StockfishOnline returned no body")
        end

        local decodeOk, decoded = pcall(HttpService.JSONDecode, HttpService, responseBody)
        if not decodeOk or type(decoded) ~= "table" then
            error("Invalid JSON from stockfish.online")
        end

        if decoded.success ~= true then
            error(tostring(decoded.data or decoded.error or "StockfishOnline analysis failed"))
        end

        local bestmoveText = tostring(decoded.bestmove or "")
        local uciMove = string.match(bestmoveText, "bestmove%s+([a-h][1-8][a-h][1-8][qrbn]?)")
        if not uciMove then
            uciMove = string.match(bestmoveText, "([a-h][1-8][a-h][1-8][qrbn]?)")
        end
        if not uciMove then
            error("StockfishOnline returned no legal move")
        end

        local evaluation = tonumber(decoded.evaluation)
        local normalized = {
            type = "bestmove",
            move = uciMove,
            lan = uciMove,
            eval = evaluation,
            centipawns = evaluation and (evaluation * 100) or nil,
            mate = decoded.mate,
            continuationArr = {},
            depth = depth,
            provider = "StockfishOnline",
        }

        if type(decoded.continuation) == "string" then
            for move in string.gmatch(decoded.continuation, "%S+") do
                table.insert(normalized.continuationArr, move)
            end
        end

        storeCachedApiResult(key, normalized)
        return normalized
    end, debug.traceback)

    if not laneAlreadyHeld then
        apiRequestBusy = false
    end
    state.ApiRequestTimes = sharedApi.RequestTimes

    if not ok then
        error(result)
    end

    return result
end

local function requestStockfish(payload)
    if type(requestFunction) ~= "function" then
        error("No executor HTTP request function is available")
    end

    local requestKind = payload.kind == "accuracy" and "accuracy" or "engine"
    local now = apiNow()

    -- If chess-api.com has recently returned HIGH_USAGE, do not probe it again
    -- for several minutes. Use the independent provider instead. This is a
    -- failover, not an attempt to bypass the server-side restriction.
    if now < (tonumber(sharedApi.PrimaryCooldownUntil) or 0) then
        return requestStockfishOnline(payload)
    end

    local gap, maxPerMinute, depth, thinkingMs = apiProfile()
    local key = apiCacheKey(payload, depth, thinkingMs)
    local cached = getCachedApiResult(key)
    if cached then
        state.ApiHighUsageUntil = sharedApi.HighUsageUntil
        return cached
    end

    while apiRequestBusy do
        if state.Destroyed then
            error("Script destroyed while waiting for API request")
        end
        task.wait(0.03)
    end

    apiRequestBusy = true

    local ok, result = xpcall(function()
        while true do
            local tnow = apiNow()
            local times = pruneApiRequestTimes(tnow)
            local waitFor = sharedApi.NextRequestAt - tnow

            if #times < maxPerMinute and waitFor <= 0 then
                break
            end

            local budgetWait = #times >= maxPerMinute
                and math.max(0, (times[1] or tnow) + 60 - tnow)
                or 0
            local targetWait = math.max(waitFor, budgetWait)
            if targetWait > 0 then
                task.wait(math.min(targetWait, 1.0))
            else
                task.wait(0.03)
            end
        end

        -- Re-check recovery profile after waiting for the limiter. A HIGH_USAGE
        -- event from another request may have switched the whole process to the
        -- lower-cost recovery profile while this request was waiting.
        local finalGap, finalMax, finalDepth, finalThinking = apiProfile()
        depth = finalDepth
        thinkingMs = finalThinking
        key = apiCacheKey(payload, depth, thinkingMs)

        local lateCached = getCachedApiResult(key)
        if lateCached then
            return lateCached
        end

        local requestNow = apiNow()
        local finalTimes = pruneApiRequestTimes(requestNow)
        if #finalTimes >= finalMax then
            error("API_LOCAL_RATE_LIMIT")
        end

        local apiPayload = {
            fen = payload.fen,
            depth = depth,
            maxThinkingTime = thinkingMs,
            taskId = HttpService:GenerateGUID(false),
        }

        if type(payload.searchmoves) == "string" and payload.searchmoves ~= "" then
            apiPayload.searchmoves = payload.searchmoves
        end

        table.insert(sharedApi.RequestTimes, apiNow())
        state.ApiRequestTimes = sharedApi.RequestTimes
        sharedApi.NextRequestAt = apiNow() + finalGap

        local response = requestFunction({
            Url = CHESS_API_URL,
            Method = "POST",
            Headers = {
                ["Content-Type"] = "application/json",
            },
            Body = HttpService:JSONEncode(apiPayload),
        })

        if not response then
            error("No response from chess-api.com")
        end

        local statusCode = tonumber(response.StatusCode or response.Status or 0) or 0
        local responseBody = response.Body or response.body or ""

        if statusCode == 429 or isHighUsageText(responseBody) then
            markHighUsage()
            return requestStockfishOnline(payload, true)
        end

        if statusCode ~= 0 and (statusCode < 200 or statusCode >= 300) then
            error(
                "Chess API HTTP " .. tostring(statusCode) .. " "
                    .. tostring(response.StatusMessage or "")
            )
        end

        if type(responseBody) ~= "string" then
            error("Chess API returned no body")
        end

        local decodeOk, decoded = pcall(HttpService.JSONDecode, HttpService, responseBody)
        if not decodeOk or type(decoded) ~= "table" then
            error("Invalid JSON from chess-api.com: " .. responseBody)
        end

        if decoded.error then
            local apiError = tostring(decoded.error)
            if isHighUsageText(apiError) then
                markHighUsage()
                return requestStockfishOnline(payload, true)
            end
            if string.find(apiError, "FEN", 1, true) then
                error("Chess API FEN error: " .. apiError .. " | FEN=" .. tostring(apiPayload.fen))
            end
            error("Chess API error: " .. apiError)
        end

        if decoded.type == "error" then
            local apiError = tostring(decoded.text or decoded.error or "unknown error")
            if isHighUsageText(apiError) then
                markHighUsage()
                return requestStockfishOnline(payload, true)
            end
            if string.find(apiError, "FEN", 1, true)
                or string.find(apiError, "FEN_VALIDATION", 1, true) then
                error("Chess API FEN error: " .. apiError .. " | FEN=" .. tostring(apiPayload.fen))
            end
            error("Chess API error: " .. apiError)
        end

        storeCachedApiResult(key, decoded)
        return decoded
    end, debug.traceback)

    if not ok then
        local message = tostring(result)
        if isHighUsageText(message) then
            markHighUsage()
        else
            sharedApi.NextRequestAt = math.max(
                sharedApi.NextRequestAt,
                apiNow() + API_FAILURE_BACKOFF
            )
        end
    end

    state.ApiHighUsageUntil = sharedApi.HighUsageUntil
    state.ApiRequestTimes = sharedApi.RequestTimes
    apiRequestBusy = false

    if not ok then
        error(result)
    end

    return result
end

local function apiResultToCp(result)
    if type(result) ~= "table" then
        return nil
    end

    if result.mate ~= nil then
        local mate = tonumber(result.mate)
        if mate then
            if mate > 0 then
                return 100000 - math.min(50000, math.max(0, mate - 1) * 100)
            end
            return -100000 + math.min(50000, math.max(0, -mate - 1) * 100)
        end
    end

    local centipawns = tonumber(result.centipawns)
    if centipawns then
        return centipawns
    end

    local eval = tonumber(result.eval)
    if eval then
        return eval * 100
    end

    return nil
end

local function mapEngineMove(board, uciMove)
    if type(uciMove) ~= "string" or #uciMove < 4 or uciMove == "0000" then
        return nil
    end

    local fromNotation = string.sub(uciMove, 1, 2)
    local toNotation = string.sub(uciMove, 3, 4)
    local from = notationToSquare(fromNotation)
    local to = notationToSquare(toNotation)
    local piece = board:getPiece(from)

    if not piece or piece.team ~= board.activeTeam then
        return nil
    end

    for _, move in pairs(piece:getMoves()) do
        if move[1] == to[1] and move[2] == to[2] then
            if move.promote then
                local promotion = string.upper(string.sub(uciMove, 5, 5))
                move.promote.pieceName = promotionNames[promotion] or "Queen"
            end
            return piece, move, fromNotation, toNotation
        end
    end

    return nil
end

local function fallbackAnalysis(board)
    local pieces = board.activeTeam and board.whitePieces or board.blackPieces

    for _, piece in pairs(pieces) do
        if piece.position then
            local moves = piece:getMoves()
            if #moves > 0 then
                local move = moves[1]
                if move.promote then
                    move.promote.pieceName = "Queen"
                end

                local from = squareToNotation(piece.position)
                local to = squareToNotation(move)

                return {
                    piece = piece,
                    moveInfo = move,
                    from = from,
                    to = to,
                    uci = from .. to,
                    score = nil,
                    scoreType = nil,
                    depth = nil,
                    pv = nil,
                    nps = nil,
                    timeMs = 0,
                }
            end
        end
    end

    return nil
end

local function analyzePosition(board, lastMoveUci)
    local result = requestStockfish({
        fen = boardToFen(board, lastMoveUci),
    })

    local uciMove = result.move or result.lan
    if type(uciMove) ~= "string" or uciMove == "" then
        return fallbackAnalysis(board)
    end

    local piece, move, fromNotation, toNotation = mapEngineMove(board, uciMove)
    if not piece or not move then
        return fallbackAnalysis(board)
    end

    local score
    local scoreType

    if result.mate ~= nil and tonumber(result.mate) then
        score = tonumber(result.mate)
        scoreType = "mate"
    else
        score = tonumber(result.eval)
        scoreType = "eval"
    end

    local pv
    if type(result.continuationArr) == "table" then
        pv = table.concat(result.continuationArr, " ")
    end

    return {
        piece = piece,
        moveInfo = move,
        from = fromNotation,
        to = toNotation,
        uci = uciMove,
        score = score,
        scoreType = scoreType,
        depth = result.depth,
        pv = pv,
        nps = result.nps,
        timeMs = tonumber(result.time),
    }
end

local function scoreToCp(scoreType, score)
    if type(score) ~= "number" then
        return nil
    end

    if scoreType == "cp" then
        return score
    end

    if scoreType == "eval" then
        return score * 100
    end

    if scoreType == "mate" then
        if score > 0 then
            return 100000 - math.min(50000, math.max(0, score - 1) * 100)
        end
        return -100000 + math.min(50000, math.max(0, -score - 1) * 100)
    end

    return nil
end

local function accuracyFromCpl(cpl)
    if type(cpl) ~= "number" then
        return nil
    end
    return math.clamp(100 * math.exp(-math.max(0, cpl) / 250), 0, 100)
end

local function classifyAccuracy(accuracy)
    if type(accuracy) ~= "number" then
        return "Unavailable"
    elseif accuracy >= 97 then
        return "Excellent"
    elseif accuracy >= 93 then
        return "Very good"
    elseif accuracy >= 85 then
        return "Good"
    elseif accuracy >= 70 then
        return "Inaccuracy"
    elseif accuracy >= 45 then
        return "Mistake"
    end
    return "Blunder"
end

local function snapshotBoard(board, lastMoveUci)
    if not board then
        return nil
    end

    local squares = {}

    for x = 1, 8 do
        for y = 1, 8 do
            local piece = board:getPiece({ x, y })
            if piece then
                squares[squareToNotation({ x, y })] = {
                    piece = piece,
                    name = piece.Name,
                    team = piece.team,
                }
            end
        end
    end

    return {
        board = board,
        activeTeam = board.activeTeam,
        fen = boardToFen(board, lastMoveUci),
        squares = squares,
    }
end

local function detectMove(previousSnapshot, currentSnapshot)
    if not previousSnapshot or not currentSnapshot then
        return nil
    end

    local oldRefs = {}
    local newRefs = {}

    for square, entry in pairs(previousSnapshot.squares) do
        oldRefs[entry.piece] = square
    end

    for square, entry in pairs(currentSnapshot.squares) do
        newRefs[entry.piece] = square
    end

    local candidates = {}

    for piece, from in pairs(oldRefs) do
        local to = newRefs[piece]
        if to and to ~= from then
            local entry = previousSnapshot.squares[from]
            if entry and entry.team == previousSnapshot.activeTeam then
                table.insert(candidates, {
                    from = from,
                    to = to,
                    oldName = entry.name,
                    newEntry = currentSnapshot.squares[to],
                })
            end
        end
    end

    if #candidates == 0 then
        local fromCandidates = {}
        local toCandidates = {}

        for square, oldEntry in pairs(previousSnapshot.squares) do
            local newEntry = currentSnapshot.squares[square]
            local changed = (oldEntry and not newEntry)
                or (not oldEntry and newEntry)
                or (oldEntry and newEntry and (oldEntry.name ~= newEntry.name or oldEntry.team ~= newEntry.team))

            if changed then
                if oldEntry and oldEntry.team == previousSnapshot.activeTeam then
                    table.insert(fromCandidates, { key = square, name = oldEntry.name })
                end

                if newEntry and newEntry.team == previousSnapshot.activeTeam then
                    table.insert(toCandidates, { key = square, entry = newEntry })
                end
            end
        end

        if #fromCandidates >= 1 and #toCandidates >= 1 then
            candidates[1] = {
                from = fromCandidates[1].key,
                to = toCandidates[1].key,
                oldName = fromCandidates[1].name,
                newEntry = toCandidates[1].entry,
            }
        end
    end

    if #candidates == 0 then
        return nil
    end

    local selected = candidates[1]
    for _, candidate in ipairs(candidates) do
        if candidate.oldName == "King" then
            selected = candidate
            break
        end
    end

    local uci = selected.from .. selected.to
    if selected.oldName == "Pawn" and selected.newEntry and selected.newEntry.name ~= "Pawn" then
        local promote = {
            Queen = "q",
            Rook = "r",
            Bishop = "b",
            Knight = "n",
        }
        uci = uci .. (promote[selected.newEntry.name] or "q")
    end

    return {
        uci = uci,
        from = selected.from,
        to = selected.to,
        side = previousSnapshot.activeTeam and "White" or "Black",
    }
end

local gui = Instance.new("ScreenGui")
gui.Name = "ChessAutoPlayerGUI"
gui.ResetOnSpawn = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = PlayerGui

local main = Instance.new("Frame")
main.Name = "Main"
main.Size = UDim2.fromOffset(382, 395)
main.Position = UDim2.new(config.XScale, config.XOffset, config.YScale, config.YOffset)
main.BackgroundColor3 = Color3.fromRGB(16, 17, 22)
main.BorderSizePixel = 0
main.Parent = gui

local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 12)
corner.Parent = main

local stroke = Instance.new("UIStroke")
stroke.Color = Color3.fromRGB(55, 58, 70)
stroke.Thickness = 1
stroke.Transparency = 0
stroke.Parent = main

local topAccent = Instance.new("Frame")
topAccent.Size = UDim2.new(1, -24, 0, 3)
topAccent.Position = UDim2.fromOffset(12, 10)
topAccent.BackgroundColor3 = Color3.fromRGB(90, 190, 255)
topAccent.BorderSizePixel = 0
topAccent.Parent = main

local accentCorner = Instance.new("UICorner")
accentCorner.CornerRadius = UDim.new(1, 0)
accentCorner.Parent = topAccent

local function makeLabel(parent, position, size, text, textSize, textColor, align)
    local label = Instance.new("TextLabel")
    label.BackgroundTransparency = 1
    label.Position = position
    label.Size = size
    label.Font = Enum.Font.GothamMedium
    label.Text = text
    label.TextColor3 = textColor or Color3.fromRGB(235, 238, 245)
    label.TextSize = textSize or 12
    label.TextXAlignment = align or Enum.TextXAlignment.Left
    label.TextWrapped = true
    label.Parent = parent
    return label
end

local engineTitle = makeLabel(main, UDim2.fromOffset(16, 22), UDim2.fromOffset(170, 20), "ENGINE", 11, Color3.fromRGB(130, 138, 155))
local engineValue = makeLabel(main, UDim2.fromOffset(190, 20), UDim2.fromOffset(140, 24), "Stockfish 18 • 100ms", 11, Color3.fromRGB(235, 238, 245), Enum.TextXAlignment.Right)

local separator = Instance.new("Frame")
separator.Size = UDim2.new(1, -32, 0, 1)
separator.Position = UDim2.fromOffset(16, 49)
separator.BackgroundColor3 = Color3.fromRGB(45, 47, 55)
separator.BorderSizePixel = 0
separator.Parent = main

local toggleData = {}
local autoRankedToggle

local function makeToggle(y, text, initial, callback)
    local label = makeLabel(main, UDim2.fromOffset(16, y), UDim2.fromOffset(215, 30), text, 13)

    local button = Instance.new("TextButton")
    button.Size = UDim2.fromOffset(100, 28)
    button.Position = UDim2.fromOffset(234, y - 1)
    button.AutoButtonColor = false
    button.BorderSizePixel = 0
    button.Font = Enum.Font.GothamBold
    button.TextSize = 10
    button.TextColor3 = Color3.fromRGB(245, 247, 252)
    button.Parent = main

    local buttonCorner = Instance.new("UICorner")
    buttonCorner.CornerRadius = UDim.new(0, 7)
    buttonCorner.Parent = button

    local data = { value = initial, button = button, label = label }

    local function refresh()
        button.Text = data.value and "ON" or "OFF"
        button.BackgroundColor3 = data.value
            and Color3.fromRGB(42, 160, 105)
            or Color3.fromRGB(48, 50, 59)
    end

    button.MouseButton1Click:Connect(function()
        data.value = not data.value
        refresh()
        callback(data.value)
    end)

    refresh()
    table.insert(toggleData, data)

    return data
end

local autoPlayToggle = makeToggle(62, "Auto Play", state.Enabled, function(enabled)
    state.Enabled = enabled
    config.AutoPlay = enabled
    if not enabled then
        state.Recommendation = nil
        if state.AutoRanked then
            state.AutoRanked = false
            config.AutoRanked = false
            if autoRankedToggle then
                autoRankedToggle.value = false
                autoRankedToggle.button.Text = "OFF"
                autoRankedToggle.button.BackgroundColor3 = Color3.fromRGB(48, 50, 59)
            end
        end
    end
    saveConfig()
end)

autoRankedToggle = makeToggle(100, "Auto Ranked Loop", state.AutoRanked, function(enabled)
    state.AutoRanked = enabled
    config.AutoRanked = enabled
    config.AutoPlay = state.Enabled

    if enabled then
        state.Enabled = true
        autoPlayToggle.value = true
        autoPlayToggle.button.Text = "ON"
        autoPlayToggle.button.BackgroundColor3 = Color3.fromRGB(42, 160, 105)

        state.RankedQueuePending = false
        state.RankedPostGame = false
        state.RankedTeleporting = false
        state.AutoRankedBusy = false
        state.NextRankedAttempt = os.clock() + 0.75
        state.RankedStartupReadyAt = os.clock() + 0.75
        state.RankedMatchActive = MatchClient.currentMatch ~= nil
        state.RankedActiveMatchId = MatchClient.currentMatch and tostring(MatchClient.currentMatch.id) or nil
    else
        -- Turning Auto Ranked off only changes its selected state and clears
        -- runtime guards. The saved value remains exactly what the user chose.
        state.RankedQueuePending = false
        state.RankedPostGame = false
        state.RankedTeleporting = false
        state.AutoRankedBusy = false
    end

    saveConfig()
end)

local bestMoveLabel = makeLabel(main, UDim2.fromOffset(16, 138), UDim2.fromOffset(350, 23), "Best move: --", 12, Color3.fromRGB(225, 229, 238))
bestMoveLabel.TextXAlignment = Enum.TextXAlignment.Left

local searchStatusLabel = makeLabel(main, UDim2.fromOffset(16, 160), UDim2.fromOffset(350, 18), "Ready", 10, Color3.fromRGB(130, 138, 155))

local function makeAccuracyBox(position, titleText)
    makeLabel(main, position, UDim2.fromOffset(130, 16), titleText, 9, Color3.fromRGB(130, 138, 155))

    local box = Instance.new("ScrollingFrame")
    box.Size = UDim2.fromOffset(350, 58)
    box.Position = UDim2.fromOffset(16, position.Y.Offset + 16)
    box.BackgroundColor3 = Color3.fromRGB(25, 27, 34)
    box.BorderSizePixel = 0
    box.CanvasSize = UDim2.fromOffset(0, 0)
    box.AutomaticCanvasSize = Enum.AutomaticSize.Y
    box.ScrollingDirection = Enum.ScrollingDirection.Y
    box.ScrollBarThickness = 4
    box.ScrollBarImageTransparency = 0.35
    box.ClipsDescendants = true
    box.Parent = main

    local padding = Instance.new("UIPadding")
    padding.PaddingLeft = UDim.new(0, 7)
    padding.PaddingRight = UDim.new(0, 7)
    padding.PaddingTop = UDim.new(0, 5)
    padding.PaddingBottom = UDim.new(0, 5)
    padding.Parent = box

    local layout = Instance.new("UIListLayout")
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.Padding = UDim.new(0, 1)
    layout.Parent = box

    local boxCorner = Instance.new("UICorner")
    boxCorner.CornerRadius = UDim.new(0, 7)
    boxCorner.Parent = box

    local boxStroke = Instance.new("UIStroke")
    boxStroke.Color = Color3.fromRGB(45, 47, 55)
    boxStroke.Thickness = 1
    boxStroke.Parent = box

    return box
end

local whiteAccuracyBox = makeAccuracyBox(UDim2.fromOffset(16, 181), "WHITE MOVES")
local blackAccuracyBox = makeAccuracyBox(UDim2.fromOffset(16, 257), "BLACK MOVES")
local accuracyLabel = makeLabel(main, UDim2.fromOffset(16, 333), UDim2.fromOffset(350, 22), "Game accuracy: --", 11, Color3.fromRGB(210, 215, 225))

local menuKeyLabel = makeLabel(main, UDim2.fromOffset(16, 362), UDim2.fromOffset(120, 18), "Menu key", 10, Color3.fromRGB(130, 138, 155))
local menuKeyButton = Instance.new("TextButton")
menuKeyButton.Size = UDim2.fromOffset(120, 22)
menuKeyButton.Position = UDim2.fromOffset(246, 359)
menuKeyButton.BackgroundColor3 = Color3.fromRGB(25, 27, 34)
menuKeyButton.BorderSizePixel = 0
menuKeyButton.AutoButtonColor = false
menuKeyButton.Font = Enum.Font.GothamBold
menuKeyButton.TextSize = 9
menuKeyButton.TextColor3 = Color3.fromRGB(235, 238, 245)
menuKeyButton.Text = state.MenuKeyCode.Name
menuKeyButton.Parent = main

local keyCorner = Instance.new("UICorner")
keyCorner.CornerRadius = UDim.new(0, 6)
keyCorner.Parent = menuKeyButton
local keyStroke = Instance.new("UIStroke")
keyStroke.Color = Color3.fromRGB(55, 58, 70)
keyStroke.Thickness = 1
keyStroke.Parent = menuKeyButton

local waitingForKey = false
menuKeyButton.MouseButton1Click:Connect(function()
    waitingForKey = true
    menuKeyButton.Text = "Press a key..."
end)

local dragging = false
local dragStart
local startPosition

main.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 then
        if input.Position.Y - main.AbsolutePosition.Y <= 40 then
            dragging = true
            dragStart = input.Position
            startPosition = main.Position
        end
    end
end)

UserInputService.InputChanged:Connect(function(input)
    if not dragging then
        return
    end

    if input.UserInputType ~= Enum.UserInputType.MouseMovement then
        return
    end

    local delta = input.Position - dragStart
    main.Position = UDim2.new(
        startPosition.X.Scale,
        startPosition.X.Offset + delta.X,
        startPosition.Y.Scale,
        startPosition.Y.Offset + delta.Y
    )
end)

UserInputService.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 and dragging then
        dragging = false
        config.XScale = main.Position.X.Scale
        config.XOffset = main.Position.X.Offset
        config.YScale = main.Position.Y.Scale
        config.YOffset = main.Position.Y.Offset
        saveConfig()
    end
end)

UserInputService.InputBegan:Connect(function(input)
    if waitingForKey then
        if input.UserInputType ~= Enum.UserInputType.Keyboard or input.KeyCode == Enum.KeyCode.Unknown then
            return
        end

        if input.KeyCode == Enum.KeyCode.Escape then
            waitingForKey = false
            menuKeyButton.Text = state.MenuKeyCode.Name
            return
        end

        state.MenuKeyCode = input.KeyCode
        config.MenuKeyCode = input.KeyCode.Name
        menuKeyButton.Text = input.KeyCode.Name
        waitingForKey = false
        saveConfig()
        return
    end

    if input.KeyCode == state.MenuKeyCode and not UserInputService:GetFocusedTextBox() then
        main.Visible = not main.Visible
    end
end)

local function updateAnalysisUI(recommendation)
    if not recommendation then
        return
    end

    local side = recommendation.side or "?"
    local moveText = recommendation.uci or (recommendation.from .. recommendation.to)
    local scoreText = recommendation.scoreType == "mate"
        and ("mate " .. tostring(recommendation.score))
        or string.format("%.2f", tonumber(recommendation.score or 0) or 0)

    bestMoveLabel.Text = string.format(
        "Best move: %s %s  •  %s",
        side,
        moveText,
        scoreText
    )

    local displayThinking = recommendation.thinkingMs or CHESS_API_MAX_THINKING_MS
    searchStatusLabel.Text = string.format(
        "Depth %s  •  %sms max  •  %s",
        tostring(recommendation.depth or "?"),
        tostring(displayThinking),
        recommendation.nps and (tostring(recommendation.nps) .. " NPS")
            or (recommendation.provider or "Stockfish 18")
    )
end

local function analyzeCurrent(board)
    if state.Busy or not board or not isPlayerTurn(board) then
        return nil
    end

    state.Busy = true
    searchStatusLabel.Text = "Analyzing..."

    local generationKey = boardKey(board)
    local positionFen = boardToFen(board, state.LastMoveUci)
    local analysisSide = board.activeTeam and "White" or "Black"
    local ok, result = pcall(function()
        return analyzePosition(board, state.LastMoveUci)
    end)
    state.Busy = false

    if not ok or not result then
        local reason = tostring(result or "unknown error")
        if isHighUsageText(reason) then
            reason = "Primary API throttled"
        end
        if #reason > 52 then
            reason = string.sub(reason, 1, 52) .. "..."
        end
        searchStatusLabel.Text = "Engine unavailable: " .. reason
        return nil
    end
    -- Keep the completed analysis visible even if the opponent moved while
    -- Stockfish was thinking. It is display-only once its original position
    -- is gone; playRecommendation() separately validates the live board.
    result.key = generationKey
    result.positionFen = positionFen
    result.side = analysisSide
    result.board = board

    -- Keep the engine result so sampled accuracy checks can reuse it when
    -- the sampled move is the same position we just analyzed.
    state.LastEngineFen = positionFen
    state.LastEngineResult = result

    if state.AccuracyBaselineFen == nil then
        state.AccuracyBaselineFen = positionFen
        state.AccuracyBaselineResult = result
    end

    state.Recommendation = result
    updateAnalysisUI(result)
    return result
end

local function playRecommendation(recommendation)
    if not recommendation or not state.Enabled then
        return false
    end

    local board = recommendation.board or MatchClient.currentMatch
    if not board or MatchClient.currentMatch ~= board or not isPlayerTurn(board) then
        return false
    end

    local piece = recommendation.piece
    local moveInfo = recommendation.moveInfo

    if not piece or not moveInfo or not piece.position then
        return false
    end

    local options = {}
    if moveInfo.promote then
        options.promotePieceName = moveInfo.promote.pieceName or "Queen"
    end

    MovePiece:FireServer(board.id, { piece.position[1], piece.position[2] }, moveInfo, options)

    -- Track the exact last move so the next FEN has correct en-passant state.
    state.LastMoveUci = recommendation.uci

    -- Keep the local MatchClient board in sync immediately. The original
    -- game's own client does the same after sending a move. Without this,
    -- the server call can succeed while the local board never advances,
    -- causing the autoplay loop to keep analysing the same position.
    local ok = pcall(function()
        MatchClient:processRound(piece, moveInfo, options)
    end)

    return ok
end

local function refreshAccuracyBox(box, lines)
    for _, child in ipairs(box:GetChildren()) do
        if child:IsA("TextLabel") then
            child:Destroy()
        end
    end

    for index, line in ipairs(lines) do
        local label = Instance.new("TextLabel")
        label.BackgroundTransparency = 1
        label.Size = UDim2.new(1, -2, 0, 15)
        label.Font = Enum.Font.GothamMedium
        label.TextSize = 9
        label.TextColor3 = Color3.fromRGB(210, 215, 225)
        label.TextXAlignment = Enum.TextXAlignment.Left
        label.TextYAlignment = Enum.TextYAlignment.Center
        label.TextWrapped = false
        label.Text = line
        label.LayoutOrder = index
        label.Parent = box
    end

    task.defer(function()
        local bottom = math.max(0, box.AbsoluteCanvasSize.Y - box.AbsoluteWindowSize.Y)
        box.CanvasPosition = Vector2.new(0, bottom)
    end)
end

local function setAccuracyBoxes()
    refreshAccuracyBox(whiteAccuracyBox, state.WhiteAccuracyMoves)
    refreshAccuracyBox(blackAccuracyBox, state.BlackAccuracyMoves)
end

local function appendAccuracyMove(job, accuracy, classification, cpl)
    local moveNumber = tonumber(job.moveNumber) or 1
    local line = string.format(
        "%d. %s  •  %.1f%% %s  •  %d CPL",
        moveNumber,
        job.playedMove,
        accuracy,
        classification,
        math.floor((cpl or 0) + 0.5)
    )

    local target = job.side == "White" and state.WhiteAccuracyMoves or state.BlackAccuracyMoves
    table.insert(target, line)
    while #target > 40 do
        table.remove(target, 1)
    end
    setAccuracyBoxes()
end

local function processAccuracyJob(job, suppliedPostResult)
    if not job or state.Destroyed then
        return false
    end

    if job.generation ~= state.AccuracyGeneration then
        return false
    end

    local bestResult = job.preResult
    if not bestResult
        and job.preFen == state.AccuracyBaselineFen
        and type(state.AccuracyBaselineResult) == "table" then
        bestResult = state.AccuracyBaselineResult
    end

    -- A missing baseline should be rare. Recover with one normal analysis,
    -- but only when the local/API usage guard allows it.
    if not bestResult then
        local ok, result = pcall(function()
            return requestStockfish({
                fen = job.preFen,
                kind = "accuracy",
            })
        end)
        if not ok or not result then
            return false
        end
        bestResult = result
    end

    local postResult = suppliedPostResult
    if not postResult
        and job.postFen == state.LastEngineFen
        and type(state.LastEngineResult) == "table" then
        postResult = state.LastEngineResult
    end

    -- Normally the resulting position was already analyzed either by
    -- ensureAccuracyBaseline() or analyzeCurrent(). Only request it here when
    -- neither cache contains the exact post-move FEN.
    if not postResult then
        local ok, result = pcall(function()
            return requestStockfish({
                fen = job.postFen,
                kind = "accuracy",
            })
        end)
        if not ok or not result then
            return false
        end
        postResult = result
    end

    local bestCp = apiResultToCp(bestResult)
    local playedCp = apiResultToCp(postResult)
    if bestCp == nil or playedCp == nil then
        return false
    end

    local cpl
    if job.side == "White" then
        cpl = math.max(0, bestCp - playedCp)
    else
        cpl = math.max(0, playedCp - bestCp)
    end

    local accuracy = accuracyFromCpl(cpl)
    if accuracy == nil then
        return false
    end

    state.AccuracyBaselineFen = job.postFen
    state.AccuracyBaselineResult = postResult

    state.AccuracySum = state.AccuracySum + accuracy
    state.AccuracyCount = state.AccuracyCount + 1

    if job.generation ~= state.AccuracyGeneration then
        return false
    end

    local gameAccuracy = state.AccuracySum / state.AccuracyCount
    local classification = classifyAccuracy(accuracy)
    appendAccuracyMove(job, accuracy, classification, cpl)

    accuracyLabel.Text = string.format(
        "Game accuracy: %.1f%%  •  %d analyzed",
        gameAccuracy,
        state.AccuracyCount
    )

    return true
end

local function ensureAccuracyBaseline(board, snapshot)
    if not board or not snapshot or state.Destroyed then
        return
    end

    if snapshot.fen == state.AccuracyBaselineFen and type(state.AccuracyBaselineResult) == "table" then
        return
    end

    if snapshot.fen == state.LastEngineFen and type(state.LastEngineResult) == "table" then
        state.AccuracyBaselineFen = snapshot.fen
        state.AccuracyBaselineResult = state.LastEngineResult
        return
    end

    -- Do not generate an extra API request for every ply. Accuracy is sampled
    -- every N moves PER SIDE, so White and Black both receive analysis while
    -- the engine remains the priority.
    if isPlayerTurn(board) then
        return
    end

    local nextCount
    local side = board.activeTeam == true and "White" or "Black"
    if side == "White" then
        nextCount = state.WhiteAccuracyMoveSerial + 1
    else
        nextCount = state.BlackAccuracyMoveSerial + 1
    end

    if not isAccuracySampleForSide(side, nextCount) then
        return
    end

    local ok, result = pcall(function()
        return requestStockfish({
            fen = snapshot.fen,
            kind = "accuracy",
        })
    end)

    if ok and result then
        state.AccuracyBaselineFen = snapshot.fen
        state.AccuracyBaselineResult = result
    end
end

local function getMatchfinding()
    local ok, module = pcall(function()
        return require((PlayerGui:WaitForChild("matchfinding"):WaitForChild("matchfinding")) :: any)
    end)

    if ok and type(module) == "table" then
        return module
    end

    return nil
end

local function getServerList(cursor)
    local url = string.format(
        "https://games.roblox.com/v1/games/%s/servers/Public?sortOrder=Desc&limit=%d%s",
        tostring(game.PlaceId),
        SERVER_LIST_LIMIT,
        cursor and ("&cursor=" .. HttpService:UrlEncode(cursor)) or ""
    )

    local ok, raw = pcall(function()
        if type(requestFunction) == "function" then
            local response = requestFunction({
                Url = url,
                Method = "GET",
            })
            if not response then
                error("No response from Roblox server list")
            end
            local statusCode = tonumber(response.StatusCode or response.Status or 0) or 0
            if statusCode ~= 0 and (statusCode < 200 or statusCode >= 300) then
                error("Server list HTTP " .. tostring(statusCode))
            end
            local body = response.Body or response.body
            if type(body) ~= "string" then
                error("Invalid server-list response")
            end
            return body
        end
        return game:HttpGet(url)
    end)

    if not ok then
        return nil
    end

    local decodedOk, data = pcall(HttpService.JSONDecode, HttpService, raw)
    if not decodedOk or type(data) ~= "table" then
        return nil
    end

    return data
end

local function findMostPopulatedServer()
    local currentJobId = tostring(game.JobId)
    local best = nil
    local cursor = nil

    for _ = 1, SERVER_SCAN_PAGES do
        local page = getServerList(cursor)
        if not page then
            break
        end

        for _, server in ipairs(page.data or {}) do
            local id = tostring(server.id or "")
            local playing = tonumber(server.playing) or 0
            local maxPlayers = tonumber(server.maxPlayers) or 0

            if id ~= ""
                and id ~= currentJobId
                and maxPlayers > 0
                and playing < maxPlayers then

                if not best or playing > best.playing then
                    best = {
                        id = id,
                        playing = playing,
                        maxPlayers = maxPlayers,
                    }
                end
            end
        end

        cursor = page.nextPageCursor
        if not cursor or cursor == "null" then
            break
        end

        task.wait(0.15)
    end

    return best
end

local function hopToMostPopulatedServer()
    local target = findMostPopulatedServer()
    if not target then
        return false
    end

    task.wait(SERVER_HOP_DELAY)

    return pcall(function()
        TeleportService:TeleportToPlaceInstance(
            game.PlaceId,
            target.id,
            LocalPlayer
        )
    end)
end

local function findRankedButton()
    local menuGui = PlayerGui:FindFirstChild("menu")
    if not menuGui then
        return nil
    end

    local frame = menuGui:FindFirstChild("Frame")
    local ranked = frame and frame:FindFirstChild("Ranked")
    local rankedFrame = ranked and ranked:FindFirstChild("Frame")
    local button = rankedFrame and rankedFrame:FindFirstChild("button")

    if button and button:IsA("GuiButton") then
        return button
    end

    return nil
end

local function queueRanked()
    if not state.AutoRanked
        or MatchClient.currentMatch ~= nil
        or state.RankedQueuePending
        or state.RankedMatchActive
        or state.RankedPostGame
        or state.RankedTeleporting
        or state.AutoRankedBusy then
        return false
    end

    if os.clock() < state.RankedStartupReadyAt then
        return false
    end

    local menuGui = PlayerGui:FindFirstChild("menu")
    if not menuGui or not menuGui.Enabled then
        return false
    end

    local button = findRankedButton()
    if not button or not button.Visible then
        return false
    end

    local matchfinding = nil
    pcall(function()
        matchfinding = require((PlayerGui:WaitForChild("matchfinding"):WaitForChild("matchfinding")) :: any)
    end)

    if matchfinding and matchfinding.inque then
        -- Already queued. Never press Ranked again while this flag is active.
        state.RankedQueuePending = true
        state.RankedQueueStartedAt = os.clock()
        state.AutoRankedBusy = true
        return false
    end

    if os.clock() < state.NextRankedAttempt then
        return false
    end

    -- Lock before firing the exact known-working Ranked button signal.
    state.RankedQueuePending = true
    state.RankedQueueStartedAt = os.clock()
    state.AutoRankedBusy = true
    state.NextRankedAttempt = os.clock() + 5

    local fired = false

    if type(firesignal) == "function" then
        local ok = pcall(firesignal, button.Activated)
        fired = ok
    elseif type(getconnections) == "function" then
        local ok, connections = pcall(getconnections, button.Activated)
        if ok and type(connections) == "table" then
            for _, connection in ipairs(connections) do
                if type(connection.Fire) == "function" then
                    pcall(connection.Fire, connection)
                    fired = true
                end
            end
        end
    end

    if not fired then
        state.RankedQueuePending = false
        state.AutoRankedBusy = false
        state.NextRankedAttempt = os.clock() + 2
        return false
    end

    -- Do not release the queue lock after a fraction of a second. Keep it
    -- until a real match appears. Only the 30-second timeout permits retrying.
    task.delay(30, function()
        if state.Destroyed or not state.AutoRanked then
            return
        end

        if state.RankedQueuePending
            and not state.RankedMatchActive
            and MatchClient.currentMatch == nil
            and os.clock() - state.RankedQueueStartedAt >= 30 then
            state.RankedQueuePending = false
            state.AutoRankedBusy = false
            state.NextRankedAttempt = os.clock() + 2
        end
    end)

    return true
end

EndGame.OnClientEvent:Connect(function(matchId)
    if not state.AutoRanked or state.Destroyed then
        return
    end

    local incomingId = tostring(matchId or "")

    -- Ignore stale EndGame events from an older match/script instance.
    if state.RankedActiveMatchId and incomingId ~= tostring(state.RankedActiveMatchId) then
        return
    end
    if state.RankedEndHandledId and incomingId == tostring(state.RankedEndHandledId) then
        return
    end

    state.RankedEndHandledId = incomingId
    state.RankedQueuePending = false
    state.RankedMatchActive = false
    state.RankedPostGame = true
    state.RankedTeleporting = false
    state.AutoRankedBusy = true

    task.spawn(function()
        task.wait(0.35)

        pcall(function()
            CloseMatch:FireServer(
                matchId,
                LocalPlayer,
                LocalPlayer
            )
        end)

        task.wait(0.15)

        pcall(function()
            if MatchClient.currentMatch then
                MatchClient:endGame()
            end
        end)

        -- Wait for the real client match to disappear. This prevents the
        -- main loop from treating an end-of-game transient as a new queue.
        local deadline = os.clock() + 5
        while not state.Destroyed and MatchClient.currentMatch ~= nil and os.clock() < deadline do
            task.wait(0.1)
        end

        pcall(function()
            local menuGui = PlayerGui:FindFirstChild("menu")
            if menuGui and not menuGui.Enabled then
                MenuModule:open()
            end
        end)

        state.Recommendation = nil
        state.LastSnapshot = nil
        state.LastBoardKey = nil
        state.CurrentGameId = nil
        state.PendingPlayKey = nil
        state.PendingAccuracy = nil
        state.LastMoveUci = nil
        state.LastEngineFen = nil
        state.LastEngineResult = nil
        state.AccuracyBaselineFen = nil
        state.AccuracyBaselineResult = nil
        state.AccuracyMoveSerial = 0
        state.WhiteAccuracyMoveSerial = 0
        state.BlackAccuracyMoveSerial = 0
        state.AccuracySum = 0
        state.AccuracyCount = 0
        state.WhiteAccuracyMoves = {}
        state.BlackAccuracyMoves = {}
        setAccuracyBoxes()
        accuracyLabel.Text = "Game accuracy: --"
        state.NextRankedAttempt = os.clock() + 1

        if not state.AutoRanked then
            state.RankedPostGame = false
            state.AutoRankedBusy = false
            return
        end

        state.RankedTeleporting = true
        state.AutoRankedBusy = true
        local hopOk = false
        local callOk, result = pcall(function()
            return hopToMostPopulatedServer()
        end)
        if callOk and result then
            hopOk = true
        end

        if not hopOk and not state.Destroyed then
            state.RankedTeleporting = false
            state.RankedPostGame = false
            state.AutoRankedBusy = false
            state.NextRankedAttempt = os.clock() + 2
        end
    end)
end)

TeleportService.TeleportInitFailed:Connect(function()
    if state.AutoRanked and not state.Destroyed then
        state.RankedTeleporting = false
        state.RankedPostGame = false
        state.RankedQueuePending = false
        state.RankedMatchActive = MatchClient.currentMatch ~= nil
        state.RankedActiveMatchId = MatchClient.currentMatch and tostring(MatchClient.currentMatch.id) or nil
        state.AutoRankedBusy = false
        state.NextRankedAttempt = os.clock() + 2
    end
end)

state.Destroy = function()
    if state.Destroyed then
        return
    end

    -- This only shuts down an old instance. Do not overwrite the user's
    -- persistent settings when a fresh copy replaces it after teleport/re-exec.
    state.Destroyed = true
    state.PendingAccuracy = nil

    pcall(function() gui:Destroy() end)
end

local onlyStartedOutput = true
if onlyStartedOutput then
    print("[ChessAuto] Started")
end

task.spawn(function()
    while not state.Destroyed do
        local currentMatch = MatchClient.currentMatch
        local gameId = currentMatch and tostring(currentMatch.id) or nil
        local key = currentMatch and boardKey(currentMatch) or nil
        local snapshot = currentMatch and snapshotBoard(currentMatch, state.LastMoveUci) or nil

        -- Reset only when the actual match changes. Do NOT use boardKey here
        -- because boardKey changes after every move (round/side-to-move).
        if gameId ~= state.CurrentGameId then
            state.AccuracyGeneration = state.AccuracyGeneration + 1
            state.AccuracyMoveSerial = 0
            state.WhiteAccuracyMoveSerial = 0
            state.BlackAccuracyMoveSerial = 0
            state.LastAccuracyDisplayedSerial = 0
            state.CurrentGameId = gameId
            state.Recommendation = nil
            state.AccuracySum = 0
            state.AccuracyCount = 0
            state.LastSnapshot = snapshot
            state.LastBoardKey = key
            state.PendingPlayKey = nil
            state.PendingAccuracy = nil
            state.LastMoveUci = nil
            state.LastEngineFen = nil
            state.LastEngineResult = nil
            state.AccuracyBaselineFen = nil
            state.AccuracyBaselineResult = nil
            state.WhiteAccuracyMoves = {}
            state.BlackAccuracyMoves = {}
            setAccuracyBoxes()
            accuracyLabel.Text = "Game accuracy: --"
        end

        -- A real MatchClient.currentMatch means matchmaking succeeded. While it
        -- exists, the ranked queue is considered active and cannot fire again.
        if currentMatch and not state.RankedPostGame and not state.RankedTeleporting then
            if not state.RankedMatchActive
                or tostring(state.RankedActiveMatchId) ~= gameId then
                state.RankedMatchActive = true
                state.RankedActiveMatchId = gameId
                state.RankedEndHandledId = nil
            end
            state.RankedQueuePending = false
            state.AutoRankedBusy = false
        end

        -- Establish the engine value of the current position when needed.
        -- This is especially important when the user starts as Black, because
        -- White can make the first move before analyzeCurrent() would run.
        if currentMatch and snapshot then
            ensureAccuracyBaseline(currentMatch, snapshot)
        end

        -- Detect the move BEFORE replacing LastSnapshot.
        -- Accuracy jobs are stored and processed serially so they can never
        -- compete with the next move-analysis request.
        if currentMatch and snapshot and state.LastSnapshot and gameId == state.CurrentGameId then
            local previousSnapshot = state.LastSnapshot

            if snapshot.activeTeam ~= previousSnapshot.activeTeam then
                local move = detectMove(previousSnapshot, snapshot)

                if move then
                    state.LastMoveUci = move.uci
                    snapshot.fen = boardToFen(currentMatch, state.LastMoveUci)

                    state.AccuracyMoveSerial = state.AccuracyMoveSerial + 1

                    local sideMoveNumber
                    if move.side == "White" then
                        state.WhiteAccuracyMoveSerial = state.WhiteAccuracyMoveSerial + 1
                        sideMoveNumber = state.WhiteAccuracyMoveSerial
                    else
                        state.BlackAccuracyMoveSerial = state.BlackAccuracyMoveSerial + 1
                        sideMoveNumber = state.BlackAccuracyMoveSerial
                    end

                    -- Accuracy is sampled every N moves per side. This keeps
                    -- both White and Black boxes populated without adding a
                    -- second API request for every single ply.
                    if isAccuracySampleForSide(move.side, sideMoveNumber) then
                        local preResult = nil
                        if previousSnapshot.fen == state.AccuracyBaselineFen
                            and type(state.AccuracyBaselineResult) == "table" then
                            preResult = state.AccuracyBaselineResult
                        elseif previousSnapshot.fen == state.LastEngineFen
                            and type(state.LastEngineResult) == "table" then
                            preResult = state.LastEngineResult
                        end

                        state.PendingAccuracy = {
                            generation = state.AccuracyGeneration,
                            preFen = previousSnapshot.fen,
                            postFen = snapshot.fen,
                            preResult = preResult,
                            uci = move.uci,
                            side = move.side,
                            playedMove = move.from .. "-" .. move.to,
                            moveNumber = sideMoveNumber,
                        }
                    end
                end
            end
        end

        if state.AutoRanked
            and not currentMatch
            and not state.RankedQueuePending
            and not state.RankedMatchActive
            and not state.RankedPostGame
            and not state.RankedTeleporting
            and not state.AutoRankedBusy then
            queueRanked()
        end

        if currentMatch and isPlayerTurn(currentMatch) then
            local recommendation = state.Recommendation

            if not recommendation or recommendation.key ~= key then
                recommendation = analyzeCurrent(currentMatch)
            end

            if recommendation then
                recommendation.board = recommendation.board or currentMatch

                if state.Enabled and state.PendingPlayKey ~= key then
                    if recommendation.key == key and playRecommendation(recommendation) then
                        state.PendingPlayKey = key
                        state.Recommendation = nil
                    end
                end
            end
        end

        -- Accuracy runs after the live move analysis has had priority.
        -- If it is now the player's turn, analyzeCurrent() already gave us
        -- the post-move evaluation, so no second accuracy request is needed.
        if state.PendingAccuracy then
            local job = state.PendingAccuracy
            state.PendingAccuracy = nil

            local suppliedPostResult = nil

            -- If ensureAccuracyBaseline() just analyzed this post-move
            -- position (this happens after one of our own moves), reuse it.
            if job.postFen == state.AccuracyBaselineFen
                and type(state.AccuracyBaselineResult) == "table" then
                suppliedPostResult = state.AccuracyBaselineResult
            elseif currentMatch
                and snapshot
                and job.postFen == snapshot.fen
                and state.LastEngineFen == snapshot.fen
                and type(state.LastEngineResult) == "table" then
                -- After an opponent move, analyzeCurrent() already analyzed
                -- the exact resulting position, so reuse that too.
                suppliedPostResult = state.LastEngineResult
            end

            processAccuracyJob(job, suppliedPostResult)
        end

        state.LastSnapshot = snapshot
        state.LastBoardKey = key
        task.wait(0.08)
    end
end)
