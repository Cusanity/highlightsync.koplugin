local Dispatcher = require("dispatcher")  -- luacheck:ignore
local Device = require("device")
local UIManager = require("ui/uimanager")
local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local FFIUtil = require("ffi/util")
local T = FFIUtil.template
local InfoMessage = require("ui/widget/infomessage")
local Notification = require("ui/widget/notification")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("highlightsync_gettext")
local SyncService = require("frontend/apps/cloudstorage/syncservice")
local Merge = require("merge")
local rapidjson = require("rapidjson")
local NetworkMgr = require("ui/network/manager")
local logger = require("logger")
local time = require("ui/time")

local SYNC_DEBOUNCE_DELAY = time.s(25)

local is_reloading_due_to_sync = false



local function dir_exists(path)
    local ok, _, code = os.rename(path, path)
    if not ok then
        -- Código 13 = permission denied, bat folder has to exist
        return code == 13
    end
    return true
end

local function ensure_dir_exists(path)
    if not dir_exists(path) then
        local safe_path = path:gsub("%$", "\\$")
        local result = os.execute('mkdir -p "' .. safe_path .. '"')
        if not result then
            error("Failed to create directory: " .. path)
        end
    end
end

local Highlightsync = WidgetContainer:extend{
    name = "Highlightsync",
    is_doc_only = false,
}

--- Needed so the "ext" table existing in pdf annotations to be encoded
--- in JSON, as non-contiguous integer keys aren't allowed in JSON.
--- @return table new_annotations The original table, but with the `ext` sub-table's
--- number keys replaced with strings.
local function with_stringified_ext_keys(annotations)
    local new_annotations = {}
    for hash, annotation in pairs(annotations) do
        local new_annotation
        if annotation["ext"] then
            new_annotation = {}
            for k, v in pairs(annotation) do
                new_annotation[k] = v
            end
            local new_ext = {}
            for k, v in pairs(annotation["ext"]) do
                new_ext[tostring(k)] = v
            end
            new_annotation["ext"] = new_ext
        else
            new_annotation = annotation
        end
        new_annotations[hash] = new_annotation
    end
    return new_annotations
end

--- Modifies the given table so the keys in the `ext` sub-table are paresd into numbers.
local function destringify_ext_keys(annotations)
    for hash, annotation in pairs(annotations) do
        if annotation["ext"] then
            local new_ext = {}
            for k, v in pairs(annotation["ext"]) do
                new_ext[tonumber(k)] = v
            end
            annotation["ext"] = new_ext
        end
    end
end

local function read_json_file(path)
    local file = io.open(path, "r")
    if not file then
        -- file doesn't exist
        return {}
    end

    local content = file:read("*a")
    file:close()

    if not content or content == "" then
        return {}
    end

    local ok, data = pcall(rapidjson.decode, content)
    if not ok or type(data) ~= "table" then
        return {}
    end

    destringify_ext_keys(data)

    return data
end

local function write_json_file(path, data)
    local file = io.open(path, "w")
    if not file then return false end

    file:write(rapidjson.encode(with_stringified_ext_keys(data)))
    file:close()
    return true
end


function Highlightsync:onDispatcherRegisterActions()

        --- for gestures
        Dispatcher:registerAction("hightlightsync_action", {
            category = "none",
            event = "SyncBookHighlights",
            title = _("Sync Highlights Now"),
            help = _("Synchronize highlights with the cloud."),
            reader = true
        })

end

Highlightsync.default_settings = {
    auto_sync = false,
    pages_before_update = nil,
}



function Highlightsync:init()
    if self.document and self.document.is_pic then
        return -- disable in PIC documents
    end

    self.is_syncing = false
    self.sync_timestamp = 0
    self.page_update_counter = 0
    self.last_page = -1
    self.periodic_sync_scheduled = false
    self.reload_task = nil

    -- Like kosync, use an instance-specific task closure for safe scheduling/unscheduling.
    self.periodic_sync_task = function()
        self.periodic_sync_scheduled = false
        self.page_update_counter = 0
        -- Do not force networking for periodic syncs; rely on existing connection.
        self:SyncBookHighlights(true, false, false)
    end

    Highlightsync.settings = G_reader_settings:readSetting("highlight_sync", self.default_settings)

    -- Migrate from the old per-event toggles to the unified auto_sync flag.
    if self.settings.sync_on_open or self.settings.sync_on_close or self.settings.sync_on_resume then
        self.settings.auto_sync = true
        self.settings.sync_on_open = nil
        self.settings.sync_on_close = nil
        self.settings.sync_on_resume = nil
        G_reader_settings:saveSetting("highlight_sync", self.settings)
    end

    -- Disable auto_sync if wifi_enable_action was reset to "prompt" behind our back,
    -- mirroring kosync's guard to avoid unanticipated WiFi-toggle prompts.
    if self.settings.auto_sync and Device:hasSeamlessWifiToggle()
    and G_reader_settings:readSetting("wifi_enable_action") ~= "turn_on" then
        self.settings.auto_sync = false
        logger.warn("Highlightsync: Automatic sync disabled because wifi_enable_action is not turn_on")
    end

    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

