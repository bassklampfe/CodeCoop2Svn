# CodeCoop2Svn
CodeCoop2svn migrates source code repositories from Relisoft's Code Co-op® format  to the Svn-format while preserving the whole revision history.

It consists of a set of Lua-Scripts, which can be adapted to your requirements.

# Rationale

I'm involved in a programming project with a huge code base and history of 16 years
of code development.  This project was managed by Code Co-op®, a "Peer-to-peer 
Version Control for Distributed Development" by relisoft.
But more and more we ran into problems.

* There were some byte-errors in the binary data files 
  (cause is unclear, maybe by earlier crashes of co-op.exe)

* Export of old versions failed due memory leaks in co-op.exe

And although the distribution method of syncing via email is smart, these problems together with other restrictions
related to Code Co-op® brought us to the conclusion, that we have to switch to another system.
Because the collaboration between developers should be quite tight, we selected subversion in contrast to GIT.

Now the task was, how to migrate the data. I've started analyzing the data formats of the 
Code Co-op® repository files and went quite far, when we got the unexpected opportunity to retrieve
all the sources releated to Code Co-op® from the original author. My thanks goes to Bartosz Milewski, 
who granted us this access. Now it was possible to create a module to read the repository files and 
flushing them out as a bunch of subversion commands. 

The provided scripts replays the complete history of a Code Co-op® project, including generated branches.

Some special remarks.

* as a Code Co-op® branch always creates a new project in Code Co-op®, and not a branch inside a project,
  the same is done in subversion.

* each changeSet in Code Co-op® is identified by a so called scriptId. These are stored in subversion as 
  a revision property "coop:scriptid" for reference.

* it's possible to import multiple Code Co-op® projects into one repository. Benefit is, that multiple branches,
  which originated in the same base project, will merge correctly into one history tree. Disadvantage is, that revision numbers in subversion will not reflect the chronological order of the commits.
  To fix this there is provided an additional script (sort-svn-dump), which will reorder a svn-dump file to chronological order, keeping the "copy-from" informations correct.

* there are some special code-fragments, which work around the byte errors in the current project. These should do no harm to other projects.


# Prerequisites

* The database files of a  Code Co-op® repository.  Code Co-op® itself is not needed for the script to run.

* Windows. Although lua and subversion are also available on linux, issues with utf8 will complicate the situation, when scripts are run on linux. This is not supported for now.

* A subversion commandline client. We have used the one which comes with Tortoise-SVN

* A lua installation. We have used LuaForWindows_v5.1.4-48.exe

* For better performance you can also use luajit, we have verified the distribution of https://luapower.com/ to do the work.



# How to use


Make a copy of Usage-Example.lua.
Change all Variables before "-- working code" to your needs.
Run the script.

After successfull completion you should find a subversion repository with all the history of the selected projects.

WARNING: The SVN_PROJECT_DIR may grow quite large, because subversion not cleares unused pristine copy by default.
You can drop this folder when the script has run and then checkout the unpolluted projects.

You can also enter a remote URL at SVN_REPOS_URL as "https://svn.somewhere.org/repos/somewhere", but be warned.
You may need to restart the script several times, until all configuration issues are fixes and simply removing 
a local SVN_REPOS_DIR and restarting the script is much simpler than removing and setting up a new remote repository each time.

When the script finally succeeded, you can always make a dump of the local repository and load it to the remote server.





Known Bugs :
============

* **ISSUE:** When merging multiple branched projects into one subversion repository, then you have to 
import the "most often branched" project before importing the "less often branched". Else the script will fail with chechsum errors.
<br>
**HOWTOFIX:** the initial checkout of a branch should provide the revision number to check out.

* **ISSUE:** When running the scripts on linux, not all issues with utf8-conversions are fixed.
<br>
**HOWTOFIX:** converting commments and filenames from/to utf8 must be reviewed on linux systems

* **ISSUE:** Reading commands of very early versions of Code Co-op® are not implemented and will result in `"FIXME: xxx version<nn"` errors.
<br>
**HOWTOFIX:** implement, whats missing ;-)

* **ISSUE:** Memory limits. We have successfully converted a database of ~155 MB. Somewhere above that lua will run into an out of memory error.
<br>
**HOWTOFIX:** instead of reading the complete 'HIST' chunk into memory with all references to CmdLog and NoteLog, change the approach to iterating over the HIST chunk.
By doing this only one changeSet is held in memory at any time and there should be no limits on the data.bin size, which can be processed.

* **ISSUE:** The scripts are fairly bad commented.
<br>
**HOWTOFIX:** complete the comments ;-)
