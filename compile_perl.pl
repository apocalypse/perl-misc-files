#!/usr/bin/perl
use strict; use warnings;

# make sure we already installed all the distro libraries we need
# e.x. libncurses, libgtk, etc via apt-get or emerge or whatever
# it's a LOT of libs and some stupid wrangling...

# We have successfully compiled those perl versions:
# 5.6.0, 5.6.1, 5.6.2
# 5.8.0, 5.8.1, 5.8.2, 5.8.3, 5.8.4, 5.8.5, 5.8.6, 5.8.7, 5.8.8, 5.8.9
# 5.10.0 5.10.1

# TODO?
# CPANPLUS won't work on 5.6.0, also some modules we want to install doesn't like 5.6.x :(
#<Apocalypse> Yeah wish me luck, last year I managed to get 5.6.0 built but couldn't get CPANPLUS to install on it
#<Apocalypse> Maybe the situation is better now - I'm working downwards so I'll hit 5.6.X sometime later tonite after I finish 5.8.5, 5.8.4, and so on :)
#<@kane> 5.6.1 is the minimum
#<Apocalypse> Ah, so CPANPLUS definitely won't work on 5.6.0? I should just drop it...

# this script does everything, but we need some layout to be specified!
# /home/apoc/perl				<-- the main directory
# /home/apoc/perl/CPANPLUS.config		<-- the default CPANPLUS config
# /home/apoc/perl/CPAN.config			<-- the default CPAN config
# /home/apoc/perl/CPANPLUS-Boxed.config		<-- the default CPANPLUS::Boxed config
# /home/apoc/perl/minicpan			<-- the minicpan sources for CPANPLUS to use
# /home/apoc/perl/CPANPLUS-0.XX			<-- the extracted CPANPLUS directory we use
# /home/apoc/perl/build				<-- where we store our perl builds + tarballs
# /home/apoc/perl/build/perl-5.6.2.tar.gz	<-- one perl tarball
# /home/apoc/perl/build/perl-5.6.2		<-- one extracted perl build
# /home/apoc/perl/perl-5.6.2			<-- finalized perl install
# /home/apoc/perl/compile_perl.pl		<-- where this script should be

# load our dependencies
use Capture::Tiny qw( capture_merged tee_merged );
use Prompt::Timeout;
use Sort::Versions;

# static var...
my $CPANPLUS_ver = "0.88";
my $PATH = "/home/$ENV{USER}/perl";
my $perlver;
my $DEBUG = 0;

# get our perl tarballs
my $perls = getPerlVersions();

# ask user for debugging
prompt_debug();

# prompt user for perl version to compile
my $res = prompt_perlver();

if ( $res ne 'a' ) {
	# do the stuff!
	make_perl( $res );
} else {
	# loop through all versions, starting from newest to oldest
	foreach my $p ( reverse @$perls ) {
		make_perl( $p );
	}
}

# all done!
exit 0;

sub prompt_debug {
	my $res = prompt( "Turn on debugging", 'y', 10, 1 );
	if ( lc( $res ) eq 'y' ) {
		$DEBUG = 1;
	}

	return;
}

# prompt the user for perl version
sub prompt_perlver {
	my $res;
	while ( ! defined $res ) {
		$res = prompt( "Which perl version to compile [ver/d/a]", $perls->[-1], 10, 1 );
		if ( lc( $res ) eq 'd' ) {
			# display available versions
			print "Available Perls: " . join( ' ', @$perls ) . "\n";
			$res = undef;
		} elsif ( lc( $res ) eq 'a' ) {
			return $res;
		} else {
			# make sure the version exists
			if ( ! grep { $_ eq $res } @$perls ) {
				print "Selected version doesn't exist, please try again.\n";
				$res = undef;
			} else {
				return $res;
			}
		}
	}

	return;
}

# gets the perls
sub getPerlVersions {
	my @perls;
	opendir( PERLS, $PATH . '/build' ) or die "unable to opendir: $@";
	@perls = sort versioncmp map { $_ =~ /^perl\-([\d\.]+)\./; $_ = $1; } grep { /^perl\-/ && -f "$PATH/build/$_"  } readdir( PERLS );
	closedir( PERLS ) or die "unable to closedir: $@";

	return \@perls;
}

