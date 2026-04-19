local logger = require("logger")

local M = {}

-- Provider dispatch table.
-- Each handler: function(server, remote_subdir, local_path) -> boolean
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
        logger.warn("AnnotationSync: raw upload skipped — local sidecar missing: " .. tostring(local_path))
        return false
    end

    local filename = ffiutil.basename(local_path)
    local base_url = WebDavApi:getJoinedPath(address, start_folder)
    local sdr_url = WebDavApi:getJoinedPath(base_url, remote_subdir)
    local file_url = WebDavApi:getJoinedPath(sdr_url, filename)

    -- MKCOL: 201 created, 405 already exists. Anything else we log but still try PUT.
    local mkcol_code = WebDavApi:createFolder(sdr_url, user, password, remote_subdir)
    if mkcol_code ~= 201 and mkcol_code ~= 405 then
        logger.info("AnnotationSync: MKCOL returned " .. tostring(mkcol_code) .. " for " .. sdr_url .. " (continuing)")
    end

    local put_code = WebDavApi:uploadFile(file_url, user, password, local_path)
    if type(put_code) ~= "number" or put_code < 200 or put_code > 299 then
        logger.warn("AnnotationSync: raw sidecar PUT failed (code=" .. tostring(put_code) .. ") for " .. file_url)
        return false
    end

    logger.dbg("AnnotationSync: raw sidecar uploaded: " .. file_url)
    return true
end

-- Public entry point.
--   server:        table from cloud_server_object (must include .type)
--   remote_subdir: the sidecar-directory basename (e.g. "MyBook.sdr")
--   local_path:    absolute path to the local metadata.<ext>.lua file
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

    local handler = M.providers[server.type]
    if not handler then
        logger.info("AnnotationSync: raw sidecar upload skipped — provider '"
            .. tostring(server.type) .. "' not supported")
        return false
    end

    local ok, result = pcall(handler, server, remote_subdir, local_path)
    if not ok then
        logger.warn("AnnotationSync: raw sidecar upload crashed: " .. tostring(result))
        return false
    end
    return result == true
end

return M
