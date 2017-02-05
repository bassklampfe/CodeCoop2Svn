#!/usr/bin/lua5.1
require"strict"

--============================================================
-- a collection of small functions for general use
--============================================================


local sprintf=string.format
local sbyte=string.byte

------------------------------------------------------------
--- formatted print to console
---
function printf(...)
	io.write(sprintf(...))
	io.flush()
end

------------------------------------------------------------
--- Error to SYSTEM (no lua error()
---
function Error(...)
	io.flush()
	io.stderr:write(sprintf(...))
	os.exit(1)
end

------------------------------------------------------------
--- Warning to SYSTEM
---
function Warning(...)
	io.flush()
	io.stderr:write(sprintf(...))
end

local function CHECK_EQ(name,want,have)
	if want~=have then
		if type(want)=="number" and type(have)=="number" then
			Warning("WARNING:%s failed want=%08X have=%08X\n",name,want,have)
		else
			Warning("WARNING:%s failed want=%s have=%s\n",name,vis(want,80),vis(have,80))
		end
	end
end
_G.CHECK_EQ=CHECK_EQ

local function ASSERT_EQ(name,want,have)
	if want~=have then
		if type(want)=="number" and type(have)=="number" then
			Error("%s failed want=%08X have=%08X\n",name,want,have)
		else
			Error("%s failed want=%s have=%s\n",name,vis(want,80),vis(have,80))
		end
	end
end
_G.ASSERT_EQ=ASSERT_EQ

------------------------------------------------------------
--- Load (binary) file
---
function load_file(path)
	local fd=assert(io.open(path,"rb"))
	local data=fd:read("*all")
	fd:close()
	return data
end

------------------------------------------------------------
--- Save (binary) file
---
function save_file(path,...)
	local fd=assert(io.open(path,"wb"))
	fd:write(...)
	fd:close()
end

local known=setmetatable(
	{["\n"]="\\n",["\t"]="\\t",["\r"]="\\r",["\\"]="\\\\",["\""]="\\\""},
	{__index=function(t,k) local v=sprintf("\\%03d",sbyte(k)) rawset(t,k,v) return v end}
	)

------------------------------------------------------------
--- Convert any data to string (better %q for string)
--- @param len (number,optional) limits the output length
---
function vis(val,len)
	if type(val)~="string" then return tostring(val) end
	if len and #val>len then return vis(val:sub(1,len)).."..." end
	return '"'..(val:gsub("[%z\001-\031\"\\]",known))..'"'
end

------------------------------------------------------------
--- Convert binary data to hex string
--- @param len (number,optional) limits the output length
---
function hex(str,len)
	if len and #str>len then return hex(str:sub(1,len)).."..." end
	return (str:gsub(".",function(b) return sprintf("%02X",sbyte(b))end))
end

------------------------------------------------------------
--- Convert time diff into hms format
---
function hms(t)
	local s=t%60 t=(t-s)/60
	local m=t%60 t=(t-m)/60
	local h=t
	if h>0 then return sprintf("%2dh%02dm%02ds",h,m,s) end
	if m>0 then return sprintf("%2dm%05.2fs",m,s) end
	return sprintf("%5.2fs",s)
end

------------------------------------------------------------
--- return true, if table in table
---
local function has_table(t)
	for _,v in pairs(t) do
		if type(v)=="table" then return true end
	end
	return false
end

------------------------------------------------------------
--- show data (this is not nessecary parseable)
--- @param nam (string) name of variable to show
--- @param val (any) value to show
--- @param ... can be
--- @param st (bool) show tables not flat
--- @param len (number) limit length of strings
--- @param file (string) file name to write to
---
function ShowData(nam,val,...)
	local len,out,st,fd
	for n=1,select("#",...) do
		local arg=select(n,...)
		local typ=type(arg)
		if typ=="number" then
			len=arg
		elseif typ=="boolean" then 
			st=arg
		elseif typ=="string" then
			fd=assert(io.open(arg,"wb"))
			out=function(...)fd:write(...)end
		else
			error("bad arg of type "..typ)
		end
	end
	out=out or io.write

	local function show_data(n,v)
		if type(v)~="table" then
			return out(n,'=',vis(v,len),'\n')
		end
		if st or has_table(v) then
			if next(v)==nil then
				return out(n,'={}\n')
			end
			for k,kv in pairs(v) do
				if type(k)=="string" and k:match("^[a-zA-Z_][a-zA-Z0-9_]*$") then
					show_data(n.."."..k,kv)
				else
					show_data(sprintf("%s[%s]",n,vis(k)),kv)
				end
			end
			return
		end
		local elem={}
		local k
		for i=1,#v do
			elem[#elem+1]=vis(v[i],len)
			k=i
		end
		k=next(v,k)
		while k do
			if type(k)=="string" and k:match("^[a-zA-Z_][a-zA-Z0-9_]*$") then
				elem[#elem+1]=sprintf("%s=%s",k,vis(v[k],len))
			else
				elem[#elem+1]=sprintf("[%s]=%s",vis(k),vis(v[k],len))
			end
			k=next(v,k)
		end
		out(n,"={",table.concat(elem,","),"}\n")
	end

	show_data(nam,val)
	if out==io.write then
		io.flush()
	end
	if fd then
		fd:close()
	end
end

------------------------------------------------------------
--- save data into a file, which can be used by dofile(path)
--- @NOTE : Huge data will result in error on load
--- due limited space for string constants in lua opcode
function SaveData(path,data)
	local fd=assert(io.open(path,"wb"))

	local did={}
	local function save_data(v)
		if type(v)~="table" then return fd:write(vis(v)) end
		if did[v] then error("Recoursion in SaveData") end
		did[v]=v
		local nl=has_table(v) and "\n" or ""
		fd:write("{",nl)
		local k=nil
		for i=1,#v do
			save_data(v[i])
			fd:write(",",nl)
			k=i
		end
		k=next(v,k)
		while k do
			if type(k)=="string" and k:match("^[a-zA-Z_][a-zA-Z0-9_]*$") then
				fd:write(k,"=")
			else
				fd:write("[",vis(k),"]=")
			end
			save_data(v[k])
			fd:write(",",nl)
			k=next(v,k)
		end
		fd:write("}")
	end
	fd:write("return ")
	save_data(data)
	fd:write(";\n")
	fd:close()
end

------------------------------------------------------------
--- convert given list of words into table
---
function qw(t)
	local r={}
	for w in t:gmatch("%S+") do
		r[#r+1]=w
		r[w]=true
	end
	return r
end

------------------------------------------------------------
--- get sorted list keys of a table
---
local function keys(t,f)
	local ks={}
	for k,v in pairs(t) do
		ks[#ks+1]=k
	end
	table.sort(ks,f)
	return ks
end
_G.keys=keys

------------------------------------------------------------
--- like pairs, but sorted
---
local function spairs(t,f)
	local ks=keys(t)
	local n=0
	return function()
		n=n+1
		local k=ks[n]
		if k then return k,t[k] end
	end
end
_G.spairs=spairs


--============================================================
-- utilities for file systems
--============================================================

require"lfs"
local function is_file(path)
	if lfs.attributes(path,"mode")=="file" then return path end
	return nil,path.." is no file"
end
_G.is_file=is_file
_G.isfile=is_file

local function is_dir(path)
	if lfs.attributes(path,"mode")=="directory" then return path end
	return nil,path.." is no dir"
end
_G.is_dir=is_dir
_G.isdir=is_dir

-- unix 2 dos
local function u2d(path)
	return path:gsub("/","\\"):gsub("\\$","")
end
_G.u2d=u2d

-- dos 2 unix
local function d2u(path)
	return path:gsub("\\","/"):gsub("/$","")
end
_G.d2u=d2u

-- only the filename without path
local function nodir(path)
	return path:gsub("^.*[\\/]","")
end
_G.nodir=nodir

-- only the path without filename
local function dirof(path)
	return path:match("^(.*)[\\/]")
end
_G.dirof=dirof

-- recoursive remove directories (use with care!)
local function rmdir_r(dir)
	if isdir(dir) then
		--printf("rmdir_r(%q)\n",dir)
		for entry in lfs.dir(dir) do
			if entry~="." and entry~=".." then
				local path=dir.."/"..entry
				local mode=lfs.attributes(path,"mode")
				--printf("%-10s %s\n",mode,path)
				if mode=="file" then
					assert(os.remove(path))
				else
					rmdir_r(path)
					assert(lfs.rmdir(path))
				end
			end
		end
	end
end
_G.rmdir_r=rmdir_r

--
-- execute a command and check return status
-- 
local function execute_cmd(...)
	local sts
	local cmd=sprintf(...)
	printf("CMD=[[%s]]\n",cmd)
	local fd=assert(io.popen(cmd.." 2>&1 && echo %ERRORLEVEL%"))
	local data=fd:read("*all")
	fd:close()
	--io.write(data)io.flush()
	data=data:gsub("(%d+)\n$",function(s) sts=tonumber(s) or s return "" end)
	if sts~=0 then 
		io.write(data)io.flush()
		return nil,data
	end
	return data
end
_G.execute_cmd=execute_cmd