sub make_perl {
	my $perl = shift;
	$perlver = $perl;

	# have we already compiled+installed this version?
	if ( ! -d "perl-$perlver" ) {
		# kick off the build process!
		do_build();
	} else {
		# all done with configuring?
		if ( -e "perl-$perlver/ready.smoke" ) {
			print "[COMPILER] Perl-$perlver is already configured...\n";
			return;
		} else {
			print "[COMPILER] Perl-$perlver is already built...\n";
		}
	}

	# do we have CPANPLUS already extracted?
	do_initCPANP_BOXED();

	# we go ahead and configure CPANPLUS for this version :)
	do_installCPANPLUS();

	# configure CPAN for this version :)
	# TODO we forget about CPAN for now, because it is unnecessary and keeps blowing up Term::ReadLine::Perl somehow...
	#do_installCPAN();

	# move on with the test stuff
	do_installCPANTesters();

	# finally, install our POE stuff
	#do_installPOE();

	# finalize the perl install!
	finalize_perl();
}

sub finalize_perl {
	# thanks to BiNGOs for the idea!
	foreach my $dir ( qw( man lib bin ) ) {
		do_shellcommand( "sudo chown -R root:root perl-$perlver/$dir" );
	}

	# we're really done!
	do_shellcommand( "touch perl-$perlver/ready.smoke" );
}

sub do_prebuild {
	if ( ! -f "build/perl-$perlver.tar.gz" ) {
		# TODO auto download of tarball
		die "Perl version $perlver tarball isn't found in build/ directory";
	}
	if ( -d "build/perl-$perlver" ) {
		# remove it so we have a consistent build process
		do_shellcommand( "rm -rf build/perl-$perlver" );
	}

	# extract the tarball!
	do_shellcommand( "tar -C build -zxf build/perl-$perlver.tar.gz" );

	# now, apply the patches each version needs
	do_prebuild_patches();
}

sub do_initCPANP_BOXED {
	print "[COMPILER] Configuring CPANPLUS::Boxed...\n";

	# we need CPANPLUS already configured on the host...
#	eval { require CPANPLUS };
#	if ( $@ ) {
#		die "CPANPLUS is not configured on the host!";
#	}

	# do we have CPANPLUS already extracted?
	if ( -d "CPANPLUS-$CPANPLUS_ver" ) {
		# just get rid of it
		do_shellcommand( "rm -rf CPANPLUS-$CPANPLUS_ver" );
	}

	# do we have the tarball?
	if ( ! -f "CPANPLUS-$CPANPLUS_ver.tar.gz" ) {
		# get it!
		do_shellcommand( "wget http://search.cpan.org/CPAN/authors/id/K/KA/KANE/CPANPLUS-$CPANPLUS_ver.tar.gz" );
	}

	# extract it!
	do_shellcommand( "tar -zxf CPANPLUS-$CPANPLUS_ver.tar.gz" );

	# configure the Boxed Config settings
	# TODO too lazy to use proper modules heh
	do_shellcommand( "cp -f CPANP-Boxed.config Boxed.pm" );
	do_shellcommand( "perl -pi -e 's/XXXCPANPLUSXXX/$CPANPLUS_ver/' Boxed.pm" );
	do_shellcommand( "perl -pi -e 's/XXXUSERXXX/$ENV{USER}/' Boxed.pm" );
	do_shellcommand( "mkdir -p CPANPLUS-$CPANPLUS_ver/.cpanplus/$ENV{USER}/lib/CPANPLUS/Config" );
	do_shellcommand( "mv Boxed.pm CPANPLUS-$CPANPLUS_ver/.cpanplus/$ENV{USER}/lib/CPANPLUS/Config/Boxed.pm" );

	# force an update
	do_cpanp_install( "x --update_source" );
}

