#!/usr/bin/lua
require"strict"

--==============================================================
-- extending string by some functions used
--==============================================================
local byte=string.byte
local char=string.char
local gsub=string.gsub

------------------------------------------------------------
-- convert iso2utf8 sequence
--
string.iso2utf8=function(text)
	return (gsub(text,"[\128-\255]",function(c)
		local code=byte(c)
		if code<=0x7F then return char(code) end
		if code<=0x03FF then
			local c2=code%0x40
			local c1=(code-c2)/0x40
			return char(c1+0xC0,c2+0x80)
		end
		error("bad iso2utf8")
	end))
end

------------------------------------------------------------
-- convert utf82iso sequence (not really checking for validity)
--
string.utf82iso=function(text)
	return (gsub(text,"[\192-\255][\128-\191]",function(c)
		local a,b=byte(c,1,2)
		return char((a-192)*64+(b-128))
	end))
end

local qxml={
	['&gt;']=">",
	['&lt;']="<",
	['&amp;']="&",
}
------------------------------------------------------------
-- remove xml quotes
--
string.unquote=function(xml)
	return gsub(xml,"&%w+;",qxml)
end

