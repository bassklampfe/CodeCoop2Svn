#!/usr/bin/lua
require"strict"
require"crc32"


--============================================================
-- implementation of reading CodeCoop data types from file
--============================================================
--[[ local caches to make code faster ]]--

local byte=string.byte
local sprintf=string.format
local push=table.insert
local join=table.concat
local crc=crc32.calc_crc32

local BinFile=require"BinFile"
local OpenBinFile=BinFile.OpenBinFile


local function XX(x)
	return sprintf("0x%08X",x) 
end

local function sum(data)
	local sum=0
	for i=1,#data do
		local c=byte(data,i)
		if c>127 then c=c-256 end
		sum=sum+c
	end
	if sum<0 then
		sum=sum+0x80000000
		sum=sum+0x80000000
	end
	return sum
end

--[[ ENUM DATA TYPES ]]--

local ENUM_FILETYPE=
{
	[0]="Header",
	"Source",
	"Text",
	"Binary",
	"Folder",
	"Root",
	"Invalid",
	"Auto",
	"Wiki",
}

local ENUM_TRANSPORT_METHOD=
{
	[0]="Unknown",
	[1]="Network",
	[2]="EMail",
}


local ENUM_AREA_LOCATION=
{
	[0]='Project',
	[1]='Original',
	[2]='Reference',
	[3]='Synch',
	[4]='PreSynch',
	[5]='Staging',
	[6]='OriginalBackup',
	[7]='Temporary',
	[8]='Compare',
	[9]='LocalEdits',
	[10]='LastArea',
}

--[[ BITFILED DEFINITIONS ]]--

local BITS_MEMBERSTATE=
{
	[0]='Voting',
	[1]='Active',
	[2]='Admin',
	[3]='Suicide',
	[4]='Ver45',
	[5]='Distributor',
	[6]='Receiver',
	[7]='NoBra',
	[8]='Out',
}

local BITS_NODESTATE=
{
	[0]='_archive',
	[1]='_milestone',
	[2]='_rejected',
	[3]='_missing',
	[4]='_executed',
	[5]='_forceExec',
	[6]='_branchPoint',
	[7]='_inventory',
	[8]='_forceAccept',
	[9]='_defect',
	[10]='_dontResend',
	[11]='_deepFork',
}


local BITS_FILESTATE=
{
	[0]='P', --// 1 -- present in the project area
	'PS',	-- 1 -- present in the pre-synch area
	'pso',	-- 1 -- relevant in the pre-synch out
	'O',	-- 1 -- present in the original area
	'co',	-- 1 -- relevant in the original area
	'R',	-- 1 -- present in the reference area
	'ro',	-- 1 -- relevant in the referenced out
	'S',	-- 1 -- present in the synch area
	'so',	-- 1 -- relevant in the synched out
	'coDelete',	-- 1 -- checked out to be physically deleted
	'soDelete',	-- 1 -- synched out to be physically deleted
	-- volatile members
	'coDiff',	-- 1 -- checked out different from original
	'soDiff',	-- 1 -- synched out different from reference

	-- back to persistent members
	'M',	-- 1 -- merge requiring user intervention
	'Mc',	-- 1 -- automatic merge failed because of conflict

	-- volatile members
	'Rnc',	-- 1 -- resolved name conflict -- in the project area file still uses old (conflict) name,
	-- while in the database we already have stored its new (non-conflict) name.
	'Rn',	-- 1 -- renamed -- used only for display
	'Mv',	-- 1 -- moved -- used only for display
	'Out',	-- 1 -- checked out by others - used only for display
	'TypeCh',	-- 1 -- file type changed
}

--
-- serialisation of an array
-- @param func must by of type func(mt,name)
--
local function ARRAY(mt,name,func)
	local count=mt.UINT32(name..".count")
	local array={}
	for i=1,count do
		array[i]=func(mt,name.."["..i.."]")
	end
	return array
end

--============================================================
-- Rebecca File types
--============================================================

local function Address(mt,name)
	local address={}
	if mt.version>2 then
		address._projName=mt.TEXT(name.."._projName")
		address._hubId=mt.TEXT(name.."._hubId")
		address._userId=mt.TEXT(name.."._userId")
	end
	return address
end

local function ProjEntry(mt,name)
	local projentry={}
	projentry._projName=mt.TEXT(name.."._name")
	projentry._hubId=mt.TEXT(name.."._path")
	return projentry
end

local function FileTypeEntry(mt,name)
	local filetypeentry={}
	filetypeentry._ext=mt.TEXT(name.."._ext")
	return filetypeentry