sub do_installCPANPLUS {
	print "[COMPILER] Configuring CPANPLUS...\n";

	# TODO Net::DNS fails it's test, so annoying!
	# TODO Term::ReadLine::Perl prompts for input... skip it's test!
	do_cpanp_install( "i Net::DNS Term::ReadLine::Perl --skiptest" );

	# use cpanp-boxed to install some modules that we know we need to bootstrap, argh!
	# perl-5.6.1 -> ExtUtils::MakeMaker, Test::More, File::Temp, Time::HiRes
	# Module::Build -> ExtUtils::CBuilder, ExtUtils::ParseXS
	# Module::Signature -> Digest::SHA ( fucking AutoInstall! )
	# LWP on perl-5.8.2 bombs on Encode
	do_cpanp_install( "i ExtUtils::MakeMaker ExtUtils::CBuilder ExtUtils::ParseXS Test::More File::Temp Time::HiRes Digest::SHA Encode" );

	# run the cpanp-boxed script and tell it to bootstrap it's dependencies
	do_cpanp_install( "s selfupdate dependencies" );
	do_cpanp_install( "s selfupdate enabled_features" );

	# finally, install CPANPLUS!
	do_cpanp_install( "i Bundle::CPANPLUS CPANPLUS" );

	# configure the installed CPANPLUS
	# TODO too lazy to use proper modules heh
	# Configuration successfully saved to CPANPLUS::Config::User
	#    (/home/apoc/perl/perl-5.10.0/.cpanplus/lib/CPANPLUS/Config/User.pm)
	do_shellcommand( "cp -f CPANPLUS.config User.pm" );
	do_shellcommand( "perl -pi -e 's/XXXPERLVERXXX/$perlver/' User.pm" );
	do_shellcommand( "perl -pi -e 's/XXXUSERXXX/$ENV{USER}/' User.pm" );
	do_shellcommand( "mkdir -p /home/$ENV{USER}/perl/perl-$perlver/.cpanplus/lib/CPANPLUS/Config" );
	do_shellcommand( "mv User.pm /home/$ENV{USER}/perl/perl-$perlver/.cpanplus/lib/CPANPLUS/Config/User.pm" );

	# force an update
	# we don't use do_cpanp_install() here because we need to use the perl's CPANPLUS config not the boxed one...
	do_shellcommand( "APPDATA=/home/$ENV{USER}/perl/perl-$perlver/ /home/$ENV{USER}/perl/perl-$perlver/bin/perl /home/$ENV{USER}/perl/perl-$perlver/bin/cpanp x --update_source" );
}

sub do_cpanp_install {
	my $modules = shift;
	return if ! defined $modules;

	# use default answer to prompts ( MakeMaker stuff - PERL_MM_USE_DEFAULT )
	# TODO check output to see if modules were installed OK
	do_shellcommand( "PERL_MM_USE_DEFAULT=1 /home/$ENV{USER}/perl/perl-$perlver/bin/perl CPANPLUS-$CPANPLUS_ver/bin/cpanp-boxed $modules" );
}

sub do_installCPAN {
	print "[COMPILER] Configuring CPAN...\n";

	# finally, install CPAN!
	do_cpanp_install( "i Bundle::CPAN CPAN" );

	# configure the installed CPAN
	# TODO too lazy to use proper modules heh
	# commit: wrote '/home/apoc/perl/perl-5.10.0/lib/5.10.0/CPAN/Config.pm'
	do_shellcommand( "cp -f CPAN.config Config.pm" );
	do_shellcommand( "perl -pi -e 's/XXXPERLVERXXX/$perlver/' Config.pm" );
	do_shellcommand( "perl -pi -e 's/XXXUSERXXX/$ENV{USER}/' Config.pm" );
	do_shellcommand( "mkdir -p /home/$ENV{USER}/perl/perl-$perlver/lib/$perlver/CPAN" );
	do_shellcommand( "mv Config.pm /home/$ENV{USER}/perl/perl-$perlver/lib/$perlver/CPAN/Config.pm" );
}

sub do_installCPANTesters {
	print "[COMPILER] Configuring CPANTesters...\n";

	# install the basic modules we need
	do_cpanp_install( "i Test::Reporter CPANPLUS::YACSmoke" );
}

