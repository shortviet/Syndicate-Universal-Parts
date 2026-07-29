--!nocheck
-- ===========================================================================
-- NametagSystem v2 – Complete Rewrite (Syndicate Universal)
-- Pure custom system, no third-party dependencies.
-- Features:
--   • Automatic Roblox avatar thumbnails per user
--   • Per-role themed cards (owner / admin / developer / moderator / staff / advertising / user)
--   • Full gradient engine (30+ types with animation support)
--   • Distance scaling, fade-in, particles
--   • Per-user color & gradient overrides via NametagConfig.json
--   • 100 % mobile / executor compatibility layer
-- ===========================================================================

local NametagSystem = {}

function NametagSystem.Init(ctx)
    -- ── Context & Services ─────────────────────────────────────────────────
    ctx = type(ctx) == "table" and ctx or {}
    local game      = ctx.game or game
    local _genv     = ctx._genv or (getgenv and getgenv()) or _G or {}
    local Players   = game:GetService("Players")
    local RS        = game:GetService("RunService")
    local UIS       = game:GetService("UserInputService")
    local TS        = game:GetService("TweenService")
    local Http      = game:GetService("HttpService")
    local CoreGui   = game:GetService("CoreGui")
    local LocalPlayer = ctx.LocalPlayer or Players.LocalPlayer

    -- ── Executor & FileSystem helpers ──────────────────────────────────────
    local function _safePcall(fn, ...)
        local ok, r = pcall(fn, ...)
        return ok and r
    end

    local function _safeGetCustomAsset(path)
        for _, fnName in ipairs({"getcustomasset", "getsynasset", "getasset", "custom_asset"}) do
            local fn = (type(_genv[fnName]) == "function" and _genv[fnName])
                   or (type(rawget(_genv, fnName)) == "function" and rawget(_genv, fnName))
            if fn then
                local r = _safePcall(fn, path)
                if r and r ~= "" then return r end
            end
        end
        return nil
    end

    local function _safeHttpGet(url)
        local htFn = (type(httpget) == "function" and httpget)
                  or (type(_genv.httpget) == "function" and _genv.httpget)
        if htFn then
            local ok, r = pcall(htFn, url)
            if ok and r then return r end
        end
        local reqFn = (type(request) == "function" and request)
                   or (type(http_request) == "function" and http_request)
                   or (type(syn) == "table" and type(syn.request) == "function" and syn.request)
                   or (type(http) == "table" and type(http.request) == "function" and http.request)
        if reqFn then
            local ok, res = pcall(reqFn, { Url = url, Method = "GET" })
            if ok and res and res.Body and #res.Body >= 10 then return res.Body end
        end
        local ok, r = pcall(function() return (game :: any):HttpGet(url) end)
        if ok and r then return r end
        return nil
    end

    local function _safeReadFile(path)
        local fn = (type(readfile) == "function" and readfile) or nil
        if fn then
            local ok, r = pcall(fn, path)
            if ok and r then return r end
        end
        return nil
    end

    local function _safeIsFile(path)
        local fn = (type(isfile) == "function" and isfile) or nil
        if fn then
            local ok, r = pcall(fn, path)
            return ok and r == true
        end
        return false
    end

    -- ── Mobile / Touch detection ──────────────────────────────────────────
    local _cam    = workspace.CurrentCamera
    local _vpSize = (_cam and _cam.ViewportSize) or Vector2.new(1280, 720)
    local _isTouch = _safePcall(function() return UIS.TouchEnabled end) and UIS.TouchEnabled
    local _isKbd   = _safePcall(function() return UIS.KeyboardEnabled end) and UIS.KeyboardEnabled
    local _shortDim = math.min(_vpSize.X, _vpSize.Y)

    -- ── Roblox Thumbnail API cache ────────────────────────────────────────
    local _avatarCache = {}
    -- _avatarPending removed: no longer needed with built-in GetUserThumbnailAsync

    local function _fetchRobloxAvatar(userId)
        userId = tonumber(userId)
        if not userId then return nil end
        if _avatarCache[userId] then return _avatarCache[userId] end
        -- Use built-in Roblox API (works in ALL executors, no HTTP needed)
        -- NOTE: GetUserThumbnailAsync YIELDS, so must use task.spawn + pcall pattern
        task.spawn(function()
            pcall(function()
                local thumbUrl = Players:GetUserThumbnailAsync(
                    userId,
                    Enum.ThumbnailType.HeadShot,
                    Enum.ThumbnailSize.Size100x100
                )
                if thumbUrl and thumbUrl ~= "" then
                    _avatarCache[userId] = thumbUrl
                end
            end)
        end)
        return nil
    end

    local function _prefetchAllAvatars()
        for _, p in ipairs(Players:GetPlayers()) do
            if p ~= LocalPlayer and p.UserId and p.UserId > 0 then
                _fetchRobloxAvatar(p.UserId)
            end
        end
    end
    pcall(task.delay, 1, _prefetchAllAvatars)

    Players.PlayerAdded:Connect(function(p)
        if p.UserId and p.UserId > 0 then
            pcall(task.delay, 2, function() _fetchRobloxAvatar(p.UserId) end)
        end
    end)

    Players.PlayerRemoving:Connect(function(p)
        if p.UserId then
            _avatarCache[p.UserId] = nil

        end
    end)

    --- Synchronous avatar fetch: triggers async fetch then polls cache.
    --- GetUserThumbnailAsync is a yielding function - cannot be called
    --- directly inside pcall in some executors. Instead we trigger the
    --- async fetch (which uses task.spawn+pcall) and wait for the cache.
    local function _fetchRobloxAvatarSync(userId)
        userId = tonumber(userId)
        if not userId then return nil end
        if _avatarCache[userId] then return _avatarCache[userId] end
        -- Trigger async fetch (uses task.spawn + pcall, works everywhere)
        _fetchRobloxAvatar(userId)
        -- Poll cache up to 2 seconds
        local waited = 0
        while not _avatarCache[userId] and waited < 2 do
            pcall(task.wait, 0.1)
            waited = waited + 0.1
        end
        return _avatarCache[userId]
    end

    local function _resolveAvatar(playerName, player, themeKey, config)
        -- 1. Check custom avatars in config (per-user custom images)
        local customAvatars = config.customAvatars or {}
        local custom = customAvatars[playerName]
        if custom then
            if custom.file and custom.file ~= "" then
                local loaded = _safeGetCustomAsset(custom.file)
                if loaded then return loaded, custom end
            end
            if custom.url and custom.url ~= "" then
                return custom.url, custom
            end
        end
        -- 2. SYNCHRONOUS Roblox Avatar fetch (waits up to 3 seconds)
        if player and player.UserId and player.UserId > 0 then
            local avatarUrl = _fetchRobloxAvatarSync(player.UserId)
            if avatarUrl then return avatarUrl, nil end
        end
        -- 3. Role-based profile pictures (owner, admin, etc.)
        local profilePics = config.profilePictures or {}
        local rolePic = profilePics[themeKey]
        if rolePic then
            if rolePic.file and rolePic.file ~= "" then
                local loaded = _safeGetCustomAsset(rolePic.file)
                if loaded then return loaded, rolePic end
            end
            if rolePic.url and rolePic.url ~= "" then
                return rolePic.url, rolePic
            end
        end
        -- 4. nil -> show initials
        return nil, nil
    end

    -- =========================================================================
    -- COLOR ENGINE
    -- =========================================================================
    local function _parseColor(val)
        if typeof(val) == "Color3" then return val end
        if type(val) == "table" then
            local r = val.r or val[1] or 255
            local g = val.g or val[2] or 255
            local b = val.b or val[3] or 255
            if r <= 1 and g <= 1 and b <= 1 and (val.r or val[1]) then
                return Color3.new(r, g, b)
            end
            return Color3.fromRGB(math.clamp(r,0,255), math.clamp(g,0,255), math.clamp(b,0,255))
        end
        if type(val) ~= "string" then return Color3.new(1,1,1) end

        local str = val:gsub("%s+", "")
        local r, g, b = str:match("^rgba?%((%d+),(%d+),(%d+)")
        if r and g and b then
            return Color3.fromRGB(tonumber(r) or 255, tonumber(g) or 255, tonumber(b) or 255)
        end
        local h, s, l = str:match("^hsla?%((%d+),(%d+)%%?,(%d+)%%?")
        if h and s and l then
            return Color3.fromHSV((tonumber(h) or 0)/360, (tonumber(s) or 0)/100, (tonumber(l) or 0)/100)
        end
        local clean = str:gsub("^#", "")
        if #clean == 3 then
            clean = clean:sub(1,1)..clean:sub(1,1)..clean:sub(2,2)..clean:sub(2,2)..clean:sub(3,3)..clean:sub(3,3)
        elseif #clean == 4 then
            clean = clean:sub(1,1)..clean:sub(1,1)..clean:sub(2,2)..clean:sub(2,2)..clean:sub(3,3)..clean:sub(3,3)
        elseif #clean == 8 then
            clean = clean:sub(1,6)
        end
        if #clean == 6 then
            return Color3.fromRGB(
                tonumber(clean:sub(1,2), 16) or 255,
                tonumber(clean:sub(3,4), 16) or 255,
                tonumber(clean:sub(5,6), 16) or 255
            )
        end
        return Color3.new(1,1,1)
    end

    local function _deepCopy(orig)
        if type(orig) ~= "table" then return orig end
        local copy = {}
        for k, v in pairs(orig) do copy[k] = _deepCopy(v) end
        return copy
    end

    -- =========================================================================
    -- GRADIENT ENGINE
    -- =========================================================================
    local _GRAD_ANIM_ALIVE = {}
    local _GRAD_ANIM_INTERVAL = 1 / 30

    local function _canAnimateGradient()
        return type(task) == "table" and type(task.spawn) == "function" and type(task.wait) == "function"
    end

    local function _buildColorSequence(rawColors, rawTransparencies)
        local csPairs, nsPairs = {}, {}
        if type(rawColors) ~= "table" or #rawColors == 0 then
            return ColorSequence.new(Color3.new(1,1,1)), NumberSequence.new(0)
        end
        local keypoints = {}
        for i, item in ipairs(rawColors) do
            local cVal, pos
            if type(item) == "table" and item.color then
                cVal = _parseColor(item.color)
                pos = tonumber(item.pos or item.offset or item.position) or ((i-1) / math.max(1, #rawColors - 1))
            else
                cVal = _parseColor(item)
                pos = (i-1) / math.max(1, #rawColors - 1)
            end
            table.insert(keypoints, { t = math.clamp(pos, 0, 1), color = cVal })
        end
        table.sort(keypoints, function(a,b) return a.t < b.t end)
        if #keypoints == 1 then
            csPairs = { ColorSequenceKeypoint.new(0, keypoints[1].color), ColorSequenceKeypoint.new(1, keypoints[1].color) }
        else
            local lastT = -0.0001
            for i, kp in ipairs(keypoints) do
                local t = kp.t
                if i == 1 then t = 0 end
                if i == #keypoints then t = 1 end
                if t <= lastT then t = math.min(1, lastT + 0.001) end
                lastT = t
                table.insert(csPairs, ColorSequenceKeypoint.new(t, kp.color))
            end
        end
        if type(rawTransparencies) == "table" and #rawTransparencies > 0 then
            if #rawTransparencies == 1 then
                local tr = tonumber(rawTransparencies[1]) or 0
                nsPairs = { NumberSequenceKeypoint.new(0, tr), NumberSequenceKeypoint.new(1, tr) }
            else
                local lastT = -0.0001
                for i, trVal in ipairs(rawTransparencies) do
                    local t = (i-1) / math.max(1, #rawTransparencies - 1)
                    local tr = math.clamp(tonumber(trVal) or 0, 0, 1)
                    if i == 1 then t = 0 end
                    if i == #rawTransparencies then t = 1 end
                    if t <= lastT then t = math.min(1, lastT + 0.001) end
                    lastT = t
                    table.insert(nsPairs, NumberSequenceKeypoint.new(t, tr))
                end
            end
        else
            nsPairs = { NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(1, 0) }
        end
        local finalCS = _safePcall(function() return ColorSequence.new(csPairs) end) and ColorSequence.new(csPairs) or ColorSequence.new(Color3.new(1,1,1))
        local finalNS = _safePcall(function() return NumberSequence.new(nsPairs) end) and NumberSequence.new(nsPairs) or NumberSequence.new(0)
        return finalCS, finalNS
    end

    local _GRAD_TYPE_MAP = {
        linear="Linear", radial="Radial", conic="Conic", angular="Angular",
        mesh="Mesh", color="Color", blend="Blend", colorblend="Blend",
        duotone="Duotone", multicolor="Multicolor", smooth="Smooth",
        soft="Soft", glass="Glass", neon="Neon", metallic="Metallic",
        iridescent="Iridescent", holographic="Holographic", aurora="Aurora",
        sunset="Sunset", spectrum="Spectrum", liquid="Liquid",
        dynamic="Dynamic", fluid="Fluid", chromatic="Chromatic",
        ombre="Ombre", fade="Fade", transition="ColorTransition",
        colortransition="ColorTransition", overlay="Overlay",
        gradmesh="Mesh", flow="Flow", wave="Wave",
    }

    local function _applyGradient(target, gradCfg)
        if not target or not gradCfg or not gradCfg.enabled then return nil end
        local rawType = tostring(gradCfg.type or "Linear"):lower()
        local gType = _GRAD_TYPE_MAP[rawType] or "Linear"
        local colors = gradCfg.colors or { "#FFFFFF", "#000000" }
        local trans  = gradCfg.transparency or { 0, 0 }
        local rot    = tonumber(gradCfg.rotation) or 0
        local cs, ns = _buildColorSequence(colors, trans)

        local function _startAnimLoop(ug, speed, offsetFn)
            if not _canAnimateGradient() then return end
            local alive = { alive = true, parent = target }
            _GRAD_ANIM_ALIVE[#_GRAD_ANIM_ALIVE + 1] = alive
            pcall(task.spawn, function()
                local t = 0
                while alive.alive and target and target.Parent do
                    pcall(task.wait, _GRAD_ANIM_INTERVAL)
                    t = t + _GRAD_ANIM_INTERVAL
                    pcall(function() offsetFn(ug, t, speed) end)
                end
                alive.alive = false
            end)
            if #_GRAD_ANIM_ALIVE > 50 then
                local cleaned = {}
                for _, a in ipairs(_GRAD_ANIM_ALIVE) do
                    if a.alive then cleaned[#cleaned+1] = a end
                end
                _GRAD_ANIM_ALIVE = cleaned
            end
        end

        if gType == "Linear" then
            local ug = Instance.new("UIGradient", target)
            ug.Color = cs; ug.Transparency = ns; ug.Rotation = rot
            ug.Offset = Vector2.new(gradCfg.offset and gradCfg.offset[1] or 0, gradCfg.offset and gradCfg.offset[2] or 0)
            return ug
        elseif gType == "Radial" then
            local ug = Instance.new("UIGradient", target)
            ug.Color = cs; ug.Transparency = ns; ug.Rotation = rot
            ug.Style = Enum.GradientStyle.Radial
            return ug
        elseif gType == "Conic" or gType == "Angular" then
            local ug = Instance.new("UIGradient", target)
            ug.Color = cs; ug.Transparency = ns; ug.Rotation = rot
            ug.Style = Enum.GradientStyle.Radial
            _startAnimLoop(ug, gradCfg.speed or 0.5, function(g, t, s)
                g.Rotation = (rot + t * s * 360) % 360
            end)
            return ug
        elseif gType == "Mesh" then
            local layers = gradCfg.layers
            if type(layers) ~= "table" or #layers == 0 then
                layers = {
                    { colors = colors, transparency = trans, rotation = rot },
                    { colors = { colors[#colors] or "#000000", colors[1] or "#FFFFFF" }, transparency = {0.5,0.5}, rotation = (rot+90)%360 },
                }
            end
            for _, layer in ipairs(layers) do
                local lcs, lns = _buildColorSequence(layer.colors, layer.transparency)
                local lug = Instance.new("UIGradient", target)
                lug.Color = lcs; lug.Transparency = lns; lug.Rotation = layer.rotation or rot
                lug.Offset = Vector2.new(0.5, 0.5)
            end
            return nil
        elseif gType == "Color" or gType == "ColorTransition" then
            local ug = Instance.new("UIGradient", target)
            ug.Color = cs; ug.Transparency = ns; ug.Rotation = rot
            return ug
        elseif gType == "Blend" then
            local ug = Instance.new("UIGradient", target)
            local bns = NumberSequence.new({
                NumberSequenceKeypoint.new(0, math.clamp(trans[1] or 0, 0, 0.9)),
                NumberSequenceKeypoint.new(0.5, math.clamp(trans[2] or 0.3, 0, 0.9)),
                NumberSequenceKeypoint.new(1, math.clamp(trans[1] or 0, 0, 0.9)),
            })
            ug.Color = cs; ug.Transparency = bns; ug.Rotation = rot
            return ug
        elseif gType == "Duotone" then
            local c1 = _parseColor(colors[1] or "#FFFFFF")
            local c2 = _parseColor(colors[2] or "#000000")
            target.BackgroundColor3 = c1
            local ug = Instance.new("UIGradient", target)
            ug.Color = ColorSequence.new(c2, c1)
            ug.Transparency = NumberSequence.new({
                NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(0.5, 0.3), NumberSequenceKeypoint.new(1, 0),
            })
            ug.Rotation = rot
            return ug
        elseif gType == "Multicolor" or gType == "Spectrum" then
            local ug = Instance.new("UIGradient", target)
            ug.Color = cs; ug.Transparency = ns; ug.Rotation = rot
            _startAnimLoop(ug, gradCfg.speed or 0.3, function(g, t, s)
                g.Rotation = (rot + t * s * 120) % 360
            end)
            return ug
        elseif gType == "Smooth" then
            local smoothCS = {}
            for i = 1, #colors do
                local t = (i-1) / math.max(1, #colors-1)
                smoothCS[#smoothCS+1] = ColorSequenceKeypoint.new(t, _parseColor(colors[i]))
            end
            if #smoothCS == 2 then
                local mid = _parseColor(colors[1]):Lerp(_parseColor(colors[2]), 0.5)
                smoothCS = {
                    ColorSequenceKeypoint.new(0, _parseColor(colors[1])),
                    ColorSequenceKeypoint.new(0.5, mid),
                    ColorSequenceKeypoint.new(1, _parseColor(colors[2])),
                }
            end
            local ug = Instance.new("UIGradient", target)
            ug.Color = ColorSequence.new(smoothCS); ug.Transparency = ns; ug.Rotation = rot
            return ug
        elseif gType == "Soft" then
            local softColors = {}
            for i = 1, #colors do
                softColors[#softColors+1] = ColorSequenceKeypoint.new(
                    (i-1)/math.max(1,#colors-1),
                    _parseColor(colors[i]):Lerp(Color3.new(1,1,1), 0.2)
                )
            end
            if #softColors == 2 then
                local c1 = _parseColor(colors[1]):Lerp(Color3.new(1,1,1), 0.2)
                local c2 = _parseColor(colors[2]):Lerp(Color3.new(1,1,1), 0.2)
                local mid = c1:Lerp(c2, 0.5)
                softColors = {
                    ColorSequenceKeypoint.new(0, c1), ColorSequenceKeypoint.new(0.35, mid),
                    ColorSequenceKeypoint.new(0.65, mid), ColorSequenceKeypoint.new(1, c2),
                }
            end
            local ug = Instance.new("UIGradient", target)
            ug.Color = ColorSequence.new(softColors); ug.Transparency = ns; ug.Rotation = rot
            ug.Style = Enum.GradientStyle.Radial
            return ug
        elseif gType == "Glass" then
            local ug = Instance.new("UIGradient", target)
            ug.Color = cs; ug.Rotation = rot + 45
            ug.Transparency = NumberSequence.new({
                NumberSequenceKeypoint.new(0, 0.3), NumberSequenceKeypoint.new(0.3, 0),
                NumberSequenceKeypoint.new(0.6, 0.15), NumberSequenceKeypoint.new(1, 0.5),
            })
            return ug
        elseif gType == "Neon" then
            local neonCS = {}
            for i = 1, #colors do
                local c = _parseColor(colors[i])
                local bright = c:Lerp(Color3.new(1,1,1), 0.5)
                local soft = c:Lerp(Color3.new(1,1,1), 0.2)
                local base = (i-1)/#colors
                neonCS[#neonCS+1] = ColorSequenceKeypoint.new(math.clamp(base,0,1), soft)
                neonCS[#neonCS+1] = ColorSequenceKeypoint.new(math.clamp(base+0.2/#colors,0,1), bright)
                neonCS[#neonCS+1] = ColorSequenceKeypoint.new(math.clamp(base+0.4/#colors,0,1), soft)
            end
            neonCS[#neonCS+1] = ColorSequenceKeypoint.new(1, neonCS[1].Value)
            local ug = Instance.new("UIGradient", target)
            ug.Color = ColorSequence.new(neonCS); ug.Rotation = rot
            ug.Transparency = NumberSequence.new({
                NumberSequenceKeypoint.new(0,0), NumberSequenceKeypoint.new(0.25,0.1),
                NumberSequenceKeypoint.new(0.5,0), NumberSequenceKeypoint.new(0.75,0.1), NumberSequenceKeypoint.new(1,0),
            })
            _startAnimLoop(ug, gradCfg.speed or 1, function(g, t, s)
                g.Rotation = (rot + t * s * 60) % 360
            end)
            return ug
        elseif gType == "Metallic" then
            local metCS = {}
            for i = 1, #colors do
                local c = _parseColor(colors[i])
                local base = (i-1)/#colors
                metCS[#metCS+1] = ColorSequenceKeypoint.new(math.clamp(base,0,1), c:Lerp(Color3.new(0,0,0),0.45))
                metCS[#metCS+1] = ColorSequenceKeypoint.new(math.clamp(base+0.15/#colors,0,1), c:Lerp(Color3.new(1,1,1),0.15))
                metCS[#metCS+1] = ColorSequenceKeypoint.new(math.clamp(base+0.35/#colors,0,1), c:Lerp(Color3.new(1,1,1),0.5))
                metCS[#metCS+1] = ColorSequenceKeypoint.new(math.clamp(base+0.5/#colors,0,1), c:Lerp(Color3.new(1,1,1),0.15))
            end
            metCS[#metCS+1] = ColorSequenceKeypoint.new(1, metCS[1].Value)
            local ug = Instance.new("UIGradient", target)
            ug.Color = ColorSequence.new(metCS); ug.Transparency = ns; ug.Rotation = rot
            return ug
        elseif gType == "Iridescent" or gType == "Holographic" then
            local c1 = _parseColor(colors[1])
            local c2 = _parseColor(colors[2] or colors[1])
            local c3 = _parseColor(colors[3] or colors[2] or colors[1])
            local iriCS = {
                ColorSequenceKeypoint.new(0, c1:Lerp(Color3.new(1,1,1),0.3)),
                ColorSequenceKeypoint.new(0.33, c1:Lerp(c2,0.33):Lerp(Color3.new(1,1,1),0.2)),
                ColorSequenceKeypoint.new(0.66, c2:Lerp(c3,0.66):Lerp(Color3.new(1,1,1),0.2)),
                ColorSequenceKeypoint.new(1, c2:Lerp(Color3.new(1,1,1),0.3)),
            }
            local ug = Instance.new("UIGradient", target)
            ug.Color = ColorSequence.new(iriCS); ug.Rotation = rot
            ug.Transparency = NumberSequence.new({
                NumberSequenceKeypoint.new(0,0), NumberSequenceKeypoint.new(0.25,0.05),
                NumberSequenceKeypoint.new(0.5,0), NumberSequenceKeypoint.new(0.75,0.05), NumberSequenceKeypoint.new(1,0),
            })
            _startAnimLoop(ug, gradCfg.speed or 0.4, function(g, t, s)
                g.Rotation = (rot + t * s * 90) % 360
            end)
            return ug
        elseif gType == "Aurora" then
            local auCS = {}
            for i = 1, #colors do
                auCS[#auCS+1] = ColorSequenceKeypoint.new((i-1)/math.max(1,#colors-1), _parseColor(colors[i]))
            end
            if #auCS < 3 then
                local c1 = _parseColor(colors[1])
                local c2 = _parseColor(colors[2] or colors[1])
                auCS = {
                    ColorSequenceKeypoint.new(0, c1),
                    ColorSequenceKeypoint.new(0.5, c1:Lerp(c2, 0.5)),
                    ColorSequenceKeypoint.new(1, c2),
                }
            end
            local ug = Instance.new("UIGradient", target)
            ug.Color = ColorSequence.new(auCS); ug.Rotation = rot
            ug.Transparency = NumberSequence.new({
                NumberSequenceKeypoint.new(0,0.1), NumberSequenceKeypoint.new(0.3,0),
                NumberSequenceKeypoint.new(0.7,0), NumberSequenceKeypoint.new(1,0.1),
            })
            _startAnimLoop(ug, gradCfg.speed or 0.3, function(g, t, s)
                g.Rotation = (rot + t * s * 50) % 360
            end)
            return ug
        elseif gType == "Sunset" then
            local ssCS = {}
            for i = 1, #colors do
                ssCS[#ssCS+1] = ColorSequenceKeypoint.new((i-1)/math.max(1,#colors-1), _parseColor(colors[i]))
            end
            local ug = Instance.new("UIGradient", target)
            ug.Color = ColorSequence.new(ssCS); ug.Transparency = ns; ug.Rotation = rot
            return ug
        elseif gType == "Liquid" or gType == "Fluid" then
            local ug = Instance.new("UIGradient", target)
            ug.Color = cs; ug.Transparency = ns; ug.Rotation = rot
            ug.Style = Enum.GradientStyle.Radial
            _startAnimLoop(ug, gradCfg.speed or 0.5, function(g, t, s)
                g.Rotation = (rot + math.sin(t * s) * 45) % 360
                g.Offset = Vector2.new(math.sin(t * s * 0.7) * 0.15, math.cos(t * s * 0.5) * 0.15)
            end)
            return ug
        elseif gType == "Dynamic" or gType == "Flow" then
            local ug = Instance.new("UIGradient", target)
            ug.Color = cs; ug.Transparency = ns; ug.Rotation = rot
            _startAnimLoop(ug, gradCfg.speed or 1, function(g, t, s)
                g.Rotation = (rot + t * s * 30) % 360
                g.Offset = Vector2.new(math.sin(t * s * 0.4) * 0.2, 0)
            end)
            return ug
        elseif gType == "Chromatic" then
            local chCS = {}
            for i = 1, #colors do
                chCS[#chCS+1] = ColorSequenceKeypoint.new((i-1)/math.max(1,#colors-1), _parseColor(colors[i]))
            end
            if #chCS < 3 then
                local extra = _parseColor(colors[1] or "#FFFFFF"):Lerp(_parseColor(colors[2] or "#000000"), 0.5)
                table.insert(chCS, 2, ColorSequenceKeypoint.new(0.5, extra))
            end
            local ug = Instance.new("UIGradient", target)
            ug.Color = ColorSequence.new(chCS); ug.Transparency = ns; ug.Rotation = rot
            _startAnimLoop(ug, gradCfg.speed or 0.6, function(g, t, s)
                g.Offset = Vector2.new((t * s * 0.3) % 1 - 0.5, 0)
            end)
            return ug
        elseif gType == "Ombre" or gType == "Fade" then
            local oC1 = _parseColor(colors[1] or "#000000")
            local oC2 = _parseColor(colors[2] or "#FFFFFF")
            local ug = Instance.new("UIGradient", target)
            ug.Color = ColorSequence.new(oC1, oC1, oC2, oC2); ug.Rotation = rot
            ug.Transparency = NumberSequence.new({
                NumberSequenceKeypoint.new(0,0), NumberSequenceKeypoint.new(0.4,0),
                NumberSequenceKeypoint.new(0.6,0.4), NumberSequenceKeypoint.new(1,0.8),
            })
            return ug
        elseif gType == "Wave" then
            local waveNS = {}
            local freq = gradCfg.frequency or 4
            local amp  = gradCfg.amplitude or 0.3
            for i = 0, 10 do
                local t = i / 10
                waveNS[#waveNS+1] = NumberSequenceKeypoint.new(t, (trans[1] or 0) + amp * math.abs(math.sin(t * freq * math.pi)))
            end
            local ug = Instance.new("UIGradient", target)
            ug.Color = cs; ug.Transparency = NumberSequence.new(waveNS); ug.Rotation = rot
            _startAnimLoop(ug, gradCfg.speed or 0.5, function(g, t, s)
                g.Offset = Vector2.new(math.sin(t * s) * 0.2, 0)
            end)
            return ug
        elseif gType == "Overlay" then
            local ug = Instance.new("UIGradient", target)
            ug.Color = cs; ug.Rotation = rot + 45
            ug.Transparency = NumberSequence.new({
                NumberSequenceKeypoint.new(0,0.2), NumberSequenceKeypoint.new(0.5,0), NumberSequenceKeypoint.new(1,0.2),
            })
            return ug
        end
        return nil
    end

    local function _applyAllGradients(card, avatar, nameLabel, roleTxt, cardBorder, gradCfg)
        if type(gradCfg) ~= "table" then return end
        if gradCfg.cardGradient   and gradCfg.cardGradient.enabled   then _applyGradient(card,     gradCfg.cardGradient)   end
        if gradCfg.avatarGradient and gradCfg.avatarGradient.enabled then _applyGradient(avatar,   gradCfg.avatarGradient) end
        if gradCfg.nameGradient   and gradCfg.nameGradient.enabled   then _applyGradient(nameLabel, gradCfg.nameGradient)   end
        if gradCfg.roleGradient   and gradCfg.roleGradient.enabled   then _applyGradient(roleTxt,   gradCfg.roleGradient)   end
        if gradCfg.borderGradient and gradCfg.borderGradient.enabled and cardBorder then
            _applyGradient(cardBorder, gradCfg.borderGradient)
        end
    end

    local function _resolveGradients(playerName, roleKey, theme, config)
        local resolved = {}
        local targets = { "cardGradient", "avatarGradient", "nameGradient", "roleGradient", "borderGradient" }
        local userGrads  = config.userGradientOverrides and config.userGradientOverrides[playerName]
        local themeGrads = (theme and theme.gradients)
        local globalGrads = config.gradients or {}
        local defaultGrads = _DEFAULTS and _DEFAULTS.gradients or {}
        for _, key in ipairs(targets) do
            local g = (userGrads and userGrads[key])
                   or (themeGrads and themeGrads[key])
                   or (globalGrads and globalGrads[key])
                   or (defaultGrads and defaultGrads[key])
            if g then resolved[key] = _deepCopy(g) end
        end
        return resolved
    end

    -- =========================================================================
    -- FONT & EASING HELPERS
    -- =========================================================================
    local _fontCache = {}
    local function _safeFont(name)
        if _fontCache[name] ~= nil then return _fontCache[name] end
        local ok, result = pcall(function() return Enum.Font[name] end)
        _fontCache[name] = ok and result or Enum.Font.GothamBold
        return _fontCache[name]
    end

    local _EASING_MAP = {
        Quad=Enum.EasingStyle.Quad, Linear=Enum.EasingStyle.Linear,
        Sine=Enum.EasingStyle.Sine, Expo=Enum.EasingStyle.Exponential,
        Exponential=Enum.EasingStyle.Exponential, Back=Enum.EasingStyle.Back,
        Bounce=Enum.EasingStyle.Bounce, Elastic=Enum.EasingStyle.Elastic,
    }
    local function _safeEasing(name)
        return _EASING_MAP[name] or Enum.EasingStyle.Quad
    end

    -- =========================================================================
    -- DEFAULTS & CONFIG
    -- =========================================================================
    local ownerProfilePicUrl      = "https://raw.githubusercontent.com/shortviet/Syndicate-Universal-Script/refs/heads/main/NAMETAG-PROFILEPICTURES/SU-owner.png"
    local ownerProfilePicFileName = "assets/SU-ROLE-PICS/SU-owner.png"
    local userProfilePicUrl       = "" -- Removed TL logo; Roblox avatar is primary, initials are fallback
    local userProfilePicFileName  = ""

    local _DEFAULTS = {
        enabled = true,
        themes = {
            user       = { bg="#1A1A22", avatarBg="#1F1F2C", avatarText="#A0A0C0", divider="#A0A0C0", border="#A0A0B4", nameText="#E6E6F0", roleText="#7878A0", bgGradient=false, bgGradientType="linear", bgGradientColors={"#1A1A22","#0E0E18"}, bgGradientAngle=0 },
            admin      = { bg="#220E0E", avatarBg="#2A1212", avatarText="#FF6464", divider="#FF6464", border="#DC5050", nameText="#FF8C8C", roleText="#C83C3C", bgGradient=false, bgGradientType="linear", bgGradientColors={"#220E0E","#150808"}, bgGradientAngle=0 },
            owner      = { bg="#160E1E", avatarBg="#1B1226", avatarText="#B87CFF", divider="#B87CFF", border="#AA64FF", nameText="#DDB8FF", roleText="#8850CC", bgGradient=false, bgGradientType="linear", bgGradientColors={"#160E1E","#0D0814"}, bgGradientAngle=0 },
            developer  = { bg="#0C1428", avatarBg="#101A34", avatarText="#64B4FF", divider="#64B4FF", border="#50A0F0", nameText="#8CD2FF", roleText="#3C82DC", bgGradient=false, bgGradientType="linear", bgGradientColors={"#0C1428","#060A18"}, bgGradientAngle=0 },
            moderator  = { bg="#221C0A", avatarBg="#2A220C", avatarText="#FFC83C", divider="#FFC83C", border="#F0B428", nameText="#FFDC64", roleText="#DCA01E", bgGradient=false, bgGradientType="linear", bgGradientColors={"#221C0A","#141006"}, bgGradientAngle=0 },
            advertising= { bg="#1C0E24", avatarBg="#24122E", avatarText="#C878FF", divider="#C878FF", border="#B464F0", nameText="#E6AAFF", roleText="#A050D2", bgGradient=false, bgGradientType="linear", bgGradientColors={"#1C0E24","#100818"}, bgGradientAngle=0 },
            staff      = { bg="#0A1C10", avatarBg="#0C2A14", avatarText="#4ADE80", divider="#4ADE80", border="#22C55E", nameText="#6EEAA0", roleText="#16A34A", bgGradient=false, bgGradientType="linear", bgGradientColors={"#0A1C10","#061008"}, bgGradientAngle=0 },
        },
        layout = {
            billboardWidth=240, billboardHeight=44, studsOffsetY=3.4, avatarWidth=44,
            cornerRadius=8, innerCornerRadius=5, borderThickness=1, dividerWidth=1,
            dividerHeightPct=0.6, dividerTransparency=0.75, nameTextSize=13, nameFont="GothamBold",
            roleTextSize=9, roleFont="GothamBold", initialsTextSize=11, avatarTextGap=10,
            textPaddingRight=4, nameLabelHeight=20, nameLabelY=4, roleLabelHeight=12, roleLabelY=26,
            roleTextTransform="upper", avatarImagePadding=3, distanceScaleEnabled=true,
            distanceScaleNear=10, distanceScaleFar=60, distanceScaleMin=0.35,
        },
        animations = { fadeInDuration=0.3, fadeInEasing="Quad", cardTransparency=0, borderTransparency=0.3 },
        particles  = { enabled=true, count=4, minSize=2, maxSize=4, transparency=0.5, moveDurationMin=3, moveDurationMax=5, colors={"#B87CFF","#A064F0","#C896FF","#8C50DC","#DDB8FF"} },
        roleKeywords = {
            owner={"owner","vip"}, developer={"developer","entwickler"}, moderator={"moderator","mod"},
            admin={"admin","administrator"}, staff={"staff"}, advertising={"advertising","werbung"},
        },
        roleUsers = { owner={}, admin={}, developer={}, moderator={}, staff={}, advertising={}, user={} },
        profilePictures = {
            owner={url=ownerProfilePicUrl, file=ownerProfilePicFileName},
            user={},
            admin={}, developer={}, moderator={}, staff={url="https://raw.githubusercontent.com/shortviet/Syndicate-Universal-Parts/main/ROLE-ICONS/SU-STAFF.png", file="assets/ROLE-ICONS/SU-STAFF.png"},
            advertising={},
        },
        customAvatars={}, roleLabels={}, displayNames={}, roleDisplayNames={},
        userColorOverrides={}, userGradientOverrides={},
        gradients = {
            cardGradient   = {enabled=false, type="Linear", colors={"#B87CFF","#1A1A22"}, transparency={0,0}, rotation=90, offset={0,0}},
            avatarGradient = {enabled=false, type="Linear", colors={"#B87CFF","#160E1E"}, transparency={0,0}, rotation=180, offset={0,0}},
            nameGradient   = {enabled=false, type="Linear", colors={"#FFFFFF","#B87CFF"}, transparency={0,0}, rotation=0, offset={0,0}},
            roleGradient   = {enabled=false, type="Linear", colors={"#B87CFF","#8850CC"}, transparency={0,0}, rotation=0, offset={0,0}},
            borderGradient = {enabled=false, type="Linear", colors={"#B87CFF","#AA64FF"}, transparency={0,0}, rotation=0, offset={0,0}},
        },
    }

    local _CONFIG = _deepCopy(_DEFAULTS)

    local function _deepMerge(base, overlay)
        for k, v in pairs(overlay) do
            if type(v) == "table" and type(base[k]) == "table" then
                _deepMerge(base[k], v)
            else
                base[k] = v
            end
        end
    end

    local NAMETAG_CONFIG_URL = "https://raw.githubusercontent.com/shortviet/Syndicate-Universal-Script/refs/heads/main/NametagConfig.json"
    pcall(task.spawn, function()
        local raw = _safeHttpGet(NAMETAG_CONFIG_URL)
        if raw then
            local ok, parsed = pcall(function() return Http:JSONDecode(raw) end)
            if ok and type(parsed) == "table" then _deepMerge(_CONFIG, parsed) end
        end
    end)

    if _safeIsFile("NametagConfig.json") then
        local raw = _safeReadFile("NametagConfig.json")
        if raw then
            local ok, parsed = pcall(function() return Http:JSONDecode(raw) end)
            if ok and type(parsed) == "table" then _deepMerge(_CONFIG, parsed) end
        end
    end

    local NameOverrides = ctx.NameOverrides or {}
    local AdminNames = ctx.AdminNames or {}

    -- =========================================================================
    -- PARTICLES
    -- =========================================================================
    local function _spawnParticles(billboard, particleCfg)
        if not particleCfg or not particleCfg.enabled then return end
        local count = particleCfg.count or 4
        local minSz = particleCfg.minSize or 2
        local maxSz = particleCfg.maxSize or 4
        local trans = particleCfg.transparency or 0.5
        local durMin = particleCfg.moveDurationMin or 3
        local durMax = particleCfg.moveDurationMax or 5
        local pColors = particleCfg.colors or { "#B87CFF" }
        for _ = 1, count do
            pcall(task.spawn, function()
                local sz = minSz + math.random() * (maxSz - minSz)
                local dot = Instance.new("Frame")
                dot.Size = UDim2.new(0, sz, 0, sz)
                dot.BackgroundColor3 = _parseColor(pColors[math.random(1, #pColors)])
                dot.BackgroundTransparency = trans
                dot.BorderSizePixel = 0
                dot.AnchorPoint = Vector2.new(0.5, 0.5)
                dot.Position = UDim2.new(math.random(), 0, math.random(), 0)
                dot.Parent = billboard
                local corner = Instance.new("UICorner")
                corner.CornerRadius = UDim.new(1, 0)
                corner.Parent = dot
                local dur = durMin + math.random() * (durMax - durMin)
                local startPos = Vector2.new(math.random(), math.random())
                local endPos = Vector2.new(math.random(), math.random())
                if _canAnimateGradient() then
                    pcall(task.spawn, function()
                        local t = 0
                        while dot and dot.Parent do
                            pcall(task.wait, _GRAD_ANIM_INTERVAL)
                            t = t + _GRAD_ANIM_INTERVAL
                            if t >= dur then dot:Destroy() return end
                            local alpha = t / dur
                            dot.Position = UDim2.new(
                                startPos.X + (endPos.X - startPos.X) * alpha, 0,
                                startPos.Y + (endPos.Y - startPos.Y) * alpha, 0
                            )
                        end
                    end)
                end
                pcall(task.delay, durMax + 1, function()
                    if dot and dot.Parent then dot:Destroy() end
                end)
            end)
        end
    end

    -- =========================================================================
    -- DISTANCE SCALING
    -- =========================================================================
    local _DISTANCE_CONNECTIONS = {}

    local function _setupDistanceScaling(billboard, layoutCfg)
        if not layoutCfg or not layoutCfg.distanceScaleEnabled then return end
        local near = layoutCfg.distanceScaleNear or 10
        local far  = layoutCfg.distanceScaleFar or 60
        local minS = layoutCfg.distanceScaleMin or 0.35
        local UIS = billboard:FindFirstChildOfClass("UIScale")
        if not UIS then UIS = Instance.new("UIScale"); UIS.Parent = billboard end
        local conn
        conn = RS.Heartbeat:Connect(function()
            if not billboard or not billboard.Parent then
                if conn then conn:Disconnect() end; return
            end
            local adornee = billboard.Adornee
            if not adornee then return end
            local camPos = workspace.CurrentCamera and workspace.CurrentCamera.CFrame.Position
            if not camPos then return end
            local char = adornee.Parent
            if not char then return end
            local hrp = char:FindFirstChild("HumanoidRootPart")
            if not hrp then return end
            local dist = (hrp.Position - camPos).Magnitude
            local alpha = math.clamp((dist - near) / (far - near), 0, 1)
            UIS.Scale = 1 - alpha * (1 - minS)
        end)
        _DISTANCE_CONNECTIONS[#_DISTANCE_CONNECTIONS + 1] = conn
    end

    -- =========================================================================
    -- CORE: CreateCustomNametag
    -- =========================================================================
    local creatingNametag = {}

    local function CreateCustomNametag(character, playerName, isAdmin)
        if not character then return end
        if creatingNametag[playerName] then return end
        creatingNametag[playerName] = true

        local player = Players:FindFirstChild(playerName)
        local playerUserId = player and tostring(player.UserId) or nil
        local override = NameOverrides[playerName]
        if not override and playerUserId then override = NameOverrides[playerUserId] end

        local displayName = _CONFIG.displayNames and _CONFIG.displayNames[playerName]
            or (override and override.display) or playerName
        local roleLabel = _CONFIG.roleLabels and _CONFIG.roleLabels[playerName]
            or (override and override.role) or nil

        local roleLower    = (roleLabel or (isAdmin and "SU Admin" or "SU User")):lower()
        local displayLower = (override and override.display or ""):lower()
        local themeKey     = "user"

        local _ROLE_PRIO = { owner=7, developer=6, admin=5, moderator=4, staff=3, advertising=2, user=1 }
        local highestPrio = 0
        for role, users in pairs(_CONFIG.roleUsers) do
            for _, u in ipairs(users) do
                if u:lower() == playerName:lower() then
                    local prio = _ROLE_PRIO[role] or 0
                    if prio > highestPrio then highestPrio = prio; themeKey = role end
                    break
                end
            end
        end

        if themeKey == "user" then
            for tk, keywords in pairs(_CONFIG.roleKeywords) do
                for _, kw in ipairs(keywords) do
                    if roleLower:find(kw) or displayLower:find(kw) then themeKey = tk; break end
                end
                if themeKey ~= "user" then break end
            end
        end

        if themeKey == "user" and isAdmin then themeKey = "admin" end

        if themeKey == "user" and displayName == playerName and player then
            local dn = player:FindFirstChild("DisplayName")
            if dn and dn.Value ~= "" then displayName = dn.Value end
        end

        if not roleLabel then
            local _ROLE_DEFAULTS = {
                user="SU User", admin="SU Admin", owner="SU Owner",
                developer="SU Developer", advertising="SU Advertising",
                moderator="SU Moderator", staff="SU Staff",
            }
            roleLabel = (_CONFIG.roleDisplayNames and _CONFIG.roleDisplayNames[themeKey])
                or _ROLE_DEFAULTS[themeKey] or "SU User"
        end

        local theme = _CONFIG.themes[themeKey] or _DEFAULTS.themes.user

        local userColorOvr = _CONFIG.userColorOverrides and _CONFIG.userColorOverrides[playerName]
        if userColorOvr and userColorOvr.__enabled then
            theme = _deepCopy(theme)
            for k, v in pairs(userColorOvr) do
                if k ~= "__enabled" and v ~= nil then
                    if v == "transparent" then theme[k] = Color3.new(1,1,1); theme[k .. "_transparent"] = true
                    else theme[k] = v end
                end
            end
        end

        local userGradOvr = _CONFIG.userGradientOverrides and _CONFIG.userGradientOverrides[playerName]
        local savedGrads = nil
        if userGradOvr then
            savedGrads = _deepCopy(_CONFIG.gradients)
            for gk, gd in pairs(userGradOvr) do
                if _CONFIG.gradients[gk] then _CONFIG.gradients[gk] = _deepCopy(gd) end
            end
        end

        local head = character:WaitForChild("Head", 5)
        if not head then creatingNametag[playerName] = nil; return end

        local existingTag = CoreGui:FindFirstChild("CovertPeerTag_" .. playerName)
        if existingTag then existingTag:Destroy() end

        local avatarUrl, avatarMeta = _resolveAvatar(playerName, player, themeKey, _CONFIG)

        local L = _CONFIG.layout
        local billboard = Instance.new("BillboardGui")
        billboard.Name = "CovertPeerTag_" .. playerName
        billboard.Adornee = head
        billboard.Size = UDim2.new(0, L.billboardWidth, 0, L.billboardHeight)
        billboard.StudsOffset = Vector3.new(0, L.studsOffsetY, 0)
        billboard.AlwaysOnTop = true
        billboard.LightInfluence = 0

        local card = Instance.new("Frame")
        card.Size = UDim2.new(1, 0, 1, 0)
        card.AnchorPoint = Vector2.new(0.5, 0.5)
        card.Position = UDim2.new(0.5, 0, 0.5, 0)
        card.BorderSizePixel = 0
        card.BackgroundTransparency = 1

        local cardBgColor = _parseColor(theme.bg)
        if theme.bgGradient and theme.bgGradientColors and #theme.bgGradientColors >= 2 then
            cardBgColor = _parseColor(theme.bgGradientColors[1])
        end
        card.BackgroundColor3 = cardBgColor
        card.Parent = billboard

        local cardScale = Instance.new("UIScale")
        cardScale.Scale = 1; cardScale.Parent = card

        if theme.bgGradient then
            card.BackgroundTransparency = 1
            _applyGradient(card, {
                enabled=true, type=theme.bgGradientType or "Linear",
                colors=theme.bgGradientColors or {"#1A1A22","#0E0E18"},
                transparency={0,0}, rotation=theme.bgGradientAngle or theme.bgGradientRotation or 0, offset={0,0},
            })
        end

        local cardCorner = Instance.new("UICorner")
        cardCorner.CornerRadius = UDim.new(0, L.cornerRadius); cardCorner.Parent = card

        local cardBorder = Instance.new("UIStroke")
        cardBorder.Color = _parseColor(theme.border)
        cardBorder.Thickness = L.borderThickness
        cardBorder.Transparency = 1
        cardBorder.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
        cardBorder.Parent = card
        if avatarMeta and avatarMeta.strokeColor then
            cardBorder.Color = Color3.new(1,1,1)
            local grad = Instance.new("UIGradient", cardBorder)
            grad.Color = avatarMeta.strokeColor
        end

        local avatar = Instance.new("Frame")
        avatar.Size = UDim2.new(0, L.avatarWidth, 1, 0)
        avatar.Position = UDim2.new(0, 0, 0, 0)
        avatar.BackgroundColor3 = _parseColor(theme.avatarBg)
        avatar.BackgroundTransparency = theme.avatarBg_transparent and 1 or 0
        avatar.BorderSizePixel = 0; avatar.ZIndex = 2; avatar.Parent = card

        local avatarCorner = Instance.new("UICorner")
        avatarCorner.CornerRadius = UDim.new(0, L.cornerRadius); avatarCorner.Parent = avatar

        local avPad = L.avatarImagePadding or 3
        local avInset = avPad * 2

        if avatarUrl and avatarUrl ~= "" then
            local imgLabel = Instance.new("ImageLabel")
            imgLabel.Size = UDim2.new(1, -avInset, 1, -avInset)
            imgLabel.Position = UDim2.new(0, avPad, 0, avPad)
            imgLabel.BackgroundTransparency = 1
            imgLabel.Image = avatarUrl
            imgLabel.ScaleType = Enum.ScaleType.Crop
            imgLabel.ZIndex = 3; imgLabel.Parent = avatar
            local imgCorner = Instance.new("UICorner")
            imgCorner.CornerRadius = UDim.new(0, L.innerCornerRadius); imgCorner.Parent = imgLabel
        else
            local initials = ""
            for word in displayName:gmatch("%S+") do
                initials = initials .. word:sub(1,1)
                if #initials >= 2 then break end
            end
            if #initials == 0 then initials = playerName:sub(1,1):upper() end
            local initLabel = Instance.new("TextLabel")
            initLabel.Size = UDim2.new(1, -avInset, 1, -avInset)
            initLabel.Position = UDim2.new(0, avPad, 0, avPad)
            initLabel.BackgroundTransparency = 1
            initLabel.Text = initials
            initLabel.TextColor3 = _parseColor(theme.avatarText)
            initLabel.TextSize = L.initialsTextSize or 11
            initLabel.Font = _safeFont(theme.nameFont or "GothamBold")
            initLabel.ZIndex = 3; initLabel.Parent = avatar
        end

        local divider = Instance.new("Frame")
        divider.Size = UDim2.new(0, L.dividerWidth, L.dividerHeightPct, 0)
        divider.Position = UDim2.new(0, L.avatarWidth, 0.5, 0)
        divider.AnchorPoint = Vector2.new(0, 0.5)
        divider.BackgroundColor3 = _parseColor(theme.divider)
        divider.BackgroundTransparency = L.dividerTransparency or 0.75
        divider.BorderSizePixel = 0; divider.ZIndex = 2; divider.Parent = card

        local textArea = Instance.new("Frame")
        textArea.Size = UDim2.new(1, -(L.avatarWidth + L.avatarTextGap + L.textPaddingRight), 1, 0)
        textArea.Position = UDim2.new(0, L.avatarWidth + L.avatarTextGap, 0, 0)
        textArea.BackgroundTransparency = 1; textArea.ZIndex = 2; textArea.Parent = card

        local nameText = Instance.new("TextLabel")
        nameText.Size = UDim2.new(1, 0, 0, L.nameLabelHeight)
        nameText.Position = UDim2.new(0, 0, 0, L.nameLabelY)
        nameText.BackgroundTransparency = 1
        nameText.Text = displayName
        nameText.TextColor3 = _parseColor(theme.nameText)
        nameText.TextSize = L.nameTextSize
        nameText.Font = _safeFont(L.nameFont or "GothamBold")
        nameText.TextXAlignment = Enum.TextXAlignment.Left
        nameText.TextTruncate = Enum.TextTruncate.AtEnd
        nameText.ZIndex = 3; nameText.Parent = textArea

        local roleText = Instance.new("TextLabel")
        roleText.Size = UDim2.new(1, 0, 0, L.roleLabelHeight)
        roleText.Position = UDim2.new(0, 0, 0, L.roleLabelY)
        roleText.BackgroundTransparency = 1
        roleText.Text = L.roleTextTransform == "upper" and roleLabel:upper() or roleLabel
        roleText.TextColor3 = _parseColor(theme.roleText)
        roleText.TextSize = L.roleTextSize
        roleText.Font = _safeFont(L.roleFont or "GothamBold")
        roleText.TextXAlignment = Enum.TextXAlignment.Left
        roleText.TextTruncate = Enum.TextTruncate.AtEnd
        roleText.ZIndex = 3; roleText.Parent = textArea

        local gradCfg = _resolveGradients(playerName, themeKey, theme, _CONFIG)
        _applyAllGradients(card, avatar, nameText, roleText, cardBorder, gradCfg)

        local animCfg = _CONFIG.animations or _DEFAULTS.animations
        local fadeDur = animCfg.fadeInDuration or 0.3
        local fadeEase = _safeEasing(animCfg.fadeInEasing or "Quad")
        local targetCardTrans = animCfg.cardTransparency or 0
        local targetBorderTrans = animCfg.borderTransparency or 0.3

        card.BackgroundTransparency = 1
        cardBorder.Transparency = 1
        nameText.TextTransparency = 1
        roleText.TextTransparency = 1

        pcall(task.delay, 0.05, function()
            local info = TweenInfo.new(fadeDur, fadeEase, Enum.EasingDirection.Out)
            pcall(function()
                TS:Create(card, info, { BackgroundTransparency = targetCardTrans }):Play()
                TS:Create(cardBorder, info, { Transparency = targetBorderTrans }):Play()
                TS:Create(nameText, info, { TextTransparency = 0 }):Play()
                TS:Create(roleText, info, { TextTransparency = 0 }):Play()
            end)
        end)

        _spawnParticles(billboard, _CONFIG.particles or _DEFAULTS.particles)
        _setupDistanceScaling(billboard, L)
        billboard.Parent = CoreGui

        if savedGrads then _CONFIG.gradients = savedGrads end
        creatingNametag[playerName] = nil
    end

    -- =========================================================================
    -- DoesPlayerQualifyForNametag
    -- =========================================================================
    local function DoesPlayerQualifyForNametag(p)
        if not p or not p.Parent then return false end
        if p == LocalPlayer then return true end
        local settingsState = ctx.settingsState
        if settingsState and settingsState.nametagVisible == false then return false end
        local name = p.Name
        local uid = tostring(p.UserId)
        if AdminNames[name] or AdminNames[uid] then return true end
        for _, users in pairs(_CONFIG.roleUsers) do
            for _, u in ipairs(users) do
                if u:lower() == name:lower() or u == uid then return true end
            end
        end
        if _CONFIG.showAllNametags ~= false then return true end
        return false
    end

    -- =========================================================================
    -- PUBLIC API (returned and registered globally)
    -- =========================================================================
    local api = {
        CreateCustomNametag = CreateCustomNametag,
        DoesPlayerQualifyForNametag = DoesPlayerQualifyForNametag,
        GetConfig = function() return _CONFIG end,
        SetConfig = function(newCfg)
            if type(newCfg) == "table" then _deepMerge(_CONFIG, newCfg) end
        end,
        RefreshAvatar = function(playerName)
            local p = Players:FindFirstChild(playerName)
            if p then _avatarCache[p.UserId] = nil; _fetchRobloxAvatar(p.UserId) end
        end,
        ClearAllNametags = function()
            for _, desc in ipairs(CoreGui:GetDescendants()) do
                if desc:IsA("BillboardGui") and desc.Name:sub(1, 14) == "CovertPeerTag_" then desc:Destroy() end
            end
        end,
        Cleanup = function()
            for _, conn in ipairs(_DISTANCE_CONNECTIONS) do
                if conn and conn.Connected then conn:Disconnect() end
            end
            _DISTANCE_CONNECTIONS = {}
        end,
    }

    -- Register globally for cross-module bridge access
    _G.SU_Nametag = api

    return api
end

return NametagSystem