end

local function HubEntry(mt,name)
	local hubentry={}
	hubentry._hubId=mt.TEXT(name.."._hubId")
	hubentry._route=mt.TEXT(name.."._route")
	hubentry._method=mt.ENUM(name.."._method",ENUM_TRANSPORT_METHOD)
	return hubentry
end

local function UniqueName(mt,name)
	local uniquename={}
	uniquename.parentid=mt.GID(name..".parentid")
	uniquename.name=mt.TEXT(name..".name")
	return uniquename
end

local function AreaFileData(mt,name)
	local areafiledata={}
	if mt.version<31 then
		areafiledata._uname=UniqueName(mt,name.."._uname")
		areafiledata._location=mt.ENUM(name.."._location",ENUM_AREA_LOCATION)
	else
		areafiledata._uname=UniqueName(mt,name.."._uname")
		areafiledata._location=mt.ENUM(name.."._location",ENUM_AREA_LOCATION)
		areafiledata._type=mt.ENUM(name.."._type",ENUM_FILETYPE)
	end
	return areafiledata
end

local function FileData(mt,name)
	local filedata={}
	filedata._state=mt.BITS(name.."._state",BITS_FILESTATE)
	filedata.globalid=mt.GID(name..".globalid")
	filedata.filetype=mt.ENUM(name..".filetype",ENUM_FILETYPE)
	filedata._uname=UniqueName(mt,name.."._uname")
	filedata.old_sum=mt.HEX32(name..".chksum")
	filedata._aliases=ARRAY(mt,name.."._aliases",AreaFileData)
	if mt.version>34 then
		filedata.old_crc=mt.HEX32(name..".crc32")
	else
		filedata.old_crc=false
	end
	return filedata
end

local function Member(mt,name)
	local member={}
	member._id=mt.GID(name.."._id")					-- id of the user
	member._state=mt.BITS(name.."._state",BITS_MEMBERSTATE)	
	if mt.version>=38 then
		member._preHistoricScipt=mt.GID(name.."._preHistoricScipt")
		member._modeRecentScript=mt.GID(name.."._modeRecentScript")
	end
	return member
end

local function MemberDescription(mt,name)
	local memberdescription={}
	memberdescription._name=mt.TEXT(name.."._name")
	memberdescription._hubId=mt.TEXT(name.."._hubId")
	memberdescription._comment=mt.TEXT(name.."._comment")
	memberdescription._license=mt.TEXT(name.."._license")
	if mt.version>24 then
		memberdescription._userId=mt.TEXT(name.."._userId")
	end
	return memberdescription
end

local function MemberInfo(mt,name)
	local memberinfo=Member(mt,name)
	memberinfo._description=MemberDescription(mt,name.."._description")
	return memberinfo
end

local function MemberNote(mt,name)
	local membernote=Member(mt,name)
	local userlog_offs=mt.X64(name..".userlog_offs")
	if mt.userlog_mt then
		mt.userlog_mt.seek(userlog_offs)
		membernote._description=MemberDescription(mt.userlog_mt,name.."._description")
	else
		mt.userlog_offs=XX(userlog_offs)
	end
	return membernote
end

local function Cluster(mt,name)
	local cluster={}
	cluster.oldL=mt.SINT32(name..".oldL")
	cluster.newL=mt.SINT32(name..".newL")
	cluster.len=mt.UINT32(name..".len")
	return cluster
end

local function LineArray(mt,name)
	local linearray={}
	local count=mt.UINT32(name..".count")
	if count<0 or count>50000 then Error("FIXME:LineArray "..name..".count="..count) end
	if mt.version<=8 then Error("FIXME:LineArray version<=8") end
	for n=1,count do
		local _offset=mt.UINT32(name.."["..n.."]._offset")
		push(linearray,{_offset=_offset})
	end
	for n=1,count do
		local _lineNo=mt.UINT32(name.."["..n.."]._lineNo")
		linearray[n]._lineNo=_lineNo
	end
	linearray._buf=mt.BLOB(name.."._buf")
	return linearray
end


local function GID(mt,name)
	return mt.GID(name)
end

local function HdrNote(mt,name)
	local hdrnote={}
	if mt.version<13 then Error("FIXME:HdrNote version<13") end
	hdrnote._timeStamp=mt.STAMP(name.."._timeStamp")
	hdrnote._lineage=ARRAY(mt,name.."._lineage",GID)
	hdrnote.comment=mt.TEXT(name..".comment")
	return hdrnote
end

