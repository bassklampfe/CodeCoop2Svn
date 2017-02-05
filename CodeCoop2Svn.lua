#!/usr/bin/lua
require"strict"
require"utils"
require"cxml"
require"stringex"
require"Rebecca"


local sprintf=string.format
local push=table.insert
local join=table.concat



local function is_empty_dir(path)
	for entry in lfs.dir(path) do
		if entry~="." and entry~=".." then
			return false
		end
	end
	return true
end
--
-- this is ugly because of windows file system race conditions
--
local function remove_saved_dir(saved_dir)
	if isdir(saved_dir) then
		while not is_empty_dir(saved_dir) do
			assert(execute_cmd("ATTRIB -s -h -r /d /s \"%s\"",u2d(saved_dir.."/*.*")))
			local ok,msg=pcall(rmdir_r,saved_dir)
			if ok then 
				assert(is_empty_dir(saved_dir),"dir not empty")
				return 
			end
			printf("rmdir_r(%s)failed(%s)\n",saved_dir,msg)
		end
	end
end


local SVN_DATA

local function data_codecoop2svn(codecoop_date)
	-- codecoop: "Sa, 29.10.2016 18:00:42"
	-- svn: "YYYY-MM-DDTHH:MM:SS.SSSSSSZ"
	local svn_date,chg=codecoop_date:gsub("^%w%w, (%d%d)%.(%d%d)%.(%d%d%d%d) (%d%d):(%d%d):(%d%d)$","%3-%2-%1T%4:%5:%6.000000Z")
	assert(chg==1,"chg is not 1 but "..chg)
	return svn_date
end

local function get_members_from_user(USER)
	local members=USER._members or error("no USER._members")
	local users={}
	for _,member in ipairs(members) do
		local userid=member._id:match("^0%-(%x+)") or Error("Bad member._id=%s\n",vis)
		users[tonumber(userid,16)]=member._description._name
	end
	return users
end

local function execute_svn_cmd(args)
	local cmd={}
	local username=args.username
	if username then
		push(cmd,sprintf("--username %q",username))
		if SVN_DATA.SVN_PASSWORDS then
			local password=SVN_DATA.SVN_PASSWORDS[username]
			if password then
				push(cmd,sprintf("--password %q",password))
			end
		end
	end
	if args.scriptId then
		push(cmd,sprintf("--with-revprop %q","coop:scriptid="..args.scriptId))
	end
	for _,arg in ipairs(args) do
		if arg:match("%s") then
			push(cmd,'"'..arg..'"')
		else
			push(cmd,arg)
		end
	end
	local res,msg=execute_cmd("svn %s",join(cmd,' '))
	if not res then return nil,msg end
	if args[1]=="propset" then return res end
	if args[1]=="log" then return res end
	if args[1]=="co" then return res end
	if args[1]=="update" then return res end
	local committed_revision=res:match("Committed revision (%d+).\n$")
	if not committed_revision then
		Error("No committed revision in %s\n",res)
	end
	if args.timeStamp then
		--execute_cmd("svn propset -r%s --revprop svn:date %q %q",committed_revision,data_codecoop2svn(args.timeStamp),SVN_DATA.SVN_REPOS_URL)
		assert(execute_svn_cmd{username=args.username,"propset","-r"..committed_revision,"--revprop","svn:date",data_codecoop2svn(args.timeStamp),SVN_DATA.SVN_REPOS_URL})
	end
	return true
end



local function check_same(setChange,svn_log_entry)

	-- get the coop entry and data
	local hdrLog=setChange._hdrLog or error("no setChange._hdrLog")
	local comment=(hdrLog.comment or error("no hdrLog.comment")):gsub("^%s+",""):gsub("%s+$",""):gsub("\r\n","\n")
	local timeStamp=hdrLog._timeStamp  or error("no hdrLog._timeStamp")
	local scriptId=setChange._scriptId or error("no setChange._scriptId")

	-- get the svn log entry and data
	local svn_msg=(svn_log_entry:element"msg" or error("no log_entry'msg'")):data():unquote():gsub("\r\n","\n")
	local svn_iso_msg=svn_msg:utf82iso()
	local svn_rev=svn_log_entry.revision


	printf("REV %d %s\n",svn_rev,vis(svn_msg))

	if comment~=svn_iso_msg then
		local q1={['\r']='\\r',['\t']='\\t',['\n']='\\n\n'}
		printf("---- comment ----\n\"%s\"\n\n",comment:gsub("[\r\n\t]",q1))
		printf("---- svn_msg ----\n\"%s\"\n\n",svn_iso_msg:gsub("[\r\n\t]",q1))
		error("mismatch\n")
	end
	--
	-- check if revprops then must be same
	--
	local revprops=svn_log_entry:element"revprops"
	if revprops then
		local svn_scriptid=(revprops:element("property","coop:scriptid")  or error("revprops property 'coop:scriptid'")):data()
		ASSERT_EQ("svn.scriptid==coop.scriptid",svn_scriptid,scriptId)
	else
		printf(">>>REPAIR SCRIPTID\n")
		assert(execute_svn_cmd{"propset","-r"..svn_rev,"--revprop","coop:scriptid",scriptId,SVN_DATA.SVN_REPOS_URL})
		os.exit()
	end
	local coopdate=data_codecoop2svn(timeStamp)
	local svn_date=(svn_log_entry:element"date" or error("no log_entry'date'")):data()
	if svn_date~=coopdate then
		printf(">>>REPAIR TIMESTAMP\n")
		assert(execute_svn_cmd{"propset","-r"..svn_rev,"--revprop","svn:date",coopdate,SVN_DATA.SVN_REPOS_URL})
		os.exit()
	end
