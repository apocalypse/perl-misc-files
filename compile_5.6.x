<Apocalypse> ah MUCH better, before I was failing tons of tests now all passed :)
<Apocalypse> I should write down everything I did and blog it somewhere heh
<Apocalypse> A lot of tiny things to fix...
<Bram> Can you create a patch for it and mail it to me?
<Apocalypse> for 5.6.1 or 2? I'm compiling them both here
<Bram> When I have time I will take a look at  buildaperl  (from Perl::Repository::APC)  to see if the patch can be integrated there.
<Bram> Both if you don't mind
<Apocalypse> ah thats cool
<Apocalypse> sure I'll email it to ya - what address?
<Bram> p5p@perl.wizbit.be


http://www.nntp.perl.org/group/perl.perl5.porters/2007/08/msg127609.html
	to fix the asm/page.h error

http://perl5.git.perl.org/perl.git/commitdiff/2bce232
http://perl5.git.perl.org/perl.git/commitdiff/a9ff62c8
	to fix configure problems
	be sure to remove all instances of "command-line" and "built-in" in the makefile

also use -Ui_db argument to sh Configure so we disable DB_File

<Apocalypse> The following 1 signals are available: SIGZERO
<Apocalypse> funny heh
<Apocalypse> /usr/bin/sort: open failed: +1: No such file or directory
<Bram> Hmm. That could be a problem with a newer version of sort.. I remember seeing a Change of it a long time ago but again don't fully remember...
<Bram> In Configure (on 5.6.1): replace the first  $sort -n +1  with:  ($sort -n -k 2 2>/dev/null || $sort -n +1) |\  and the second with  $sort -n
	do that to fix signal problem

on windows, hack Test::Harness to use Win32::Autoglob for t/*.t goodness!