sub do_installPOE {
	# install POE's dependencies!
	# The ExtUtils modules are for Glib, which doesn't specify it in the "normal" way, argh!
	do_cpanp_install( "i Test::Pod Test::Pod::Coverage Socket6 Time::HiRes Term::ReadKey Term::Cap IO::Pty URI LWP Module::Build Curses ExtUtils::Depends ExtUtils::PkgConfig" );

	# install POE itself to pull in some more stuff
	do_cpanp_install( "i POE" );

	# install our POE loops + their dependencies
	my $loop_install = "";
	my $poe_loop_install = "";
	foreach my $loop ( qw( Event Tk Gtk Wx Prima IO::Poll Glib EV ) ) {
		# skip problematic loops
		if ( $perlver =~ /^5\.6\./ and ( $loop eq 'Tk' or $loop eq 'Wx' or $loop eq 'Event' or $loop eq 'Glib' ) ) {
			next;
		}

		$loop_install .= " $loop";

		# stupid differing loops
		my $poeloop = $loop;
		$poeloop =~ s/\:\:/\_/g;
		$poe_loop_install .= " POE::Loop::$poeloop";
	}

	# actually install!
	do_cpanp_install( "i $loop_install" );
	do_cpanp_install( "i $poe_loop_install" );
}

sub do_shellcommand {
	my $cmd = shift;

	print "[COMPILER] Executing $cmd\n";
	my $output;
	if ( $DEBUG ) {
		$output = tee_merged { system( $cmd ) };
	} else {
		$output = capture_merged { system( $cmd ) };
	}
	my @output = split( /\n/, $output );
	return \@output;
}

sub do_build {
	# do prebuild stuff
	do_prebuild();

	# we start off with the Configure step
	my $extraoptions = '';
	if ( $perlver =~ /^5\.6\./ ) {
		# disable DB_File support ( buggy )
		$extraoptions .= '-Ui_db';
	} elsif ( $perlver =~ /^5\.8\./ ) {
		# disable DB_File support ( buggy )
		$extraoptions .= '-Ui_db';
	}

	# actually do the configure!
	do_shellcommand( "cd build/perl-$perlver; sh Configure -des -Dprefix=/home/$ENV{USER}/perl/perl-$perlver $extraoptions" );

	# some versions need extra patching after the Configure part :(
	do_premake_patches();

	# generate dependencies - not needed because Configure -des defaults to automatically doing it
	#do_shellcommand( "cd build/perl-$perlver; make depend" );

	# actually compile!
	my $output = do_shellcommand( "cd build/perl-$perlver; make" );
	if ( $output->[-1] !~ /to\s+run\s+test\s+suite/ ) {
		die "Unable to Compile perl-$perlver!\n";
	}

	# make sure we pass tests
	$output = do_shellcommand( "cd build/perl-$perlver; make test" );
	if ( ! grep { /^All\s+tests\s+successful\.$/ } @$output ) {
		# Is it ok to proceed?
		if ( ! check_perl_test( $output ) ) {
			die "Testsuite failed!";
		}
	}

	# okay, do the install!
	do_shellcommand( "cd build/perl-$perlver; make install" );

	# cleanup the build dir ( lots of space! )
	do_shellcommand( "cd build/; rm -rf perl-$perlver" );

	# all done!
	print "[COMPILER] Installed perl-$perlver successfully!\n";
}

# checks for "allowed" test failures ( known problems )
sub check_perl_test {
	my $output = shift;

	# TODO argh, file::find often fails, need to track down why it happens
	if ( grep { /^Failed\s+1\s+test/ } @$output and grep { m|^lib/File/Find/t/find\.+FAILED| } @$output ) {
		print "[COMPILER] Detected File::Find test failure, ignoring it...\n";
		return 1;
	}

	# 5.8.8 has known problems with sprintf.t and sprintf2.t
	#t/op/sprintf..............................FAILED--no leader found
	#t/op/sprintf2.............................FAILED--expected 263 tests, saw 3
	if ( $perlver eq '5.8.8' and grep { /^Failed\s+2\s+test/ } @$output and grep { m|^t/op/sprintf\.+FAILED| } @$output ) {
		print "[COMPILER] Detected sprintf test failure on 5.8.8, ignoring it...\n";
		return 1;
	}

	# Unknown failure!
	return 0;
}