function Highlightsync:onReaderReady()
    if is_reloading_due_to_sync then
        is_reloading_due_to_sync = false
        -- Still register events on reload; debounce will prevent a redundant sync.
        self:registerEvents()
        self.last_page = self.ui:getCurrentPage()
        return
    end

    if self.settings.auto_sync then
        UIManager:nextTick(function()
            -- silent=true (background), reload=true (apply incoming highlights), interactive=false
            self:SyncBookHighlights(true, true, false)
        end)
    end
    self:registerEvents()
    self.last_page = self.ui:getCurrentPage()
end

-- Dynamically wire or unwire all auto-sync event handlers based on the auto_sync toggle.
-- Mirrors kosync's registerEvents() pattern exactly.
function Highlightsync:registerEvents()
    if self.settings.auto_sync then
        self.onCloseDocument        = self._onCloseDocument
        self.onPageUpdate           = self._onPageUpdate
        self.onResume               = self._onResume
        self.onSuspend              = self._onSuspend
        self.onNetworkConnected     = self._onNetworkConnected
        self.onNetworkDisconnecting = self._onNetworkDisconnecting
    else
        self.onCloseDocument        = nil
        self.onPageUpdate           = nil
        self.onResume               = nil
        self.onSuspend              = nil
        self.onNetworkConnected     = nil
        self.onNetworkDisconnecting = nil
    end
end

function Highlightsync:_onCloseDocument()
    logger.dbg("Highlightsync: onCloseDocument")
    if is_reloading_due_to_sync then return end
    self.onResume  = nil
    self.onSuspend = nil
    local server = self.settings.sync_server
    if not server then return end
    -- Dropbox: block until online. WebDAV: skip if offline (deferred retry fires post-teardown).
    if server.type == "dropbox" then
        NetworkMgr:goOnlineToRun(function()
            self:SyncBookHighlights(true, false, false)
        end)
    else
        if NetworkMgr:isConnected() then
            self:SyncBookHighlights(true, false, false)
        end
    end
end

function Highlightsync:_onResume()
    logger.dbg("Highlightsync: onResume")
    -- Skip if WiFi restore will fire a NetworkConnected event (avoids duplicate sync).
    if Device:hasWifiRestore() and NetworkMgr.wifi_was_on and G_reader_settings:isTrue("auto_restore_wifi") then
        return
    end
    UIManager:scheduleIn(1, function()
        self:SyncBookHighlights(true, true, false)
    end)
end

function Highlightsync:_onSuspend()
    logger.dbg("Highlightsync: onSuspend")
    self:SyncBookHighlights(true, false, false)
end

function Highlightsync:_onNetworkConnected()
    logger.dbg("Highlightsync: onNetworkConnected")
    UIManager:scheduleIn(0.5, function()
        self:SyncBookHighlights(true, false, false)
    end)
end

function Highlightsync:_onNetworkDisconnecting()
    logger.dbg("Highlightsync: onNetworkDisconnecting")
    self:SyncBookHighlights(true, false, false)
end

function Highlightsync:_onPageUpdate(page)
    if page == nil then return end
    if self.last_page ~= page then
        self.last_page = page
        self.page_update_counter = self.page_update_counter + 1
        if self.periodic_sync_scheduled
        or (self.settings.pages_before_update and self.page_update_counter >= self.settings.pages_before_update) then
            self:schedulePeriodicSync()
        end
    end
end

function Highlightsync:schedulePeriodicSync()
    UIManager:unschedule(self.periodic_sync_task)
    UIManager:scheduleIn(10, self.periodic_sync_task)
    self.periodic_sync_scheduled = true
end

