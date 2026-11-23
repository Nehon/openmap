-- padMap with the Gamepad UI: OpenMap's map on its own canvas over Blizzard's map area. Blizzard's map
-- stays untouched under it, so its controller close runs only Blizzard's code (OpenMap-review.md, "In-game result").

local _, ns = ...
local mod = ns:GetModule("worldmap")

local STRATA = { "BACKGROUND", "LOW", "MEDIUM", "HIGH", "DIALOG", "FULLSCREEN", "FULLSCREEN_DIALOG", "TOOLTIP" }
local owner = {}
local overlay, marker
local areaLabel                 -- Blizzard's zone name label on the overlay
local started = false
local bound = false             -- the keys bound to OpenMap's buttons (out of combat, while Blizzard's map has the controller)
local placed = {}
local followed                  -- Blizzard's map last followed

-- the pad's buttons OpenMap takes on its map, from Blizzard's footer (Blizzard_WorldMap.lua:1148). Setup puts
-- OpenMap's own on its host: A its control or icon under the cursor, else a zoom in; X a zoom out of a map,
-- or on a quest icon Blizzard's quest details (QuestTitle), else OpenMap's quest click
local KEYS = {
	{ key = GAMEPAD_FACE_BOTTOM or "PAD1", button = "OpenMapPadA", run = function() overlay:NavigateToGamepadCursor() end },
	{ key = GAMEPAD_FACE_LEFT or "PAD3", button = "OpenMapPadX", quest = true, run = function()
		local pin = mod.PadHovered and mod.PadHovered()
		if mod.QuestOfPin and mod.QuestOfPin(pin) then pin:OnClick() else overlay:NavigateToParentMap() end
	end },
	{ key = GAMEPAD_STICK_LEFT_PRESS or "PADLSTICK", button = "OpenMapPadLStick", run = function() mod.PadWaypoint() end },
}
for _, k in ipairs(KEYS) do k.click = "CLICK " .. k.button .. ":LeftButton" end
local QUEST = "OpenMapPadQuest"
local QUEST_CLICK = "CLICK " .. QUEST .. ":LeftButton"
local questButton

-- only with the Gamepad UI and padMap, and never with OpenMap's map in Blizzard's (started at login without the Gamepad UI)
local function Wanted()
	return mod.PadUI() and mod.db.padMap and not mod.OnBlizzardMap()
end

-- (an error in Blizzard's callback is otherwise silent: each one said once in the chat)
local said = {}
local function Try(key, fn)
	local ok, err = pcall(fn)
	if not ok and not said[key] then
		said[key] = true
		ns:Print("pad map: %s failed: %s", key, tostring(err):sub(1, 200))
	end
	return ok
end

-- Blizzard's map has the controller (not its quest log)
local function MapFocused()
	local map = _G.WorldMapFrame
	return map and map:IsShown() and map.IsCanvasGamepadFocus and map:IsCanvasGamepadFocus() or false
end

local function Above(strata)
	for i, s in ipairs(STRATA) do
		if s == strata then return STRATA[i + 1] or s end
	end
	return "DIALOG"
end

-- over Blizzard's canvas, its rect read (anchored to nothing of Blizzard's)
local function Place()
	local sc = WorldMapFrame.ScrollContainer
	local l, b, w, h = sc:GetRect()
	if not l then return end
	local r = sc:GetEffectiveScale() / overlay:GetEffectiveScale()
	l, b, w, h = l * r, b * r, w * r, h * r
	-- (full screen: the screen's whole width, the Look tab's "fills the width"; Blizzard's map keeps its art's shape)
	if mod.db.fullWidth and WorldMapFrame:IsMaximized() then
		l, w = 0, UIParent:GetWidth() * UIParent:GetEffectiveScale() / overlay:GetEffectiveScale()
	end
	if placed[1] == l and placed[2] == b and placed[3] == w and placed[4] == h then return end
	local resized = placed[3] ~= w or placed[4] ~= h
	placed[1], placed[2], placed[3], placed[4] = l, b, w, h
	overlay:ClearAllPoints()
	overlay:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", l, b)
	overlay:SetSize(w, h)
	if resized and overlay.mapID then overlay:OnFrameSizeChanged() end
end

-- a screen point (px) in Blizzard's map area, scaled to the overlay's: Blizzard keeps its cursor in its own
-- area (MapCanvas_ScrollContainerMixin.lua:895), and the overlay is wider at full width
local function ToOverlay(x, y)
	local sc = WorldMapFrame.ScrollContainer
	local l, b, w, h = sc:GetRect()
	local ol, ob, ow, oh = overlay:GetRect()
	if not (l and ol) or w <= 0 or h <= 0 then return x, y end
	local es, oes = sc:GetEffectiveScale(), overlay:GetEffectiveScale()
	return (ol + (x / es - l) * ow / w) * oes, (ob + (y / es - b) * oh / h) * oes
