
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local InputDialog = require("ui/widget/inputdialog")
local Menu = require("ui/widget/menu")
local PathChooser = require("ui/widget/pathchooser")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox = require("ui/widget/confirmbox")
local ButtonDialog = require("ui/widget/buttondialog")
local UIManager = require("ui/uimanager")
local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local json = require("json")
local http = require("socket.http")
local socketutil = require("socketutil")
local lfs = require("libs/libkoreader-lfs")
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

-- "English [en]" -> "English". A result in several languages lists each with
-- its own bracketed code, so every code goes, not just the last.
local function displayLanguage(lang)
    lang = str_field(lang)
    if not lang then return nil end
    lang = lang:gsub("%s*%[[^%]]*%]", ""):match("^%s*(.-)%s*$")
    return lang ~= "" and lang or nil
end

-- The compact line under each result, e.g. "EPUB · 3.6MB · 2008 · English ·
-- ↓ 1.2k". Fields the result doesn't have are left out rather than shown as
-- blanks; only the format always appears, as "?" when unknown.
local function resultMeta(r)
    local format = str_field(r.format)
    local parts = { format and format:upper() or "?" }
    local function add(v)
        if v and v ~= "" then parts[#parts + 1] = v end
    end
    add(str_field(r.size))
    add(str_field(r.year))
    add(displayLanguage(r.language))
    add(formatDownloads(r.downloads))
    return table.concat(parts, " · ")
end

-- The md5 names the cached cover file, so anything but a plain 32-digit hex
-- hash (e.g. one containing "../") could write outside the cache directory.
local function is_md5(s)
    return type(s) == "string" and #s == 32 and s:match("^%x+$") ~= nil
end

-- Formats offered as filters in Settings. Lowercase, matching the API.
local FILTER_FORMATS = { "epub", "pdf", "mobi", "azw3", "fb2", "djvu", "cbz", "txt" }

-- Client-side filtering: the API has no format or language filter of its
-- own. `formats` is a set of lowercase formats (empty = any) and `lang` a
-- lowercase code like "en" (empty = any), matched against the bracketed
-- code(s) in the result's language, e.g. "English [en]". A result missing the
-- field being filtered on is excluded, since it can't be shown to match.
local function matchesFilters(r, formats, lang)
    if next(formats) then
        local f = str_field(r.format)
        if not (f and formats[f:lower()]) then return false end
    end
    if lang ~= "" then
        local l = str_field(r.language)
        if not l then return false end
        for code in l:gmatch("%[([^%]]+)%]") do
            if code:lower() == lang then return true end
        end
        return false
    end
    return true
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

-- The cover cache is trimmed back under this many bytes before each search.
local COVER_CACHE_MAX = 20 * 1024 * 1024

-- Results asked for per page: the API's maximum. The API trims each upstream
-- results page to this limit, so asking for fewer would leave the rest of
-- every page unreachable once "Load more" moves on to the next one.
local RESULTS_PER_PAGE = 50

-- The API clamps `page` to this, so there is nothing to load beyond it.
local MAX_PAGE = 100

-- API request timeouts, in seconds. A search can legitimately keep the socket
-- silent for a while: the server may log in upstream and then search, each
-- with a 30s timeout of its own, and spends up to 10s more on download
-- counts. So the wait for a response is generous, but no longer unbounded.
local API_BLOCK_TIMEOUT = 75
local API_TOTAL_TIMEOUT = 90

-- How many distinct recent queries the search dialog offers.
local HISTORY_MAX = 10

local function formatSize(bytes)
    if bytes >= 1024 * 1024 then
        return string.format("%.1f MB", bytes / (1024 * 1024))
    end
    return string.format("%d KB", math.ceil(bytes / 1024))
end

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
    -- Not every context a plugin is loaded in has a main menu.
    if self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end
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
        missing = _("No Anna's Archive TLD set.\nSet it in Anna's Archive → Settings.")
    elseif self:secretKey() == "" then
        missing = _("No secret key set.\nSet it in Anna's Archive → Settings.")
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

-- Returns the body, status and nil, plus the response headers (lowercased
-- names, as LuaSocket gives them) so callers can read e.g. Retry-After. On a
-- network failure returns nil, nil and an error message instead.
--
-- Without a timeout an unreachable or wedged server blocked the whole UI
-- indefinitely. socketutil's timeouts are global, so they are always reset
-- afterwards -- the request is pcall'd so an error can't skip that.
function AnnaPlugin:httpGet(url, headers)
    local body = {}
    socketutil:set_timeout(API_BLOCK_TIMEOUT, API_TOTAL_TIMEOUT)
    local pok, ok, status, resp_headers = pcall(http.request, {
        url = url,
        sink = socketutil.table_sink(body),
        headers = headers or {},
    })
    socketutil:reset_timeout()
    if not pok then
        return nil, nil, _("Network error: ") .. tostring(ok)
    end
    if not ok then
        if status == socketutil.TIMEOUT_CODE or status == socketutil.SINK_TIMEOUT_CODE then
            return nil, nil, _("The server took too long to respond. Try again later.")
        end
        return nil, nil, _("Network error: ") .. tostring(status)
    end
    return table.concat(body), status, nil, resp_headers
end

-- API calls

-- Error responses carry {"error": "...", "code": "..."}. Most of the codes
-- point at a setting the user can fix, so name where it lives. `headers` is
-- optional; when given, a 429's Retry-After is passed on.
function AnnaPlugin:apiError(body, status, headers)
    local ok, d = pcall(json.decode, body)
    if not (ok and type(d) == "table") then d = {} end
    local msg = str_field(d.error) or ("HTTP " .. tostring(status))
    local code = str_field(d.code)
    local hint
    if status == 401 then
        if code == "BAD_KEY" then
            hint = _("Anna's Archive rejected your secret key. Check it in Anna's Archive → Settings.")
        elseif code == "CHALLENGE" then
            hint = _("Anna's Archive answered with a bot check instead of results. A valid secret key skips it — check yours in Anna's Archive → Settings.")
        else
            hint = _("A valid secret key is required. Set it in Anna's Archive → Settings.")
        end
    elseif status == 400 and code == "UNKNOWN_MIRROR" then
        hint = _("The server doesn't know this mirror. Check the Anna's Archive TLD in Anna's Archive → Settings.")
    elseif status == 429 then
        -- Retry-After may also be an HTTP date; only a plain number is shown.
        local retry = headers and tonumber(headers["retry-after"])
        if retry then
            hint = string.format(_("Too many requests. Try again in %d seconds."), math.ceil(retry))
        else
            hint = _("Too many requests. Try again in a little while.")
        end
    elseif status == 502 then
        hint = _("Anna's Archive couldn't be reached. Try again later, or pick another mirror TLD in Anna's Archive → Settings.")
    end
    if hint then return msg .. "\n\n" .. hint end
    return msg
end

-- Saved filter formats, lowercase. Empty means any format.
function AnnaPlugin:formatFilter()
    local formats = self.settings:readSetting("filter_formats")
    if type(formats) ~= "table" then return {} end
    return formats
end

-- Saved filter language code, lowercase, e.g. "en". Empty means any language.
function AnnaPlugin:languageFilter()
    local lang = self.settings:readSetting("filter_language")
    if type(lang) ~= "string" then return "" end
    return lang:lower():match("^%s*(.-)%s*$")
end

-- `page` is 1-based and defaults to the first.
function AnnaPlugin:searchBooks(query, page)
    local url = self:apiUrl() .. "/search?query=" .. url_encode(query)
        .. "&limit=" .. RESULTS_PER_PAGE .. "&page=" .. (page or 1)
        .. self:tldParam()
    local body, status, err, headers = self:httpGet(url, self:authHeaders())
    if not body then return nil, err end
    if status ~= 200 then return nil, self:apiError(body, status, headers) end
    local ok, data = pcall(json.decode, body)
    if not ok or type(data) ~= "table" then
        return nil, _("Invalid response from the server.")
    end
    -- A 200 without a results list is still an answer the server meant; pass
    -- on its error message if it gave one.
    if type(data.results) ~= "table" then
        return nil, str_field(data.error) or _("Invalid response from the server.")
    end

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

-- Every file in the cover cache with its size and modification time, plus
-- their total size. Reusing a cached cover bumps its modification time, so
-- the oldest file is the cover shown least recently.
function AnnaPlugin:listCoverCache()
    local dir = self:coverCacheDir()
    local files, total = {}, 0
    if lfs.attributes(dir, "mode") ~= "directory" then return files, total end
    for name in lfs.dir(dir) do
        local path = dir .. "/" .. name
        local attr = lfs.attributes(path)
        if attr and attr.mode == "file" then
            files[#files + 1] = {
                name = name, path = path, size = attr.size, time = attr.modification,
            }
            total = total + attr.size
        end
    end
    return files, total
end

-- Delete the least recently shown covers until the cache is back under
-- COVER_CACHE_MAX. A search (and each "Load more") can add a page of covers on
-- top, so the cache can sit a little over the cap until the next search trims
-- it. Also clears out
-- .part files stranded by a download that never finished (e.g. the device
-- powered off mid-download); recent ones may still be in flight, so are left.
function AnnaPlugin:trimCoverCache()
    local files, total = self:listCoverCache()
    local stranded = os.time() - 5 * 60
    table.sort(files, function(a, b) return a.time < b.time end)
    for _, f in ipairs(files) do
        local is_part = f.name:sub(-5) == ".part"
        if (is_part and f.time < stranded)
                or (not is_part and total > COVER_CACHE_MAX) then
            if os.remove(f.path) then total = total - f.size end
        end
    end
end

function AnnaPlugin:clearCoverCache()
    for _, f in ipairs((self:listCoverCache())) do
        os.remove(f.path)
    end
end

-- Nil when the result's md5 isn't a well-formed hash: it is used as the file
-- name, so it must not be able to point outside the cache. Such a result just
-- goes without a cover.
function AnnaPlugin:coverPath(result)
    if not is_md5(result.md5) then return nil end
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
        local path = cover_url and self:coverPath(r)
        if path then
            if file_exists(path) then
                r.cover_path = path
                lfs.touch(path) -- mark as recently shown, so trimming keeps it
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
    -- A body that decodes to a bare string or number would otherwise blow up
    -- on the first `data.download_url`.
    if not ok or type(data) ~= "table" then return nil, "Invalid response" end
    return data
end

-- Settings validators

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Each validator takes the trimmed input and returns the value to save, or
-- nil and a message to show. Without them a stray space or a pasted URL was
-- saved as-is and only surfaced later as a confusing network error.
local function validatePort(v)
    local n = tonumber(v)
    if not v:match("^%d+$") or not n or n < 1 or n > 65535 then
        return nil, _("The port must be a number from 1 to 65535.")
    end
    return tostring(n)
end

-- The plugin builds the URL itself, so a host pasted as a full URL is cut
-- back to the bare name. A port on the end is split off and returned too, so
-- the caller can save it as the port setting.
local function validateHost(v)
    local host = v:gsub("^%a[%w+.-]*://", ""):gsub("[/?#].*$", "")
    local port
    local name, p = host:match("^([^:]+):(%d+)$")
    if name then host, port = name, p end
    if host == "" or host:find("[%s:@]") then
        return nil, _("Enter a host name or IP address, e.g. 192.168.1.10.")
    end
    if port and not validatePort(port) then
        return nil, (select(2, validatePort(port)))
    end
    return host, port
end

local function validateTLD(v)
    local tld = v:gsub("^%.", ""):lower()
    if not tld:match("^%a+$") then
        return nil, _("Enter just the top-level domain, e.g. gd.")
    end
    return tld
end

local function validateKey(v)
    if v:find("%s") then
        return nil, _("The secret key can't contain spaces.")
    end
    return v
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
                            return _("API host: ") .. self:apiHost()
                        end,
                        keep_menu_open = true,
                        callback = function(touchmenu_instance)
                            self:editSetting("api_host", _("API host"), self:apiHost(),
                                _("Host name or IP address of annas-archive-api, without http://."),
                                validateHost, function(port)
                                    self.settings:saveSetting("api_port", port)
                                    touchmenu_instance:updateItems()
                                end)
                        end,
                    },
                    {
                        text_func = function()
                            return _("API port: ") .. self:apiPort()
                        end,
                        keep_menu_open = true,
                        callback = function()
                            self:editSetting("api_port", _("API port"), self:apiPort(),
                                nil, validatePort)
                        end,
                    },
                    {
                        text_func = function()
                            local tld = self:annaTLD()
                            return _("Anna's Archive TLD: ")
                                .. (tld ~= "" and tld or _("(not set)"))
                        end,
                        keep_menu_open = true,
                        callback = function()
                            self:editSetting("anna_tld", _("Anna's Archive TLD"), self:annaTLD(),
                                _("Required, e.g. gd. Your key is sent to this mirror — check Anna's Archive's Wikipedia page for the current list."),
                                validateTLD)
                        end,
                    },
                    {
                        text_func = function()
                            local k = self:secretKey()
                            return _("Secret key: ") .. (k ~= "" and string.rep("*", math.min(#k, 8)) or _("(not set)"))
                        end,
                        keep_menu_open = true,
                        callback = function()
                            self:editSetting("download_key", _("Account secret key"), self:secretKey(),
                                nil, validateKey)
                        end,
                    },
                    {
                        text = _("Test connection"),
                        keep_menu_open = true,
                        callback = function() self:testConnection() end,
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
                            local n = #self:formatFilter()
                                + (self:languageFilter() ~= "" and 1 or 0)
                            return n > 0 and (_("Filter results") .. " (" .. n .. ")")
                                or _("Filter results")
                        end,
                        sub_item_table_func = function() return self:filterMenuItems() end,
                    },
                    {
                        text_func = function()
                            return _("Download folder: ") .. self:downloadDir()
                        end,
                        keep_menu_open = true,
                        callback = function()
                            self:chooseDownloadDir()
                        end,
                    },
                    {
                        text_func = function()
                            local _files, total = self:listCoverCache()
                            return _("Clear cover cache") .. " (" .. formatSize(total) .. ")"
                        end,
                        keep_menu_open = true,
                        callback = function(touchmenu_instance)
                            UIManager:show(ConfirmBox:new{
                                text = _("Delete all cached cover thumbnails?\n\nThey download again when a search needs them."),
                                ok_text = _("Clear"),
                                ok_callback = function()
                                    self:clearCoverCache()
                                    touchmenu_instance:updateItems()
                                end,
                            })
                        end,
                    },
                },
            },
        },
    }
