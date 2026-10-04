
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local InputDialog = require("ui/widget/inputdialog")
local Menu = require("ui/widget/menu")
local PathChooser = require("ui/widget/pathchooser")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox = require("ui/widget/confirmbox")
local UIManager = require("ui/uimanager")
local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local json = require("json")
local http = require("socket.http")
local ltn12 = require("ltn12")
local logger = require("logger")
local _ = require("gettext")

-- Optional UI modules for cover+count display; not available in all KOReader
-- builds. If any require fails the plugin still loads and falls back to Menu.
local Screen, Geom, Font, Blitbuffer, ImageWidget, TitleBar
local ScrollableContainer, InputContainer, FrameContainer
local VerticalGroup, HorizontalGroup, CenterContainer, LeftContainer
local TextWidget, TextBoxWidget, VerticalSpan, HorizontalSpan, GestureRange
local LineWidget

local _rich_ui = pcall(function()
    Screen        = require("device").screen
    Geom          = require("ui/geometry")
    Font          = require("ui/font")
    Blitbuffer    = require("ffi/blitbuffer")
    ImageWidget   = require("ui/widget/imagewidget")
    TitleBar      = require("ui/widget/titlebar")
    ScrollableContainer = require("ui/widget/container/scrollablecontainer")
    InputContainer      = require("ui/widget/container/inputcontainer")
    FrameContainer      = require("ui/widget/container/framecontainer")
    VerticalGroup       = require("ui/widget/verticalgroup")
    HorizontalGroup     = require("ui/widget/horizontalgroup")
    CenterContainer     = require("ui/widget/container/centercontainer")
    LeftContainer       = require("ui/widget/container/leftcontainer")
    TextWidget          = require("ui/widget/textwidget")
    TextBoxWidget       = require("ui/widget/textboxwidget")
    VerticalSpan        = require("ui/widget/verticalspan")
    HorizontalSpan      = require("ui/widget/horizontalspan")
    GestureRange        = require("ui/gesturerange")
    LineWidget          = require("ui/widget/linewidget")
end)
if not _rich_ui then
    logger.warn("AnnaPlugin: rich UI widgets unavailable, falling back to Menu")
end