--============================================================
-- Helper functions to verify checksum
--============================================================

local function CheckOldCrcSum(cmd,buf)
	buf=buf or cmd._buf
	local have_sum=XX(sum(buf))
	local have_crc=XX(crc(buf))
	--	printf("have_sum=%s have_crc=%s\n",have_sum,have_crc)

	if (cmd.old_crc and cmd.old_crc~="0x00000000" and cmd.old_crc~=have_crc) 
	or (cmd.old_sum and cmd.old_sum~="0x00000000" and cmd.old_sum~=have_sum) 
	then
		cmd._buf=hex(buf,60)
		ShowData(cmd._,cmd,80)
		printf(cmd._..".old_crc want=%s have=%s\n",tostring(cmd.old_crc),have_crc)
		printf(cmd._..".old_sum want=%s have=%s\n",tostring(cmd.old_sum),have_sum)
		Error("CheckOldCrcSum FAILED\n")
	end
end	

-- these are also used external
local function CheckNewCrcSum(cmd,buf)
	buf=buf or cmd._buf
	local have_sum=XX(sum(buf))
	local have_crc=XX(crc(buf))
	--printf("have_sum=%s have_crc=%s\n",have_sum,have_crc)
	if (cmd.new_crc and cmd.new_crc~="0x00000000" and cmd.new_crc~=have_crc) 
	or (cmd.new_sum and cmd.new_sum~="0x00000000" and cmd.new_sum~=have_sum) 
	then
		cmd._buf=hex(buf,60)
		ShowData(cmd._,cmd,80)
		printf(cmd._..".new_crc want=%s have=%s\n",tostring(cmd.new_crc),have_crc)
		printf(cmd._..".new_sum want=%s have=%s\n",tostring(cmd.new_sum),have_sum)
		Error("CheckNewCrcSum FAILED\n")
	end
end	

local function CheckOldNull(cmd,buf)
	buf=buf or cmd._buf
	if (cmd.old_crc and cmd.old_crc~="0x00000000") 
	or (cmd.old_sum and cmd.old_sum~="0x00000000") 
	then
		cmd._buf=hex(buf,60)
		ShowData(cmd._,cmd,80)
		printf(cmd._..".old_crc want=%s not 0x00000000\n",tostring(cmd.old_crc))
		printf(cmd._..".old_sum want=%s not 0x00000000\n",tostring(cmd.old_sum))
		Error("CheckOldNull FAILED\n")
	end
end	

local function CheckNewNull(cmd,buf)
	buf=buf or cmd._buf
	if (cmd.new_crc and cmd.new_crc~="0x00000000") 
	or (cmd.new_sum and cmd.new_sum~="0x00000000") 
	then
		cmd._buf=hex(buf,60)
		ShowData(cmd._,cmd,80)
		printf(cmd._..".new_crc want=%s not 0x00000000\n",tostring(cmd.new_crc))
		printf(cmd._..".new_sum want=%s not 0x00000000\n",tostring(cmd.new_sum))
		Error("CheckNewNull FAILED\n")
	end
end	

local mt_cmd={}
mt_cmd.__index=mt_cmd
mt_cmd.CheckOldCrcSum=CheckOldCrcSum
mt_cmd.CheckNewCrcSum=CheckNewCrcSum

--============================================================
-- Rebecca commands
--============================================================

local function FileCmd(mt,name)
	if mt.version<12 then Error("FIXME:FileCmd version<12") end
	local filecmd=FileData(mt,name)
	filecmd._="FileCmd"
	filecmd.new_crc=mt.HEX32(name..".new_crc")
	filecmd.new_sum=mt.HEX32(name..".new_sum")
	if mt.version<35 then
		if mt.version<16 then Error("FIXME:FileCmd version<16") end
		-- "old checksum was stored in place of new crc
		filecmd.old_sum=filecmd.new_crc
		filecmd.old_crc=false	-- no CRC
		filecmd.new_crc=false	-- no CRC
	end
	-- these are wildcards
	if filecmd.old_crc=="0x6789ABCD" then filecmd.old_crc=false end
	if filecmd.new_crc=="0x6789ABCD" then filecmd.new_crc=false end

	return setmetatable(filecmd,mt_cmd)
end

local function WholeFileCmd(mt,name)
	name="WholeFileCmd"..name
	local wholefilecmd=FileCmd(mt,name)
	wholefilecmd._="WholeFileCmd"
	if wholefilecmd.filetype=="Binary" then
		wholefilecmd._buf=mt.BLOB(name.."._buf")
	else
		wholefilecmd._buf=mt.TEXT(name.."._buf")
	end
	CheckOldNull(wholefilecmd)
	--CheckOldCrcSum(wholefilecmd)
	CheckNewCrcSum(wholefilecmd)
	--CheckNewNull(wholefilecmd)
	return wholefilecmd
