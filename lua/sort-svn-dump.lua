#!/usr/bin/lua
require"strict"
require"socket"
local ARGV=arg
local push=table.insert
local join=table.concat
local sprintf=string.format

local function printf(...)
	io.write(sprintf(...))
	io.flush()
end

function hms(t)
	local s=t%60 t=(t-s)/60
	local m=t%60 t=(t-m)/60
	local h=t
	if h>0 then return sprintf("%2dh%02dm%02ds",h,m,s) end
	if m>0 then return sprintf("%2dm%05.2fs",m,s) end
	return sprintf("%5.2fs",s)
end

local function QW(words)
	local r={}
	for word in words:gmatch("%S+") do
		r[word]=true
		push(r,word)
	end
	return r
end

local validNodeKind=QW"file dir"
local validNodeAction=QW"change add delete replace"

local TIME_STAMP_FIXES=
{
	["2003-03-24T07:10:32.000000Z"]="2004-03-24T07:10:32.000000Z",
	["2006-01-26T17:13:05.000000Z"]="2007-01-26T17:13:05.000000Z",
	["2006-01-26T18:54:52.000000Z"]="2007-01-26T18:54:52.000000Z",
	["2006-04-04T18:12:12.000000Z"]="2007-04-04T18:12:12.000000Z",
	["2006-04-04T18:12:39.000000Z"]="2007-04-04T18:12:39.000000Z",
	["2006-04-04T18:35:48.000000Z"]="2007-04-04T18:35:48.000000Z",
	["2006-04-04T18:50:29.000000Z"]="2007-04-04T18:50:29.000000Z",
	["2006-11-16T16:47:48.000000Z"]="2007-11-16T16:47:48.000000Z",
	["2007-06-03T18:07:44.000000Z"]="2008-06-03T18:07:44.000000Z",
}

local KEY_STAT={}
local HEAD_STAT={}

local function load_svn_dump(dump_file)
	printf("load_svn_dump(%q)\n",dump_file)
	local fd=assert(io.open(dump_file,"rb"))
	local file_size=fd:seek("end") fd:seek("set")
	local last_date
	local function read_line(n)
		local pos=fd:seek()
		local line
		if n then
			line=fd:read(n+1) or error("unexpected end of file in read_head()")
			assert(line:sub(n+1)=='\n',"Bad EOL in read_line("..n..")")
			line=line:sub(1,n)
		else
			line=fd:read() or error("unexpected end of file in read_head()")
		end
		--printf("%05d:%s\n",pos,vis(line.."\n",80))
		return line
	end


	local function read_head(what)
		local pos=fd:seek()
		--printf("====== %d:read head %s ======\n",pos,what)
		local head={}
		while true do
			local line=read_line()
			if line=="" then
				break
			end
			local k,v=line:match("^([a-z0-9A-Z-]+): (.+)$")
			if not k then error("no key: value in "..vis(line)) end
			head[k]=tonumber(v) or v
			HEAD_STAT[k]=(HEAD_STAT[k]or 0)+1
			push(head,k)
		end
		local p2=fd:seek()
		--printf("%5d:total len %d\n",p2,p2-pos)
		return head
	end

	local function read_data()
		local pos=fd:seek()
		--printf("====== %s:read props ======\n",pos)
		local data={}
		while true do
			local line1=read_line()
			if line1=="" then
				break
			end
			if line1=="PROPS-END" then
				push(data,line1)
				break
			else
				local klen=tonumber(line1:match("^K (%d+)$") or error("no K nn in "..vis(line1)))
				local k=read_line(klen)
				local line3=read_line()
				local vlen=tonumber(line3:match("^V (%d+)$") or error("no V nn in "..vis(line3)))
				local v=read_line(vlen)
				if k=="svn:date" then
					v=TIME_STAMP_FIXES[v] or v
					printf("svn:date=%q\n",v)
				end

				data[k]=v
				KEY_STAT[k]=(KEY_STAT[k]or 0)+1
				push(data,k)
			end
		end
		local p2=fd:seek()
		--printf("%5d:total len %d\n",p2,p2-pos)
		return data
	end

	local head1=read_head("head1")
	--ShowData('head1',head1,true)
	local version=head1["SVN-fs-dump-format-version"] or error("no SVN-fs-dump-format-version in head1="..vist(head1))

	local head2=read_head("head2")
	--ShowData('head2',head2,true)
	local UUID=head2["UUID"] or error("no UUID in head1="..vist(head2))


	local REVISIONS={version=version,UUID=UUID}
	local CURR_REVISION



	while fd:seek()<file_size do
		local head=read_head("head")
		--ShowData('head',head,true)
		if next(head) then
			if head["Prop-content-length"] then
				head.props=read_data()
				local svn_date=head.props["svn:date"]
				if svn_date then
