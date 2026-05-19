describe("Raw sidecar upload", function()
    local raw_sidecar, test_utils
    local test_data_dir = os.getenv("PWD") .. "/test_raw_sidecar_tmp"
    local old_getDataDir
    local captured

    setup(function()
        require("commonrequire")
        local plugin_path = "plugins/AnnotationSync.koplugin/?.lua"
        package.path = plugin_path .. ";" .. package.path

        test_utils = require("spec/unit/test_utils")
        old_getDataDir = test_utils.setup_test_env(test_data_dir)
    end)

    teardown(function()
        test_utils.teardown_test_env(test_data_dir, old_getDataDir)
    end)

    -- Inject a fake webdavapi so we never touch the network.
    -- Must run before `require("raw_sidecar")` so the lazy require inside the
    -- provider picks up our mock. (ffi/util is the real one from commonrequire.)
    local function install_mock_webdavapi()
        captured = { calls = {} }
        package.loaded["apps/cloudstorage/webdavapi"] = {
            getJoinedPath = function(_, base, path)
                base = (base or ""):gsub("/+$", "")
                path = (path or ""):gsub("^/+", ""):gsub("/+$", "")
                if path == "" then return base end
                return base .. "/" .. path
            end,
            createFolder = function(_, folder_url, user, pass, folder_name)
                table.insert(captured.calls, {
                    op = "mkcol", url = folder_url, user = user,
                    pass = pass, folder_name = folder_name,
                })
                return captured.mkcol_code or 201
            end,
            uploadFile = function(_, file_url, user, pass, local_path, etag)
                table.insert(captured.calls, {
                    op = "put", url = file_url, user = user,
                    pass = pass, local_path = local_path, etag = etag,
                })
                return captured.put_code or 201
            end,
        }
    end

    local function fresh_module()
        package.loaded["raw_sidecar"] = nil
        install_mock_webdavapi()
        raw_sidecar = require("raw_sidecar")
    end

    local function write_fake_sidecar(name)
        local path = test_data_dir .. "/" .. (name or "metadata.epub.lua")
        local f = io.open(path, "w")
        f:write("return { annotations = {} }\n")
        f:close()
        return path
    end

    it("uploads the sidecar to the correct WebDAV URL", function()
        fresh_module()
        local server = {
            type = "webdav",
            address = "https://dav.example.com/remote.php/dav/files/u",
            username = "alice",
            password = "secret",
            url = "/sync/annotations",
        }
        local local_path = write_fake_sidecar()
        local ok = raw_sidecar.upload_sidecar(server, "MyBook.sdr", local_path)
        assert.is_true(ok)
        assert.are.equal(2, #captured.calls)
        assert.are.equal("mkcol", captured.calls[1].op)
        assert.are.equal(
            "https://dav.example.com/remote.php/dav/files/u/sync/annotations/MyBook.sdr",
            captured.calls[1].url
        )
        assert.are.equal("put", captured.calls[2].op)
        assert.are.equal(
            "https://dav.example.com/remote.php/dav/files/u/sync/annotations/MyBook.sdr/metadata.epub.lua",
            captured.calls[2].url
        )
        assert.are.equal("alice", captured.calls[2].user)
        assert.are.equal(local_path, captured.calls[2].local_path)
    end)

    it("treats MKCOL 405 (already exists) as success and still PUTs", function()
        fresh_module()
        captured.mkcol_code = 405
        local ok = raw_sidecar.upload_sidecar({
            type = "webdav", address = "https://d", username = "u",
            password = "p", url = "/",
        }, "X.sdr", write_fake_sidecar())
        assert.is_true(ok)
        assert.are.equal("put", captured.calls[2].op)
    end)

    it("returns false when PUT fails", function()
        fresh_module()
        captured.put_code = 500
        local ok = raw_sidecar.upload_sidecar({
            type = "webdav", address = "https://d", username = "u",
            password = "p", url = "/",
        }, "X.sdr", write_fake_sidecar())
        assert.is_false(ok)
    end)

    it("no-ops for unsupported providers (Dropbox)", function()
        fresh_module()
        local ok = raw_sidecar.upload_sidecar({
            type = "dropbox", address = "x", username = "u", password = "p", url = "/",
        }, "X.sdr", write_fake_sidecar())
        assert.is_false(ok)
        assert.are.equal(0, #captured.calls)
    end)

    it("skips when local sidecar is missing", function()
        fresh_module()
        local ok = raw_sidecar.upload_sidecar({
            type = "webdav", address = "https://d", username = "u",
            password = "p", url = "/",
        }, "X.sdr", test_data_dir .. "/does-not-exist.lua")
        assert.is_false(ok)
        assert.are.equal(0, #captured.calls)
    end)

    it("rejects malformed inputs without calling provider", function()
        fresh_module()
        assert.is_false(raw_sidecar.upload_sidecar(nil, "X.sdr", "/tmp/x"))
        assert.is_false(raw_sidecar.upload_sidecar({type = "webdav"}, "", "/tmp/x"))
        assert.is_false(raw_sidecar.upload_sidecar({type = "webdav"}, "X.sdr", ""))
        assert.are.equal(0, #captured.calls)
    end)

    it("preserves the sidecar filename (metadata.pdf.lua etc.)", function()
        fresh_module()
        local local_path = write_fake_sidecar("metadata.pdf.lua")
        local ok = raw_sidecar.upload_sidecar({
            type = "webdav", address = "https://d", username = "u",
            password = "p", url = "/r",
        }, "Book.sdr", local_path)
        assert.is_true(ok)
        assert.are.equal("https://d/r/Book.sdr/metadata.pdf.lua", captured.calls[2].url)
    end)

    it("future providers can register via M.providers", function()
        fresh_module()
        local called = {}
        raw_sidecar.providers.ftp = function(server, subdir, path)
            called.server = server
            called.subdir = subdir
            called.path = path
            return true
        end
        local local_path = write_fake_sidecar()
        local ok = raw_sidecar.upload_sidecar(
            { type = "ftp" }, "Book.sdr", local_path
        )
        assert.is_true(ok)
        assert.are.equal("Book.sdr", called.subdir)
        assert.are.equal(local_path, called.path)
        raw_sidecar.providers.ftp = nil
    end)

    it("upload_book uploads to the base sync dir without an MKCOL", function()
        fresh_module()
        local server = {
            type = "webdav",
            address = "https://dav.example.com/remote.php/dav/files/u",
            username = "alice",
            password = "secret",
            url = "/sync/annotations",
        }
        local local_path = write_fake_sidecar("MyBook.epub")
        local ok = raw_sidecar.upload_book(server, local_path)
        assert.is_true(ok)
        assert.are.equal(1, #captured.calls)
        assert.are.equal("put", captured.calls[1].op)
        assert.are.equal(
            "https://dav.example.com/remote.php/dav/files/u/sync/annotations/MyBook.epub",
            captured.calls[1].url
        )
        assert.are.equal(local_path, captured.calls[1].local_path)
    end)

    it("upload_book rejects malformed inputs without calling provider", function()
        fresh_module()
        assert.is_false(raw_sidecar.upload_book(nil, "/tmp/x"))
        assert.is_false(raw_sidecar.upload_book({ type = "webdav" }, ""))
        assert.are.equal(0, #captured.calls)
    end)

    it("upload_book no-ops for unsupported providers (Dropbox)", function()
        fresh_module()
        local ok = raw_sidecar.upload_book({
            type = "dropbox", address = "x", username = "u", password = "p", url = "/",
        }, write_fake_sidecar("MyBook.epub"))
        assert.is_false(ok)
        assert.are.equal(0, #captured.calls)
    end)
end)

describe("SyncManager._uploadRawSidecar guard chain", function()
    local SyncManager, json, test_utils
    local test_data_dir = os.getenv("PWD") .. "/test_raw_sidecar_guard_tmp"
    local old_getDataDir

    setup(function()
        require("commonrequire")
        local plugin_path = "plugins/AnnotationSync.koplugin/?.lua"
        package.path = plugin_path .. ";" .. package.path

        test_utils = require("spec/unit/test_utils")
        json = require("json")
        old_getDataDir = test_utils.setup_test_env(test_data_dir)
        os.execute("mkdir -p " .. test_data_dir .. "/book.sdr")
        local f = io.open(test_data_dir .. "/book.sdr/metadata.epub.lua", "w")
        f:write("return {}\n")
        f:close()

        package.loaded["raw_sidecar"] = nil
        package.loaded["manager"] = nil
        SyncManager = require("manager")
    end)

    teardown(function()
        test_utils.teardown_test_env(test_data_dir, old_getDataDir)
        package.loaded["raw_sidecar"] = nil
        package.loaded["manager"] = nil
    end)

    local function make_plugin(upload_enabled)
        return {
            settings = { upload_raw_sidecar = upload_enabled },
            ui = { document = { file = test_data_dir .. "/book.epub" } },
        }
    end

    it("no-ops when upload_raw_sidecar is disabled", function()
        local raw_sidecar = require("raw_sidecar")
        local called = false
        local original = raw_sidecar.upload_sidecar
        raw_sidecar.upload_sidecar = function() called = true; return true end
        local mgr = SyncManager:new(make_plugin(false))
        mgr:_uploadRawSidecar({ file = test_data_dir .. "/book.epub" })
        raw_sidecar.upload_sidecar = original
        assert.is_false(called)
    end)

    it("no-ops when no cloud_server_object configured", function()
        local raw_sidecar = require("raw_sidecar")
        local called = false
        local original = raw_sidecar.upload_sidecar
        raw_sidecar.upload_sidecar = function() called = true; return true end
        G_reader_settings:delSetting("cloud_server_object")
        local mgr = SyncManager:new(make_plugin(true))
        mgr:_uploadRawSidecar({ file = test_data_dir .. "/book.epub" })
        raw_sidecar.upload_sidecar = original
        assert.is_false(called)
    end)

    it("uploads the sidecar into its .sdr subdir and the book alongside it", function()
        local raw_sidecar = require("raw_sidecar")
        local sidecar_calls = {}
        local book_calls = {}
        local original_sidecar = raw_sidecar.upload_sidecar
        local original_book = raw_sidecar.upload_book
        raw_sidecar.upload_sidecar = function(_server, subdir, path)
            table.insert(sidecar_calls, { subdir = subdir, path = path })
            return true
        end
        raw_sidecar.upload_book = function(_server, path)
            table.insert(book_calls, { path = path })
            return true
        end

        local book_path = test_data_dir .. "/book.epub"
        local bf = io.open(book_path, "w")
        bf:write("fake epub bytes\n")
        bf:close()

        G_reader_settings:saveSetting("cloud_server_object", json.encode({
            type = "webdav", address = "https://d", username = "u",
            password = "p", url = "/",
        }))

        local mgr = SyncManager:new(make_plugin(true))
        mgr:_uploadRawSidecar({ file = book_path })

        raw_sidecar.upload_sidecar = original_sidecar
        raw_sidecar.upload_book = original_book
        G_reader_settings:delSetting("cloud_server_object")

        assert.are.equal(1, #sidecar_calls)
        assert.are.equal("book.sdr", sidecar_calls[1].subdir)
        assert.are.equal(test_data_dir .. "/book.sdr/metadata.epub.lua", sidecar_calls[1].path)
        assert.are.equal(1, #book_calls)
        assert.are.equal(book_path, book_calls[1].path)
    end)
end)
