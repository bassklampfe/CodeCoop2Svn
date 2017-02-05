#!/usr/bin/lua
require"strict"
require"utils"
require"CodeCoop2Svn"

--============================================================
-- global settings
--============================================================


--============================================================
-- Define working directories
-- SVN_REPOS_DIR     folder, where to create local repository
-- SVN_PROJECT_DIR   working directory for the "living" project data
-- SVN_REPOS_URL     URL for the client commands
-- COOP_DATABASE_DIR folder, where codecoop projects are stored
-- COOP_PROJECTS     list of project, which are to migrated
--
local SVN_REPOS_DIR="c:/SVN/coopexport"
local SVN_PROJECT_DIR="c:/temp/coopexport-projects"
local SVN_REPOS_URL="file:///"..SVN_REPOS_DIR

local COOP_DATABASE_DIR="c:/CodeCoop/Database"
local COOP_PROJECTS={"1","3","9","4"}


--============================================================
-- this table defines Comment fixes
-- this is required when the same project name was used
-- in different braches
-- "Original Coop comment" => "Modified Comment with changed branch name"
-- if unneeded then leave empty
--
local COMMENT_FIXES=
{
	["Branch 'ProjectA' created Sat Sep 17 13:00:28 2005"]=
	"Branch 'ProjectA-2005' created Sat Sep 17 13:00:28 2005",
	["Branch 'ProjectA' created Sun, 22.08.2010 17:27:45"]=
	"Branch 'ProjectA-2010' created Sun, 22.08.2010 17:27:45",
}

--============================================================
-- this table defines username replacements
-- "Code Co-Op username" => "svn username"
-- if unneeded then leave empty
local SVN_USERS=
{
	["John Doe"]="john",
	["Otto Beispiel"]="otto",
}



--============================================================
-- working code
--============================================================
--
-- prepare subversion repository if not exists
-- this only works for local repositories
-- comment out, if using remote repository (not recommended)
--

if not isfile(SVN_REPOS_DIR.."/format") then
	printf("====== CREATE EMPRY REPOSITORY ======\n")
	lfs.mkdir(SVN_REPOS_DIR)
	assert(execute_cmd("svnadmin create %q",SVN_REPOS_DIR))
	save_file(SVN_REPOS_DIR.."/hooks/pre-revprop-change.bat","@echo off\r\n")
end

--
-- publish relevant data to the script
--
SetSvnData
{
	SVN_REPOS_DIR=SVN_REPOS_DIR,
	SVN_PROJECT_DIR=SVN_PROJECT_DIR,
	SVN_REPOS_URL=SVN_REPOS_URL,
	COMMENT_FIXES=COMMENT_FIXES,
	SVN_USERS=SVN_USERS,
}

--
-- import project by project
--
for _,project in ipairs(COOP_PROJECTS) do
	CodeCoop2Svn(COOP_DATABASE_DIR.."/"..project)
end