end

-- Settings UI

-- `validate` is optional; see the validators above. It may return a second
-- value, which `on_extra` receives (validateHost uses this for a port).
function AnnaPlugin:editSetting(key, title, current, description, validate, on_extra)
    local dialog
    dialog = InputDialog:new{
        title = title,
        description = description,
        input = current,
        buttons = {{
            { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
            { text = _("Save"), is_enter_default = true, callback = function()
                local value, extra = trim(dialog:getInputText() or ""), nil
                if validate then
                    value, extra = validate(value)
                    if not value then
                        UIManager:show(InfoMessage:new{ text = extra })
                        return
                    end
                end
                self.settings:saveSetting(key, value)
                if on_extra and extra then on_extra(extra) end
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

-- Asks the API for /api/health with the upstream probe, so one tap tells a
-- wrong host or port apart from a mirror that is down or behind a bot check.
-- Needs neither the key nor a TLD: the probe uses the API's default mirror.
function AnnaPlugin:testConnection()
    local spinner = InfoMessage:new{ text = _("Testing connection…") }
    UIManager:show(spinner)
    UIManager:forceRePaint()
    local body, status, err = self:httpGet(self:apiUrl() .. "/health?upstream=1")
    UIManager:close(spinner)

    local text
    local ok, data = pcall(json.decode, body or "")
    if not body then
        text = _("Could not reach the API at ") .. self:apiUrl() .. "\n\n" .. (err or "?")
    elseif status ~= 200 or not ok or type(data) ~= "table" or data.ok ~= true then
        text = _("The API answered, but not as expected (HTTP ") .. tostring(status)
            .. _(").\nCheck the host and port point at annas-archive-api.")
    else
        text = _("Connected to the API.")
        local up = type(data.upstream) == "table" and data.upstream or {}
        local up_status = str_field(up.status)
        if up_status == "ok" then
            text = text .. "\n" .. _("Anna's Archive is reachable.")
        elseif up_status == "challenged" then
            text = text .. "\n" .. _("Anna's Archive is behind a bot check. Searches with your secret key should still work.")
        elseif up_status == "unreachable" then
            text = text .. "\n" .. _("Anna's Archive is unreachable from the API: ")
                .. (str_field(up.error) or "?")
        end
    end
    UIManager:show(InfoMessage:new{ text = text })
end

-- Search flow

function AnnaPlugin:hasFilters()
    return #self:formatFilter() > 0 or self:languageFilter() ~= ""
end

-- TouchMenu items for the format and language filters, for the Settings menu
-- to include. Filtering happens here rather than on the server, which has no
-- such filters, so it narrows each page of results after it arrives.
function AnnaPlugin:filterMenuItems()
    local function isChecked(fmt)
        for _, f in ipairs(self:formatFilter()) do
            if f == fmt then return true end
        end
        return false
    end
    local function toggle(fmt)
        local formats = {}
        local found = false
        for _, f in ipairs(self:formatFilter()) do
            if f == fmt then found = true else formats[#formats + 1] = f end
        end
        if not found then formats[#formats + 1] = fmt end
        self.settings:saveSetting("filter_formats", formats)
        self.settings:flush()
    end

    local items = {
        {
            text = _("Any format"),
            checked_func = function() return #self:formatFilter() == 0 end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                self.settings:saveSetting("filter_formats", {})
                self.settings:flush()
                if touchmenu_instance then touchmenu_instance:updateItems() end
            end,
        },
    }
    for _, fmt in ipairs(FILTER_FORMATS) do
        items[#items + 1] = {
            text = fmt:upper(),
            checked_func = function() return isChecked(fmt) end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                toggle(fmt)
                -- "Any format" changes along with this one.
                if touchmenu_instance then touchmenu_instance:updateItems() end
            end,
        }
    end
    items[#items].separator = true
    items[#items + 1] = {
        text_func = function()
            local lang = self:languageFilter()
            return _("Language: ") .. (lang ~= "" and lang or _("any"))
        end,
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            local dialog
            dialog = InputDialog:new{
                title = _("Filter by language"),
                description = _("A language code as shown in brackets in results, e.g. en for \"English [en]\". Leave empty for any language."),
                input = self:languageFilter(),
                buttons = {{
                    { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
                    { text = _("Any"), callback = function()
                        self.settings:saveSetting("filter_language", "")
                        self.settings:flush()
                        UIManager:close(dialog)
                        if touchmenu_instance then touchmenu_instance:updateItems() end
                    end },
                    { text = _("Save"), is_enter_default = true, callback = function()
                        -- Accept "[en]" too, as copied from a result.
                        local code = (dialog:getInputText() or ""):lower():gsub("[%[%]%s]", "")
                        self.settings:saveSetting("filter_language", code)
                        self.settings:flush()
                        UIManager:close(dialog)
                        if touchmenu_instance then touchmenu_instance:updateItems() end
                    end },
                }},
            }
            UIManager:show(dialog)
            dialog:onShowKeyboard()
        end,
    }
    return items
end

-- Recent queries, most recent first.
function AnnaPlugin:searchHistory()
    local history = self.settings:readSetting("search_history")
    if type(history) ~= "table" then return {} end
    return history
end

-- Moves `query` to the front, dropping an earlier copy (ignoring case and
-- surrounding spaces) and anything beyond HISTORY_MAX.
function AnnaPlugin:addToHistory(query)
    query = query:match("^%s*(.-)%s*$")
    if query == "" then return end
    local history = { query }
    for _, q in ipairs(self:searchHistory()) do
        if #history >= HISTORY_MAX then break end
        if type(q) == "string" and q:lower() ~= query:lower() then
            history[#history + 1] = q
        end
    end
    self.settings:saveSetting("search_history", history)
    self.settings:flush()
end

-- Lists recent queries over the search dialog; tapping one closes both and
-- runs it.
function AnnaPlugin:showHistory(search_dialog, replace_results)
    local history = self:searchHistory()
    local history_dialog
    local buttons = {}
    for _, q in ipairs(history) do
        buttons[#buttons + 1] = {{
            text = q,
            callback = function()
                UIManager:close(history_dialog)
                UIManager:close(search_dialog)
                self:doSearch(q, replace_results)
            end,
        }}
    end
    buttons[#buttons + 1] = {
        {
            text = _("Clear history"),
            callback = function()
                UIManager:show(ConfirmBox:new{
                    text = _("Forget all recent searches?"),
                    ok_text = _("Clear"),
                    ok_callback = function()
                        self.settings:delSetting("search_history")
                        self.settings:flush()
                        UIManager:close(history_dialog)
                    end,
                })
            end,
        },
        {
            text = _("Close"),
            callback = function() UIManager:close(history_dialog) end,
        },
    }
    history_dialog = ButtonDialog:new{
        title = _("Recent searches"),
        buttons = buttons,
    }
    UIManager:show(history_dialog)
end

-- `query` pre-fills the box when refining a search from the results page;
-- `replace_results` is passed through to doSearch to close that page.
function AnnaPlugin:showSearchDialog(query, replace_results)
    local dialog
    dialog = InputDialog:new{
        title = _("Search Anna's Archive"),
        input = query,
        buttons = {{
            -- The dialog and keyboard only refresh their own area on close,
            -- which left the rest of the screen stale behind them (e.g. from
            -- the download popups when reached via "Search for another book").
            { text = _("Cancel"), callback = function()
                UIManager:close(dialog)
                UIManager:setDirty(nil, "flashui")
            end },
            { text = _("History"), enabled = #self:searchHistory() > 0, callback = function()
                self:showHistory(dialog, replace_results)
            end },
            { text = _("Search"), is_enter_default = true, callback = function()
                local text = dialog:getInputText()
                UIManager:close(dialog)
                if text and text:match("%S") then
                    self:doSearch(text, replace_results)
                end
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- Fetches the page after `state.page` and returns its results that are new
-- (pages can overlap when the upstream reshuffles between requests, so
-- results are deduped by md5) and pass the filters, sorted in the chosen
-- order. Also returns how many results the server sent, before deduping and
-- filtering. Returns nil and an error message if the request failed.
--
-- Each page is sorted on its own and appended after the ones before it,
-- rather than re-sorting everything: a "Load more" then never moves rows the
-- user has already scrolled past.
function AnnaPlugin:fetchNextPage(state)
    local page = state.page + 1
    local results, err = self:searchBooks(state.query, page)
    if not results then return nil, err end

    local formats = {}
    for _, f in ipairs(self:formatFilter()) do formats[f] = true end
    local lang = self:languageFilter()

    local kept = {}
    for _, r in ipairs(results) do
        local key = r.md5:lower()
        if not state.seen[key] then
            state.seen[key] = true
            if matchesFilters(r, formats, lang) then
                kept[#kept + 1] = r
            else
                state.hidden = state.hidden + 1
            end
        end
    end
    state.page = page
    state.exhausted = #results == 0 or page >= MAX_PAGE
    sortResults(kept, self:sortOrder())
    return kept, nil, #results
end

-- When refining from a results page, `replace_results` closes it -- but only
-- once the new search has something to show, so a failed or empty search
-- leaves the previous results open underneath its message.
function AnnaPlugin:doSearch(query, replace_results)
    if not self:requireConfig() then return end

    local spinner = InfoMessage:new{ text = _("Searching…") }
    UIManager:show(spinner)
    UIManager:forceRePaint()

    -- Trim while the spinner is up: the search is about to wait on the
    -- network anyway, so the directory scan costs nothing visible.
    if _rich_ui then self:trimCoverCache() end

    -- Carried along by the results view, so "Load more" knows which page is
    -- next and which results are already shown.
    local state = {
        query = query, page = 0, seen = {}, hidden = 0, exhausted = false,
        filtered = self:hasFilters(),
    }
    local results, err, count = self:fetchNextPage(state)
    UIManager:close(spinner)

    if not results then
        UIManager:show(InfoMessage:new{ text = _("Search failed: ") .. (err or "?") })
        return
    end
    self:addToHistory(query)
    if count == 0 then
        UIManager:show(InfoMessage:new{ text = _("No results found.") })
        return
    end

    if replace_results then replace_results() end
    -- Even when the filters hid this whole page the view opens, empty but for
    -- its "Load more", since later pages may still have matches.
    self:showResults(query, results, state)
    if #results == 0 then
        UIManager:show(InfoMessage:new{
            text = string.format(_("%d results hidden by filters."), state.hidden),
        })
    end
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

    local meta   = resultMeta(r)
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

-- The text under the results for "Load more" and the filter count: nil when
-- there's no more to load and nothing was hidden.
local function moreLabel(state)
    local hidden = state.hidden > 0
        and string.format(_("%d results hidden by filters"), state.hidden)
    if state.exhausted then return nil, hidden end
    return _("Load more results"), hidden
end

-- Fetches the next page for "Load more" behind a spinner. Returns the new
-- results, or nil after showing why there are none to add.
function AnnaPlugin:loadMoreResults(state)
    local spinner = InfoMessage:new{ text = _("Loading more…") }
    UIManager:show(spinner)
    UIManager:forceRePaint()
    local results, err, count = self:fetchNextPage(state)
    UIManager:close(spinner)
    if not results then
        UIManager:show(InfoMessage:new{ text = _("Loading more failed: ") .. (err or "?") })
        return nil
    end
    if count == 0 then
        UIManager:show(InfoMessage:new{ text = _("No more results.") })
    elseif #results == 0 then
        UIManager:show(InfoMessage:new{
            text = string.format(_("All %d results on this page were hidden by filters or already shown."), count),
        })
    end
    return results
end

-- `state` is the one doSearch built: it carries the query, the last page
-- fetched and the md5s already shown, so "Load more" can append the next page.
function AnnaPlugin:showResults(query, results, state)
    local title = _("Results: ") .. query
    if state.filtered then title = title .. " " .. _("(filtered)") end

    if not _rich_ui then
        local items = {}
        local function addItems(batch)
            for _, r in ipairs(batch) do
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
                    mandatory = resultMeta(r),
                    callback = function() self:confirmDownload(r) end,
                }
            end
        end
        addItems(results)

        local menu
        -- Menu calls close_callback after every item's callback, which would
        -- close the list on "Load more"; this skips that one close.
        local keep_open = false
        -- The result items plus a trailing "Load more" / hidden-count item.
        local function itemTable()
            local t = {}
            for i, item in ipairs(items) do t[i] = item end
            local more, hidden = moreLabel(state)
            if more then
                t[#t + 1] = {
                    text = more,
                    mandatory = hidden or nil,
                    callback = function()
                        keep_open = true
                        local first_new = #items + 1
                        local batch = self:loadMoreResults(state)
                        if batch then
                            addItems(batch)
                            menu:switchItemTable(nil, itemTable(), math.min(first_new, #items))
                        end
                    end,
                }
            elseif hidden then
                t[#t + 1] = { text = hidden, dim = true, select_enabled = false }
            end
            return t
        end
        menu = Menu:new{
            title = title,
            title_bar_left_icon = "appbar.search",
            item_table = itemTable(),
            multilines_show_more_text = true,
            close_callback = function()
                if keep_open then
                    keep_open = false
                    return
                end
                UIManager:close(menu)
            end,
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
    local polling = false
    local deadline
    local closed = false
    local cover_slots = {}
    local function close()
        closed = true
        UIManager:unschedule(poll_covers)
        -- Without a refresh type, close() repaints what was underneath into
        -- the framebuffer but never refreshes it, so the e-ink screen kept
        -- showing the results list around every later popup (the download
        -- confirmation, spinners, the "Saved to" dialog). Flash it away.
        UIManager:close(results_widget, "flashui")
        -- Release the decoded cover bitmaps. Closing already sends the
        -- widgets CloseWidget, which frees them, but a cover's blitbuffer is
        -- big enough that leaking one through some other path would add up
        -- over many searches; freeing twice is harmless.
        for _, slot in pairs(cover_slots) do
            if slot[1] then slot[1]:free() end
        end
    end

    -- Before building the rows, so cached covers are in them from the start.
    local pending = self:startCoverDownloads(results)

    local title_bar = TitleBar:new{
        title = title,
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
    local function addRows(batch)
        for _, r in ipairs(batch) do
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
    end
    addRows(results)

    -- The last entry in the list: "Load more" while there are pages left,
    -- and how many results the filters have hidden so far. Rebuilt after each
    -- load, since both change.
    local footer
    local scroller
    local loadMore
    local function buildFooter()
        local more, hidden = moreLabel(state)
        if not more and not hidden then return nil end
        local col = VerticalGroup:new{ align = "center" }
        if more then
            col[#col + 1] = TextWidget:new{
                text = more, face = Font:getFace("cfont", 18), bold = true,
                max_width = list_w,
            }
        end
        if hidden then
            col[#col + 1] = TextWidget:new{
                text = hidden, face = Font:getFace("cfont", 14), max_width = list_w,
            }
        end
        local h = col:getSize().h + Screen:scaleBySize(24)
        local item = InputContainer:new{ dimen = Geom:new{ w = list_w, h = h } }
        if more then
            item.ges_events = {
                TapSelect = { GestureRange:new{ ges = "tap", range = item.dimen } },
            }
            function item:onTapSelect() loadMore() return true end
        end
        item[1] = CenterContainer:new{ dimen = Geom:new{ w = list_w, h = h }, col }
        return item
    end
    footer = buildFooter()
    if footer then list[#list + 1] = footer end

    -- Appends a page of results in place, keeping the scroll position so the
    -- reader carries on from where "Load more" was. reset() makes the
    -- container re-measure the longer list on its next paint, but also
    -- scrolls back to the top, so the offset is put back afterwards. The list
    -- only grows (bar the footer when the last page is reached), so the old
    -- offset is still in range.
    local function appendPage(batch)
        if footer then
            table.remove(list)
            footer:free()
        end
        addRows(batch)
        footer = buildFooter()
        if footer then list[#list + 1] = footer end
        list:resetLayout()

        local offset = scroller:getScrolledOffset()
        scroller:reset()
        scroller:setScrolledOffset(offset)
        UIManager:setDirty(results_widget, function() return "ui", scroller.dimen end)
    end

    local loading = false
    loadMore = function()
        if loading or closed then return end
        loading = true
        local batch = self:loadMoreResults(state)
        loading = false
        if not batch or closed then return end
        local new_pending = self:startCoverDownloads(batch)
        appendPage(batch)
        for _, r in ipairs(new_pending) do pending[#pending + 1] = r end
        if #new_pending > 0 then
            -- Give the new batch's wgets their full time too.
            deadline = os.time() + COVER_TIMEOUT + 5
            if not polling then
                polling = true
                UIManager:scheduleIn(1, poll_covers)
            end
        end
    end

    scroller = ScrollableContainer:new{
        dimen = Geom:new{ x = 0, y = 0, w = screen_w, h = screen_h - title_h },
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
    deadline = os.time() + COVER_TIMEOUT + 5
    poll_covers = function()
        polling = false
        if closed then return end
        local arrived = false
        for i = #pending, 1, -1 do
            local r = pending[i]
            local path = self:coverPath(r)
            if path and file_exists(path) then
                r.cover_path = path
                -- Swap the cover in and free the widget it replaces (the
                -- placeholder), rather than leaving it for the GC.
                local slot = cover_slots[r]
                local old = slot[1]
                slot[1] = self:buildCoverWidget(path)
                if old then old:free() end
                table.remove(pending, i)
                arrived = true
            elseif not path then
                table.remove(pending, i)
            end
        end
        if arrived then
            UIManager:setDirty(results_widget, function() return "ui", scroller.dimen end)
        end
        if #pending > 0 and os.time() < deadline then
            polling = true
            UIManager:scheduleIn(1, poll_covers)
        end
    end
    if #pending > 0 then
        polling = true
        UIManager:scheduleIn(1, poll_covers)
    end
end

-- Download flow

local util = require("util")
local DocumentRegistry = require("document/documentregistry")

-- Seconds wget may go without receiving any data before it gives up, and how
-- many attempts it makes. -T is an idle timeout rather than a cap on the whole
-- transfer, so a slow but steady download of a large PDF still completes.
local DOWNLOAD_TIMEOUT = 30
local DOWNLOAD_TRIES = 3

-- How often the progress dialog checks on the backgrounded wget.
local DOWNLOAD_POLL_SECS = 1

-- The file extension comes from the API, so it must not be able to carry a
-- path ("../../x") or anything else odd into the filename: short and
-- alphanumeric only. A missing or rejected format becomes "bin" rather than a
-- guessed "epub" -- mislabelling a PDF as EPUB would send it to the wrong
-- reader engine and fail to open, whereas .bin is honest and easy to rename.
local function download_ext(result)
    local format = str_field(result.format)
    format = format and format:lower()
    if format and #format <= 5 and format:match("^%w+$") then
        return format
    end
    return "bin"
end

-- Cut to at most `max_chars` characters. Cutting by bytes could split a
-- multi-byte UTF-8 character and leave an invalid filename behind.
local function utf8_truncate(s, max_chars)
    local chars = util.splitToChars(s)
    if #chars <= max_chars then return s end
    return table.concat(chars, "", 1, max_chars)
end

-- One component of a filename built from book metadata: no characters that
-- are path separators or illegal on FAT/exFAT SD cards, no control characters,
-- and no leading dots (which would hide the file or read as "..").
local function filename_part(s, max_chars)
    s = s:gsub("%c", " "):gsub('[/\\:*?"<>|]', "_")
    s = s:gsub("^[%s%.]+", "")
    s = utf8_truncate(s, max_chars)
    return (s:gsub("%s+$", ""))
end

-- A path in `dir` for `base`.`ext` that doesn't clobber an existing file --
-- or the .part of a download in progress -- by appending " (2)", " (3)"...
local function unique_path(dir, base, ext)
    local function taken(p)
        return lfs.attributes(p, "mode") ~= nil
            or lfs.attributes(p .. ".part", "mode") ~= nil
    end
    local path = string.format("%s/%s.%s", dir, base, ext)
    local n = 2
    while taken(path) do
        path = string.format("%s/%s (%d).%s", dir, base, n, ext)
        n = n + 1
    end
    return path
end

local function read_number(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local s = f:read("*a") or ""
    f:close()
    return tonumber(s:match("%d+"))
end

-- Where a book of this format goes by default: the folder last chosen for the
-- format via "Save to…", else the general download folder. A remembered
-- folder that has since gone (e.g. an unmounted SD card) is skipped.
function AnnaPlugin:formatDownloadDir(ext)
    local dirs = self.settings:readSetting("download_dir_by_format")
    local dir = type(dirs) == "table" and dirs[ext]
    if type(dir) == "string" and lfs.attributes(dir, "mode") == "directory" then
        return dir
    end
    return self:downloadDir()
end

function AnnaPlugin:rememberFormatDownloadDir(ext, dir)
    local dirs = self.settings:readSetting("download_dir_by_format")
    if type(dirs) ~= "table" then dirs = {} end
    if dirs[ext] == dir then return end
    dirs[ext] = dir
    self.settings:saveSetting("download_dir_by_format", dirs)
    self.settings:flush()
end

-- `close_results` (optional) closes the results page; it is called before
-- "Open now" hands over to the reader so the page isn't left in the window
-- stack underneath. `chosen_dir` is set when re-shown after "Save to…".
function AnnaPlugin:confirmDownload(result, close_results, chosen_dir)
    if not self:requireConfig() then return end

    local ext = download_ext(result)
    local dir = chosen_dir or self:formatDownloadDir(ext)

    local title = str_field(result.title) or "?"
    local author = str_field(result.author)
    author = (author and author ~= "" and author) or _("Unknown")
    local format = str_field(result.format)
    local details = { format and format:upper() or "?" }
    for _, field in ipairs({ "size", "year" }) do
        local v = str_field(result[field])
        if v and v ~= "" then details[#details + 1] = v end
    end
    local msg = string.format("%s\n%s · %s\n\n%s\n%s", title, author,
        table.concat(details, " · "), _("Save to:"), dir)

    UIManager:show(ConfirmBox:new{
        text = _("Download?\n\n") .. msg,
        ok_text = _("Download"),
        ok_callback = function()
            -- Only remembered once used, so browsing to a folder and then
            -- backing out doesn't change where the next download goes.
            if chosen_dir then self:rememberFormatDownloadDir(ext, chosen_dir) end
            self:startDownload(result, dir, close_results)
        end,
        other_buttons = {{
            {
                text = _("Save to…"),
                callback = function()
                    UIManager:show(PathChooser:new{
                        select_directory = true,
                        path = dir,
                        onConfirm = function(path)
                            -- PathChooser closes itself only after this
                            -- returns; reopen once it has gone so the dialog
                            -- isn't caught in its closing refresh.
                            UIManager:nextTick(function()
                                self:confirmDownload(result, close_results, path)
                            end)
                        end,
                    })
                end,
            },
        }},
    })
end

function AnnaPlugin:startDownload(result, dir, close_results)
    local spinner = InfoMessage:new{ text = _("Fetching download link…") }
    UIManager:show(spinner)
    UIManager:forceRePaint()

    local data, err = self:fetchDownloadInfo(result.md5)
    UIManager:close(spinner)

    if not data then
        UIManager:show(InfoMessage:new{ text = _("Failed: ") .. (err or "?") })
        return
    end

    -- The API documents `download_url`; `url` is kept as a fallback for older
    -- servers. Either way it goes to wget, so only plain web URLs are accepted.
    local url = str_field(data.download_url) or str_field(data.url)
    if not url or not url:lower():match("^https?://") then
        UIManager:show(InfoMessage:new{ text = _("No download URL in response.") })
        return
    end

    self:downloadToFile(result, url,
        dir or self:formatDownloadDir(download_ext(result)), close_results)
end

-- The download runs as a backgrounded wget so the UI stays responsive and
-- can show progress and offer Cancel. It writes to a .part file next to the
-- destination, only renamed into place once wget reports success, so a
-- failed or cancelled download never leaves a truncated book behind -- nor
-- touches a file that was already there. An inner shell waits on wget and
-- records its exit status in a marker file, which the poll below picks up;
-- wget's PID goes to a pidfile so Cancel can kill it.
function AnnaPlugin:downloadToFile(result, url, dir, close_results)
    -- lfs rather than `mkdir -p` in a shell: the folder name may hold anything.
    local ok, mk_err = util.makePath(dir)
    if not ok then
        logger.warn("annasarchive: cannot create", dir, mk_err)
        UIManager:show(InfoMessage:new{ text = _("Could not create folder:\n") .. dir })
        return
    end

    local ext = download_ext(result)
    local base = filename_part(str_field(result.title) or "", 80)
    if base == "" then base = "book" end
    local author = filename_part(str_field(result.author) or "", 40)
    if author ~= "" then base = base .. " - " .. author end
    local filepath = unique_path(dir, base, ext)
    local part = filepath .. ".part"

    -- The pid and status markers live in the cache rather than beside the
    -- book, so they never show up in the user's library folder.
    local work_dir = DataStorage:getDataDir() .. "/cache/annasarchive_download"
    util.makePath(work_dir)
    local tag = (str_field(result.md5) or ""):gsub("[^%w]", "") .. "_" .. os.time()
    local pidfile = work_dir .. "/" .. tag .. ".pid"
    local statusfile = work_dir .. "/" .. tag .. ".status"
    os.remove(pidfile)
    os.remove(statusfile)

    -- The status is written under a temporary name and moved into place, so
    -- the poll never reads a half-written file.
    local q_status = sh_quote(statusfile)
    local q_status_tmp = sh_quote(statusfile .. ".tmp")
    local script = string.format(
        "wget -q -T %d -t %d --no-check-certificate -O %s %s & echo $! > %s;"
            .. " wait $!; echo $? > %s; mv %s %s",
        DOWNLOAD_TIMEOUT, DOWNLOAD_TRIES, sh_quote(part), sh_quote(url),
        sh_quote(pidfile), q_status_tmp, q_status_tmp, q_status)
    os.execute("sh -c " .. sh_quote(script) .. " >/dev/null 2>&1 &")

    local name = filepath:match("[^/]+$")
    local total = str_field(result.size)
    local function progressText()
        local got = formatSize(lfs.attributes(part, "size") or 0)
        if total and total ~= "" then got = got .. " / " .. total end
        return _("Downloading…") .. "\n\n" .. name .. "\n\n" .. got
    end

    local function removeMarkers()
        os.remove(pidfile)
        os.remove(statusfile)
    end

    local function killWget()
        local pid = read_number(pidfile)
        if pid then os.execute("kill " .. pid .. " 2>/dev/null") end
    end

    local dialog, poll, shown_text
    local cancelled, cancel_polls = false, 0

    dialog = ButtonDialog:new{
        title = progressText(),
        -- Tapping outside or Back must not close it: the poll would carry on
        -- with no way left to cancel.
        dismissable = false,
        buttons = {{
            {
                text = _("Cancel"),
                callback = function()
                    cancelled = true
                    killWget()
                    UIManager:close(dialog)
                    -- The progress updates were partial refreshes; flush
                    -- their ghosting on the way back to the results.
                    UIManager:setDirty(nil, "full")
                end,
            },
        }},
    }
    shown_text = dialog.title

    poll = function()
        local status = read_number(statusfile)

        if cancelled then
            -- Wait for wget to actually exit before removing the .part, or
            -- it could recreate it. Retry the kill in case Cancel came before
            -- the pidfile existed, and stop waiting after a while.
            cancel_polls = cancel_polls + 1
            if status or cancel_polls > 10 then
                os.remove(part)
                removeMarkers()
            else
                killWget()
                UIManager:scheduleIn(DOWNLOAD_POLL_SECS, poll)
            end
            return
        end

        if not status then
            -- Only repaint when the count has moved, and only the dialog,
            -- with a non-flashing refresh: ButtonDialog:setTitle() would
            -- refresh the whole screen every second.
            local text = progressText()
            if text ~= shown_text then
                shown_text = text
                dialog.title = text
                dialog:reinit()
                UIManager:setDirty(dialog, function()
                    return "ui", dialog.movable.dimen
                end)
            end
            UIManager:scheduleIn(DOWNLOAD_POLL_SECS, poll)
            return
        end

        UIManager:close(dialog)
        removeMarkers()

        if status ~= 0 then
            logger.warn("annasarchive: wget exited with", status)
            os.remove(part)
            UIManager:show(InfoMessage:new{ text = _("Download failed.") })
            return
        end

        -- Something may have taken the name while we downloaded.
        local final = filepath
        if lfs.attributes(final, "mode") ~= nil then
            final = unique_path(dir, base, ext)
        end
        local renamed, rename_err = os.rename(part, final)
        if not renamed then
            logger.warn("annasarchive: rename failed", rename_err)
            os.remove(part)
            UIManager:show(InfoMessage:new{ text = _("Download failed.") })
            return
        end

        self:showDownloadComplete(final, close_results)
    end

    UIManager:show(dialog)
    UIManager:scheduleIn(DOWNLOAD_POLL_SECS, poll)
end

function AnnaPlugin:showDownloadComplete(filepath, close_results)
    -- An InfoMessage with a timeout used to stand in for this, but its
    -- auto-dismiss leaves the screen it vanishes from unrefreshed -- on
    -- e-ink that shows up as ghosting from whatever was on screen before the
    -- plugin ran. Ask explicitly instead, and refresh on the way out.
    local done_dialog
    local buttons = {}
    -- Only offered when KOReader can open the file type (not e.g. a .bin).
    if DocumentRegistry:hasProvider(filepath) then
        buttons[#buttons + 1] = {{
            text = _("Open now"),
            callback = function()
                UIManager:close(done_dialog)
                if close_results then close_results() end
                -- showReader closes the current FileManager/ReaderUI itself
                -- and does its own full refresh.
                require("apps/reader/readerui"):showReader(filepath)
            end,
        }}
    end
    buttons[#buttons + 1] = {
        {
            text = _("Search for another book"),
            callback = function()
                UIManager:close(done_dialog)
                self:showSearchDialog()
            end,
        },
        {
            text = _("Close"),
            callback = function()
                UIManager:close(done_dialog)
                UIManager:setDirty(nil, "full")
            end,
        },
    }
    done_dialog = ButtonDialog:new{
        title = _("Saved to:\n") .. filepath,
        buttons = buttons,
    }
    UIManager:show(done_dialog)
end

return AnnaPlugin