end

local function NewFolderCmd(mt,name)
	name="NewFolderCmd"..name
	local newfoldercmd=FileCmd(mt,name)
	newfoldercmd._="NewFolderCmd"
	CheckOldNull(newfoldercmd)
	CheckNewNull(newfoldercmd)
	newfoldercmd.old_sum=nil
	newfoldercmd.old_crc=nil
	newfoldercmd.new_sum=nil
	newfoldercmd.new_crc=nil
	return newfoldercmd
end

local function DeleteCmd(mt,name)
	name="DeleteCmd"..name
	local deletecmd=FileCmd(mt,name)
	deletecmd._="DeleteCmd"
	if deletecmd.filetype=="Binary" then
		deletecmd._buf=mt.BLOB(name.."._buf")
	else
		deletecmd._buf=mt.TEXT(name.."._buf")
	end
	--CheckOldCrcSum(deletecmd) this failes on cs-11
	--CheckNewNull(deletecmd)	this failes on cs-11
	return deletecmd
end

local function DeleteFolderCmd(mt,name)
	name="DeleteFolderCmd"..name
	local deletefoldercmd=FileCmd(mt,name)
	CheckOldNull(deletefoldercmd)
	CheckNewNull(deletefoldercmd)
	deletefoldercmd.old_sum=nil
	deletefoldercmd.old_crc=nil
	deletefoldercmd.new_sum=nil
	deletefoldercmd.new_crc=nil
	deletefoldercmd._="DeleteFolderCmd"
	return deletefoldercmd
end

local function DiffCmd(mt,name)
	local diffcmd=FileCmd(mt,name)
	diffcmd._="DiffCmd"
	diffcmd._oldFileSize=mt.UINT32(name.."._oldFileSize")
	diffcmd._newFileSize=mt.UINT32(name.."._newFileSize")
	diffcmd._clusters=ARRAY(mt,name.."._clusters",Cluster)
	diffcmd._newlines=LineArray(mt,name..".newlines")
	diffcmd._oldlines=LineArray(mt,name..".oldlines")
	return diffcmd
end

local function TextDiffCmd(mt,name)
	local textdiffcmd=DiffCmd(mt,"TextDiffCmd"..name)
	textdiffcmd._="TextDiffCmd"
	return textdiffcmd
end	

local function BinDiffCmd(mt,name)
	local bindiffcmd=DiffCmd(mt,"BinDiffCmd"..name)
	bindiffcmd._="BinDiffCmd"
	return bindiffcmd
end	

local function NewMemberCmd(mt,name)
	name="NewMemberCmd"..name
	if mt.version<41 then Error("FIXME:NewMemberCmd version<41") end
	local newmembercmd=MemberInfo(mt,name)
	newmembercmd._="NewMemberCmd"
	return newmembercmd
end

local function DeleteMemberCmd(mt,name)
	name="DeleteMemberCmd"..name
	if mt.version<41 then Error("FIXME:DeleteMemberCmd version<41") end
	local deletemembercmd=MemberInfo(mt,name)
	deletemembercmd._="DeleteMemberCmd"
	return deletemembercmd
end

local function EditMemberCmd(mt,name)
	name="EditMemberCmd"..name
	if mt.version<41 then Error("FIXME:EditMemberCmd version<41") end
	local editmembercmd={}
	editmembercmd._="EditMemberCmd"
	editmembercmd._oldMemberInfo=MemberInfo(mt,name.."._oldMemberInfo")
	editmembercmd._newMemberInfo=MemberInfo(mt,name.."._newMemberInfo")
	return editmembercmd
end


--~ -- enum ScriptCmdType
--~ -- These command types are identical to version 4.2
--~ local typeWholeFile = 0
--~ local typeTextDiffFile = 1
--~ local typeDeletedFile = 2
--~ local typeNewFolder = 3
--~ local typeDeleteFolder = 4
--~ local typeUserCmd = 5  -- Obsolete in version 4.5
--~ local typeBinDiffFile = 6
--~ -- These are new command types introduced in version 4.5
--~ local typeAck = 7
--~ local typeMakeReference = 8
--~ local typeResendRequest = 9
--~ local typeNewMember = 10
--~ local typeDeleteMember = 11
--~ local typeEditMember = 12
--~ local typeJoinRequest = 13
--~ local typeResendFullSynchRequest = 14
--~ -- These are new command types introduced in version 5.1
--~ local typeVerificationRequest = 15