local function url_encode(str)
    return tostring(str):gsub("([^%w%-%.%_%~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end)
end

-- The JSON decoder represents `null` with a sentinel that is a *function*
-- value, not Lua nil. That means a field like "format": null is truthy and
-- slips past `field and ...` guards, then blows up on the first string op
-- (e.g. `field:upper()` -> "attempt to index a function value"). Coerce any
-- non-string (nil, the null sentinel, numbers, tables) to nil so callers can
-- rely on a plain `string or default`.
local function str_field(v)
    return type(v) == "string" and v or nil
end

-- Prefixed with a down arrow so the bare number reads as a download count.
-- U+2193 is used throughout KOReader's own UI, so it renders in these fonts.
local function formatDownloads(n)
    if type(n) ~= "number" then return nil end
    if n >= 1000 then return string.format("↓ %.1fk", n / 1000) end
    return "↓ " .. tostring(n)
end

-- Quote a string for sh. Cover URLs come from scraped HTML, so they must not
-- be able to break out of the wget command line.
local function sh_quote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function file_exists(path)
    local f = io.open(path, "rb")
    if f then f:close() return true end
    return false
end

-- Seconds a single cover download may take before wget gives up on it.
local COVER_TIMEOUT = 10

-- Case-insensitive text order with blanks last, so results missing the field
-- don't crowd the top of an A-Z list. Returns nil on a tie.
local function compareText(x, y)
    x = x and x:lower() or ""
    y = y and y:lower() or ""
    if x == y then return nil end
    if x == "" then return false end
    if y == "" then return true end
    return x < y
end

-- Result sort orders, matching the annas-archive-api web UI. Each compare
-- returns nil on a tie, which falls through to the title and then to the
-- upstream position, so the order is total and table.sort stays stable.
local SORTS = {
    { key = "relevance", text = _("Relevance") },
    { key = "downloads", text = _("Most downloaded"), compare = function(a, b)
        local x = type(a.downloads) == "number" and a.downloads or -1
        local y = type(b.downloads) == "number" and b.downloads or -1
        if x == y then return nil end
        return x > y
    end },
    { key = "title", text = _("Title A–Z") },
    { key = "author", text = _("Author A–Z"), compare = function(a, b)
        return compareText(str_field(a.author), str_field(b.author))
    end },
    { key = "format", text = _("Format"), compare = function(a, b)
        return compareText(str_field(a.format), str_field(b.format))
    end },
}

-- Looked up here rather than inline in the menu: a `for _, s` loop there
-- shadows the gettext `_` it also needs to call.
local function sortLabel(key)
    for _, s in ipairs(SORTS) do
        if s.key == key then return s.text end
    end
end

local function sortResults(results, key)
    if key == "relevance" then return end
    local compare
    for _, s in ipairs(SORTS) do
        if s.key == key then compare = s.compare end
    end
    local pos = {}
    for i, r in ipairs(results) do pos[r] = i end
    table.sort(results, function(a, b)
        local c = compare and compare(a, b)
        if c == nil then c = compareText(a.title, b.title) end
        if c == nil then c = pos[a] < pos[b] end
        return c
    end)
end

local AnnaPlugin = WidgetContainer:extend{
    name = "annasarchive",
    is_doc_only = false,
}

function AnnaPlugin:init()
    self.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/annasarchive.lua")
    self.ui.menu:registerToMainMenu(self)
end

-- Settings accessors

function AnnaPlugin:apiHost()
    return self.settings:readSetting("api_host") or "localhost"
end

function AnnaPlugin:apiPort()
    return self.settings:readSetting("api_port") or "3000"
end

-- Required, and deliberately undefaulted. The key is sent to whichever mirror
-- this names -- on searches too now, not just downloads -- and Anna's Archive
-- rotates its domains, so a TLD baked in here would eventually point the key at
-- a retired domain that someone else has since registered. The user picks it.
function AnnaPlugin:annaTLD()
    return self.settings:readSetting("anna_tld") or ""
end

function AnnaPlugin:tldParam()
    return "&tld=" .. url_encode(self:annaTLD())
end

function AnnaPlugin:apiUrl()
    return string.format("http://%s:%s/api", self:apiHost(), self:apiPort())
end

-- The Anna's Archive account secret key. It authorises both endpoints now:
-- /api/download has always needed it, and /api/search needs it too since the
-- upstream started putting anonymous searches behind a DDoS-Guard challenge
-- that only a signed-in session skips. Stored under the historical
-- "download_key" name so existing installs keep their saved key.
function AnnaPlugin:secretKey()
    return self.settings:readSetting("download_key") or ""
end

-- Searching and downloading both need the key and a mirror, so both check the
-- same way rather than failing later against the API.
function AnnaPlugin:requireConfig()
    local missing
    if self:annaTLD() == "" then
        missing = _("No Anna's Archive TLD set.\nSet it in Settings → Anna's Archive.")
    elseif self:secretKey() == "" then
        missing = _("No secret key set.\nSet it in Settings → Anna's Archive.")
    else
        return true
    end
    UIManager:show(InfoMessage:new{ text = missing })
    return false
end

function AnnaPlugin:authHeaders()
    return { ["authorization"] = "Bearer " .. self:secretKey() }
end

function AnnaPlugin:downloadDir()
    return self.settings:readSetting("download_dir")
        or (DataStorage:getDataDir() .. "/downloads")
end

function AnnaPlugin:sortOrder()
    return self.settings:readSetting("sort_order") or "relevance"
end

function AnnaPlugin:coverCacheDir()
    return DataStorage:getDataDir() .. "/cache/annasarchive_covers"
end

-- HTTP

function AnnaPlugin:httpGet(url, headers)
    local body = {}
    local ok, status = http.request{
        url = url,
        sink = ltn12.sink.table(body),
        headers = headers or {},
    }
    if not ok then return nil, nil, "Network error: " .. tostring(status) end
    return table.concat(body), status
end

-- API calls

-- Error responses carry {"error": "...", "code": "..."}. A 401 means the key
-- is missing or was rejected (code "CHALLENGE" when the upstream served a bot
-- check instead of results) -- both are fixed in Settings, so say so.
function AnnaPlugin:apiError(body, status)
    local ok, d = pcall(json.decode, body)
    local msg = (ok and type(d) == "table" and str_field(d.error))
        or ("HTTP " .. tostring(status))
    if status == 401 then
        return msg .. "\n\nCheck your secret key in Settings."
    end
    return msg
end

function AnnaPlugin:searchBooks(query)
    local url = self:apiUrl() .. "/search?query=" .. url_encode(query)
        .. "&limit=20" .. self:tldParam()
    local body, status, err = self:httpGet(url, self:authHeaders())
    if not body then return nil, err end
    if status ~= 200 then return nil, self:apiError(body, status) end
    local ok, data = pcall(json.decode, body)
    if not ok or not data or not data.results then return nil, "Invalid response" end

    -- Defensive: the upstream scraper can occasionally emit malformed or
    -- partial entries (e.g. during Anna's Archive outages / DDoS-Guard
    -- challenge pages), so don't trust every element to be a well-formed
    -- {title, author, format, md5} table. Drop anything that isn't.
    local results = {}
    local dropped = 0
    for _, r in ipairs(data.results) do
        if type(r) == "table" and type(r.title) == "string" and type(r.md5) == "string" then
            results[#results + 1] = r
        else
            dropped = dropped + 1
        end
    end
    if dropped > 0 then
        logger.warn("AnnaPlugin: dropped", dropped, "malformed search result(s)")
    end
    return results
end

function AnnaPlugin:coverPath(result)
    return self:coverCacheDir() .. "/" .. result.md5 .. ".jpg"
end

-- Covers load in the background so the results show straight away. Cached
-- covers are attached at once; every missing one is started together as its
-- own backgrounded wget, so they download in parallel and os.execute returns
-- immediately. Each writes to a .part file that is only renamed into place on
-- success, so a file at the cover path is always complete. One try with a
-- short timeout keeps a dead cover host from lingering. Returns the results
-- still waiting on a cover.
function AnnaPlugin:startCoverDownloads(results)
    local pending, cmds = {}, {}
    for _, r in ipairs(results) do
        local cover_url = str_field(r.cover_url)
        if cover_url then
            local path = self:coverPath(r)
            if file_exists(path) then
                r.cover_path = path
            else
                local part = sh_quote(path .. ".part")
                cmds[#cmds + 1] = string.format(
                    "(wget -q -T %d -t 1 --no-check-certificate -O %s %s"
                        .. " && mv %s %s || rm -f %s) >/dev/null 2>&1 &",
                    COVER_TIMEOUT, part, sh_quote(cover_url),
                    part, sh_quote(path), part)
                pending[#pending + 1] = r
            end
        end
    end
    if #cmds > 0 then
        os.execute("mkdir -p " .. sh_quote(self:coverCacheDir()) .. "; "
            .. table.concat(cmds, " "))
    end
    return pending
end

function AnnaPlugin:fetchDownloadInfo(md5)
    local url = self:apiUrl() .. "/download?md5=" .. url_encode(md5)
        .. self:tldParam()
    local body, status, err = self:httpGet(url, self:authHeaders())
    if not body then return nil, err end
    if status ~= 200 then return nil, self:apiError(body, status) end
    local ok, data = pcall(json.decode, body)
    if not ok then return nil, "Invalid response" end
    return data
end

-- Menu

function AnnaPlugin:addToMainMenu(menu_items)
    menu_items.annasarchive = {
        text = _("Anna's Archive"),
        sorting_hint = "search",
        sub_item_table = {
            {
                text = _("Search Anna's Archive"),
                callback = function() self:showSearchDialog() end,
            },
            {
                text = _("Settings"),
                sub_item_table = {
                    {
                        text_func = function()
                            return "API Host: " .. self:apiHost()
                        end,
                        keep_menu_open = true,
                        callback = function()
                            self:editSetting("api_host", "API Host", self:apiHost())
                        end,
                    },
                    {
                        text_func = function()
                            return "API Port: " .. self:apiPort()
                        end,
                        keep_menu_open = true,
                        callback = function()
                            self:editSetting("api_port", "API Port", self:apiPort())
                        end,
                    },
                    {
                        text_func = function()
                            local tld = self:annaTLD()
                            return "Anna's Archive TLD: "
                                .. (tld ~= "" and tld or "(not set)")
                        end,
                        keep_menu_open = true,
                        callback = function()
                            self:editSetting("anna_tld", "Anna's Archive TLD", self:annaTLD(),
                                _("Required, e.g. gd. Your key is sent to this mirror — check Anna's Archive's Wikipedia page for the current list."))
                        end,
                    },
                    {
                        text_func = function()
                            local k = self:secretKey()
                            return "Secret Key: " .. (k ~= "" and string.rep("*", math.min(#k, 8)) or "(not set)")
                        end,
                        keep_menu_open = true,
                        callback = function()
                            self:editSetting("download_key", "Account Secret Key", self:secretKey())
                        end,
                    },
                    {
                        text_func = function()
                            local label = sortLabel(self:sortOrder())
                            return label and (_("Sort results: ") .. label)
                                or _("Sort results")
                        end,
                        sub_item_table_func = function()
                            local items = {}
                            for _, s in ipairs(SORTS) do
                                items[#items + 1] = {
                                    text = s.text,
                                    radio = true,
                                    checked_func = function() return self:sortOrder() == s.key end,
                                    callback = function()
                                        self.settings:saveSetting("sort_order", s.key)
                                        self.settings:flush()
                                    end,
                                }
                            end
                            return items
                        end,
                    },
                    {
                        text_func = function()
                            return "Download Dir: " .. self:downloadDir()
                        end,
                        keep_menu_open = true,
                        callback = function()
                            self:chooseDownloadDir()
                        end,
                    },
                },
            },
        },
    }
end

-- Settings UI

function AnnaPlugin:editSetting(key, title, current, description)
    local dialog
    dialog = InputDialog:new{
        title = title,
        description = description,
        input = current,
        buttons = {{
            { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
            { text = _("Save"), callback = function()
                self.settings:saveSetting(key, dialog:getInputText())
                self.settings:flush()
                UIManager:close(dialog)
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function AnnaPlugin:chooseDownloadDir()
    local chooser = PathChooser:new{
        select_directory = true,
        path = self:downloadDir(),
        onConfirm = function(path)
            self.settings:saveSetting("download_dir", path)
            self.settings:flush()
        end,
    }
    UIManager:show(chooser)
end

-- Search flow

-- `query` pre-fills the box when refining a search from the results page;
-- `replace_results` is passed through to doSearch to close that page.
function AnnaPlugin:showSearchDialog(query, replace_results)
    local dialog
    dialog = InputDialog:new{
        title = _("Search Anna's Archive"),
        input = query,
        buttons = {{
            { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
            { text = _("Search"), is_enter_default = true, callback = function()
                local query = dialog:getInputText()
                UIManager:close(dialog)
                if query and query:match("%S") then
                    self:doSearch(query, replace_results)
                end
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- When refining from a results page, `replace_results` closes it -- but only
-- once the new search has something to show, so a failed or empty search
-- leaves the previous results open underneath its message.
function AnnaPlugin:doSearch(query, replace_results)
    if not self:requireConfig() then return end

    local spinner = InfoMessage:new{ text = _("Searching…") }
    UIManager:show(spinner)
    UIManager:forceRePaint()

    local results, err = self:searchBooks(query)
    UIManager:close(spinner)

    if not results then
        UIManager:show(InfoMessage:new{ text = _("Search failed: ") .. (err or "?") })
        return
    end
    if #results == 0 then
        UIManager:show(InfoMessage:new{ text = _("No results found.") })
        return
    end

    if replace_results then replace_results() end
    sortResults(results, self:sortOrder())
    self:showResults(query, results)
end

function AnnaPlugin:buildCoverWidget(cover_path)
    local W = Screen:scaleBySize(60)
    local H = Screen:scaleBySize(80)
    if cover_path then
        return ImageWidget:new{
            file = cover_path, width = W, height = H, scale_factor = 0,
        }
    end
    return FrameContainer:new{
        width = W, height = H, bordersize = 1,
        background = Blitbuffer.COLOR_LIGHT_GRAY, padding = 0,
        CenterContainer:new{
            dimen = Geom:new{ w = W, h = H },
            TextWidget:new{
                text = "?", face = Font:getFace("cfont", 20),
            },
        },
    }
end

function AnnaPlugin:buildResultRow(r, row_w, on_tap)
    local COVER_W = Screen:scaleBySize(60)
    local COVER_H = Screen:scaleBySize(80)
    local PAD     = Screen:scaleBySize(8)
    local TEXT_W  = row_w - COVER_W - PAD * 3

    local format = str_field(r.format)
    local fmt    = format and format:upper() or "?"
    local dl     = formatDownloads(r.downloads)
    local meta   = dl and (fmt .. " · " .. dl) or fmt
    local author = str_field(r.author)

    local text_col = VerticalGroup:new{ align = "left" }
    -- Title and author wrap onto as many lines as they need rather than being
    -- cut off, so the row grows to fit them.
    text_col[#text_col + 1] = TextBoxWidget:new{
        text = r.title or "?", face = Font:getFace("cfont", 20),
        width = TEXT_W, bold = true,
    }
    if author and author ~= "" then
        text_col[#text_col + 1] = VerticalSpan:new{ width = Screen:scaleBySize(3) }
        text_col[#text_col + 1] = TextBoxWidget:new{
            text = author, face = Font:getFace("cfont", 16), width = TEXT_W,
        }
    end
    text_col[#text_col + 1] = VerticalSpan:new{ width = Screen:scaleBySize(3) }
    text_col[#text_col + 1] = TextWidget:new{
        text = meta, face = Font:getFace("cfont", 14), max_width = TEXT_W,
    }
    local ROW_H = math.max(COVER_H, text_col:getSize().h) + Screen:scaleBySize(8)

    local row_body = HorizontalGroup:new{ align = "center" }
    row_body[1] = HorizontalSpan:new{ width = PAD }
    local cover_slot = CenterContainer:new{
        dimen = Geom:new{ w = COVER_W, h = ROW_H }, self:buildCoverWidget(r.cover_path),
    }
    row_body[2] = cover_slot
    row_body[3] = HorizontalSpan:new{ width = PAD }
    row_body[4] = LeftContainer:new{
        dimen = Geom:new{ w = TEXT_W, h = ROW_H }, text_col,
    }

    local item = InputContainer:new{
        dimen = Geom:new{ w = row_w, h = ROW_H },
    }
    item.ges_events = {
        TapSelect = { GestureRange:new{ ges = "tap", range = item.dimen } },
    }
    function item:onTapSelect() on_tap() return true end
    item[1] = FrameContainer:new{
        width = row_w, height = ROW_H, padding = 0, bordersize = 0,
        background = Blitbuffer.COLOR_WHITE, row_body,
    }
    -- The cover slot is returned too, so a cover that arrives later can be
    -- swapped in without rebuilding the row.
    return item, cover_slot
end

function AnnaPlugin:showResults(query, results)
    if not _rich_ui then
        local items = {}
        for _, r in ipairs(results) do
            local format = str_field(r.format)
            local fmt = format and format:upper() or "?"
            local dl = formatDownloads(r.downloads)
            local label = dl and (fmt .. " · " .. dl) or fmt
            -- Menu collapses an embedded newline when the row fits on one
            -- line, which would run the author straight on from the title,
            -- so separate them with a dash instead.
            local author = str_field(r.author)
            local text = r.title
            if author and author ~= "" then
                text = text .. " — " .. author
            end
            items[#items + 1] = {
                text = text,
                mandatory = label,
                callback = function() self:confirmDownload(r) end,
            }
        end
        local menu
        menu = Menu:new{
            title = _("Results: ") .. query,
            title_bar_left_icon = "appbar.search",
            item_table = items,
            multilines_show_more_text = true,
            close_callback = function() UIManager:close(menu) end,
        }
        function menu.onLeftButtonTap()
            self:showSearchDialog(query, function() UIManager:close(menu) end)
        end
        UIManager:show(menu)
        return
    end

    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()

    local results_widget
    local poll_covers
    local closed = false
    local function close()
        closed = true
        UIManager:unschedule(poll_covers)
        UIManager:close(results_widget)
    end

    -- Before building the rows, so cached covers are in them from the start.
    local pending = self:startCoverDownloads(results)

    local title_bar = TitleBar:new{
        title = _("Results: ") .. query,
        left_icon = "appbar.search",
        left_icon_tap_callback = function() self:showSearchDialog(query, close) end,
        close_callback = close,
    }
    local title_h = title_bar:getHeight()

    -- Rows are narrowed by the width the vertical scrollbar takes. At the full
    -- screen width they overflowed the space beside it, and ScrollableContainer
    -- answered with a horizontal scrollbar.
    local list_w = screen_w - ScrollableContainer:getScrollbarWidth()
    local list = VerticalGroup:new{ align = "left" }
    local cover_slots = {}
    for _, r in ipairs(results) do
        local row
        row, cover_slots[r] = self:buildResultRow(r, list_w, function()
            close()
            self:confirmDownload(r)
        end)
        list[#list + 1] = row
        -- A separator has no child widget, so it can't be a FrameContainer:
        -- FrameContainer:getSize() indexes self[1] and would crash on nil.
        list[#list + 1] = LineWidget:new{
            dimen = Geom:new{ w = list_w, h = 1 },
            background = Blitbuffer.COLOR_LIGHT_GRAY,
        }
    end

    local scroller = ScrollableContainer:new{
        dimen       = Geom:new{ x = 0, y = 0, w = screen_w, h = screen_h - title_h },
        show_parent = results_widget,
    }
    scroller[1] = list

    results_widget = FrameContainer:new{
        width = screen_w, height = screen_h, padding = 0,
        margin = 0, bordersize = 0, background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{ title_bar, scroller },
    }
    results_widget.cropping_widget = scroller
    results_widget.covers_fullscreen = true
    scroller.show_parent = results_widget
    -- Without a refresh type, show() only paints the widget into the
    -- framebuffer and enqueues no refresh for it, so the e-ink screen only
    -- updated where something else happened to refresh (e.g. where the
    -- "Searching…" box closed) and the rest of the list stayed stale until a
    -- scroll repainted it. Ask for the whole view to be refreshed.
    UIManager:show(results_widget, "ui")

    -- Check once a second for covers that have finished downloading, and
    -- repaint once per batch rather than once per cover -- each repaint is an
    -- e-ink refresh. Stop when they're all in, when the view closes, or once
    -- every wget has had time to time out.
    local deadline = os.time() + COVER_TIMEOUT + 5
    poll_covers = function()
        if closed then return end
        local arrived = false
        for i = #pending, 1, -1 do
            local r = pending[i]
            local path = self:coverPath(r)
            if file_exists(path) then
                r.cover_path = path
                cover_slots[r][1] = self:buildCoverWidget(path)
                table.remove(pending, i)
                arrived = true
            end
        end
        if arrived then
            UIManager:setDirty(results_widget, function() return "ui", scroller.dimen end)
        end
        if #pending > 0 and os.time() < deadline then
            UIManager:scheduleIn(1, poll_covers)
        end
    end
    if #pending > 0 then UIManager:scheduleIn(1, poll_covers) end
end

-- Download flow

function AnnaPlugin:confirmDownload(result)
    if not self:requireConfig() then return end

    local author = str_field(result.author)
    author = (author and author ~= "" and author) or "Unknown"
    local format = str_field(result.format)
    local fmt = format and format:upper() or "?"
    local msg = string.format("%s\n%s · %s", result.title, author, fmt)

    UIManager:show(ConfirmBox:new{
        text = _("Download?\n\n") .. msg,
        ok_text = _("Download"),
        ok_callback = function() self:startDownload(result) end,
    })
end

function AnnaPlugin:startDownload(result)
    local spinner = InfoMessage:new{ text = _("Fetching download link…") }
    UIManager:show(spinner)
    UIManager:forceRePaint()

    local data, err = self:fetchDownloadInfo(result.md5)
    UIManager:close(spinner)

    if not data then
        UIManager:show(InfoMessage:new{ text = _("Failed: ") .. (err or "?") })
        return
    end

    local url = data.download_url or data.url
    if not url then
        UIManager:show(InfoMessage:new{ text = _("No download URL in response.") })
        return
    end

    self:downloadToFile(result, url)
end

function AnnaPlugin:downloadToFile(result, url)
    local dir = self:downloadDir()
    os.execute(string.format('mkdir -p "%s"', dir:gsub('"', '\\"')))

    local ext = str_field(result.format) or "epub"
    local title = (str_field(result.title) or "book"):gsub('[/\\:*?"<>|]', "_"):sub(1, 80)
    local author = str_field(result.author)
    local author_part = ""
    if author and author ~= "" then
        author_part = " - " .. author:gsub('[/\\:*?"<>|]', "_"):sub(1, 40)
    end
    local filepath = dir .. "/" .. title .. author_part .. "." .. ext

    local spinner = InfoMessage:new{ text = _("Downloading…") }
    UIManager:show(spinner)
    UIManager:forceRePaint()

    local cmd = string.format(
        'wget -q --no-check-certificate -O "%s" "%s"',
        filepath:gsub('"', '\\"'),
        url:gsub('"', '\\"')
    )
    local code = os.execute(cmd)
    UIManager:close(spinner)

    local success = (code == 0) or (code == true)
    if not success then
        os.remove(filepath)
        UIManager:show(InfoMessage:new{ text = _("Download failed.") })
        return
    end

    UIManager:show(InfoMessage:new{
        text = _("Saved to:\n") .. filepath,
        timeout = 5,
    })
end

return AnnaPlugin
