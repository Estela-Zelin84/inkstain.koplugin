local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local Json = require("pluginota.json")
local Sha256 = require("pluginota.sha256")

local Updater = {}
Updater.__index = Updater

local DEFAULT_MIRRORS = {}

local function log_prefix(self)
    return "[PluginOTA]["..tostring(self.plugin_id or "plugin").."]"
end

local function command_ok(rc)
    return rc == true or rc == 0
end

local function shell_quote(s)
    return "'"..tostring(s or ""):gsub("'", "'\\''").."'"
end

local function safe_id(s)
    local v=tostring(s or ""):gsub("[^%w%._%-]","_")
    return v~="" and v or "plugin"
end

local function basename(path)
    path=tostring(path or ""):gsub("/+$","")
    return path:match("([^/]+)$") or path
end

local function file_exists(path)
    return lfs.attributes(path,"mode") == "file"
end

local function dir_exists(path)
    return lfs.attributes(path,"mode") == "directory"
end

local function read_file(path,binary)
    local f,err=io.open(path,binary and "rb" or "r")
    if not f then return nil,err end
    local data=f:read("*a")
    f:close()
    return data
end

local function file_size(path)
    local f=io.open(path,"rb")
    if not f then return nil end
    local size=f:seek("end")
    f:close()
    return size
end

local function mkdir(path)
    path=tostring(path or "")
    if path=="" then return nil,"empty path" end
    if dir_exists(path) then return true end
    local parent=path:match("^(.*)/[^/]+$")
    if parent and parent~="" and parent~=path then
        local ok,err=mkdir(parent)
        if not ok then return nil,err end
    end
    local ok,err=lfs.mkdir(path)
    if ok or dir_exists(path) then return true end
    return nil,err
end

local function atomic_write(path,data,binary)
    local parent=path:match("^(.*)/[^/]+$")
    if parent and parent~="" then
        local ok,err=mkdir(parent)
        if not ok then return nil,err end
    end
    local tmp=path..".tmp-"..tostring(os.time()).."-"..tostring(math.random(1000,9999))
    local f,err=io.open(tmp,binary and "wb" or "w")
    if not f then return nil,err end
    local wrote,write_err=f:write(data or "")
    local flushed,flush_err=f:flush()
    f:close()
    if not wrote or flushed==nil then os.remove(tmp); return nil,write_err or flush_err end
    local ok,rename_err=os.rename(tmp,path)
    if ok then return true end

    -- Some platforms cannot replace an existing file with rename(). Keep the
    -- previous generation until the new state file has been placed safely.
    local previous=path..".previous-"..tostring(os.time()).."-"..tostring(math.random(1000,9999))
    local had_previous=file_exists(path)
    if had_previous then
        local backed_up,backup_err=os.rename(path,previous)
        if not backed_up then os.remove(tmp); return nil,backup_err or rename_err end
    end
    ok,rename_err=os.rename(tmp,path)
    if not ok then
        if had_previous then os.rename(previous,path) end
        os.remove(tmp)
        return nil,rename_err
    end
    if had_previous then os.remove(previous) end
    return true
end

local function remove_tree(path)
    path=tostring(path or "")
    if path=="" then return true end
    local mode = type(lfs.symlinkattributes)=="function" and lfs.symlinkattributes(path,"mode") or nil
    if not mode then mode=lfs.attributes(path,"mode") end
    if mode=="file" or mode=="link" then
        local ok,err=os.remove(path)
        if ok or not lfs.attributes(path,"mode") then return true end
        return nil,err
    end
    if mode~="directory" then return true end
    local ok,iter,state=pcall(lfs.dir,path)
    if not ok or type(iter)~="function" then return nil,tostring(iter or state or "cannot list directory") end
    for name in iter,state do
        if name~="." and name~=".." then
            local removed,err=remove_tree(path.."/"..name)
            if not removed then return nil,err end
        end
    end
    local removed,err=lfs.rmdir(path)
    if removed or not dir_exists(path) then return true end
    return nil,err
end

local function copy_file(source,target)
    local input,err=io.open(source,"rb")
    if not input then return nil,err end
    local parent=target:match("^(.*)/[^/]+$")
    if parent and parent~="" then
        local ok,merr=mkdir(parent)
        if not ok then input:close(); return nil,merr end
    end
    local output,oerr=io.open(target,"wb")
    if not output then input:close(); return nil,oerr end
    local ok=true
    local copy_err
    while true do
        local chunk=input:read(256*1024)
        if not chunk then break end
        local wrote,werr=output:write(chunk)
        if not wrote then ok=false; copy_err=werr; break end
    end
    if ok and output:flush()==nil then ok=false; copy_err="flush failed" end
    input:close(); output:close()
    if not ok then os.remove(target); return nil,copy_err end
    return true