--~ 					if last_date and svn_date<last_date then
--~ 						ShowData('last_date',last_date)
--~ 						ShowData('svn:date',svn_date)
--~ 						ShowData('svn:log',head.props["svn:log"])
--~ 					end
					last_date=svn_date
				end
				--ShowData('head.props',head.props,true)
			end
			-- a new revision
			local revnumber=head["Revision-number"]
			if revnumber then
				CURR_REVISION={head=head,nodes={}}
				REVISIONS[revnumber]=CURR_REVISION
			elseif head["Node-path"] then
				if head["Node-action"]~="delete" then
					head.text=read_line(head["Text-content-length"] or 0)
				end
				push(CURR_REVISION.nodes,head)
			else
				ShowData("unknown_head",head,true)
				os.exit(1)
			end
		else
			push(CURR_REVISION.nodes,false)
		end
	end
	fd:close()
	return REVISIONS
end

local function save_svn_dump(path,dump)
	printf("save_svn_dump(%q)\n",path)
	local fd=assert(io.open(path,"wb"))

	fd:write("SVN-fs-dump-format-version: ",dump.version,"\n\n")
	fd:write("UUID: ",dump.UUID,"\n\n")

	local function props_to_string(props)
		local ret={}
		for i=1,#props do
			local k=props[i]
			local v=props[k]
			if not v then
				push(ret,k.."\n")
				break
			end
			push(ret,"K "..#k.."\n"..k.."\n")
			push(ret,"V "..#v.."\n"..v.."\n")
		end
		return join(ret)
	end


	local function save_head(head,nodes)
		local props=head.props
		if props then
			props=props_to_string(props)
			head["Prop-content-length"]=#props
		end
		if head["Prop-content-length"] or head["Text-content-length"] then
			head["Content-length"]=(head["Prop-content-length"] or 0)+(head["Text-content-length"] or 0)
		end
		for i=1,#head do
			local k=head[i]
			local v=head[k]
			fd:write(k,": ",v,"\n")
		end
		fd:write("\n")
		if props then fd:write(props) end
		if nodes then
			for n,node in ipairs(nodes) do
				if node then
					save_head(node)
					if node.text then
						fd:write(node.text,"\n")
					end
				else
					fd:write("\n")
				end
			end
		end
	end
	save_head(dump[0].head,dump[0].nodes)

	local n=#dump	
	for i=1,n do
		local rev=dump[i]
		save_head(rev.head,rev.nodes)
		--~ 		if i%100==0 then
		--~ 			collectgarbage()
		--~ 			printf("%d/%d bytes=%d\n",i,n,collectgarbage("count"))
		--~ 		end
	end

	fd:close()
end

local function ta(t,k) local v={} rawset(t,k,v) return v end


--- sorts arr in a stable manner via a simplified mergesort
-- the simplification is to avoid the dividing step and just start 
-- merging arrays of size=1 (which are sorted by definition)
function msort(arr, goes_before)
	local n = #arr
	local step = 1
	local fn = goes_before or function(a,b) return a < b end
	local tab1,tab2 = arr, {}
	-- tab1 is sorted in buckets of size=step
	-- tab2 will be sorted in buckets of size=step*2
	while step < n do
		for i=1,n,step*2 do
			-- for each bucket of size=step, merge the results
			local pos,a,b = i, i, i + step
			local e1,e2 = b-1, b+step-1
			-- e1= end of first bucket, e2= end of second bucket
			if e1 >= n then 
				-- end of our array, just copy the sorted remainder
				while a <= e1 do 
					tab2[a],a = tab1[a], a+1
				end
				break 
			elseif 
			e2 > n then e2 = n 
			end
			-- merge the buckets
			while true do
				local va,vb = tab1[a], tab1[b]
				if fn(va,vb) then
					tab2[pos] = va
					a = a + 1
					if a > e1 then 
						-- first bucket is done, append the remainder
						pos = pos + 1
						while b <= e2 do tab2[pos],b,pos = tab1[b], b + 1,pos+1 end
						break 
					end
				else
					tab2[pos] = vb
					b = b + 1
					if b > e2 then
						-- second bucket is done, append the remainder
						pos = pos + 1
						while a <= e1 do tab2[pos],a,pos = tab1[a], a + 1,pos+1 end
						break
					end
				end
				pos = pos + 1
			end
		end
		step = step * 2
		tab1,tab2 = tab2,tab1
	end	
	-- copy sorted result from temporary table to input table if needed
	if tab1~=arr then 
		for i=1,n do arr[i] = tab1[i] end 
	end
	return arr
end




local function sort_revisions_by_date(dump)
	printf("sort_revisions_by_date()\n")
	--
	-- pass : link nodes to revisions
	--
	for r,rev in ipairs(dump) do
		for n,node in ipairs(rev.nodes) do
			if node then
				local copyfromrev=node["Node-copyfrom-rev"]
				if copyfromrev then
					local crev=dump[copyfromrev]
					assert(crev.head["Revision-number"]==copyfromrev,"rev mismatch crev="..crev.head["Revision-number"].." copyfrom="..copyfromrev)
					local copynodes=crev.copynodes or ta(crev,"copynodes")
					push(copynodes,node)
				end
			end
		end
	end

	--
	-- pass 2 : sort revisions
	--
	local function cmprevdate(reva,revb)
		local datea=reva.head.props["svn:date"] or error("no svn:date in reva")
		local dateb=revb.head.props["svn:date"] or error("no svn:date in revb")
		if datea==dateb then
			local nra=reva.head["Revision-number"] or error("no Revision-number in reva")
			local nrb=revb.head["Revision-number"] or error("no Revision-number in revb")
			return nra<nrb
			--~ 			ShowData('reva.head',reva.head,true,80)
			--~ 			ShowData('revb.head',revb.head,true,80)
			--~ 			assert(datea~=dateb,"datea="..datea..",dateb="..dateb)
		end
		return datea<dateb
	end
	msort(dump,cmprevdate)

--
-- pass 3 : fix revision numbers
--
	for r,rev in ipairs(dump) do
		local head=rev.head
		head["Revision-number"]=r
		local copynodes=rev.copynodes rev.copynodes=nil
		if copynodes then
			for n,node in ipairs(copynodes) do
				node["Node-copyfrom-rev"]=r
			end
		end
	end

--
-- pass 4 : check order
--
	for r,rev in ipairs(dump) do
		for n,node in ipairs(rev.nodes) do
			if node then
				local copyfromrev=node["Node-copyfrom-rev"]
				if copyfromrev then
					assert(copyfromrev<r,"bad order copyfromrev="..copyfromrev.."is not < rev="..r)
				end
			end
		end
	end
end

for a,arg in ipairs(ARGV) do
	local name=arg:gsub("%.%w+$","")
	local t0=socket.gettime()
	local dump=load_svn_dump(arg)
	save_svn_dump(name.."-saved.dump",dump)
	collectgarbage()	
	printf("bytes=%d\n",collectgarbage("count"))
	sort_revisions_by_date(dump)
	save_svn_dump(name.."-sorted.dump",dump)
	local t1=socket.gettime()
	printf("Total time %s\n",hms(t1-t0))
end

