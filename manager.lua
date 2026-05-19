local DocumentRegistry = require("document/documentregistry")
local DataStorage = require("datastorage")
local util = require("util")
local logger = require("logger")
local _ = require("gettext")
local docsettings = require("frontend/docsettings")
local UIManager = require("ui/uimanager")
local Event = require("ui/event")
local lfs = require("libs/libkoreader-lfs")
local json = require("json")

local annotations = require("annotations")
local remote = require("remote")
local utils = require("utils")
local raw_sidecar = require("raw_sidecar")

local SyncManager = {}

function SyncManager:new(plugin)
    local o = {
        plugin = plugin
    }
    setmetatable(o, self)
    self.__index = self
    return o
end

-- Sync all changed documents listed in changed_documents.lua
function SyncManager:syncAllChangedDocuments()
    local total, changed_docs = self:getPendingChangedDocuments()
    if total == 0 then
        utils.show_msg("No changed documents to sync.")
        return
    end
    local count = 0
    local ui_document = self.plugin.ui and self.plugin.ui.document
    for file, _ in pairs(changed_docs) do
        -- Try to get a document object for this file, open if needed
        local document = self:getDocumentByFile(file)
        if document then
            logger.info("AnnotationSync: syncing document: " .. file)
            local is_temporary = (document ~= ui_document)
            local ok, success = pcall(self.syncDocument, self, document, false)
            if ok and success then
                count = count + 1
            elseif not ok then
                logger.warn("AnnotationSync: syncDocument CRASHED for " .. file .. ": " .. tostring(success))
            end

            if is_temporary then
                logger.info("AnnotationSync: closing temporary document: " .. file)
                document:close()
            end
        else
            -- Check if file still exists
            if not util.fileExists(file) then
                logger.warn("AnnotationSync: file missing, removing from sync list: " .. file)
                self:removeFromChangedDocumentsFileByPath(file)
            else
                logger.warn("AnnotationSync: could not open document for sync: " .. file)
            end
        end
    end
    if count == 0 then
        utils.show_msg("Unable to sync modified documents: " .. total)
    else
        self:updateLastSync("Sync All")
        utils.show_msg("Successfully synced modified documents: " .. count)
    end
end

-- Orchestrates the sync process for a single document
function SyncManager:syncDocument(document, is_manual)
    local file = document and document.file
    if not file then return false end

    self:_flushSettings()
    logger.dbg("AnnotationSync: syncing document: " .. file)

    local json_path = self:writeAnnotationsJSON(document)
    if not json_path then return false end

    logger.dbg("AnnotationSync: remote sync of " .. json_path .. " (force=" .. tostring(is_manual) .. ")")
    local sync_success = false
    remote.sync_annotations(self.plugin, document, json_path, function(success, merged_list)
        sync_success = success
        self:_onSyncComplete(document, success, merged_list)
    end, is_manual)
    return sync_success
end

-- Refreshes the local sync JSON file with latest memory/sidecar state
function SyncManager:writeAnnotationsJSON(document)
    local file = document and document.file
    if not file then return false end

    local sdr_dir = docsettings:getSidecarDir(file)
    if not sdr_dir or sdr_dir == "" then return false end

    -- Fix for Issue #34: Ensure the local sidecar directory exists
    if not lfs.attributes(sdr_dir, "mode") then
        logger.info("AnnotationSync: creating missing sidecar directory: " .. sdr_dir)
        os.execute("mkdir -p " .. sdr_dir)
    end

    local filename = self:_getAnnotationFilename(file)
    return annotations.write_annotations_json(document, self:getAnnotationsForDocument(document), sdr_dir, filename)
end

function SyncManager:changedDocumentsFile()
    return DataStorage:getDataDir() .. "/changed_documents.lua"
end

function SyncManager:getPendingChangedDocuments()
    local count = 0
    local track_path = self:changedDocumentsFile()
    local ok, changed_docs = pcall(dofile, track_path)
    if ok and type(changed_docs) == "table" then
        for _ in pairs(changed_docs) do count = count + 1 end
    end
    return count, changed_docs