sub do_premake_patches {
	# do we need to do anything?
}

sub do_prebuild_patches {
	# okay, what version is this?
	if ( $perlver =~ /^5\.8\.(\d+)$/ ) {
		my $v = $1;
		if ( $v == 0 or $v == 1 or $v == 2 or $v == 3 or $v == 4 or $v == 5 or $v == 6 or $v == 7 or $v == 8 ) {
			# fix asm/page.h error
			patch_asmpageh();

			patch_makedepend_escape();

			patch_makedepend_cleanups_580();
		}
	} elsif ( $perlver =~ /^5\.6\.(\d+)$/ ) {
		my $v = $1;

		# fix asm/page.h error
		patch_asmpageh();

		# the Configure script is buggy in detecting signals
		patch_Configure_signals();

		patch_makedepend_escape();
		if ( $v == 2 ) {
			patch_makedepend_cleanups_562();
		} elsif ( $v == 1 ) {
			patch_makedepend_addcleanups_561();
		} elsif ( $v == 0 ) {
			patch_makedepend_addcleanups_560();
		}
	}
}

sub do_patch {
	my( $patchdata ) = @_;

	# okay, apply it!
	open( my $patch, '>', "build/perl-$perlver/patch.diff" ) or die "unable to create patchfile: $@";
	print $patch $patchdata;
	close( $patch );
	do_shellcommand( "patch -p0 -d build/perl-$perlver < build/perl-$perlver/patch.diff" );
	unlink("build/perl-$perlver/patch.diff") or die "unable to unlink patchfile: $@";
	return 1;
}

sub patch_asmpageh {
	# from http://www.nntp.perl.org/group/perl.perl5.porters/2007/08/msg127609.html
	# updated from http://www.nntp.perl.org/group/perl.perl5.porters/2009/03/msg145182.html
	my $data = <<'EOF';
--- ext/IPC/SysV/SysV.xs.orig	2009-11-14 21:27:40.668648136 -0700
+++ ext/IPC/SysV/SysV.xs	2009-11-14 21:29:06.180359572 -0700
@@ -3,9 +3,6 @@
#include "XSUB.h"

#include <sys/types.h>
-#ifdef __linux__
-#   include <asm/page.h>
-#endif
#if defined(HAS_MSG) || defined(HAS_SEM) || defined(HAS_SHM)
#ifndef HAS_SEM
#   include <sys/ipc.h>
@@ -21,7 +18,10 @@
#      ifndef HAS_SHMAT_PROTOTYPE
	extern Shmat_t shmat (int, char *, int);
#      endif
-#      if defined(__sparc__) && (defined(__NetBSD__) || defined(__OpenBSD__))
+#      if defined(HAS_SYSCONF) && defined(_SC_PAGESIZE)
+#          undef  SHMLBA /* not static: determined at boot time */
+#          define SHMLBA sysconf(_SC_PAGESIZE)
+#      elif defined(HAS_GETPAGESIZE)
#          undef  SHMLBA /* not static: determined at boot time */
#          define SHMLBA getpagesize()
#      endif
EOF

	# okay, apply it!
	return do_patch( $data );
}

sub patch_makedepend_cleanups_562 {
	# from http://perl5.git.perl.org/perl.git/commitdiff/2bce232
	my $data = <<'EOF';
--- makedepend.SH.orig
+++ makedepend.SH
@@ -163,6 +163,7 @@
	-e '/^#.*<builtin>/d' \
	-e '/^#.*<built-in>/d' \
	-e '/^#.*<command line>/d' \
+	    -e '/^#.*<command-line>/d' \
	-e '/^#.*"-"/d' \
	-e 's#\.[0-9][0-9]*\.c#'"$file.c#" \
	-e 's/^[     ]*#[    ]*line/#/' \
EOF

	# okay, apply it!
	return do_patch( $data );
}