local read_types=
{
	[0]=WholeFileCmd,
	[1]=TextDiffCmd,
	[2]=DeleteCmd,
	[3]=NewFolderCmd,
	[4]=DeleteFolderCmd,
	--[5]=Type5,
	[6]=BinDiffCmd,
	[10]=NewMemberCmd,
	[11]=DeleteMemberCmd,
	[12]=EditMemberCmd,
}


local function GetCmdLogEntryAt(mt,offs,script_version)
	mt.seek(offs)
	local name=sprintf("#%06X",offs)
	local t=mt.UINT32("RecordType")
	local f=read_types[t] or Error("RecordType %d not known",t)
	mt.version=script_version
	local h=f(mt,name)
	return h
end


-- Node::Cmd
local function Node__Cmd(mt,name)
	local node__cmd={}
	node__cmd._unitId=mt.GID(name.."._unitId")
	node__cmd._logOffset=mt.X64(name.."._logOffset")
	--mode__cmd._cmd=GetCmdLogEntryAt(mt.cmdlog_mt,name,node__cmd._logOffset)
	return node__cmd
end

--============================================================
-- one node in Data<n>.bin
--============================================================
local function Node(mt,name)
	local node={}
	local hdrLogOffset=mt.X64(name.."._hdrLogOffset")
	node._scriptVersion=mt.UINT32(name.."._scriptVersion")
	if mt.notelog_mt then
		mt.notelog_mt.version=node._scriptVersion
		mt.notelog_mt.seek(hdrLogOffset)
		node._hdrLog=HdrNote(mt.notelog_mt,name.."._hdrLog")
	else
		node._hdrLogOffset=XX(hdrLogOffset)
	end
	do
		local count=mt.UINT32(name..".cmds.count")
		node._cmds={}
		for cmdlog_idx=1,count do
			local cmdlog_entry_name=name.."._cmds["..cmdlog_idx.."]"
			local cmdlog_entry=Node__Cmd(mt,cmdlog_entry_name)
			if mt.cmdlog_mt then
				local entry=GetCmdLogEntryAt(mt.cmdlog_mt,cmdlog_entry._logOffset,node._scriptVersion)
				--printf("entry.globalid=%s cmdlog_entry._unitId=%s\n",vis(entry.globalid),vis(cmdlog_entry._unitId))
				--ASSERT_EQ("entry.globalid==cmdlog_entry._unitId",entry.globalid,cmdlog_entry._unitId)
				local type=entry._ or Error("Entry has no type")
				--cmdlog_entry.cmdlog_entry=entry
				push(node._cmds,{_=type,[type]=entry})
			else
				push(node._cmds,cmdlog_entry)
			end
		end
	end
	do
		local count=mt.UINT32(name.."._ackList.count")
		if count>0 then
			local _ackList={}
			for i=1,count do
				push(_ackList,mt.GID(name.."._ackList["..i.."]"))
			end
			node._ackList=_ackList
		end
	end
	if mt.version<27 then
		Error("FIXME version<27")
	else
		node._state=mt.BITS(name.."._state",BITS_NODESTATE)
		node._scriptId=mt.GID(name.."._scriptId")
	end
	if mt.version>=37 and mt.version<=41 then
		mt.X(name..".unused_script_kind")
	end
	if mt.version< 43 then
		node._predecessorId=-1
	else
		node._predecessorId=mt.GID(name.."._predecessorId")
	end
	node._scriptVersion=nil

	return node
end



--SortedTree::Deserialze
local function SortedTree(mt,name)
	-- eigentlich SortedTree _setChanges
	local sorted_tree={}
	sorted_tree.count=mt.UINT32(name.."._count")
	for notelog_idx=1,sorted_tree.count do
		local name=name..".["..notelog_idx.."]"
		local node=Node(mt,name)
		push(sorted_tree,node)
	end
	if mt.version>41 then
		sorted_tree._firstInterestingScript=mt.GID(name.."._firstInterestingScript")
	end
	return sorted_tree
end






local function dump_file_of(bin_path,name,objfunc)
	printf("dump_file_of(%s,%s)\n",vis(bin_path),vis(name))
	local mt=OpenBinFile(bin_path)
	local entries={}
	while not mt.eof() do
		local e=#entries+1
		local entry=objfunc(mt,name.."["..e.."]")
		push(entries,entry)
	end
	--push(entries,{eofoffs=XX(mt.pos())})
	mt.close()
	return entries
