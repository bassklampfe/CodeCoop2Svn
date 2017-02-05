#!/usr/bin/lua
require"strict"

--==============================================================
-- general module to read binary file while generating a listing
--==============================================================

--[[ required modules ]]--

local bit=require"bit"
local band,bshl = bit.band,bit.lshift

--[[ local caches to make code faster ]]--
local byte=string.byte
local sprintf=string.format
local push=table.insert
local join=table.concat

--[[ utility codes ]]--
local function printf(...)
	io.write(sprintf(...))
	io.flush()
end

local function fprintf(fd,...)
	fd:write(sprintf(...))
end

local function uint32(s)
	local a,b,c,d=byte(s,1,4)
	--if d>127 then d=d-256 end
	return ((d*256+c)*256+b)*256+a
end

local function sint32(s)
	local a,b,c,d=byte(s,1,4)
	if d>127 then d=d-256 end
	return ((d*256+c)*256+b)*256+a
end

--[[ data tables ]]--
local de_wkd={Sat="Sa",Sun="So",Mon="Mo",Tue="Di",Wed="Mi",Thu="Do",Fri="Fr"}


--[[ the module ]]--
local M={openfiles={}}


--[[ main method ]]--
local function OpenBinFile(bin_path)
	printf("Open\t%q\n",bin_path)
	local lst_path=bin_path:gsub("/Database/","/Analysis/"):gsub("%.bin$","")..".lst"
	local lst_fd=assert(io.open(lst_path,"w"))
	local bin_fd=assert(io.open(bin_path,"rb"))
	M.openfiles[bin_path]=(M.openfiles[bin_path] or 0)+1
	fprintf(lst_fd,"OpenBinFile(%q)\n",bin_path)
	local bin_len=bin_fd:seek("end")
	bin_fd:seek("set")

	local mt={bin_fd=bin_fd,lst_fd=lst_fd,version=9999}

	--
	-- public standard functions
	--
	local function close()
		printf("Close\t%q $%06X/$%06X\n",bin_path,bin_fd:seek(),bin_len)
		fprintf(lst_fd,"-- close at $%06X/$%06X --\n",bin_fd:seek(),bin_len)
		lst_fd:close()lst_fd=nil
		bin_fd:close()bin_fd=nil
		M.openfiles[bin_path]=M.openfiles[bin_path]-1
		if M.openfiles[bin_path]==0 then M.openfiles[bin_path]=nil end
	end
	mt.close=close

	local function eof()
		return bin_fd:seek()>=bin_len
	end
	mt.eof=eof

	local function pos()
		return bin_fd:seek()
	end
	mt.pos=pos

	local function len()
		return bin_len
	end
	mt.len=len

	local function seek(pos)
		bin_fd:seek("set",pos)
	end
	mt.seek=seek

	--
	-- local helper functions
	--
	local function read(n)
		if n==0 then return "" end
		local data=assert(bin_fd:read(n))
		if #data~=n then Error("bin_fd:read(%d)=%d",n,#data) end
		return data
	end

	--
	-- low level functions
	--
	local function get_uint32()
		local p=pos() 
		return uint32(read(4)),p
	end

	local function get_sint32()
		local p=pos() 
		return sint32(read(4)),p
	end

	local function get_long_string()
		local p=pos() 
		local v=get_uint32()
		if p+4+v>bin_len then Error("big string $%08X:%dd",v,v) end
		return read(v),p
	end

	--
	-- high level function (with listing)
	--
	local function UINT32(name)
		local v,p=get_uint32()
		fprintf(lst_fd,"%04X : $%08X                %s=%d\n",p,v,name,v)
		return v
	end
	mt.UINT32=UINT32

	local function SINT32(name)
		local v,p=get_sint32()
		fprintf(lst_fd,"%04X : $%08X                %s=%d\n",p,v,name,v)
		return v
	end
	mt.SINT32=SINT32
	
	--
	-- Hex32 returns a hex string (for better dump of checksum/crcs)
	--
	local function HEX32(name)
		local v,p=get_uint32()
		fprintf(lst_fd,"%04X : $%08X                %s=%d\n",p,v,name,v)
		return sprintf("0x%08X",v)
	end
	mt.HEX32=HEX32


	-- X is used for unknown or dont care data
	local function X(name)
		local v,p=get_uint32()
		fprintf(lst_fd,"%04X : $%08X                %s\n",p,v,name)
		return v
	end
	mt.X=X

	--
	-- this is a bit tricky since there are errors in the binary files
	--
	local function X64(name)
		local p=pos()
		local u32lo=get_uint32()
		local u32hi=get_uint32()
		fprintf(lst_fd,"%04X : $%08X:%08X       %s=%dUL\n",p,u32hi,u32lo,name,u32lo)
		-- WARNING:WARNING:hist.node[1989]._cmds[8]._logOffset.u32hi failed want=00000000 have=17800000
		-- when this error occurs
		if u32hi==0x17800000 and u32lo==0x6349B6C9  then
			if mt.cmdlog_mt then
				printf("u32hi=%08X u32lo=%08X mt.cmdlog_mt.pos()=%08X\n",
					u32hi,u32lo,mt.cmdlog_mt.pos())
				-- we assume correct offset is next one in cmdlog.bin
				u32hi=0
				u32lo=mt.cmdlog_mt.pos()
			else
				u32hi=0
				u32lo=0
			end
			fprintf(lst_fd,"%04X : $%08X:%08X PATCH %s=%dUL\n",p,u32hi,u32lo,name,u32lo)
		end
		if u32hi~=0 then error(name..".u32hi is "..tostring(u32hi)) end
		return u32lo
	end
	mt.X64=X64

	local function ENUM(name,values)
		local v,p=get_uint32()
		fprintf(lst_fd,"%04X : $%08X                %s={%d:%s}\n",p,v,name,v,values[v] or "-nil-")
		return values[v] or v
	end
	mt.ENUM=ENUM

	local function BITS(name,values)
		local v,p=get_uint32()
		local bits={}
		local names={}
		for i=0,31 do
			local b=bshl(1,i)
			if band(v,b)~=0 then
				push(names,values[i] or tostring(i))
				bits[values[i] or i]=true
			end
		end
		fprintf(lst_fd,"%04X : $%08X                %s={%s}\n",p,v,name,join(names,","))
		return bits
	end
	mt.BITS=BITS

	local function TEXT(name)
		local v,p=get_long_string()
		fprintf(lst_fd,"%04X : $%08X                %s[%d]=%s\n",p,#v,name,#v,vis(v,80))
		return v,p
	end
	mt.TEXT=TEXT

	local function BLOB(name)
		local v,p=get_long_string()
		fprintf(lst_fd,"%04X : $%08X                %s[%d]=%s\n",p,#v,name,#v,hex(v,40))
		return v,p
	end
	mt.BLOB=BLOB

	local function GID(name)
		local u32,p=get_uint32()
		local v1=u32%0x100000
		local v2=(u32-v1)/0x100000
		local id=sprintf("%x-%x",v2,v1)
		--      XXXX : XXXXXXXX
		fprintf(lst_fd,"%04X : $%08X                %s=%q\n",p,u32,name,id)
		return id
	end
	mt.GID=GID

	local function STAMP(name)
		local v,p=get_uint32()
		local s=os.date("%a, %d.%m.%Y %H:%M:%S",v):gsub("%a%a%a",de_wkd)
		fprintf(lst_fd,"%04X : $%08X                %s=%q\n",p,v,name,s)
		return s
	end
	mt.STAMP=STAMP

	local function M(name)
		local p=pos()
		local bbbb=read(4)
		local u32=uint32(bbbb)
		local magic=bbbb:reverse()
		fprintf(lst_fd,"%04X : $%08X                %s=%q\n",p,u32,name,magic)
		return magic
	end
	mt.M=M

	return mt
end
M.OpenBinFile=OpenBinFile

return M
