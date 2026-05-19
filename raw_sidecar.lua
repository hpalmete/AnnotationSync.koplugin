local logger = require("logger")

local M = {}

-- Provider dispatch table.
-- Each handler: function(server, remote_subdir, local_path) -> boolean
-- A nil/empty remote_subdir means "upload into the base sync folder".
-- Add entries here to support additional cloud providers.
M.providers = {}

M.providers.webdav = function(server, remote_subdir, local_path)
    local WebDavApi = require("apps/cloudstorage/webdavapi")
    local ffiutil = require("ffi/util")
    local lfs = require("libs/libkoreader-lfs")

    local address = server.address
    local user = server.username
    local password = server.password
    local start_folder = server.url or ""

    if not address or address == "" then
        logger.warn("AnnotationSync: raw upload skipped — WebDAV server address missing")
        return false
    end
    if not lfs.attributes(local_path, "mode") then
        logger.warn("AnnotationSync: raw upload skipped — local file missing: " .. tostring(local_path))
        return false
    end

    local filename = ffiutil.basename(local_path)
    local target_url = WebDavApi:getJoinedPath(address, start_folder)

    -- A non-empty remote_subdir nests the upload inside that folder, creating it
    -- if needed. A nil/empty subdir uploads straight into the base sync folder.
    if remote_subdir and remote_subdir ~= "" then
        target_url = WebDavApi:getJoinedPath(target_url, remote_subdir)
        -- MKCOL: 201 created, 405 already exists. Anything else we log but still try PUT.
        local mkcol_code = WebDavApi:createFolder(target_url, user, password, remote_subdir)
        if mkcol_code ~= 201 and mkcol_code ~= 405 then
            logger.info("AnnotationSync: MKCOL returned " .. tostring(mkcol_code) .. " for " .. target_url .. " (continuing)")
        end
    end

    local file_url = WebDavApi:getJoinedPath(target_url, filename)
    local put_code = WebDavApi:uploadFile(file_url, user, password, local_path)
    if type(put_code) ~= "number" or put_code < 200 or put_code > 299 then
        logger.warn("AnnotationSync: raw upload PUT failed (code=" .. tostring(put_code) .. ") for " .. file_url)
        return false
    end

    logger.dbg("AnnotationSync: raw upload completed: " .. file_url)
    return true
end

-- Resolves the provider handler and runs it under pcall. Never throws.
local function dispatch(server, remote_subdir, local_path)
    local handler = M.providers[server.type]
    if not handler then
        logger.info("AnnotationSync: raw upload skipped — provider '"
            .. tostring(server.type) .. "' not supported")
        return false
    end

    local ok, result = pcall(handler, server, remote_subdir, local_path)
    if not ok then
        logger.warn("AnnotationSync: raw upload crashed: " .. tostring(result))
        return false
    end
    return result == true
end

-- Uploads a file into a named subdirectory of the base sync folder, creating
-- that subdirectory if needed (used for the metadata.<ext>.lua sidecar).
--   server:        table from cloud_server_object (must include .type)
--   remote_subdir: the sidecar-directory basename (e.g. "MyBook.sdr")
--   local_path:    absolute path to the local file to upload
-- Returns true on success, false otherwise. Never throws.
function M.upload_sidecar(server, remote_subdir, local_path)
    if type(server) ~= "table" then
        logger.dbg("AnnotationSync: raw upload skipped — no server")
        return false
    end
    if type(remote_subdir) ~= "string" or remote_subdir == "" then
        logger.warn("AnnotationSync: raw upload skipped — invalid remote_subdir")
        return false
    end
    if type(local_path) ~= "string" or local_path == "" then
        logger.warn("AnnotationSync: raw upload skipped — invalid local_path")
        return false
    end

    return dispatch(server, remote_subdir, local_path)
end

-- Uploads a file directly into the base sync folder, alongside the .sdr
-- subdirectories (used for the book file itself).
--   server:     table from cloud_server_object (must include .type)
--   local_path: absolute path to the local file to upload
-- Returns true on success, false otherwise. Never throws.
function M.upload_book(server, local_path)
    if type(server) ~= "table" then
        logger.dbg("AnnotationSync: book upload skipped — no server")
        return false
    end
    if type(local_path) ~= "string" or local_path == "" then
        logger.warn("AnnotationSync: book upload skipped — invalid local_path")
        return false
    end

    return dispatch(server, nil, local_path)
end

return M