end


--
-- PASSED FOR ALL REPOS
--
function LoadGlobalUserlogBin(bin_path)
	return dump_file_of(bin_path,"GlobalDb._userLog",Address)
end

function LoadGlobalProjlogBin(bin_path)
	return dump_file_of(bin_path,"GlobalDb._projLog",ProjEntry)
end

function LoadGlobalFiletypelogBin(bin_path)
	return dump_file_of(bin_path,"GlobalDb._typeLog",FileTypeEntry)
end

function LoadGlobalHublogBin(bin_path)
	return dump_file_of(bin_path,"GlobalDb._hubLog",HubEntry)
end

--
-- PASSED FOR ALL PROJECTS (obsolete)
--
--~ local function dump_proj_userlog_bin(bin_path)
--~ 	return dump_file_of(bin_path,"proj.userlog",MemberDescription);
--~ end

--~ local function dump_proj_notelog_bin(bin_path)
--~ 	return dump_file_of(bin_path,"proj.notelog",HdrNote);
--~ end



local function dump_data_bin(bin_path,cmdlog_mt,notelog_mt,userlog_mt)
	printf("dump_data_bin(%s)\n",vis(bin_path))

	local mt=OpenBinFile(bin_path)
	if mt.len()==0 then
		mt.close()
		return
	end
	mt.cmdlog_mt=cmdlog_mt
	mt.notelog_mt=notelog_mt
	mt.userlog_mt=userlog_mt

	local data={}

	local function BLK(want_magic)
		local block={}
		block.pos=mt.pos()	-- 4=type 1:lua
		block.offs=XX(block.pos)
		block.magic=mt.M(want_magic..".magic")
		assert(block.magic==want_magic)
		block.version=mt.UINT32(want_magic..".version")
		mt.version=block.version
		assert(block.version==55,"block.v2 not 55")
		block.size=mt.X(want_magic..".size")
		block.eoff=block.pos+block.size+12
		block.sizexxx=XX(block.size)
		block.endoffs=XX(block.eoff)
		data[want_magic]=block
		return block
	end

	--
	-- WORK BEGINS
	--

	-- 
	local RVCS=BLK("RVCS")
	local DATA=BLK("DATA")
	do
		local BASE=BLK("BASE")
		BASE._fileData=ARRAY(mt,'BASE._fileData',FileData)
		assert(BASE.eoff==mt.pos())
		--ShowData("BASE",BASE)
	end



	do
		local USER=BLK("USER")
		-- Db::Deserialize()
		USER._projectName=mt.TEXT("USER._projectName")
		USER._copyright=mt.TEXT("USER._copyright")
		USER._myId=mt.GID("USER._myId") -- userid
		USER._counter=mt.UINT32("USER._counter")
		USER._scriptCounter=mt.UINT32("USER._scriptCounter")
		USER._lastUserOffset=XX(mt.X64("USER._lastUserOffset"))
		USER._members=ARRAY(mt,'USER._members',MemberNote)
		USER._properties=mt.BITS("USER._properties",{[0]="KeepCheckedOut",[1]="AutoSynch",[2]="AutoJoin",[3]="AutoFullSynch",[4]="AllBcc"})
		local n=0
		USER.extra={}
		-- loop until sync
		while mt.pos()<DATA.eoff do
			n=n+1
			push(USER.extra,XX(mt.X("user.extra["..n.."]")))
		end		

	end

	do
		-- SynchArea.Deserialize
		local SYNC=BLK("SYNC")
		if mt.version<36 then Error("FIXME: SYNC version<36") end

		SYNC._scriptId=mt.X("sync._scriptId")
		SYNC._scriptComment=mt.X("sync._scriptComment")
		SYNC._synchItems=mt.X("sync._synchItems")
		if SYNC._scriptId~=0xFFFFFFFF then Warning("_scriptId not FFFFFFFF\n") end
		if SYNC._scriptComment~=0 then Warning("_scriptComment not 0\n") end
		-- really an array, we assume it should be empty
		if SYNC._synchItems~=0 then Warning("_synchItems not 0\n") end
	end
	do
		-- History::Db::Deserialize
		local HIST=BLK("HIST")
		HIST._cmdValidEnd=XX(mt.X64("HIST._cmdValidEnd"))
		HIST._hdrValidEnd=XX(mt.X64("HIST._hdrValidEnd"))

		HIST._setChanges=SortedTree(mt,"HIST._setChanges")
		HIST._nextScriptId=GID(mt,"HIST._nextScriptId")
		HIST._memberChipChanges=SortedTree(mt,"HIST._memberChipChanges")

		local n=0
		local hist_extra={}
		while mt.pos()<HIST.eoff do
			n=n+1
			push(hist_extra,XX(mt.X("HIST.extra["..n.."]")))
		end				
		if next(hist_extra) then
			HIST.extra=hist_extra
		end
	end -- HIST


	do
		local SIDE=BLK("SIDE")
		-- das sind 3 Arrays. wir brauchen sie einfach nur leer
		SIDE.s1=mt.X("SIDE.s1")
		SIDE.s2=mt.X("SIDE.s2")
		SIDE.s3=mt.X("SIDE.s3")
		if SIDE.s1~=0 then Error("SIDE.s1 not 0") end
		if SIDE.s2~=0 then Error("SIDE.s2 not 0") end
		if SIDE.s3~=0 then Error("SIDE.s3 not 0") end
	end

	do
		local COUT=BLK("COUT")
		COUT.count=mt.UINT32("COUT.count")
		COUT.entries={}
		for n=1,COUT.count do
			local name="COUT.entries["..n.."]"
			local entry={}
			entry.cout_script_id=mt.GID(name..".cout_script_id")
			entry.cout_v2=mt.UINT32(name..".cout_v2")
			entry.cout_v3=mt.UINT32(name..".cout_v3")
			push(COUT.entries,entry)
		end
	end
	ASSERT_EQ("mt.pos()==mt.len()",mt.pos(),mt.len())
	--push(data,{eofoffs=XX(mt.pos())})
	mt.close()
	return data