function Highlightsync:onCloseWidget()
    UIManager:unschedule(self.periodic_sync_task)
    self.periodic_sync_task = nil
    -- Cancel any pending deferred reload so it doesn't fire on a torn-down document.
    if self.reload_task then
        UIManager:unschedule(self.reload_task)
        self.reload_task = nil
        is_reloading_due_to_sync = false
    end
end

function Highlightsync:getSyncPeriod()
    if not self.settings.auto_sync then
        return _("Not available")
    end
    local period = self.settings.pages_before_update
    if period and period > 0 then
        return period
    end
    return _("Never")
end



function Highlightsync:onSync(local_path, cached_path, income_path, reload, sidecar_dir, file_name, data_annotations)

    local local_highlights  = data_annotations
    local cached_highlights = read_json_file(cached_path) or {}
    local income_highlights = read_json_file(income_path) or {}

    local annotations, local_changed = Merge.Merge_highlights(local_highlights, income_highlights, cached_highlights)

    self.last_sync_changed = local_changed

    if not local_changed then
        logger.dbg("Highlightsync: no changes after merge, skipping reload")
        return true
    end

    write_json_file(sidecar_dir .. "/" .. file_name .. ".json", annotations) -- Save annotations local

    if self.ui and self.ui.annotation then
        self.ui.annotation.annotations = annotations
        if reload then
            is_reloading_due_to_sync = true
            -- Defer reload: wait for any open modal (e.g. kosync ConfirmBox) to be
            -- dismissed first. Initial 2s delay covers kosync's network round-trip.
            self.reload_task = function()
                if not self.ui or not self.ui.document then
                    self.reload_task = nil
                    is_reloading_due_to_sync = false
                    return
                end
                local top = UIManager:getTopmostVisibleWidget()
                if top and top.modal then
                    UIManager:scheduleIn(0.5, self.reload_task)
                else
                    self.reload_task = nil
                    UIManager:tickAfterNext(function()
                        if self.ui and self.ui.document then
                            self.ui:reloadDocument()
                        else
                            is_reloading_due_to_sync = false
                        end
                    end)
                end
            end
            UIManager:scheduleIn(2, self.reload_task)
        end
    end

    return true
end

function Highlightsync:is_doc()
    if self.document then
        return true
    else
        return false
    end
end

function Highlightsync:canSync()
    return self.is_doc(self) and self.settings.sync_server ~= nil
end

local function sanitize_filename(str)
    if not str then return "" end
    return str:gsub("[^%w%.%-%_]", "_")
end

function Highlightsync:onSyncBookHighlights()
        self:SyncBookHighlights(false, true, true)
end

function Highlightsync:SyncBookHighlights(silent, reload, interactive)
    if not self:canSync() then return end

    if self.is_syncing then
        logger.warn("Highlightsync: Duplicate sync attempt ignored.")
        return
    end

    -- Debounce non-interactive (auto) syncs: skip if we synced less than 25s ago.
    if not interactive then
        local now = UIManager:getElapsedTimeSinceBoot()
        if now - self.sync_timestamp <= SYNC_DEBOUNCE_DELAY then
            logger.dbg("Highlightsync: Skipping auto-sync, last sync was less than 25s ago")
            return
        end
    end

    -- enable lock
    self.is_syncing = true

    local doc_path = self.document and self.document.file
    local doc_settings = self.ui and self.ui.doc_settings
    local sidecar_dir = doc_settings:getSidecarDir(doc_path)
    ensure_dir_exists(sidecar_dir)
    local data_annotations = self.ui.annotation.annotations  -- snapshot at call time; safe for deferred retries
    local file_name = sanitize_filename(sidecar_dir:match("([^/]+)/*$"))
    local json_path = sidecar_dir .. "/" .. file_name .. ".json"

    write_json_file(json_path, data_annotations) -- Save annotations local

    self.last_sync_changed = false
    SyncService.sync(self.settings.sync_server, json_path,
    function(local_path, cached_path, income_path)
        local success = self:onSync(local_path, cached_path, income_path, reload, sidecar_dir, file_name, data_annotations)
        self.sync_timestamp = UIManager:getElapsedTimeSinceBoot()
        return success
    end,
    silent,
    function()
        if interactive or self.last_sync_changed then
            UIManager:show(Notification:new{
                text = _("Highlights synchronized."),
                timeout = 2,
            })
        end
    end
    )

    -- Release lock: when offline, SyncService queues a retry without calling the
    -- callback, so we must clear here or the lock stays set permanently.
    self.is_syncing = false
end