sub patch_makedepend_cleanups_580 {
	# from http://perl5.git.perl.org/perl.git/commitdiff/2bce232
	my $data = <<'EOF';
--- makedepend.SH.orig
+++ makedepend.SH
@@ -157,6 +157,7 @@
	-e '/^#.*<builtin>/d' \
	-e '/^#.*<built-in>/d' \
	-e '/^#.*<command line>/d' \
+            -e '/^#.*<command-line>/d' \
	-e '/^#.*"-"/d' \
	-e '/: file path prefix .* never used$/d' \
	-e 's#\.[0-9][0-9]*\.c#'"$file.c#" \
EOF

	# okay, apply it!
	return do_patch( $data );
}

sub patch_makedepend_addcleanups_561 {
	# from http://perl5.git.perl.org/perl.git/commitdiff/2bce232
	my $data = <<'EOF';
--- makedepend.SH.orig
+++ makedepend.SH
@@ -154,6 +154,10 @@
	$cppstdin $finc -I. $cppflags $cppminus <UU/$file.c |
	$sed \
	-e '1d' \
+	    -e '/^#.*<builtin>/d' \
+	    -e '/^#.*<built-in>/d' \
+	    -e '/^#.*<command line>/d' \
+	    -e '/^#.*<command-line>/d' \
	-e '/^#.*<stdin>/d' \
	-e '/^#.*"-"/d' \
	-e 's#\.[0-9][0-9]*\.c#'"$file.c#" \
EOF

	# okay, apply it!
	return do_patch( $data );
}

sub patch_makedepend_addcleanups_560 {
	# from http://perl5.git.perl.org/perl.git/commitdiff/2bce232
	my $data = <<'EOF';
--- makedepend.SH.orig
+++ makedepend.SH
@@ -136,6 +136,10 @@
$cppstdin $finc -I. $cppflags $cppminus <UU/$file.c |
$sed \
	-e '1d' \
+	-e '/^#.*<builtin>/d' \
+	-e '/^#.*<built-in>/d' \
+	-e '/^#.*<command line>/d' \
+	-e '/^#.*<command-line>/d' \
	-e '/^#.*<stdin>/d' \
	-e '/^#.*"-"/d' \
	-e 's#\.[0-9][0-9]*\.c#'"$file.c#" \
EOF

	# okay, apply it!
	return do_patch( $data );
}

sub patch_makedepend_escape {
	# from http://perl5.git.perl.org/perl.git/commitdiff/a9ff62c8
	my $data = <<'EOF';
--- makedepend.SH.orig
+++ makedepend.SH
@@ -126,7 +126,7 @@
     *.y) filebase=`basename $file .y` ;;
esac
case "$file" in
-    */*) finc="-I`echo $file | sed 's#/[^/]*$##`" ;;
+    */*) finc="-I`echo $file | sed 's#/[^/]*$##'`" ;;
     *)   finc= ;;
esac
$echo "Finding dependencies for $filebase$_o."
EOF

	# okay, apply it!
	return do_patch( $data );
}

sub patch_Configure_signals {
	# <Apocalypse> The following 1 signals are available: SIGZERO
	# <Apocalypse> funny heh
	# <Apocalypse> /usr/bin/sort: open failed: +1: No such file or directory
	# <Bram> Hmm. That could be a problem with a newer version of sort.. I remember seeing a Change of it a long time ago but again don't fully remember...
	# <Bram> In Configure (on 5.6.1): replace the first  $sort -n +1  with:  ($sort -n -k 2 2>/dev/null || $sort -n +1) |\  and the second with  $sort -n
	my $data = <<'EOF';
--- Configure.orig
+++ Configure
@@ -14249,7 +14249,7 @@

set signal
if eval $compile_ok; then
-	./signal$_exe | $sort -n +1 | $uniq | $awk -f signal.awk >signal.lst
+	./signal$_exe | ($sort -n -k 2 2>/dev/null || $sort -n +1) | $uniq | $awk -f signal.awk >signal.lst
else
	echo "(I can't seem be able to compile the whole test program)" >&4
	echo "(I'll try it in little pieces.)" >&4
@@ -14283,7 +14283,7 @@
	done
	if $test -s signal.ls1; then
		$cat signal.nsg signal.ls1 |
-			$sort -n +1 | $uniq | $awk -f signal.awk >signal.lst
+			$sort -n | $uniq | $awk -f signal.awk >signal.lst
	fi

fi
EOF

	# apply it!
	return do_patch( $data );
}