end



local function isdatafile(path)
	if  lfs.attributes(path,"mode")=="file"
	and lfs.attributes(path,"size")>0 then
		return path
	end
end

function LoadProjectData(database_proj_dir)
	local data_path=isdatafile(database_proj_dir.."/".."data1.bin")
	or isdatafile(database_proj_dir.."/".."data2.bin")
	or error("No datafile with content in "..database_proj_dir)
	local cmdlog_mt=OpenBinFile(database_proj_dir.."/".."CmdLog.bin")
	local notelog_mt=OpenBinFile(database_proj_dir.."/".."NoteLog.bin")
	local userlog_mt=OpenBinFile(database_proj_dir.."/".."UserLog.bin")
	local data=dump_data_bin(data_path,cmdlog_mt,notelog_mt,userlog_mt)
	cmdlog_mt.close() 
	notelog_mt.close()
	userlog_mt.close()
	
	if next(BinFile.openfiles) then
		ShowData("BinFile.openfiles",BinFile.openfiles)
		error("open files left")
	end
	return data
end




local function TextDiffFileExec(TextDiffCmd,filepath)
	printf("TextDiffFileExec(%q)\n",filepath)
	local old_data=load_file(filepath)
	CheckOldCrcSum(TextDiffCmd,old_data)

	local old_lines={}
	local new_lines={}
	for line in old_data:gmatch("([^\n]*\n?)") do
		push(old_lines,line)
	end
	local old_data_joined=join(old_lines)
	assert(old_data_joined==old_data,"diff in old_data")

	if #TextDiffCmd._clusters==0 then
		assert(#TextDiffCmd._oldlines==0)
		assert(#TextDiffCmd._newlines==0)
		for l,line in ipairs(old_lines) do
			new_lines[l]=line
		end
	else
		local function split_lines(lines)
			local buf=lines._buf lines._buf=nil
			-- fix bit error in "11","13"
			buf=buf:gsub("%(i%(i%(i%(i","\r\n\000\t\t\t}\r")
			for i,line in ipairs(lines)  do
				local offsetend=(lines[i+1] and lines[i+1]._offset) or #buf
				line._line=buf:sub(line._offset+1,offsetend):gsub("%z$","")
			end
			return lines
		end
--~ 		printf("==== before ====\n")
--~ 		ShowData('TextDiffCmd',TextDiffCmd)
		local oldlines=split_lines(TextDiffCmd._oldlines)
		local newlines=split_lines(TextDiffCmd._newlines)
--~  		printf("==== after ====\n")
--~  		ShowData('TextDiffCmd',TextDiffCmd)

		local countDelLines=0
		local countAddLines=0

		for _,cluster in ipairs(TextDiffCmd._clusters) do
			local old_lineno,new_lineno,cnt_lineno=cluster.oldL,cluster.newL,cluster.len
			assert(cnt_lineno>0)
			-- see TextDiffFileCmdExec
			if old_lineno==-1 then -- add new lines
--~ 				printf(">>>> insert line %d..%d\n",new_lineno,new_lineno+cnt_lineno-1)
				for i=1,cnt_lineno do
					countAddLines=countAddLines+1
					local newl=newlines[countAddLines]
					ASSERT_EQ("newl._lineNo==new_lineno+i-1",newl._lineNo,new_lineno+i-1)
					new_lines[newl._lineNo+1]=newl._line
				end
			elseif new_lineno==-1 then -- delete lines
--~ 				printf(">>>> delete line %d..%d\n",old_lineno,old_lineno+cnt_lineno-1)
				for i=1,cnt_lineno do
					countDelLines=countDelLines+1
					local oldl=oldlines[countDelLines]
					ASSERT_EQ("oldl._lineNo==old_lineno+i-1",oldl._lineNo,old_lineno+i-1)
					ASSERT_EQ("old_lines[oldl._lineNo+1]==oldl._line",old_lines[oldl._lineNo+1],oldl._line)
				end
			else -- move lines
--~ 				printf(">>>> Keep %d line %d..%d at %d..%d\n",cnt_lineno,
--~ 					old_lineno,old_lineno+cnt_lineno-1,
--~ 					new_lineno,new_lineno+cnt_lineno-1)
				for i=1,cnt_lineno do
					new_lines[new_lineno+i]=old_lines[old_lineno+i]
				end
			end
		end
	end

--~ 	ShowData('new_lines',new_lines,true)

	local new_data_joined=join(new_lines)
	save_file(filepath,new_data_joined)
	CheckNewCrcSum(TextDiffCmd,new_data_joined)
end

local function BinDiffFileExec(BinDiffCmd,filepath)
	printf("BinDiffFileExec(%q)\n",filepath)
--	ShowData('BinDiffCmd',BinDiffCmd)
	local old_data=load_file(filepath)
	CheckOldCrcSum(BinDiffCmd,old_data)

	local newLines=BinDiffCmd._newlines or error("no BinDiffCmd._newlines")
	local oldLines=BinDiffCmd._oldlines or error("no BinDiffCmd._oldlines")
	local buf=newLines._buf 
	newLines._buf=nil
	oldLines._buf=nil
--~ 	ShowData("BinDiffCmd",BinDiffCmd)
	local newData={}
	local newOffsets={}
	for _,cluster in ipairs(BinDiffCmd._clusters) do
		local oldOffset,newOffset,len=cluster.oldL,cluster.newL,cluster.len
		assert(len>0)
		if oldOffset~=-1 and newOffset~=-1 then -- matching block
--~ 			printf("copy(%d,%d,%d):%d\n",oldOffset,newOffset,len,newOffset+len)
			newData[newOffset]=old_data:sub(oldOffset+1,oldOffset+len)
			push(newOffsets,newOffset)
		else
--~ 			printf("skip(%d,%d,%d)\n",oldOffset,newOffset,len)
		end
	end
	table.sort(newOffsets)
--~ 	ShowData('newOffsets',newOffsets)

	local bufOffs=0
	local datOffs=0
	local newOffsetsIdx=1
	local newblobs={}
	local newOffset=newOffsets[newOffsetsIdx]

	while datOffs<BinDiffCmd._newFileSize do
--~ 		printf("idx %d datOffs=%d newOffset=%d\n",newOffsetsIdx,datOffs,newOffset)
		if datOffs<newOffset then
			local len=newOffset-datOffs
			local blk=buf:sub(bufOffs+1,bufOffs+len)
			assert(#blk==len)
--~ 			printf("new[%d]=%s\n",datOffs,hex(blk,40))
			push(newblobs,blk)
			datOffs=datOffs+len
			bufOffs=bufOffs+len
		elseif datOffs==newOffset then
			local blk=newData[newOffset]
			local len=#blk
--~ 			printf("old[%d]=%s\n",datOffs,hex(blk,40))
			push(newblobs,blk)
			datOffs=datOffs+len
			newOffsetsIdx=newOffsetsIdx+1
			newOffset=newOffsets[newOffsetsIdx]or BinDiffCmd._newFileSize
		else
			Error("corrupted data")
		end
	end
	local new_data_joined=join(newblobs)
	save_file(filepath,new_data_joined)
	CheckNewCrcSum(BinDiffCmd,new_data_joined)
end

mt_cmd.BinDiffFileExec=BinDiffFileExec
mt_cmd.TextDiffFileExec=TextDiffFileExec