end

local function try_to_get_log(projectName)
	local svn_log_xml=execute_svn_cmd
	{
		"log","--xml","--with-all-revprops","--stop-on-copy",SVN_DATA.SVN_REPOS_URL.."/"..projectName
	}
	if svn_log_xml then
		local svn_log=cxml.str2xml(svn_log_xml)
		return svn_log
	end
end


local function replay_svn(data)
	
	-- get data
	local HIST=data.HIST or error("no HIST in data")
	local USER=data.USER or error("no USER in data")
	local setChanges=HIST._setChanges or error("no _setChanges in HIST")
	local users=get_members_from_user(USER)
	
	if SVN_DATA.SVN_USERS then
		for id,user in pairs(users) do
			users[id]=SVN_DATA.SVN_USERS[user] or user
		end
	end
	
	--
	-- state variables
	--
	local GLOBALIDS={}
	local comment_path=dirof(SVN_DATA.SVN_PROJECT_DIR).."/.comment"
	local CURRENT_PROJ_NAME
	local CURRENT_PROJ_URL
	local CURRENT_PROJ_DIR
	local CURRENT_SVN_LOG

	local HAVE_BRANCHES={}

	local function path(uname)
		--ShowData('uname',uname)
		if uname.parentid~="0-0" then
			local parent=GLOBALIDS[uname.parentid] or Error("No GLOBALIDS[%q]",uname.parentid)
			return path(parent).."/"..uname.name
		end
		return uname.name
	end

	------------------------------------------------------------
	-- execution of real commands on the file system
	------------------------------------------------------------
	local knownCmds={}

	local function executeRealCmd(cmd,cmds)
		local type=cmd._
		cmd=cmd[type] or Error("no cmd[%q]",type)
		if cmd._state._done then
			return
		end
		local handler=knownCmds[type] or Error("no handler for cmd._=%s\n",vis(type))
		return handler(cmd,cmds)
	end

	--
	-- this ugly fix is needed because the may be a sequence 
	-- rename "a","b" ; remove "b" 
	-- which should have been
	-- remove "b" ; rename "a","b"
	--
	local function try_delete(filepath,cmds)
		for _,cmd in ipairs(cmds) do
			if cmd._=="DeleteCmd" and 
			(not cmd.DeleteCmd._state._done)
			and filepath==path(cmd.DeleteCmd._uname) then
				executeRealCmd(cmd)
				return
			end
		end
	end

	local function check_rename(cmd,cmds)
		local filepath=path(cmd._uname)
		if #cmd._aliases==1 then
			CHECK_EQ('_aliases[1]._location="Original"',cmd._aliases[1]._location,"Original")
			local oldfilepath=path(cmd._aliases[1]._uname)
			if isfile(CURRENT_PROJ_DIR.."/"..filepath) then
				try_delete(filepath,cmds)
			end
			assert(execute_cmd("svn mv %q %q",CURRENT_PROJ_DIR.."/"..oldfilepath,CURRENT_PROJ_DIR.."/"..filepath))
		else
			assert(#cmd._aliases==0)
		end
		return filepath
	end

	function knownCmds.WholeFileCmd(cmd)
		assert(#cmd._aliases==0)
		local filepath=path(cmd._uname)
		save_file(CURRENT_PROJ_DIR.."/"..filepath,cmd._buf)
		assert(execute_cmd("svn add %q",CURRENT_PROJ_DIR.."/"..filepath))
		cmd._state._done=true
	end

	function knownCmds.DeleteCmd(cmd)
		assert(#cmd._aliases==0)
		local filepath=path(cmd._uname)
		assert(execute_cmd("svn rm %q",CURRENT_PROJ_DIR.."/"..filepath))
		cmd._state._done=true
	end

	function knownCmds.NewFolderCmd(cmd)
		assert(#cmd._aliases==0)
		local filepath=path(cmd._uname)
		assert(execute_cmd("svn mkdir %q",CURRENT_PROJ_DIR.."/"..filepath))
		GLOBALIDS[cmd.globalid]=cmd._uname
		cmd._state._done=true
	end

	function knownCmds.DeleteFolderCmd(cmd)
		assert(#cmd._aliases==0)
		local filepath=path(cmd._uname)
		-- to fix recoursive removes in dir
		assert(execute_cmd("svn revert --depth=infinity %q",CURRENT_PROJ_DIR.."/"..filepath))
		assert(execute_cmd("svn rm %q",CURRENT_PROJ_DIR.."/"..filepath))
		GLOBALIDS[cmd.globalid]=nil
		cmd._state._done=true
	end

	function knownCmds.TextDiffCmd(cmd,cmds)
		local filepath=check_rename(cmd,cmds)
		cmd:TextDiffFileExec(CURRENT_PROJ_DIR.."/"..filepath)
		cmd._state._done=true
	end

	function knownCmds.BinDiffCmd(cmd,cmds)
		local filepath=check_rename(cmd,cmds)
		cmd:BinDiffFileExec(CURRENT_PROJ_DIR.."/"..filepath)
		cmd._state._done=true
	end

	------------------------------------------------------------
	-- execution of dummy command, while parsing along an svnlog
	-- we only need the keep track over created/removed folders
	------------------------------------------------------------
	local function executeDummyCmds(cmds)
		local function dummyCmd(cmd)
			local type=cmd._
			cmd=cmd[type]
			-- printf("cmd %s\n",type)
			if type=="WholeFileCmd" then return end
			if type=="TextDiffCmd" then return end
			if type=="BinDiffCmd" then return end
			if type=="DeleteCmd" then return end
			if type=="NewFolderCmd" then
				assert(#cmd._aliases==0)
				GLOBALIDS[cmd.globalid]=cmd._uname
				return
			end
			if type=="DeleteFolderCmd" then
				assert(#cmd._aliases==0)
				GLOBALIDS[cmd.globalid]=nil
				return
			end
			ShowData('cmd',cmd,80)
			Error("????")
		end
		for _,cmd in ipairs(cmds) do
			dummyCmd(cmd)
		end 
	end

	--
	-- Replay of one setChange 
	-- (this results in one SVN commit)
	--
	local function replayOneSetChange(setChange,setChangeIdx)
		-- skip if done by forward looking in svn log
		if setChange._done then return end
		
		--
		-- get essential data from setChange
		--
		local hdrLog=setChange._hdrLog or error("no setChange._hdrLog")
		local comment=(hdrLog.comment or error("no hdrLog.comment")):gsub("^%s+",""):gsub("%s+$","")
		local scriptId=setChange._scriptId or error("no setChange._scriptId")
		local userid=scriptId:match("^(%x+)%-(%x+)$") or Error("Bad setChange._scriptId=%s",vis(setChange._scriptId))
		local username=users[tonumber(userid,16)] or Error("No username for id %s scriptid %s",userid,vis(setChange._scriptId))
		local timeStamp=hdrLog._timeStamp or error("no hdrLog._timeStamp")
		if setChange._state._rejected then
			printf("*** SKIP REJECTED ***\n")
			return
		end

		save_file(comment_path,comment)

		--
		-- the BIG one: creating/branching projects
		--
		if setChange._state._milestone then
			--
			-- need to replace comment in some times
			--
			comment=(SVN_DATA.COMMENT_FIXES and SVN_DATA.COMMENT_FIXES[comment]) or comment 
			if setChangeIdx==1 then

				local projectName=comment:match("^Project '(.-)' created ") 
				or comment:match("^Project '(.-)' joined ") 
				or Error("No projectname in commment %s",vis(comment))

				--
				-- update paths
				--
				CURRENT_PROJ_NAME=projectName
				CURRENT_PROJ_URL=SVN_DATA.SVN_REPOS_URL.."/"..projectName.."/trunk"
				CURRENT_PROJ_DIR=SVN_DATA.SVN_PROJECT_DIR.."/"..projectName

				CURRENT_SVN_LOG=try_to_get_log(projectName)
				if CURRENT_SVN_LOG then

					if comment:match("^Project '(.-)' joined ") then
						printf("============== JOINED PROJECT !!! ===========\n")
--						ShowData('setChange',setChange,80)
						--
						-- this one must be the joined message
						--
						do
							local svn_log_entry=CURRENT_SVN_LOG[#CURRENT_SVN_LOG]
							printf("----- svn_log_entry -----\n")
							ShowData('svn_log_entry',svn_log_entry,80)
							-- get the svn log entry and data
							local svn_msg=(svn_log_entry:element"msg" or error("no log_entry'msg'")):data():unquote():gsub("\r\n","\n")
							local svn_project=svn_msg:match("^Project '(.-)' created ") 
							or svn_msg:match("^Branch '(.-)' created ") 
							or Error("no project in svn_msg %s\n",vis(svn_msg))
							CURRENT_SVN_LOG[#CURRENT_SVN_LOG]=nil -- done
						end
						--
						-- this one must be the all added
						--
						do
							local svn_log_entry=CURRENT_SVN_LOG[#CURRENT_SVN_LOG]
							printf("----- svn_log_entry -----\n")
							ShowData('svn_log_entry',svn_log_entry,80)
							-- get the svn log entry and data
							local svn_msg=(svn_log_entry:element"msg" or error("no log_entry'msg'")):data():unquote():gsub("\r\n","\n")
							if svn_msg=="File(s) added during project creation" then
								CURRENT_SVN_LOG[#CURRENT_SVN_LOG]=nil -- done
							end
						end
						--
						-- this must be the all added from codecoop
						--
						do
							local nextSetChange=setChanges[setChangeIdx+1]
							printf("----- setChanges -----\n")
							--ShowData('setChanges[+1]',nextSetChange,80)
							ASSERT_EQ("coop-comment","Files added by the full sync script",nextSetChange._hdrLog.comment)
							executeDummyCmds(nextSetChange._cmds)
							nextSetChange._done=true
						end

						--
						-- this must be the real first change
						--
						--do
						local nextSetChange=setChanges[setChangeIdx+2]
						printf("----- setChanges -----\n")
						--ShowData('setChanges[+2]',nextSetChange,80)
						--nextSetChange._state._done=true
						--end

						printf(">> LOOKING FOR %s\n",nextSetChange._scriptId)
						while #CURRENT_SVN_LOG>1 do
							local svn_log_entry=CURRENT_SVN_LOG[#CURRENT_SVN_LOG]
							local revprops=svn_log_entry:element"revprops" or error("no log_entry'revprops'")
							local svn_scriptid=(revprops:element("property","coop:scriptid")  or error("revprops property 'coop:scriptid'")):data()
							printf("svn_scriptid=%q\n",svn_scriptid)
							if svn_scriptid==nextSetChange._scriptId then
								return true
							end
--								ShowData('svn_log_entry',svn_log_entry,80)
							CURRENT_SVN_LOG[#CURRENT_SVN_LOG]=nil -- done
						end
						printf("!!! NOT FOUND !!!\n")
						os.exit()
					end

					local svn_log_entry=CURRENT_SVN_LOG[#CURRENT_SVN_LOG]
					check_same(setChange,svn_log_entry)
					CURRENT_SVN_LOG[#CURRENT_SVN_LOG]=nil -- done
					return true
				end
				--
				-- create initial project in subversion
				--
				assert(execute_svn_cmd
					{
						username=username,
						"mkdir","-F",comment_path,
						SVN_DATA.SVN_REPOS_URL.."/"..projectName,
						SVN_DATA.SVN_REPOS_URL.."/"..projectName.."/tags",
						SVN_DATA.SVN_REPOS_URL.."/"..projectName.."/branches",
						SVN_DATA.SVN_REPOS_URL.."/"..projectName.."/trunk",
						timeStamp=timeStamp,
						scriptId=scriptId,
					})

			else

				local projectName=comment:match("^Branch '(.-)' created ") 
				or Error("No projectname in commment %s",vis(comment))

				CURRENT_SVN_LOG=try_to_get_log(projectName)
				if CURRENT_SVN_LOG then
					local svn_log_entry=CURRENT_SVN_LOG[#CURRENT_SVN_LOG]
					check_same(setChange,svn_log_entry)
					CURRENT_SVN_LOG[#CURRENT_SVN_LOG]=nil -- done

					CURRENT_PROJ_NAME=projectName
					CURRENT_PROJ_URL=SVN_DATA.SVN_REPOS_URL.."/"..projectName.."/trunk"
					CURRENT_PROJ_DIR=SVN_DATA.SVN_PROJECT_DIR.."/"..projectName
					return true
				end


				if HAVE_BRANCHES[projectName] then
					Error("Branch %q already created",newProjectName)
				end
				HAVE_BRANCHES[projectName]=true

				--
				-- branche project in subversion
				--
				assert(execute_svn_cmd
					{
						username=username,
						"cp","-F",comment_path,
						SVN_DATA.SVN_REPOS_URL.."/"..CURRENT_PROJ_NAME,
						SVN_DATA.SVN_REPOS_URL.."/"..projectName,
						timeStamp=timeStamp,
						scriptId=scriptId,
					})
				--
				-- update paths
				--
				CURRENT_PROJ_NAME=projectName
				CURRENT_PROJ_URL=SVN_DATA.SVN_REPOS_URL.."/"..projectName.."/trunk"
				CURRENT_PROJ_DIR=SVN_DATA.SVN_PROJECT_DIR.."/"..projectName
			end

			--
			-- fetch it from subversion
			--
			remove_saved_dir(CURRENT_PROJ_DIR)
			assert(execute_svn_cmd
				{
					"co",CURRENT_PROJ_URL,CURRENT_PROJ_DIR,
				})

			return
		end -- _milestone
		
		--
		-- ok, normal state
		--
		
		if setChange._state._inventory and setChangeIdx~=2 then
			Error("unexpected _inventory at cmd[%d]",setChangeIdx)
		end
		
		if setChange._state._executed then

			if CURRENT_SVN_LOG then
				local svn_log_entry=CURRENT_SVN_LOG[#CURRENT_SVN_LOG]
				check_same(setChange,svn_log_entry)
				CURRENT_SVN_LOG[#CURRENT_SVN_LOG]=nil -- done
				--
				-- when replaying svn we only need to keep track
				-- for the global id's of folders
				--
				executeDummyCmds(setChange._cmds)

				if #CURRENT_SVN_LOG==1 then-- last entry
					printf(">last log entry is \n")
					ShowData('svn_log_entry',svn_log_entry,80)
					local rev=svn_log_entry.revision or Error("no revision in svn_log_entry")
					if isdir(CURRENT_PROJ_DIR) then
						assert(execute_cmd("svn revert --depth=infinity %q",CURRENT_PROJ_DIR))
						assert(execute_svn_cmd{
								username=username,
								"update","-r",rev,
								CURRENT_PROJ_DIR
							})
					else
						remove_saved_dir(CURRENT_PROJ_DIR)
						assert(execute_svn_cmd{
								username=username,
								"co","-r",rev,
								CURRENT_PROJ_URL,CURRENT_PROJ_DIR
							})
					end
					CURRENT_SVN_LOG=nil
					return
				end
				return
			end
			CURRENT_SVN_LOG=nil

			assert(execute_cmd("svn update %q",CURRENT_PROJ_DIR))
			local cmds=setChange._cmds
			for _,cmd in ipairs(cmds) do
				executeRealCmd(cmd,cmds)
			end
			assert(execute_svn_cmd
				{
					username=username,
					"ci","-F",comment_path,CURRENT_PROJ_DIR,
					timeStamp=timeStamp,
					scriptId=scriptId,
				})
			return 
		end
		
		ShowData('setChange['..setChangeIdx..']',setChange,80)
		error("Cannot do trySetChange")
	end

	for i=1,#setChanges do
		replayOneSetChange(setChanges[i],i)
		setChanges[i]=true -- release memory!!!
	end
end


function SetSvnData(svn_data)
	SVN_DATA=svn_data
	local SVN_REPOS_URL=svn_data.SVN_REPOS_URL
	if SVN_REPOS_URL:match("^file:///") then
		local SVN_REPOS_DIR=SVN_REPOS_URL:gsub("^file:///","")
		if not isfile(SVN_REPOS_DIR.."/format") then
			printf("====== CREATE EMPTY REPOSITORY ======\n")
			lfs.mkdir(SVN_REPOS_DIR)
			assert(execute_cmd("svnadmin create %q",SVN_REPOS_DIR))
			save_file(SVN_REPOS_DIR.."/hooks/pre-revprop-change.bat","@echo off\r\n")
		end
	end
end

function CodeCoop2Svn(database_proj_dir)
	local analysis_proj_dir=database_proj_dir:gsub("/Database/","/Analysis/")
	lfs.mkdir(dirof(analysis_proj_dir))
	lfs.mkdir(analysis_proj_dir)

	local data=LoadProjectData(database_proj_dir)
	printf("**** %d KB USED ****\n",collectgarbage("count"))
	replay_svn(data)
end	