end

function SyncManager:hasPendingChangedDocuments()
    local count, _ = self:getPendingChangedDocuments()
    return count > 0
end

function SyncManager:addToChangedDocumentsFile(file)
    local track_path = self:changedDocumentsFile()
    -- Load existing table or create new
    local changed_docs = {}
    local ok, loaded = pcall(dofile, track_path)
    if ok and type(loaded) == "table" then
        changed_docs = loaded
    end
    if file and type(file) == "string" then
        changed_docs[file] = true
        self:writeChangedDocumentsFile(changed_docs)
    end
end

function SyncManager:removeFromChangedDocumentsFile(document)
    local file = document and document.file
    self:removeFromChangedDocumentsFileByPath(file)
end

function SyncManager:removeFromChangedDocumentsFileByPath(file)
    if not file then return end
    local track_path = self:changedDocumentsFile()
    local ok, changed_docs = pcall(dofile, track_path)
    if ok and type(changed_docs) == "table" and changed_docs[file] then
        changed_docs[file] = nil
        self:writeChangedDocumentsFile(changed_docs)
    end
end

function SyncManager:writeChangedDocumentsFile(changed_docs)
    local track_path = self:changedDocumentsFile()
    local f = io.open(track_path, "w")
    if f then
        f:write("return ", self:_serialize_table(changed_docs), "\n")
        f:close()
    else
        logger.warn("AnnotationSync: Failed to open changed documents file: " .. track_path)
    end
end

-- Get annotations associated with given document
function SyncManager:getAnnotationsForDocument(document)
    -- Handle active document
    if document == self.plugin.ui.document and self.plugin.ui.annotation and self.plugin.ui.annotation.annotations then
        return self.plugin.ui.annotation.annotations
    end
    -- Handle inactive document
    local annotation_sidecar = docsettings:open(document.file)
    local result = annotation_sidecar:readSetting("annotations")
    return result or {}
end

-- Get only annotations marked as deleted in the local sync JSON
function SyncManager:getDeletedAnnotations(document)
    local file = document and document.file
    if not file then return {} end

    local sdr_dir = docsettings:getSidecarDir(file)
    if not sdr_dir or sdr_dir == "" then return {} end

    local filename = self:_getAnnotationFilename(file)
    local json_path = sdr_dir .. "/" .. filename

    local map = utils.read_json(json_path)
    if not map then return {} end

    local deleted = {}
    for _, v in pairs(map) do
        if v.deleted then
            table.insert(deleted, v)
        end
    end

    table.sort(deleted, function(a, b)
        local cmp = annotations.compare_positions(a.page, b.page, document)
        return (cmp or 0) > 0
    end)

    return deleted
end

-- Helper to get a document object by file path
function SyncManager:getDocumentByFile(file)
    -- If the current document is available, return it if it matches.
    local ui_document = self.plugin.ui and self.plugin.ui.document
    if ui_document and ui_document.file == file then
        return ui_document
    end
    -- Otherwise open the document with the correct provider in order to use
    -- its `comparePositions()` function.
    local document
    local provider = DocumentRegistry:getProvider(file)
    if provider then
        logger.dbg("AnnotationSync: provider for " .. file .. ": " .. provider.provider)
        document = DocumentRegistry:openDocument(file, provider)
        -- A document provided by crengine must be rendered in order to use
        -- any functions that rely on XPointers.
        if provider.provider == "crengine" then
            if document then
                logger.dbg("AnnotationSync: rendering: " .. file)
                document:render()
            end
        end
    end
    return document
end

function SyncManager:updateLastSync(descriptor)
    local parenthetical = ""
    if descriptor and type(descriptor) == "string" then
        parenthetical = " (" .. descriptor .. ")"
    end
    self.plugin.settings.last_sync = os.date("%Y-%m-%d %H:%M:%S") .. parenthetical
    logger.dbg("AnnotationSync: updateLastSync: updated at " .. self.plugin.settings.last_sync)
end