function Highlightsync:addToMainMenu(menu_items)

    menu_items.highlight_sync = {
        text = _("Highlight Sync"),
        sub_item_table = {
            {
                text = _("Sync Cloud"),
                callback = function(touchmenu_instance)
                    local server = self.settings.sync_server
                    local edit_cb = function()
                        local sync_settings = SyncService:new{}
                        sync_settings.onClose = function(this)
                            UIManager:close(this)
                        end
                        sync_settings.onConfirm = function(sv)
                            self.settings.sync_server = sv
                            touchmenu_instance:updateItems()
                        end
                        UIManager:show(sync_settings)
                    end
                    if not server then
                        edit_cb()
                        return
                    end
                    local dialogue
                    local delete_button = {
                        text = _("Delete"),
                        callback = function()
                            UIManager:close(dialogue)
                            UIManager:show(ConfirmBox:new{
                                text = _("Delete server info?"),
                                cancel_text = _("Cancel"),
                                cancel_callback = function()
                                end,
                                ok_text = _("Delete"),
                                ok_callback = function()
                                    self.settings.sync_server = nil
                                    touchmenu_instance:updateItems()
                                end,
                            })
                        end,
                    }
                    local edit_button = {
                        text = _("Edit"),
                        callback = function()
                            UIManager:close(dialogue)
                            edit_cb()
                        end
                    }
                    local close_button = {
                        text = _("Close"),
                        callback = function()
                            UIManager:close(dialogue)
                        end
                    }
                    local type = server.type == "dropbox" and " (DropBox)" or " (WebDAV)"
                    dialogue = ButtonDialog:new{
                        title = T(_("Cloud storage:\n%1\n\nFolder path:\n%2\n\nSet up the same cloud folder on each device to sync across your devices."),
                                     server.name.." "..type, SyncService.getReadablePath(server)),
                        buttons = {
                            {delete_button, edit_button, close_button}
                        },
                    }
                    UIManager:show(dialogue)
                end,
                keep_menu_open = true,
            },
            {
                text = _("Sync Highlights"),
                callback = function()
                    self:SyncBookHighlights(false, true, true)
                end,
                enabled_func = function() return self.canSync(self) end
            },
            {
                text = _("Settings"),
                sub_item_table = {
                    {
                        text = _("Automatically sync highlights"),
                        checked_func = function() return self.settings.auto_sync end,
                        help_text = _("Automatically sync highlights on open, close, resume, suspend, and network changes."),
                        callback = function()
                            -- Mirror kosync: block enabling when wifi_enable_action isn't "turn_on",
                            -- since prompt-mode WiFi nagging is unusable with auto-sync.
                            if not self.settings.auto_sync
                                    and Device:hasSeamlessWifiToggle()
                                    and G_reader_settings:readSetting("wifi_enable_action") ~= "turn_on" then
                                UIManager:show(InfoMessage:new{
                                    text = _("You will have to switch the 'Action when Wi-Fi is off' Network setting to 'turn on' to be able to enable this feature!"),
                                })
                                return
                            end
                            self.settings.auto_sync = not self.settings.auto_sync
                            self:registerEvents()
                            if self.settings.auto_sync then
                                -- Pull immediately so we don't silently overwrite remote changes.
                                UIManager:nextTick(function()
                                    self:SyncBookHighlights(false, true, true)
                                end)
                            end
                            G_reader_settings:saveSetting("highlight_sync", self.settings)
                        end,
                    },
                    {
                        text_func = function()
                            return T(_("Periodically sync every # pages (%1)"), self:getSyncPeriod())
                        end,
                        enabled_func = function() return self.settings.auto_sync end,
                        keep_menu_open = true,
                        callback = function(touchmenu_instance)
                            local SpinWidget = require("ui/widget/spinwidget")
                            local items = SpinWidget:new{
                                text = _("Number of page turns between automatic syncs.\nSet to 0 to disable page-based syncing."),
                                value = self.settings.pages_before_update or 0,
                                value_min = 0,
                                value_max = 999,
                                value_step = 1,
                                value_hold_step = 10,
                                ok_text = _("Set"),
                                title_text = _("Pages between syncs"),
                                default_value = 0,
                                callback = function(spin)
                                    self.settings.pages_before_update = spin.value > 0 and spin.value or nil
                                    G_reader_settings:saveSetting("highlight_sync", self.settings)
                                    if touchmenu_instance then touchmenu_instance:updateItems() end
                                end,
                            }
                            UIManager:show(items)
                        end,
                    },
                }
            }
        }
    }
end

require("insert_menu")

return Highlightsync