end
mod.PadToOverlay = ToOverlay

-- Blizzard's controller cursor on the overlay (px), or nil
local function CursorPx()
	local soft = _G.SoftCursor
	if not (soft and soft:IsShown()) then return end
	local l, b, w, h = soft:GetRect()
	if not l then return end
	local es = soft:GetEffectiveScale()
	return ToOverlay((l + w / 2) * es, (b + h / 2) * es)
end

-- Blizzard's map cursor: its reticle (30 px of the atlas's middle, SoftCursor.xml) and its lines' gap at the reticle
-- (MapCanvas_ScrollContainerMixin.lua:974)
local RETICLE, GAP = 34, 14
local function Line(line, x, y, w, h)
	if w <= 0 or h <= 0 then line:Hide() return end
	line:ClearAllPoints()
	line:SetPoint("BOTTOMLEFT", marker, "BOTTOMLEFT", x, y)
	line:SetSize(w, h)
	line:Show()
end

-- Blizzard's controller cursor is under the overlay: drawn on it where it is, as Blizzard draws it
local function Mark()
	local x, y = CursorPx()
	local l, b, w, h = overlay:GetRect()
	if not (x and l) then marker:Hide() return end
	local es = overlay:GetEffectiveScale()
	x, y = x / es - l, y / es - b
	marker.reticle:ClearAllPoints()
	marker.reticle:SetPoint("CENTER", marker, "BOTTOMLEFT", x, y)
	marker.shadow:ClearAllPoints()
	marker.shadow:SetPoint("CENTER", marker, "BOTTOMLEFT", x + 1, y)
	local lines = marker.lines
	Line(lines[1], 0, y - 1, x - GAP, 2)
	Line(lines[2], x + GAP, y - 1, w - x - GAP, 2)
	Line(lines[3], x - 1, 0, 2, y - GAP)
	Line(lines[4], x - 1, y + GAP, 2, h - y - GAP)
	marker:Show()
end