function SyncManager:_flushSettings()
    UIManager:broadcastEvent(Event:new("FlushSettings"))
end

function SyncManager:_getAnnotationFilename(file)
    if self.plugin.settings.use_filename then
        local filename = file:match("([^/]+)$") or file
        return filename .. ".json"
    end
    local hash = file and type(file) == "string" and util.partialMD5(file) or _("No hash")
    return hash .. ".json"
end

function SyncManager:_onSyncComplete(document, success, merged_list)
    if success then
        if merged_list then
            self.plugin:applySyncedAnnotations(document, merged_list)
        end
        self:removeFromChangedDocumentsFile(document)
        -- Gate 1 passed: annotation sync succeeded and merged state applied.
        -- Now push the raw sidecar file (if enabled) — never before this point.
        self:_uploadRawSidecar(document)
    else
        logger.warn("AnnotationSync: sync failed for " .. (document.file or "unknown") .. ", keeping in changed list")
    end
end

-- Uploads the raw sidecar file (metadata.<ext>.lua) and the book file itself
-- to the cloud, under a subdirectory named after the .sdr folder basename.
-- Only runs after a successful annotation sync and successful flush of merged
-- state to disk.
function SyncManager:_uploadRawSidecar(document)
    if not self.plugin.settings.upload_raw_sidecar then return end

    local file = document and document.file
    if not file then return end

    -- Gate 2: force merged annotations to disk. For the inactive-document branch
    -- applySyncedAnnotations already flushed; for the active document we need
    -- FlushSettings to propagate onSaveSettings -> doc_settings flush.
    self:_flushSettings()

    local sdr_dir = docsettings:getSidecarDir(file)
    if not sdr_dir or sdr_dir == "" then
        logger.warn("AnnotationSync: raw sidecar upload skipped — no sidecar dir for " .. file)
        return
    end

    local sidecar_path = self:_resolveSidecarFile(file, sdr_dir)
    if not sidecar_path then
        logger.warn("AnnotationSync: raw sidecar upload skipped — sidecar file not found under " .. sdr_dir)
        return
    end

    local sdr_basename = sdr_dir:match("([^/]+)/?$")
    if not sdr_basename or sdr_basename == "" then
        logger.warn("AnnotationSync: raw sidecar upload skipped — could not derive basename from " .. sdr_dir)
        return
    end

    -- Gate 3: provider dispatch. raw_sidecar.upload_sidecar no-ops gracefully
    -- for unsupported providers (Dropbox, FTP) so future providers plug in
    -- without touching this call site.
    local server_json = G_reader_settings:readSetting("cloud_server_object")
    if not server_json or server_json == "" then
        logger.dbg("AnnotationSync: raw sidecar upload skipped — no cloud server configured")
        return
    end
    local ok, server = pcall(json.decode, server_json)
    if not ok or type(server) ~= "table" then
        logger.warn("AnnotationSync: raw sidecar upload skipped — malformed cloud_server_object")
        return
    end

    raw_sidecar.upload_sidecar(server, sdr_basename, sidecar_path)

    -- Also upload the book file itself into the same remote .sdr subdirectory.
    raw_sidecar.upload_sidecar(server, sdr_basename, file)
end

-- Resolves the path to metadata.<ext>.lua inside the sdr directory, following
-- KOReader's naming convention. Returns nil if the file doesn't exist on disk.
function SyncManager:_resolveSidecarFile(file, sdr_dir)
    local ext = file:match("%.([^%.]+)$")
    ext = (ext and ext:lower()) or "lua"
    local sidecar_path = sdr_dir .. "/metadata." .. ext .. ".lua"
    if lfs.attributes(sidecar_path, "mode") == "file" then
        return sidecar_path
    end
    return nil
end

-- Helper to serialize a Lua table as code
function SyncManager:_serialize_table(tbl)
    local result = "{\n"
    for k, v in pairs(tbl) do
        result = result .. string.format("  [%q] = %s,\n", k, tostring(v))
    end
    result = result .. "}"
    return result
end

return SyncManager