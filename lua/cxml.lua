#!/usr/bin/lua
require"strict"

--[[
My Fancy Xml Module quite quick and dirty but good enough to do the job
Regards, JJvB

in lua tables, [1] is the tag name, [2...] are the elements ["string"] are the attributes
--]]

module("cxml",package.seeall)


local format=string.format


local xmlobj={}
local xmlobj_mt={__index=xmlobj}
function xmlobj:element(tag,name)
 	if type(tag)=="number" and tag>0 then
 		return self[tag+1]
 	end
	for i=2,#self do
		local elem=self[i]
		if elem[1]==tag then
			if name==nil or elem.name==name then return elem,i end
		end
	end
	return nil,"no element "..tag
end

function xmlobj:numelements()
	return #self-1
end

function xmlobj:elements(k)
	local i=1
	return function()
		i=i+1
		while i<=#self do
			local e=self[i]
			if k==nil or e[1]==k then return e,i end
			i=i+1
		end
		return nil
	end
end

function xmlobj:remove_element(tag)
	for i=2,#self do
		local elem=self[i]
		if elem[1]==tag then
			return table.remove(self,i)
		end
	end
end

function xmlobj:data()
	if self[2] and type(self[2])=="string" then return self[2] end
	return nil
end

function xmlobj:tag()
	if self[1] and type(self[1])=="string" then return self[1] end
	return nil
end


