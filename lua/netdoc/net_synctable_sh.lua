if ndoc._synctable_loaded then return end 
ndoc._synctable_loaded = true

if SERVER then AddCSLuaFile() end

include 'net_flex_sh.lua'
include 'net_stringtable_sh.lua'

local type = type 
local select = select 
local net_Start, net_Send = net.Start, net.Send 
local net_BytesWritten = net.BytesWritten
local net_WriteUInt, net_ReadUInt = net.WriteUInt, net.ReadUInt
local net_readKey, net_writeKey = ndoc.net_readKey, ndoc.net_writeKey
local net_readValue, net_writeValue = ndoc.net_readValue, ndoc.net_writeValue

local _allowedKeyTypes = ndoc._allowedKeyTypes
local _allowedValueTypes = ndoc._allowedValueTypes

local _stringToId = ndoc._stringToId

--
-- PATH HOOKING
--
local hooks = setmetatable({}, {__mode = 'k'})

local stack_stores = {}
local stack_store_empty = function() end
local function store_stack(...)
	local c = select('#', ...)
	if c == 0 then return stack_store_empty end
	if stack_stores[c] then return stack_stores[c](...) end

	local vars = {} for i = 1, c do vars[i] = 'v'..i end
	local vars_def = table.concat(vars, ', ')

	-- read the code it's safe
	RunString(string.format([[
		_G.__STACK_STORE = function(...)
			local %s = ...
			return function(...)
				return %s, ...
			end
		end
	]], vars_def, vars_def))

	stack_stores[c] = _G.__STACK_STORE
	_G.__STACK_STORE = nil
	return stack_stores[c]
end
ndoc.store_stack = store_stack


function ndoc.compilePath(path)
	local segments = string.Explode('.', path, false)
	return store_stack(unpack(segments))
end

local isValidPath = function(table, a, ...)
	if a == nil then return true end
	return table[a] ~= nil and ifValidPath(table[a], ...)
end
ndoc.isValidPath = isValidPath

local hooks = setmetatable({}, {__mode = 'k'})
-- key: table value:
--  	key: key-string value: hook-data
local function addHook(tbl, type, fn, args, key, ...)
	-- note that the memory used by this is mind blowing. dont over do these hook things.
	if not hooks[tbl] then hooks[tbl] = {} end
	if not hooks[tbl][key] then hooks[tbl][key] = {} end
	table.insert(hooks[tbl][key], {
			path = store_stack(...),
			args = args,
			type = type,
			fn = fn
		})

	if key == '?' then
		for k, v in ndoc.pairs(tbl) do
			if type(v) == 'table' then
				addHook(v, type, fn, store_stack(args(k)), ...)
			end
		end
	end

	local next = tbl[key]
	if next and type(next) == 'table' then
		addHook(next, type, fn, ...)
	end
end

local function updateHookStruct(tbl, key, val)
	if type(val) ~= 'table' then return end
	if not hooks[tbl] or not hooks[tbl][key] then return end

	for k, hook in ipairs(hooks[tbl][key]) do
		addHook(val, hook.type, hook.fn, hook.args, hook.path()) -- check this line if theere are bugs. hook.path() might need to be select(2, hook.path())
	end

	-- future you!!! this is where you left off!!! if you dont remember	
	for k, hook in pairs(hooks[tbl]['?']) do
		addHook(val, hook.type, hook.fn, store_stack(hook.args(k)), store_hook.path()) -- check this line if theere are bugs. hook.path() might need to be select(2, hook.path())
	end
end

local function callHooks(tbl, type, key, val)
	if not hooks[tbl] or not hooks[tbl][key] then return end
	for k, hook in ipairs(hooks[tbl][key]) do
		local a = hook.fn(hook.args(val))
		if a ~= nil then return a end
	end
end

function ndoc.addHook(key, type, fn)
	local path = ndoc.compilePath(key)
	addHook(ndoc.table, type, fn, store_stack(), path())

	return path
end

--
-- SYNCING TABLES
-- 

