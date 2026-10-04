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

-- Wait for the game's UI to finish initializing after teleport.
-- MatchClient requires VersusScreen to already exist.
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

local STOCKFISH_URL = "http://127.0.0.1:5001/bestmove"
local DEFAULT_ENGINE_SECONDS = 5
local DEFAULT_ACCURACY_SECONDS = 1
local CONFIG_FILE = "prometheus_stockfish_config.json"
local SERVER_LIST_LIMIT = 50
local SERVER_SCAN_PAGES = 5
local SERVER_HOP_DELAY = 0.8
local GITHUB_RAW_URL = "https://raw.githubusercontent.com/altsalts75-alt/chess/main/prometheus_stockfish_final_github_keepiy.lua"

local executorEnv = getgenv and getgenv() or _G
local executorSyn = type(executorEnv.syn) == "table" and executorEnv.syn or nil
local requestFunction = executorEnv.request
    or executorEnv.http_request
    or (executorSyn and executorSyn.request)
local AutoPlayState = executorEnv

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
    EngineSeconds = DEFAULT_ENGINE_SECONDS,
    AccuracySeconds = DEFAULT_ACCURACY_SECONDS,
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

    if type(saved.EngineSeconds) == "number" then
        config.EngineSeconds = math.clamp(saved.EngineSeconds, 0.5, 30)
    end

    if type(saved.AccuracySeconds) == "number" then
        config.AccuracySeconds = math.clamp(saved.AccuracySeconds, 0.2, 10)
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
    if type(runtimeConfig.EngineSeconds) == "number" then
        config.EngineSeconds = math.clamp(runtimeConfig.EngineSeconds, 0.5, 30)
    end

    if type(runtimeConfig.AccuracySeconds) == "number" then
        config.AccuracySeconds = math.clamp(runtimeConfig.AccuracySeconds, 0.2, 10)
    end

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
        EngineSeconds = config.EngineSeconds,
        AccuracySeconds = config.AccuracySeconds,
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
        EngineSeconds = payload.EngineSeconds,
        AccuracySeconds = payload.AccuracySeconds,
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
    EngineSeconds = config.EngineSeconds,
    AccuracySeconds = config.AccuracySeconds,
    MenuKeyCode = Enum.KeyCode[config.MenuKeyCode] or Enum.KeyCode.RightShift,
    Busy = false,
    Destroyed = false,
    Recommendation = nil,
    AccuracySum = 0,
    AccuracyCount = 0,
    AccuracyGeneration = 0,
    AccuracyMoveSerial = 0,
    LastAccuracyDisplayedSerial = 0,
    CurrentGameId = nil,
    LastSnapshot = nil,
    LastBoardKey = nil,
    AutoRankedBusy = false,
    NextRankedAttempt = 0,
    PendingPlayKey = nil,
}

if state.AutoRanked then
    state.Enabled = true
end
config.AutoPlay = state.Enabled