-- the sticks as Blizzard's map reads them (WorldMapMixin:GamepadZoom, GamepadPanSpeed): then the overlay's canvas
-- zooms with the right stick (OpenMap's PadZoom when stitched) and pans at the edge (CheckForEdgePan) as Blizzard's
local function Sticks()
	local from, to = WorldMapFrame.ScrollContainer, overlay.ScrollContainer
	local focused = MapFocused()
	to.gamepadZoom = focused and from.gamepadZoom or 0
	to.gamepadPanMagnitude = from.gamepadPanMagnitude or 1
end

-- Blizzard's map's pin levels, in its order (Blizzard_WorldMap.lua:259): Setup puts OpenMap's art and icons among them
local function CopyLevels(f)
	local list = {}
	for name, d in pairs(WorldMapFrame:GetPinFrameLevelsManager().definitions) do
		if name ~= "PIN_FRAME_LEVEL_DEFAULT" then list[#list + 1] = { name, d.startLevel, d.range } end
	end
	table.sort(list, function(a, b) return a[2] < b[2] end)
	local to = f:GetPinFrameLevelsManager()
	for _, d in ipairs(list) do to:AddFrameLevel(d[1], d[3]) end
end

-- override bindings, not a handler on the pad's input: then B and the rest reach Blizzard's bindings
-- with no OpenMap code in their path. Blizzard binds the keys again on its refreshes: taken back each frame
local function Unbind()
	if bound and not InCombatLockdown() then
		ClearOverrideBindings(overlay)
		bound = false
	end
end
-- (a Blizzard menu open over the map, Y's zone list or the filters, keeps the map's focus: its A picks an entry)
local function MenuOpen()
	local manager = Menu and Menu.GetManager and Menu.GetManager()
	return manager and manager:IsAnyMenuOpen() or false
end
-- X on OpenMap's quest icon: a secure click on the quest's title in Blizzard's quest log, whose own click opens
-- the details (QuestMapFrame.lua:2489); a call from here taints the map. Nil with no title (a collapsed header)
local function QuestTitle()
	local questID = mod.QuestOfPin and mod.PadHovered and mod.QuestOfPin(mod.PadHovered())
	local find = _G.QuestLogQuests_GetQuestButton
	return questID and find and find(questID) or nil
end
local function SetQuestTitle(title)
	if not questButton then
		-- (on UIParent: a protected child makes its parent protected, and the overlay hides in combat)
		questButton = CreateFrame("Button", QUEST, UIParent, "SecureActionButtonTemplate")
		questButton:SetAttribute("type", "click")
		questButton:RegisterForClicks("AnyUp", "AnyDown")   -- (the template acts on the one the game's key-down setting asks for)
	end
	if questButton:GetAttribute("clickbutton") ~= title then questButton:SetAttribute("clickbutton", title) end
end
local function Keys()
	if InCombatLockdown() then return end
	if not (overlay:IsShown() and MapFocused()) or MenuOpen() then Unbind() return end
	local title = QuestTitle()
	if title then SetQuestTitle(title) end
	for _, k in ipairs(KEYS) do
		local button, click = k.button, k.click
		if k.quest and title then button, click = QUEST, QUEST_CLICK end
		if GetBindingAction(k.key, true) ~= click then
			SetOverrideBindingClick(overlay, true, k.key, button, "LeftButton")
			bound = true
		end
	end
end

-- Blizzard's own changes of its map (LB / RB, Y's zone list, the quest log, its A and X in combat): the overlay follows
local function Follow()
	local mapID = WorldMapFrame:GetMapID()
	if mapID == followed then return end
	followed = mapID
	if mapID then overlay:SetMapID(mapID) end
end

-- a quest picked in Blizzard's quest log or tracker (QuestMapFrame.lua:1102): Blizzard changes its map only
-- for a quest of another zone, so the view also goes in on the quest. Its map first: a later follow resets the view
local function PingQuest(questID)
	if not (overlay and overlay:IsShown()) then return end
	Follow()
	if mod.GlideToQuest then mod.GlideToQuest(questID) end
end

local function Build()
	if type(MapCanvasMixin) ~= "table" or not _G.WorldMapFrame then return end
	-- (MapCanvasFrameTemplate's own parts: its OnLoad needs the scroll container, which a template can't give from Lua)
	local f = CreateFrame("Frame", "OpenMapPadMap", UIParent)
	Mixin(f, MapCanvasMixin)
	-- Blizzard's three, less ClearCachedActivitiesForPlayer: it writes the quest and POI caches of Blizzard's map
	-- (SharedMapPoiTemplates.lua:402), and a write from here taints its quest pins, then its footer
	local function ProviderShow(provider) provider:OnShow() end
	local function ProviderMapChanged(provider) provider:OnMapChanged() end
	function f:OnShow()
		self:RefreshAll(true)
		secureexecuterange(self.dataProviders, ProviderShow)
		self:RegisterEvent("HANDLE_UI_ACTION")
	end
	function f:OnUpdate()
		self:UpdatePinSuppression()
		self:UpdatePinNudging()
		self:ProcessCursorHandlers()
		self:RunDataProviderOnUpdate()
		self:UpdateGamepadCursor()
	end
	function f:OnMapChanged()
		secureexecuterange(self.dataProviders, ProviderMapChanged)
	end
	f:SetToplevel(true)
	f:EnableMouse(true)
	f:Hide()
	local sc = CreateFrame("ScrollFrame", nil, f, "MapCanvasFrameScrollContainerTemplate")
	f.ScrollContainer = sc
	sc:ClearAllPoints()
	sc:SetAllPoints()
	-- (set by SetGamepadFocus, which also gives Blizzard's cursor to this canvas: never called here)
	sc.edgePanDistance = GetCVarNumberOrDefault("GamepadMapEdgePanDistance")
	-- Blizzard's, less SoftCursor:RefreshBounds: that cursor is Blizzard's map's, and a write from here taints it
	function sc:OnCanvasSizeChanged()
		if not self.mapID then return end
		self:CreateZoomLevels()
		self.Child.TiledBackground:SetAtlas(C_Map.GetMapArtBackgroundAtlas(self.mapID), true)
		local layers = C_Map.GetMapArtLayers(self.mapID)
		self:SetCanvasSize(layers[1].layerWidth, layers[1].layerHeight)
		self:ResetZoom(true)
	end
	-- Blizzard's cursor read on the overlay (CursorPx): A, the zone name, the edge pan
	function sc:GetGamepadCursorPosition()
		local x, y = CursorPx()
		if not x then return 0, 0 end
		local es = self:GetEffectiveScale()
		return x / es, y / es
	end
	function sc:GetNormalizedGamepadCursorPosition()
		return self:NormalizeUIPosition(self:GetGamepadCursorPosition())
	end
	-- (OnLoad's lock reasons switch the mouse on it, as on Blizzard's zone map: Blizzard_BattlefieldMap.xml)
	f.BorderFrame = CreateFrame("Frame", nil, f)
	f.BorderFrame:SetAllPoints()
	f:OnLoad()
	for _, script in ipairs({ "OnUpdate", "OnShow", "OnHide", "OnEvent" }) do f:SetScript(script, f[script]) end
	CopyLevels(f)
	-- Blizzard's providers that write nothing of Blizzard's map: the zone name under the cursor (OpenMap's
	-- levels on it, Extras.lua), the corpse, the tracked quest's area. Not those of quests and POIs: shared caches
	if _G.AreaLabelDataProviderMixin then
		local labels = CreateFromMixins(AreaLabelDataProviderMixin)
		labels:SetOffsetY(-40)   -- (Blizzard's with the Gamepad UI: Blizzard_WorldMap.lua:246)
		f:AddDataProvider(labels)
		areaLabel = labels.Label
	end
	for _, mixin in ipairs({ "DeathMapDataProviderMixin", "QuestBlobDataProviderMixin" }) do
		if _G[mixin] then f:AddDataProvider(CreateFromMixins(_G[mixin])) end
	end
	-- (OpenMap's pad cursor reads its host's focus: WorldMap.lua PadFocus)
	function f:IsCanvasGamepadFocus() return MapFocused() end

	-- the canvas, a child frame, draws over f's own textures; pins go up to level 9000 (MapCanvas_PinFrameLevelsManager.lua)
	local top = CreateFrame("Frame", nil, f)
	top:SetAllPoints()
	top:SetFrameLevel(9500)
	marker = top
	top.shadow = top:CreateTexture(nil, "OVERLAY", nil, 1)
	top.reticle = top:CreateTexture(nil, "OVERLAY", nil, 2)
	for _, t in ipairs({ top.shadow, top.reticle }) do
		t:SetAtlas("gamepad-reticletargeting-indicator-x1")
		t:SetSize(RETICLE, RETICLE)
	end
	top.shadow:SetVertexColor(0, 0, 0)
	top.lines = {}
	for i = 1, 4 do
		top.lines[i] = top:CreateTexture(nil, "OVERLAY")
		top.lines[i]:SetColorTexture(1, 0.82, 0, 1)   -- (NORMAL_FONT_COLOR, as Blizzard's)
	end

	for _, k in ipairs(KEYS) do
		local b = CreateFrame("Button", k.button, f)
		b:RegisterForClicks("AnyDown")
		b:SetScript("OnClick", function()
			if MapFocused() then k.run() end
		end)
	end

	local driver = CreateFrame("Frame", nil, f)
	local function Update()
		if not Wanted() then f:Hide() return end
		Place()
		Follow()
		Mark()
		Sticks()
		Keys()
	end
	driver:SetScript("OnUpdate", function()
		if not Try("update", Update) then f:Hide() end
	end)
	overlay = f
end

-- OpenMap's map set up on the overlay, once (WorldMap.lua Setup); its art is built at the first opening
local function Host()
	if overlay or not Try("build", Build) or not overlay then return end
	Try("host", function() mod.StartOnOverlay(overlay) end)
end

local function Show()
	if not Wanted() then return end
	if not overlay then Host() end
	if not overlay then return end
	Try("show", function()
		overlay:SetFrameStrata(Above(WorldMapFrame:GetFrameStrata()))
		-- (one strata up, over the pins, as on Blizzard's map: the overlay's strata reaches it)
		if areaLabel then areaLabel:SetFrameStrata(Above(overlay:GetFrameStrata())) end
		wipe(placed)
		Place()
		followed = nil
		Follow()
		overlay:Show()
	end)
end

local function Hide()
	if overlay then overlay:Hide() end
	Unbind()
end

-- Blizzard runs these callbacks in securecallfunction: nothing of them reaches its map
function mod.StartPadOverlay()
	if started then return end
	started = true
	if not (EventRegistry and EventRegistry.RegisterCallback) then return end
	EventRegistry:RegisterCallback("WorldMapOnShow", Show, owner)
	EventRegistry:RegisterCallback("WorldMapOnHide", Hide, owner)
	EventRegistry:RegisterCallback("MapCanvas.PingQuestID", function(_, questID) Try("quest", function() PingQuest(questID) end) end, owner)
	-- (bindings can't change in combat: A goes back to Blizzard's map before a fight)
	ns.RegisterEvent(owner, "PLAYER_REGEN_DISABLED", Unbind)
	ns.RegisterEvent(owner, "PLAYER_REGEN_ENABLED", Unbind)
	if _G.WorldMapFrame then
		Host()
		if WorldMapFrame:IsShown() then Show() end
	elseif EventUtil and EventUtil.ContinueOnAddOnLoaded then
		EventUtil.ContinueOnAddOnLoaded("Blizzard_WorldMap", Host)
	end
end