if SERVER then 
	util.AddNetworkString('ndoc.t.setKV')
	util.AddNetworkString('ndoc.t.sync')
	util.AddNetworkString('ndoc.t.cl.requestFullSync')

	local _tableUidNext = 0
	local function nextUid()
		local tid = _tableUidNext
		_tableUidNext = _tableUidNext + 1
		return tid
	end

	local _idToProxy = setmetatable({}, {_mode = 'v'})
	local _proxyToId = setmetatable({}, {_mode = 'k'})
	local _proxyToReal = setmetatable({}, {_mode = 'k'})
	local _originalToProxy = setmetatable({}, {_mode = 'v'})


	function ndoc.ipairs(tbl)
		return ipairs(_proxyToReal[tbl])
	end

	function ndoc.pairs(tbl)
		return pairs(_proxyToReal[tbl])
	end

	function ndoc.getTableId(proxy)
		return _proxyToId[proxy] or _proxyToId[_originalToProxy[proxy]]
	end

	function ndoc.getTableById(id)
		return _idToProxy[id]
	end

	function ndoc.createTable(parent, key)
		local path = store_stack(parent.__path(key))
		local depth = select('#', parent.__path())

		local real = {}
		local proxy = {
			__key = key,
			__path = path,
			__depth = depth, -- the node's depth in the tree
			__hooks = {}
		}

		local tid = nextUid()
		
		_idToProxy[tid] = proxy
		_proxyToId[proxy] = tid
		_proxyToReal[proxy] = real

		setmetatable(proxy, {
				__index = real,
				__newindex = function(self, k, v)
					local tk, tv = type(k), type(v)
					if not _allowedKeyTypes[tk] then error("[ndoc] key type " .. tk .. " not supported by ndoc.") end 
					if not _allowedValueTypes[tv] then error("[ndoc] value type " .. tv .. " not supported by ndoc.") end

					if tv == 'table' then
						-- ndoc.print("setting table as value: " .. tostring(v))
						if type(real[k]) == 'table' then
							-- simply update the table rather than reassign it
							local oldVal = real[k]
							for k, v in pairs(v) do
								if oldVal[k] ~= v then
									oldVal[k] = v
								end
							end
							for k,_ in pairs(_proxyToReal[oldVal]) do
								if not v[k] then
									oldVal[k] = nil
								end
							end
							return 
						end
						v = ndoc.createTable(v, path)
					end
					if tk == 'string' then
						-- make sure it's in the string table
						if not _stringToId[k] then
							ndoc.addNetString(k)
						end
					end

					ndoc.print(tostring(tid) .. ' : ' .. tostring(k) .. ' = ' .. tostring(v))

					net_Start 'ndoc.t.setKV'
					net_WriteUInt(tid, 12)
					net_writeKey(k)
					net_writeValue(v)
					net_Send(ndoc.all_players)

					real[k] = v

					-- update the hook structure
					updateHookStruct(self, k, v)
					-- call hooks
					callHooks(self, 'set', k, v)
				end
			})

		if parent then
			_originalToProxy[parent] = proxy

			-- TODO: add optimization for adding arrays
			for k,v in pairs(parent) do
				proxy[k] = v
			end
		end

		return proxy
	end

	ndoc._syncTable = function(proxy, pl)
		local bytes = 0
		local tid = _proxyToId[proxy]
		if not tid then
			ndoc.error("syncing tables for "..pl:SteamID().." tried to sync an invalid tableid.")
			return 0
		end

		net_Start 'ndoc.t.sync'
		net_WriteUInt(tid, 12)

		local real = _proxyToReal[proxy]
		if not real then 
			ndoc.error("syncing tables for "..pl:SteamID().." no real entry for " .. tostring(proxy) .. " proxy")
			return 
		end -- we don't want to kill the entire onboard just because of this

		for k, v in ndoc.pairs(proxy) do
			if net_BytesWritten() > 32768 then
				net_WriteUInt(0, 4) -- TYPE_NIL
				bytes = bytes + 32768
				net_Send(pl or net.all_players)
				
				net_Start 'ndoc.t.sync'
				net_WriteUInt(tid, 12)
			end
			
			net_writeKey(k)
			net_writeValue(v)
		end

		net_WriteUInt(0, 4)
		bytes = bytes + net_BytesWritten()
		net_Send(pl or net.all_players)

		return bytes
	end

	net.Receive('ndoc.t.cl.requestFullSync', function(_, pl)
		local totalBytes = 0
		local lastTotalBytes = 0
		ndoc.async.eachSeries(_idToProxy, function(k, v, cback)
			totalBytes = totalBytes + ndoc._syncTable(v, pl)
			if  totalBytes - lastTotalBytes > 32768 then
				timer.Simple(0.1, cback)
				lastTotalBytes = totalBytes
			else
				cback()
			end
		end, function() 
			ndoc.print("bigtable sync data pack used " .. totalBytes)
		end)
	end)

	ndoc.table = ndoc.createTable() -- table with id: 0
	hooks[ndoc.table] = {}

elseif CLIENT then

	-- CLIENT
	local _idToProxy = setmetatable({}, {_mode = 'v'})
	local _proxyToId = setmetatable({}, {_mode = 'k'})
	local _proxyToReal = setmetatable({}, {_mode = 'k'})

	function ndoc.getTableById(id)
		local proxy = _idToProxy[id]
		if proxy then return proxy end
		
		local real = {}
		proxy = {}
		setmetatable(proxy, {
				__index = real,
				__newindex = function()
					error 'attempt to assign in client copy of table - not yet supported'
				end
			})

		_proxyToReal[proxy] = real
		_idToProxy[id] = proxy
		_proxyToId[proxy] = id

		return proxy
	end
	local _tableWithId = ndoc.getTableById

	function ndoc.ipairs(tbl)
		return ipairs(_proxyToReal[tbl])
	end

	function ndoc.pairs(tbl)
		return pairs(_proxyToReal[tbl])
	end

	net.Receive('ndoc.t.setKV', function()
		local tid = net_ReadUInt(12)
		local k = net_readKey()
		local v = net_readValue()

		--ndoc.print(tostring(tid) .. ' : ' .. tostring(k) .. ' = ' .. tostring(v))
		local real = _proxyToReal[_tableWithId(tid)]
		if not real then
			ndoc.error("failed to get 'real' for table " .. tid .. " during sync.")
			return 
		end
		real[k] = v
	end)

	net.Receive('ndoc.t.sync', function()
		local tid = net_ReadUInt(12)
		local t = _tableWithId(tid)
		local real = _proxyToReal[t]

		print("syncing table " .. tid)

		while true do
			local k = net_readKey()
			if k == nil then break end
			local v = net_readValue()
			real[k] = v
		end
	end)

	ndoc.loadBigtable = function()
		ndoc.print("syncing net document")
		net.Start 'ndoc.t.cl.requestFullSync'
		net.SendToServer()
	end

	ndoc.table = ndoc.getTableById(0) -- table from id: 0


end

-- TODO: optimize onboarding arrays
