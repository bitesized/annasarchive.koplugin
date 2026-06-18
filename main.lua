
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

function AnnaPlugin:annaTLD()
    return self.settings:readSetting("anna_tld") or "gs"
end

function AnnaPlugin:apiUrl()
    return string.format("http://%s:%s/api", self:apiHost(), self:apiPort())
end

function AnnaPlugin:downloadKey()
    return self.settings:readSetting("download_key") or ""
end

function AnnaPlugin:downloadDir()
    return self.settings:readSetting("download_dir")
        or (DataStorage:getDataDir() .. "/downloads")
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

function AnnaPlugin:searchBooks(query)
    local url = self:apiUrl() .. "/search?query=" .. url_encode(query)
        .. "&limit=20&tld=" .. url_encode(self:annaTLD())
    local body, status, err = self:httpGet(url)
    if not body then return nil, err end
    if status ~= 200 then return nil, "HTTP " .. status end
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

function AnnaPlugin:fetchDownloadInfo(md5)
    local key = self:downloadKey()
    local url = self:apiUrl() .. "/download?md5=" .. md5
        .. "&tld=" .. url_encode(self:annaTLD())
    local body, status, err = self:httpGet(url, { ["authorization"] = "Bearer " .. key })
    if not body then return nil, err end
    if status ~= 200 then
        local ok, d = pcall(json.decode, body)
        return nil, (ok and d and d.error) or ("HTTP " .. status)
    end
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
                text = _("Search"),
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
                            return "Anna's Archive TLD: " .. self:annaTLD()
                        end,
                        keep_menu_open = true,
                        callback = function()
                            self:editSetting("anna_tld", "Anna's Archive TLD", self:annaTLD())
                        end,
                    },
                    {
                        text_func = function()
                            local k = self:downloadKey()
                            return "Download Key: " .. (k ~= "" and string.rep("*", math.min(#k, 8)) or "(not set)")
                        end,
                        keep_menu_open = true,
                        callback = function()
                            self:editSetting("download_key", "Download Key", self:downloadKey())
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

function AnnaPlugin:editSetting(key, title, current)
    local dialog
    dialog = InputDialog:new{
        title = title,
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

function AnnaPlugin:showSearchDialog()
    local dialog
    dialog = InputDialog:new{
        title = _("Search Anna's Archive"),
        buttons = {{
            { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
            { text = _("Search"), is_enter_default = true, callback = function()
                local query = dialog:getInputText()
                UIManager:close(dialog)
                if query and query:match("%S") then
                    self:doSearch(query)
                end
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function AnnaPlugin:doSearch(query)
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

    self:showResults(query, results)
end

function AnnaPlugin:showResults(query, results)
    local items = {}
    for _, r in ipairs(results) do
        local format = str_field(r.format)
        local fmt = format and format:upper() or "?"
        items[#items + 1] = {
            text = r.title,
            mandatory = fmt,
            callback = function() self:confirmDownload(r) end,
        }
    end

    local menu
    menu = Menu:new{
        title = _("Results: ") .. query,
        item_table = items,
        close_callback = function() UIManager:close(menu) end,
    }
    UIManager:show(menu)
end

-- Download flow

function AnnaPlugin:confirmDownload(result)
    if self:downloadKey() == "" then
        UIManager:show(InfoMessage:new{
            text = _("No download key set.\nAdd one in Settings → Anna's Archive."),
        })
        return
    end

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