end

local function copy_tree(source,target)
    local mode=lfs.attributes(source,"mode")
    if mode=="file" then return copy_file(source,target) end
    if mode~="directory" then return nil,"source missing" end
    local ok,err=mkdir(target)
    if not ok then return nil,err end
    for name in lfs.dir(source) do
        if name~="." and name~=".." then
            local copied,cerr=copy_tree(source.."/"..name,target.."/"..name)
            if not copied then return nil,cerr end
        end
    end
    return true
end

local function list_paths(path)
    local out={}
    if not dir_exists(path) then return out end
    for name in lfs.dir(path) do
        if name~="." and name~=".." then out[#out+1]=path.."/"..name end
    end
    table.sort(out)
    return out
end

local function semver_parse(value)
    local major,minor,patch,pre=tostring(value or ""):match("^v?(%d+)%.(%d+)%.(%d+)(.*)$")
    if not major then return nil end
    local out={major=tonumber(major),minor=tonumber(minor),patch=tonumber(patch),pre={}}
    pre=tostring(pre or ""):gsub("^[%-+]","")
    if pre~="" then
        pre=pre:match("^[^+]+") or pre
        for part in pre:gmatch("[^%.]+") do
            local number=part:match("^%d+$") and tonumber(part) or nil
            out.pre[#out.pre+1]=number or tostring(part):lower()
        end
    end
    return out
end

local function semver_compare(a,b)
    local x,y=semver_parse(a),semver_parse(b)
    if not x or not y then
        if tostring(a)==tostring(b) then return 0 end
        return tostring(a)>tostring(b) and 1 or -1
    end
    for _,key in ipairs({"major","minor","patch"}) do
        if x[key]~=y[key] then return x[key]>y[key] and 1 or -1 end
    end
    if #x.pre==0 and #y.pre==0 then return 0 end
    if #x.pre==0 then return 1 end
    if #y.pre==0 then return -1 end
    for i=1,math.max(#x.pre,#y.pre) do
        local p,q=x.pre[i],y.pre[i]
        if p==nil then return -1 end
        if q==nil then return 1 end
        if p~=q then
            if type(p)=="number" and type(q)=="number" then return p>q and 1 or -1 end
            if type(p)=="number" then return -1 end
            if type(q)=="number" then return 1 end
            return tostring(p)>tostring(q) and 1 or -1
        end
    end
    return 0
end

local function valid_https(url)
    return type(url)=="string" and url:match("^https://")~=nil
end

local function append_unique(out,seen,url)
    if valid_https(url) and not seen[url] then
        seen[url]=true
        out[#out+1]=url
    end
end

local function add_with_mirrors(self,out,seen,url)
    append_unique(out,seen,url)
    if type(url)~="string" or not url:match("^https://github%.com/") then return end
    for _,prefix in ipairs(self.github_mirrors or {}) do
        prefix=tostring(prefix or "")
        if valid_https(prefix) then
            if prefix:sub(-1)~="/" then prefix=prefix.."/" end
            append_unique(out,seen,prefix..url)
        end
    end
end

local function meta_version(plugin_root)
    local text=read_file(tostring(plugin_root or "").."/_meta.lua",false)
    if type(text)~="string" then return nil end
    return text:match('[%s,{]version%s*=%s*["\']([^"\']+)["\']')
        or text:match('^version%s*=%s*["\']([^"\']+)["\']')
end

local function default_state_dir(plugin_id)
    local ok,DataStorage=pcall(require,"datastorage")
    if ok and DataStorage and type(DataStorage.getDataDir)=="function" then
        return DataStorage:getDataDir().."/pluginota/"..safe_id(plugin_id)
    end
    return "/tmp/pluginota-"..safe_id(plugin_id)
end

local function sha256_file(path)
    local pipe=io.popen("sha256sum "..shell_quote(path).." 2>/dev/null","r")
    if pipe then
        local line=pipe:read("*l") or ""
        pipe:close()
        local value=line:match("^([0-9a-fA-F]+)")
        if value and #value==64 then return value:lower() end
    end
    local digest,err=Sha256.file(path)
    if not digest then return nil,err end
    return digest:lower()
end

function Updater.read_meta_version(plugin_root)
    return meta_version(plugin_root)
end

function Updater:new(opts)
    opts=opts or {}
    local root=tostring(opts.plugin_root or ""):gsub("/+$","")
    if root=="" then return nil,"plugin_root is required" end
    local plugin_dir=tostring(opts.plugin_dir or basename(root))
    if plugin_dir=="" or plugin_dir:find("/",1,true) then return nil,"plugin_dir must be a directory name" end
    local repo=tostring(opts.repo or "")
    local manifest_urls=opts.manifest_urls
    if repo~="" and not repo:match("^[^/]+/[^/]+$") then return nil,"repo must be owner/repository" end
    if repo=="" and type(manifest_urls)~="table" then return nil,"repo or manifest_urls is required" end
    local version=tostring(opts.version or meta_version(root) or "")
    if version=="" then return nil,"cannot read version from _meta.lua" end

    local self=setmetatable({},Updater)
    self.plugin_root=root
    self.plugin_dir=plugin_dir
    self.plugin_id=safe_id(opts.plugin_id or plugin_dir:gsub("%.koplugin$",""))
    self.repo=repo
    self.version=version
    self.channel=tostring(opts.channel or "stable")
    self.channel_tag=tostring(opts.channel_tag or (self.channel=="stable" and "stable-channel" or self.channel.."-channel"))
    self.manifest_name=tostring(opts.manifest_name or "update.json")
    self.github_mirrors=opts.github_mirrors or DEFAULT_MIRRORS
    self.configured_manifest_urls=manifest_urls
    self.http_get=opts.http_get
    self.http_download=opts.http_download
    self.connect_timeout=tonumber(opts.connect_timeout) or 5
    self.total_timeout=tonumber(opts.total_timeout) or 20
    self.download_timeout=tonumber(opts.download_timeout) or 240
    self.state_dir=tostring(opts.state_dir or default_state_dir(self.plugin_id))
    self.state_file=self.state_dir.."/state.json"
    self.package_dir=self.state_dir.."/packages"
    self.work_dir=self.state_dir.."/work"
    mkdir(self.package_dir); mkdir(self.work_dir)
    return self
end

function Updater:_load_state()
    local raw=read_file(self.state_file,false)
    if type(raw)~="string" or raw=="" then return {} end
    local ok,value=pcall(Json.decode,raw)
    if ok and type(value)=="table" then return value end
    return {}
end

function Updater:_save_state(state)
    local ok,raw=pcall(Json.encode,state or {})
    if not ok then return nil,raw end
    return atomic_write(self.state_file,raw,false)
end

function Updater:_curl(url,path,max_time)
    if not valid_https(url) then return nil,"only HTTPS URLs are allowed" end
    local cmd="curl -L --fail --silent --show-error --connect-timeout "..tostring(self.connect_timeout)
        .." --max-time "..tostring(max_time or self.total_timeout)
        .." -o "..shell_quote(path).." "..shell_quote(url).." 2>/dev/null"
    local rc=os.execute(cmd)
    if command_ok(rc) and file_exists(path) then return true end
    os.remove(path)
    return nil,"curl download failed"
end

function Updater:_get_text(url)
    if type(self.http_get)=="function" then
        local ok,value,err=pcall(self.http_get,url,{connect_timeout=self.connect_timeout,total_timeout=self.total_timeout})
        if ok and type(value)=="string" and value~="" then return value end
        return nil,tostring(ok and err or value or "http_get failed")
    end
    local path=self.work_dir.."/manifest-"..tostring(os.time()).."-"..tostring(math.random(1000,9999))..".json"
    local ok,err=self:_curl(url,path,self.total_timeout)
    if not ok then return nil,err end
    local raw,rerr=read_file(path,false)
    os.remove(path)
    return raw,rerr
end

function Updater:_download_file(url,path)
    os.remove(path)
    if type(self.http_download)=="function" then
        local ok,value,err=pcall(self.http_download,url,path,{connect_timeout=self.connect_timeout,total_timeout=self.download_timeout})
        if ok and value==true and file_exists(path) then return true end
        os.remove(path)
        return nil,tostring(ok and err or value or "http_download failed")
    end
    return self:_curl(url,path,self.download_timeout)
end

function Updater:manifest_urls()
    local out,seen={},{}
    if type(self.configured_manifest_urls)=="table" then
        for _,url in ipairs(self.configured_manifest_urls) do add_with_mirrors(self,out,seen,url) end
    elseif self.repo~="" then
        local official="https://github.com/"..self.repo.."/releases/download/"..self.channel_tag.."/"..self.manifest_name
        add_with_mirrors(self,out,seen,official)
    end
    local state=self:_load_state()
    local preferred=tostring(state.last_good_manifest_url or "")
    if preferred~="" and seen[preferred] then
        for i,url in ipairs(out) do
            if url==preferred then table.remove(out,i); table.insert(out,1,preferred); break end
        end
    end
    return out
end

function Updater:_remember_manifest(url)
    local state=self:_load_state()
    state.last_good_manifest_url=url
    self:_save_state(state)
end

local function package_urls(self,manifest)
    local out,seen={},{}
    add_with_mirrors(self,out,seen,manifest.package_url or manifest.url)
    for _,key in ipairs({"package_urls","mirror_urls","mirrors"}) do
        if type(manifest[key])=="table" then
            for _,url in ipairs(manifest[key]) do add_with_mirrors(self,out,seen,url) end
        end
    end
    return out
end

function Updater:_validate_manifest(m)
    if type(m)~="table" then return nil,"manifest is not an object" end
    if tonumber(m.schema or 1)~=1 then return nil,"unsupported manifest schema" end
    if tostring(m.version or "")=="" then return nil,"manifest has no version" end
    if tostring(m.channel or "stable")~=self.channel then return nil,"update channel mismatch" end
    if m.package_type~=nil and tostring(m.package_type)~="full" then return nil,"only full packages are supported" end
    if m.plugin~=nil and tostring(m.plugin)~=self.plugin_dir then return nil,"manifest is for another plugin" end
    if #package_urls(self,m)==0 then return nil,"manifest has no package URL" end
    local sha=tostring(m.sha256 or ""):lower():gsub("%s+","")
    if not sha:match("^[0-9a-f]+$") or #sha~=64 then return nil,"manifest SHA-256 is invalid" end
    return true
end

function Updater:check()
    local errors={}
    for _,url in ipairs(self:manifest_urls()) do
        local raw,err=self:_get_text(url)
        if raw then
            local ok,m=pcall(Json.decode,raw)
            if ok then
                local valid,reason=self:_validate_manifest(m)
                if valid then
                    self:_remember_manifest(url)
                    m._manifest_source_url=url
                    if semver_compare(m.version,self.version)<=0 then
                        return {current=true,version=m.version,name=m.name,summary=m.summary,notes=m.notes,_manifest_source_url=url}
                    end
                    return m
                end
                errors[#errors+1]=reason
            else
                errors[#errors+1]="manifest JSON is invalid"
            end
        else
            errors[#errors+1]=tostring(err or "manifest download failed")
        end
    end
    return nil,errors[#errors] or "cannot load update manifest"
end

function Updater:download(manifest)
    local valid,reason=self:_validate_manifest(manifest)
    if not valid then return nil,reason end
    local state=self:_load_state()
    if state.pending then return nil,"a previous update is still pending restart confirmation" end
    local target=self.package_dir.."/"..self.plugin_id.."-"..safe_id(manifest.version)..".zip"
    local expected=tostring(manifest.sha256):lower():gsub("%s+","")
    local expected_size=tonumber(manifest.size or manifest.bytes or manifest.package_size)
    local last_error="package download failed"
    for index,url in ipairs(package_urls(self,manifest)) do
        local ok,err=self:_download_file(url,target)
        if ok then
            local size=file_size(target)
            if expected_size and expected_size>0 and size~=expected_size then
                last_error="package size mismatch"
            else
                local actual,hash_err=sha256_file(target)
                if actual and actual==expected then
                    logger.info(log_prefix(self),"package downloaded","source=",tostring(index),"version=",tostring(manifest.version))
                    return target
                end
                last_error=hash_err or "package SHA-256 mismatch"
            end
        else
            last_error=err or last_error
        end
        os.remove(target)
    end
    return nil,last_error
end

local function safe_zip_entry(name,root)
    name=tostring(name or "")
    if name=="" or name:sub(1,1)=="/" or name:find("\\",1,true) or name:find("//",1,true) or name:find("%z") then return false end
    for part in name:gmatch("[^/]+") do
        if part=="." or part==".." or part=="" then return false end
    end
    return name==root or name:sub(1,#root+1)==root.."/"
end

function Updater:_validate_zip(path)
    local pipe=io.popen("unzip -Z1 "..shell_quote(path).." 2>/dev/null","r")
    if not pipe then return nil,"cannot inspect update package" end
    local count=0
    for line in pipe:lines() do
        count=count+1
        if not safe_zip_entry(line,self.plugin_dir) then
            pipe:close()
            return nil,"update package contains an unsafe or unexpected path: "..tostring(line)
        end
    end
    local ok=pipe:close()
    if count==0 then return nil,"update package is empty" end
    if ok==nil then return nil,"cannot inspect update package" end
    return true
end

function Updater:_cleanup(protected)
    protected=protected or {}
    for _,path in ipairs(list_paths(self.work_dir)) do
        if not protected[path] then remove_tree(path) end
    end
    for _,path in ipairs(list_paths(self.package_dir)) do
        if not protected[path] then os.remove(path) end
    end
end

function Updater:install(path,manifest)
    local valid,reason=self:_validate_manifest(manifest)
    if not valid then return nil,reason end
    local state=self:_load_state()
    if state.pending then return nil,"a previous update is still pending restart confirmation" end
    if not file_exists(path) then return nil,"update package is missing" end
    local zip_ok,zip_err=self:_validate_zip(path)
    if not zip_ok then os.remove(path); return nil,zip_err end

    local stamp=tostring(os.time()).."-"..tostring(math.random(1000,9999))
    local stage=self.work_dir.."/stage-"..stamp
    local unpacked=stage.."/unpacked"
    local backup=self.work_dir.."/backup-"..stamp
    remove_tree(stage); remove_tree(backup)
    local ok,err=mkdir(unpacked)
    if not ok then return nil,err end

    local function fail(message)
        remove_tree(stage)
        remove_tree(backup)
        os.remove(path)
        return nil,message
    end

    local rc=os.execute("unzip -q "..shell_quote(path).." -d "..shell_quote(unpacked).." 2>/dev/null")
    if not command_ok(rc) then return fail("cannot unpack update package") end
    local incoming=unpacked.."/"..self.plugin_dir
    if not file_exists(incoming.."/main.lua") or not file_exists(incoming.."/_meta.lua") then
        return fail("update package is missing main.lua or _meta.lua")
    end
    local incoming_version=meta_version(incoming)
    if tostring(incoming_version or "")~=tostring(manifest.version or "") then
        return fail("package version does not match manifest")
    end

    local copied,copy_err=copy_tree(self.plugin_root,backup)
    if not copied then return fail("cannot back up current plugin: "..tostring(copy_err)) end

    local function rollback(message)
        remove_tree(self.plugin_root)
        local restored,restore_err=copy_tree(backup,self.plugin_root)
        remove_tree(stage)
        os.remove(path)
        if restored then
            remove_tree(backup)
            return nil,tostring(message).."; previous version restored"
        end
        return nil,tostring(message).."; rollback failed: "..tostring(restore_err).."; backup kept at "..backup
    end

    local removed,remove_err=remove_tree(self.plugin_root)
    if not removed then return rollback("cannot replace current plugin: "..tostring(remove_err)) end
    local moved=os.rename(incoming,self.plugin_root)
    if not moved then
        local installed,install_err=copy_tree(incoming,self.plugin_root)
        if not installed then return rollback("cannot install new plugin: "..tostring(install_err)) end
    end
    if not file_exists(self.plugin_root.."/main.lua") or not file_exists(self.plugin_root.."/_meta.lua") then
        return rollback("installed plugin is incomplete")
    end

    remove_tree(stage)
    local next_state=self:_load_state()
    next_state.pending=true
    next_state.expected=tostring(manifest.version)
    next_state.backup=backup
    next_state.package=path
    next_state.installed_at=os.time()
    local saved,save_err=self:_save_state(next_state)
    if not saved then return rollback("cannot save update state: "..tostring(save_err)) end
    logger.info(log_prefix(self),"update installed","version=",tostring(manifest.version))
    return true
end

function Updater:startup()
    local state=self:_load_state()
    if not state.pending then
        self:_cleanup()
        return nil
    end
    if tostring(state.expected or "")==tostring(self.version) then
        if state.backup then remove_tree(state.backup) end
        if state.package then os.remove(state.package) end
        local last_good=state.last_good_manifest_url
        self:_save_state(last_good and {last_good_manifest_url=last_good} or {})
        self:_cleanup()
        logger.info(log_prefix(self),"update confirmed","version=",tostring(self.version))
        return "updated"
    end
    logger.warn(log_prefix(self),"update pending but running version differs","expected=",tostring(state.expected),"running=",tostring(self.version))
    return "mismatch"
end

function Updater:rollback_pending()
    local state=self:_load_state()
    if not state.pending or type(state.backup)~="string" or not dir_exists(state.backup) then
        return nil,"no rollback backup is available"
    end
    remove_tree(self.plugin_root)
    local ok,err=copy_tree(state.backup,self.plugin_root)
    if not ok then return nil,"rollback failed: "..tostring(err) end
    if state.package then os.remove(state.package) end
    remove_tree(state.backup)
    local last_good=state.last_good_manifest_url
    self:_save_state(last_good and {last_good_manifest_url=last_good} or {})
    self:_cleanup()
    return true
end

return Updater