---------------------------------------------------------------------
-- take a lua tables of tables and return a xml-string to post
---------------------------------------------------------------------
function xml2str(obj)
	if type(obj)=="string" then
		return obj
	end
	local tag=obj[1]
	if not tag then
		if obj.comment then return format("<!--%s-->",obj.comment) end
		if obj.cdata then return format("<![CDATA[%s]]>",obj.cdata) end
		error("not yet")

	end
	local attr={}
	local elem={}
	for k,v in pairs(obj) do
		if type(k)=="number" then
			if k~=1 then
				elem[#elem+1]=xml2str(v)
			end
		else
			attr[#attr+1]=format(" %s=%q",k,tostring(v))
		end
	end
	attr=table.concat(attr)
	elem=table.concat(elem)
	if elem~="" then
		return "<"..tag..attr..">"..elem.."</"..tag..">"
	else
		return "<"..tag..attr.."/>"
	end
end

function xmlobj:tostring()
	return xml2str(self)
end

---------------------------------------------------------------------
-- take a lua tables of tables and write to output
---------------------------------------------------------------------
function xml2vis(obj,indent,output)
	output=output or io.write
	indent=indent or ""
	if type(obj)=="string" then
		output(obj)
		return
	end
	local tag=obj[1]
	if not tag then
		if obj.comment then output("<!--",obj.comment,"-->\n") return end
		if obj.cdata then output("<![CDATA[",obj.cdata,"]]>\n") return end
		error("not yet")
	end
	local attr={}
	local elem={}
	for k,v in pairs(obj) do
		if type(k)=="number" then
			if k~=1 then
				elem[#elem+1]=v
			end
		else
			attr[#attr+1]=format(" %s=%q",k,v)
		end
	end
	output(indent,"<",tag)
	for i=1,#attr do
		output(attr[i])
	end
	if #elem>0 then
		if #elem==1 and type(elem[1])=="string" then
			output(">",elem[1],"</",tag,">\n")
			return
		end
		output(">\n")
		for i=1,#elem do
			xml2vis(elem[i],indent.."  ",output)
		end
		output(indent,"</",tag,">\n")
		return
	end
	output("/>\n")
end

function xmlobj:vis()
	local out={}
	xml2vis(self,"",function(...) out[#out+1]=table.concat({...})end)
	return table.concat(out)
end

------------------------------------------------------
-- take a string and return lua object
------------------------------------------------------
function str2xml(str)

	--
	-- local data needed
	--
	local pos=1
	local find=string.find
	--
	-- common error funtion
	--
	local function err(text)
		error(format("Error : %s at %d:%.20q",text,pos,str:sub(pos,pos+20)),2)
	end

	local function get_attribute()
		local a,b,nam,val=find(str,"^([a-zA-Z_][-a-zA-Z_0-9.:]*)%s*=%s*\"([^\"]*)\"%s*",pos)
		if nam then pos=b+1 return nam,val end
		local a,b,nam,val=find(str,"^([a-zA-Z_][-a-zA-Z_0-9.:]*)%s*=%s*\'([^\']*)\'%s*",pos)
		if nam then pos=b+1 return nam,val end
		return nil
	end

	--
	-- the recoursive top down parser
	--
	local function need_obj()
		local a,b,tag=find(str,"^<([a-zA-Z_][-a-zA-Z_0-9.:]*)%s*",pos)
		if not tag then err("expected tag name") end
		pos=b+1
		local obj=setmetatable({tag},xmlobj_mt)
		for nam,val in get_attribute do
			if rawget(obj,nam) then err(string.format("duplicate attribute %q in %q (%q and %q)",nam,tag,tostring(obj[nam]),tostring(val))) end
			obj[nam]=val
		end
		local a,b=find(str,"^/>%s*",pos) -- finishing tag
		if b then pos=b+1 return obj end
		local a,b=find(str,"^>%s*",pos)
		if not b then err("expected '>'") end
		pos=b+1
		while true do

			repeat -- multiple choise
				--
				-- subtag ?
				--
				if find(str,"^<",pos) then
					--
					-- end of item?
					--
					local a,b,c=find(str,"^</([a-zA-Z_][-a-zA-Z_0-9.:]*)>%s*",pos)
					if c then
						if c~=tag then err(string.format("Tag mismatch have %q want %q",c,tag)) end
						pos=b+1
						return obj
					end

					if find(str,"^<!",pos) then
						--
						-- big CDATA?
						--
						local a,b,cdata=find(str,"^<!%[CDATA%[(.-)%]%]>%s*",pos)
						if a then
							obj[#obj+1]={cdata=cdata}
							pos=b+1
							break
						end

						--
						-- comment?
						--
						local a,b,comment=find(str,"^<!%-%-(.-)%-%->%s*",pos)
						if comment then
							obj[#obj+1]={comment=comment}
							pos=b+1
							break
						end
					end
					--
					-- must be obj
					--

					local element=need_obj()
					obj[#obj+1]=element
					break
				else -- no <
					local a,b,x=find(str,"^([^<>]+)%s*",pos)
					if not x then err("Expected CDATA") end
					pos=b+1
					obj[#obj+1]=x
				end
			until true
		end
	end

	--
	-- check for xml prefix
	--
	local a,b,tag=find(str,"^%s*<%?([a-zA-Z_][-a-zA-Z_0-9.:]*)%s*",pos)

	if tag then
		pos=b+1
		local obj={"?"..tag}
		for nam,val in get_attribute do
			obj[nam]=val
		end
		local a,b=find(str,"^%s*%?>%s*",pos)
		if not b then err("expected '?>'") end
		pos=b+1
	end
	local obj=need_obj()

	if not obj then err("no xml object found") end
	if pos~=#str+1 then
		return nil,"garbage at end"
	end
	return obj
end


---------------------------------------------------------------------
-- take a lua tables of tables and write to file
---------------------------------------------------------------------
function xmlobj:save_to_file(file)
	local fd=assert(io.open(file,"wb"))
	fd:write('<?xml version="1.0" encoding="UTF-8"?>\n')
	xml2vis(self,"",function(...) fd:write(...) end)
	fd:close()
end

function xml2file(xml,file)
	local fd=assert(io.open(file,"wb"))
	fd:write('<?xml version="1.0" encoding="UTF-8"?>\n')
	xml2vis(xml,"",function(...) fd:write(...) end)
	fd:close()
end

function file2xml(file,check_signature)
	local fd=assert(io.open(file,"rb"))
	local data=fd:read("*all")
	fd:close()
	if check_signature then check_signature(data) end
	return str2xml(data)
end

--
-- the test case
--
if arg and arg[0]=="cxml.lua" then
	local xml_want_tree={"data",["xmlns"]="www",{comment="1strecord"},{"record",id=1,{"value","TEST"}},{cdata="XYZ"},{"record",id=2}}
	local xml_want_str=[==[<data xmlns="www"><!--1strecord--><record id="1"><value>TEST</value></record><![CDATA[XYZ]]><record id="2"/></data>]==]
	local xml_have_str=xml2str(xml_want_tree)
	print("want",format("%q",xml_want_str))
	print("have",format("%q",xml_have_str))
	assert(xml_want_str==xml_have_str)
	local xml_have_tree=str2xml(xml_want_str)
	local xml_have_str=xml2str(xml_have_tree)
	print("want",format("%q",xml_want_str))
	print("have",format("%q",xml_have_str))
	assert(xml_want_str==xml_have_str)

	xml2vis(xml_want_tree)

end

return cxml