executorEnv.__CHESS_CONFIG = {
    EngineSeconds = config.EngineSeconds,
    AccuracySeconds = config.AccuracySeconds,
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

    config.EngineSeconds = state.EngineSeconds
    config.AccuracySeconds = state.AccuracySeconds
    config.AutoPlay = state.Enabled
    config.AutoRanked = state.AutoRanked
    config.MenuKeyCode = state.MenuKeyCode.Name

    saveConfig()

    getgenv().__CHESS_TELEPORT_HANDOFF = true

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

local function enPassantSquare(board)
    local activeTeam = board.activeTeam

    for x = 1, 8 do
        for y = 1, 8 do
            local pawn = board:getPiece({ x, y })

            if pawn and pawn.Name == "Pawn"
                and pawn.team ~= activeTeam
                and pawn.position
                and pawn.position.doublestep
                and pawn.position.doublestep == board.round - 1 then

                local targetY = pawn.position[2] + (activeTeam == true and 1 or -1)

                if targetY >= 1 and targetY <= 8 then
                    return squareToNotation({ pawn.position[1], targetY })
                end
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

local function boardToFen(board)
    local boardFen = boardPlacementToFen(board)
    local side = board.activeTeam == true and "w" or "b"
    local ep = enPassantSquare(board)
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

local function requestStockfish(payload)
    if type(requestFunction) ~= "function" then
        error("No executor HTTP request function is available")
    end

    local response = requestFunction({
        Url = STOCKFISH_URL,
        Method = "POST",
        Headers = {
            ["Content-Type"] = "application/json",
        },
        Body = HttpService:JSONEncode(payload),
    })

    if not response then
        error("No response from Stockfish bridge")
    end

    local statusCode = tonumber(response.StatusCode or response.Status or 0) or 0
    if statusCode ~= 0 and (statusCode < 200 or statusCode >= 300) then
        error("Stockfish bridge HTTP error: " .. tostring(statusCode) .. " " .. tostring(response.StatusMessage or ""))
    end

    local body = response.Body or response.body
    if type(body) ~= "string" then
        error("Stockfish bridge returned no body")
    end

    local ok, decoded = pcall(HttpService.JSONDecode, HttpService, body)
    if not ok or type(decoded) ~= "table" then
        error("Invalid JSON from Stockfish bridge")
    end

    if decoded.ok == false then
        error(tostring(decoded.error or "Stockfish bridge error"))
    end

    return decoded
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

local function analyzePosition(board)
    local result = requestStockfish({
        fen = boardToFen(board),
        movetime = math.floor(state.EngineSeconds * 1000 + 0.5),
        gameKey = boardKey(board),
    })

    if not result.bestmove then
        return fallbackAnalysis(board)
    end

    local piece, move, fromNotation, toNotation = mapEngineMove(board, result.bestmove)
    if not piece or not move then
        return fallbackAnalysis(board)
    end

    return {
        piece = piece,
        moveInfo = move,
        from = fromNotation,
        to = toNotation,
        uci = result.bestmove,
        score = result.score,
        scoreType = result.scoreType,
        depth = result.depth,
        pv = result.pv,
        nps = result.nps,
        timeMs = result.timeMs,
    }
end

local function scoreToCp(scoreType, score)
    if type(score) ~= "number" then
        return nil
    end

    if scoreType == "cp" then
        return score
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

local function snapshotBoard(board)
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
        fen = boardToFen(board),
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
main.Size = UDim2.fromOffset(350, 285)
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

local engineTitle = makeLabel(main, UDim2.fromOffset(16, 22), UDim2.fromOffset(170, 20), "ENGINE SEARCH", 11, Color3.fromRGB(130, 138, 155))
local engineValue = makeLabel(main, UDim2.fromOffset(200, 20), UDim2.fromOffset(130, 24), "Stockfish", 11, Color3.fromRGB(235, 238, 245), Enum.TextXAlignment.Right)

local searchTimeLabel = makeLabel(main, UDim2.fromOffset(16, 49), UDim2.fromOffset(180, 28), "Search time", 13)
local searchTimeBox = Instance.new("TextBox")
searchTimeBox.Size = UDim2.fromOffset(110, 28)
searchTimeBox.Position = UDim2.fromOffset(224, 48)
searchTimeBox.BackgroundColor3 = Color3.fromRGB(25, 27, 34)
searchTimeBox.BorderSizePixel = 0
searchTimeBox.ClearTextOnFocus = false
searchTimeBox.Font = Enum.Font.GothamMedium
searchTimeBox.PlaceholderText = "5"
searchTimeBox.Text = string.format("%.1f", state.EngineSeconds)
searchTimeBox.TextColor3 = Color3.fromRGB(245, 247, 252)
searchTimeBox.TextSize = 12
searchTimeBox.Parent = main
local searchCorner = Instance.new("UICorner")
searchCorner.CornerRadius = UDim.new(0, 7)
searchCorner.Parent = searchTimeBox
local searchStroke = Instance.new("UIStroke")
searchStroke.Color = Color3.fromRGB(55, 58, 70)
searchStroke.Thickness = 1
searchStroke.Parent = searchTimeBox

local separator = Instance.new("Frame")
separator.Size = UDim2.new(1, -32, 0, 1)
separator.Position = UDim2.fromOffset(16, 86)
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

local autoPlayToggle = makeToggle(100, "Auto Play", state.Enabled, function(enabled)
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

autoRankedToggle = makeToggle(138, "Auto Ranked Loop", state.AutoRanked, function(enabled)
    state.AutoRanked = enabled
    config.AutoRanked = enabled
    config.AutoPlay = state.Enabled

    if enabled then
        state.Enabled = true
        autoPlayToggle.value = true
        autoPlayToggle.button.Text = "ON"
        autoPlayToggle.button.BackgroundColor3 = Color3.fromRGB(42, 160, 105)
    end

    saveConfig()
end)

local bestMoveLabel = makeLabel(main, UDim2.fromOffset(16, 176), UDim2.fromOffset(318, 23), "Best move: --", 12, Color3.fromRGB(225, 229, 238))
bestMoveLabel.TextXAlignment = Enum.TextXAlignment.Left

local searchStatusLabel = makeLabel(main, UDim2.fromOffset(16, 198), UDim2.fromOffset(318, 18), "Ready", 10, Color3.fromRGB(130, 138, 155))

local accuracyLabel = makeLabel(main, UDim2.fromOffset(16, 220), UDim2.fromOffset(318, 44), "Last move: --\nGame accuracy: --", 11, Color3.fromRGB(210, 215, 225))

local menuKeyLabel = makeLabel(main, UDim2.fromOffset(16, 267), UDim2.fromOffset(120, 18), "Menu key", 10, Color3.fromRGB(130, 138, 155))
local menuKeyButton = Instance.new("TextButton")
menuKeyButton.Size = UDim2.fromOffset(120, 22)
menuKeyButton.Position = UDim2.fromOffset(214, 264)
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

searchTimeBox.FocusLost:Connect(function()
    local value = tonumber(searchTimeBox.Text)
    if not value then
        searchTimeBox.Text = string.format("%.1f", state.EngineSeconds)
        return
    end

    value = math.clamp(value, 0.5, 30)
    state.EngineSeconds = value
    config.EngineSeconds = value
    searchTimeBox.Text = string.format("%.1f", value)
    saveConfig()
end)

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

    searchStatusLabel.Text = string.format(
        "Depth %s  •  %.1fs  •  %s",
        tostring(recommendation.depth or "?"),
        (tonumber(recommendation.timeMs) or math.floor(state.EngineSeconds * 1000)) / 1000,
        recommendation.nps and (tostring(recommendation.nps) .. " NPS") or "Stockfish"
    )
end

local function analyzeCurrent(board)
    if state.Busy or not board or not isPlayerTurn(board) then
        return nil
    end

    state.Busy = true
    searchStatusLabel.Text = "Analyzing..."

    local generationKey = boardKey(board)
    local positionFen = boardToFen(board)
    local analysisSide = board.activeTeam and "White" or "Black"
    local ok, result = pcall(function()
        return analyzePosition(board)
    end)
    state.Busy = false

    if not ok or not result then
        searchStatusLabel.Text = "Engine analysis failed"
        return nil
    end

    -- Keep the completed analysis visible even if the opponent moved while
    -- Stockfish was thinking. It is display-only once its original position
    -- is gone; playRecommendation() separately validates the live board.
    result.key = generationKey
    result.positionFen = positionFen
    result.side = analysisSide
    result.board = board
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

    -- Keep the local MatchClient board in sync immediately. The original
    -- game's own client does the same after sending a move. Without this,
    -- the server call can succeed while the local board never advances,
    -- causing the autoplay loop to keep analysing the same position.
    local ok = pcall(function()
        MatchClient:processRound(piece, moveInfo, options)
    end)

    return ok
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

    local ok = pcall(function()
        TeleportService:TeleportToPlaceInstance(
            game.PlaceId,
            target.id,
            LocalPlayer
        )
    end)

    return ok
end

local function queueRanked()
    if not state.AutoRanked or MatchClient.currentMatch ~= nil or state.AutoRankedBusy then
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
        return false
    end

    if os.clock() < state.NextRankedAttempt then
        return false
    end

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

    task.delay(0.35, function()
        state.AutoRankedBusy = false
    end)

    return fired
end

EndGame.OnClientEvent:Connect(function(matchId)
    if not state.AutoRanked or state.Destroyed then
        return
    end

    if state.AutoRankedBusy then
        return
    end

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

        task.wait(0.1)

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
        state.NextRankedAttempt = os.clock() + 1

        -- A fresh server resets matchmaking state (including a possibly stale
        -- matchfinding.inque flag), which avoids getting stuck in the ranked queue.
        if state.AutoRanked then
            task.spawn(function()
                hopToMostPopulatedServer()
            end)
            return
        end

        task.wait(1)
        state.AutoRankedBusy = false
    end)
end)

TeleportService.TeleportInitFailed:Connect(function()
    if state.AutoRanked and not state.Destroyed then
        state.AutoRankedBusy = false
        state.NextRankedAttempt = os.clock() + 2
    end
end)

state.Destroy = function()
    if state.Destroyed then
        return
    end

    state.Destroyed = true
    state.Enabled = false
    state.AutoRanked = false
    saveConfig()

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
        local snapshot = currentMatch and snapshotBoard(currentMatch) or nil

        -- Reset only when the actual match changes. Do NOT use boardKey here
        -- because boardKey changes after every move (round/side-to-move).
        if gameId ~= state.CurrentGameId then
            state.AccuracyGeneration = state.AccuracyGeneration + 1
            state.AccuracyMoveSerial = 0
            state.LastAccuracyDisplayedSerial = 0
            state.CurrentGameId = gameId
            state.Recommendation = nil
            state.AccuracySum = 0
            state.AccuracyCount = 0
            state.LastSnapshot = snapshot
            state.LastBoardKey = key
            state.PendingPlayKey = nil

            if not gameId then
                accuracyLabel.Text = "Last move: --\nGame accuracy: --"
            end
        end

        -- Detect the move BEFORE replacing LastSnapshot. This is the key fix
        -- for the previously blank accuracy fields.
        if currentMatch and snapshot and state.LastSnapshot and gameId == state.CurrentGameId then
            local previousSnapshot = state.LastSnapshot

            if snapshot.activeTeam ~= previousSnapshot.activeTeam then
                local move = detectMove(previousSnapshot, snapshot)

                if move then
                    state.AccuracyMoveSerial = state.AccuracyMoveSerial + 1
                    local moveSerial = state.AccuracyMoveSerial
                    local generation = state.AccuracyGeneration
                    local gameKey = gameId
                    local previousFen = previousSnapshot.fen
                    local side = move.side
                    local playedMove = move.from .. "-" .. move.to

                    task.spawn(function()
                        local ok, result = pcall(function()
                            return requestStockfish({
                                endpoint = "evaluate",
                                fen = previousFen,
                                move = move.uci,
                                movetime = math.floor(state.AccuracySeconds * 1000 + 0.5),
                                gameKey = gameKey,
                            })
                        end)

                        if state.Destroyed or generation ~= state.AccuracyGeneration then
                            return
                        end

                        if not ok or not result then
                            if moveSerial >= state.LastAccuracyDisplayedSerial then
                                accuracyLabel.Text = string.format(
                                    "Last move: %s %s • Accuracy unavailable\nGame accuracy: %.0f%%",
                                    side,
                                    playedMove,
                                    state.AccuracyCount > 0 and (state.AccuracySum / state.AccuracyCount) or 0
                                )
                                state.LastAccuracyDisplayedSerial = moveSerial
                            end
                            return
                        end

                        local accuracy
                        local cpl

                        if result.sameAsBest or result.bestmove == move.uci then
                            accuracy = 100
                            cpl = 0
                        else
                            local bestCp = scoreToCp(result.bestScoreType, result.bestScore)
                            local playedCp = scoreToCp(result.playedScoreType, result.playedScore)

                            if bestCp ~= nil and playedCp ~= nil then
                                cpl = math.max(0, bestCp - playedCp)
                                accuracy = accuracyFromCpl(cpl)
                            end
                        end

                        if accuracy == nil then
                            if moveSerial >= state.LastAccuracyDisplayedSerial then
                                accuracyLabel.Text = string.format(
                                    "Last move: %s %s • Accuracy unavailable\nGame accuracy: %.0f%%",
                                    side,
                                    playedMove,
                                    state.AccuracyCount > 0 and (state.AccuracySum / state.AccuracyCount) or 0
                                )
                                state.LastAccuracyDisplayedSerial = moveSerial
                            end
                            return
                        end

                        state.AccuracySum = state.AccuracySum + accuracy
                        state.AccuracyCount = state.AccuracyCount + 1
                        local gameAccuracy = state.AccuracySum / state.AccuracyCount

                        -- Only guard against an old move overwriting a newer
                        -- result after a new game starts. Completed analyses from
                        -- the same game are allowed to arrive out of order.
                        if generation ~= state.AccuracyGeneration then
                            return
                        end

                        local classification = classifyAccuracy(accuracy)

                        if moveSerial >= state.LastAccuracyDisplayedSerial then
                            accuracyLabel.Text = string.format(
                                "Last move: %s %s • %.0f%% %s • %d CPL\nGame accuracy: %.0f%%",
                                side,
                                playedMove,
                                accuracy,
                                classification,
                                math.floor((cpl or 0) + 0.5),
                                gameAccuracy
                            )
                            state.LastAccuracyDisplayedSerial = moveSerial
                        end
                    end)
                end
            end
        end

        if state.AutoRanked and not currentMatch then
            queueRanked()
        end

        if currentMatch and isPlayerTurn(currentMatch) then
            local recommendation = state.Recommendation

            if not recommendation or recommendation.key ~= key then
                recommendation = analyzeCurrent(currentMatch)
            end

            if recommendation then
                -- Only let the live board be used for execution. The displayed
                -- analysis may intentionally belong to the immediately previous
                -- position if the opponent moved quickly.
                recommendation.board = recommendation.board or currentMatch

                if state.Enabled and state.PendingPlayKey ~= key then
                    if recommendation.key == key and playRecommendation(recommendation) then
                        state.PendingPlayKey = key
                        state.Recommendation = nil
                    end
                end
            end
        end

        state.LastSnapshot = snapshot
        state.LastBoardKey = key
        task.wait(0.08)
    end
end)
